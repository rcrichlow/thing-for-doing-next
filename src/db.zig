//! Application-owned PostgreSQL client API.
//!
//! The API is deliberately shaped after pg.zig (Pool/Conn/Result/Row, `exec`,
//! `query`, `row`, `row.get(T, col)`, `error.PG` with details in `conn.err`) so
//! the implementation can be swapped without touching callers. Callers must not
//! import `db/libpq.zig`.
//!
//! Current implementation: libpq, synchronous, text format for parameters and
//! results. libpq calls block the calling OS thread and are not Io cancelation
//! points, which is acceptable on `Io.Threaded` where each task has a thread.

const std = @import("std");
const libpq = @import("db/libpq.zig");
const c = libpq.c;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.db);

pub const Error = error{
    /// PostgreSQL reported an error; details are in `Conn.err`.
    PG,
    /// The connection could not be established or was lost.
    ConnectionFailed,
    /// A string parameter contained a NUL byte, which PostgreSQL text cannot hold.
    InvalidParameter,
    /// `Conn.row` matched more than one row.
    MoreThanOneRow,
    /// The server returned a result kind this client does not handle (e.g. COPY).
    UnsupportedResult,
    OutOfMemory,
};

pub const ReadError = error{
    ColumnOutOfRange,
    /// A non-optional type was requested for a NULL value.
    UnexpectedNull,
    /// The requested Zig type does not match the column's PostgreSQL type.
    ColumnTypeMismatch,
    /// The server's text representation could not be parsed as the requested type.
    InvalidColumnValue,
};

/// Details of an error reported by PostgreSQL. Slices are valid until the next
/// operation on, or release of, the connection that produced it.
pub const PgError = struct {
    /// SQLSTATE, e.g. "23505". Empty if the server did not provide one.
    code: []const u8,
    severity: []const u8,
    message: []const u8,
    detail: ?[]const u8,
    constraint: ?[]const u8,

    pub fn isUnique(err: PgError) bool {
        return std.mem.eql(u8, err.code, "23505");
    }

    pub fn isCheckViolation(err: PgError) bool {
        return std.mem.eql(u8, err.code, "23514");
    }
};

/// A fixed-size pool of connections, all opened eagerly by `init`. Broken
/// connections are reset when next acquired rather than in the background.
pub const Pool = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    available_cond: Io.Condition = .init,
    conns: []*Conn,
    available: usize,

    pub const Options = struct {
        /// libpq connection string or `postgresql://` URI.
        url: [:0]const u8,
        size: usize,
    };

    pub fn init(io: Io, gpa: Allocator, options: Options) Error!*Pool {
        std.debug.assert(options.size > 0);
        const pool = try gpa.create(Pool);
        errdefer gpa.destroy(pool);
        const conns = try gpa.alloc(*Conn, options.size);
        errdefer gpa.free(conns);

        var opened: usize = 0;
        errdefer for (conns[0..opened]) |conn| conn.deinit();
        while (opened < options.size) : (opened += 1) {
            conns[opened] = try Conn.open(gpa, options.url);
            conns[opened].pool = pool;
        }

        pool.* = .{ .io = io, .gpa = gpa, .conns = conns, .available = options.size };
        return pool;
    }

    /// Asserts every connection has been released.
    pub fn deinit(pool: *Pool) void {
        std.debug.assert(pool.available == pool.conns.len);
        for (pool.conns) |conn| conn.deinit();
        pool.gpa.free(pool.conns);
        pool.gpa.destroy(pool);
    }

    /// Waits for a free connection. Callers should hold at most one at a time;
    /// with the pool sized to the task limit, waiting then never happens.
    pub fn acquire(pool: *Pool) (Error || Io.Cancelable)!*Conn {
        try pool.mutex.lock(pool.io);
        while (pool.available == 0) {
            pool.available_cond.wait(pool.io, &pool.mutex) catch |err| {
                pool.mutex.unlock(pool.io);
                return err;
            };
        }
        pool.available -= 1;
        const conn = pool.conns[pool.available];
        pool.mutex.unlock(pool.io);

        conn.ensureConnected() catch |err| {
            pool.release(conn);
            return err;
        };
        return conn;
    }

    pub fn release(pool: *Pool, conn: *Conn) void {
        conn.prepareForReuse();
        pool.mutex.lockUncancelable(pool.io);
        pool.conns[pool.available] = conn;
        pool.available += 1;
        pool.mutex.unlock(pool.io);
        pool.available_cond.signal(pool.io);
    }
};

pub const Conn = struct {
    pg: *c.PGconn,
    gpa: Allocator,
    pool: ?*Pool = null,
    /// Set when an operation returns `error.PG`; cleared by the next operation.
    err: ?PgError = null,
    /// Owns the memory behind `err`.
    err_result: ?*c.PGresult = null,
    /// Holds encoded parameters for the current operation.
    scratch: std.heap.ArenaAllocator,

    /// Opens a standalone connection. Prefer `Pool`.
    pub fn open(gpa: Allocator, url: [:0]const u8) Error!*Conn {
        // With expand_dbname, `dbname` may be a URI or connection string whose
        // settings override the defaults listed before it.
        const keywords = [_][*c]const u8{ "connect_timeout", "application_name", "dbname", null };
        const values = [_][*c]const u8{ "10", "thing-for-doing-next", url.ptr, null };
        const pg = c.PQconnectdbParams(&keywords, &values, 1) orelse return error.OutOfMemory;
        if (c.PQstatus(pg) != c.CONNECTION_OK) {
            log.err("connecting to PostgreSQL failed: {s}", .{connErrorMessage(pg)});
            c.PQfinish(pg);
            return error.ConnectionFailed;
        }
        _ = c.PQsetNoticeProcessor(pg, logNotice, null);

        const conn = gpa.create(Conn) catch {
            c.PQfinish(pg);
            return error.OutOfMemory;
        };
        conn.* = .{ .pg = pg, .gpa = gpa, .scratch = .init(gpa) };
        return conn;
    }

    /// Closes a connection. Pooled connections are closed by `Pool.deinit`.
    pub fn deinit(conn: *Conn) void {
        conn.clearError();
        conn.scratch.deinit();
        c.PQfinish(conn.pg);
        conn.gpa.destroy(conn);
    }

    /// Returns a pooled connection to its pool.
    pub fn release(conn: *Conn) void {
        if (conn.pool) |pool| pool.release(conn);
    }

    /// Runs a statement and returns the number of affected rows, if the
    /// command reports one. Without arguments, `sql` may contain several
    /// statements separated by semicolons.
    pub fn exec(conn: *Conn, sql: [:0]const u8, args: anytype) Error!?i64 {
        const result = try conn.run(sql, args);
        defer c.PQclear(result);
        const affected = std.mem.span(c.PQcmdTuples(result));
        if (affected.len == 0) return null;
        return std.fmt.parseInt(i64, affected, 10) catch null;
    }

    /// Runs a query. `deinit` must be called on the result.
    pub fn query(conn: *Conn, sql: [:0]const u8, args: anytype) Error!Result {
        const result = try conn.run(sql, args);
        return .{
            .pg = result,
            .row_count = @intCast(c.PQntuples(result)),
            .number_of_columns = @intCast(c.PQnfields(result)),
        };
    }

    /// Runs a query expected to return at most one row. Returns
    /// `error.MoreThanOneRow` otherwise. `deinit` must be called on the row.
    pub fn row(conn: *Conn, sql: [:0]const u8, args: anytype) Error!?QueryRow {
        var result = try conn.query(sql, args);
        switch (result.row_count) {
            0 => {
                result.deinit();
                return null;
            },
            1 => return .{ .result = result, .row = result.rowAt(0) },
            else => {
                result.deinit();
                return error.MoreThanOneRow;
            },
        }
    }

    pub fn begin(conn: *Conn) Error!void {
        _ = try conn.exec("BEGIN", .{});
    }

    pub fn commit(conn: *Conn) Error!void {
        _ = try conn.exec("COMMIT", .{});
    }

    pub fn rollback(conn: *Conn) Error!void {
        _ = try conn.exec("ROLLBACK", .{});
    }

    fn run(conn: *Conn, sql: [:0]const u8, args: anytype) Error!*c.PGresult {
        conn.clearError();
        _ = conn.scratch.reset(.{ .retain_with_limit = 16 * 1024 });

        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        const result = if (fields.len == 0)
            c.PQexec(conn.pg, sql.ptr)
        else blk: {
            var values: [fields.len][*c]const u8 = undefined;
            inline for (fields, 0..) |field, i| {
                values[i] = try encodeParam(conn.scratch.allocator(), @field(args, field.name));
            }
            break :blk c.PQexecParams(conn.pg, sql.ptr, fields.len, null, &values, null, null, 0);
        };
        return conn.checkResult(result);
    }

    fn checkResult(conn: *Conn, maybe_result: ?*c.PGresult) Error!*c.PGresult {
        const result = maybe_result orelse {
            if (c.PQstatus(conn.pg) != c.CONNECTION_OK) {
                log.err("PostgreSQL connection lost: {s}", .{connErrorMessage(conn.pg)});
                return error.ConnectionFailed;
            }
            return error.OutOfMemory;
        };
        switch (c.PQresultStatus(result)) {
            c.PGRES_COMMAND_OK, c.PGRES_TUPLES_OK, c.PGRES_EMPTY_QUERY => return result,
            c.PGRES_BAD_RESPONSE, c.PGRES_NONFATAL_ERROR, c.PGRES_FATAL_ERROR => {
                conn.err_result = result;
                conn.err = .{
                    .code = errorField(result, c.PG_DIAG_SQLSTATE) orelse "",
                    .severity = errorField(result, c.PG_DIAG_SEVERITY_NONLOCALIZED) orelse "ERROR",
                    .message = errorField(result, c.PG_DIAG_MESSAGE_PRIMARY) orelse
                        std.mem.trimEnd(u8, std.mem.span(c.PQresultErrorMessage(result)), "\n"),
                    .detail = errorField(result, c.PG_DIAG_MESSAGE_DETAIL),
                    .constraint = errorField(result, c.PG_DIAG_CONSTRAINT_NAME),
                };
                if (c.PQstatus(conn.pg) != c.CONNECTION_OK) return error.ConnectionFailed;
                return error.PG;
            },
            else => {
                c.PQclear(result);
                return error.UnsupportedResult;
            },
        }
    }

    fn clearError(conn: *Conn) void {
        if (conn.err_result) |result| c.PQclear(result);
        conn.err_result = null;
        conn.err = null;
    }

    fn ensureConnected(conn: *Conn) Error!void {
        if (c.PQstatus(conn.pg) == c.CONNECTION_OK) return;
        c.PQreset(conn.pg);
        if (c.PQstatus(conn.pg) != c.CONNECTION_OK) {
            log.err("reconnecting to PostgreSQL failed: {s}", .{connErrorMessage(conn.pg)});
            return error.ConnectionFailed;
        }
    }

    /// Leaves the connection idle so the next user starts clean.
    fn prepareForReuse(conn: *Conn) void {
        conn.clearError();
        _ = conn.scratch.reset(.{ .retain_with_limit = 16 * 1024 });
        switch (c.PQtransactionStatus(conn.pg)) {
            c.PQTRANS_IDLE => {},
            c.PQTRANS_INTRANS, c.PQTRANS_INERROR => {
                log.warn("rolling back a transaction left open on a released connection", .{});
                if (c.PQexec(conn.pg, "ROLLBACK")) |result| c.PQclear(result);
            },
            // Unknown means the connection is bad; it is reset on next acquire.
            else => {},
        }
    }
};

/// Rows returned by `Conn.query`. Results are fully buffered by the server
/// round trip, so `drain` is only needed for API compatibility.
pub const Result = struct {
    pg: *c.PGresult,
    row_count: usize,
    number_of_columns: usize,
    index: usize = 0,

    /// Returns the next row. Row values are valid until `deinit`.
    pub fn next(result: *Result) ReadError!?Row {
        if (result.index == result.row_count) return null;
        defer result.index += 1;
        return result.rowAt(result.index);
    }

    pub fn drain(result: *Result) ReadError!void {
        result.index = result.row_count;
    }

    pub fn deinit(result: *const Result) void {
        c.PQclear(result.pg);
    }

    fn rowAt(result: *const Result, index: usize) Row {
        return .{ .pg = result.pg, .index = @intCast(index), .number_of_columns = result.number_of_columns };
    }
};

pub const Row = struct {
    pg: *c.PGresult,
    index: c_int,
    number_of_columns: usize,

    /// Reads column `col` (0-based) as `T`. Type mapping is strict:
    /// `i16`/`i32`/`i64` require smallint/int/bigint, `f32`/`f64` require
    /// real/double precision, and `bool` requires boolean. `[]const u8` returns
    /// the text representation of any column. Use `?T` for nullable columns.
    /// Returned slices are valid until the owning result is deinitialized.
    pub fn get(row: Row, comptime T: type, col: usize) ReadError!T {
        if (col >= row.number_of_columns) return error.ColumnOutOfRange;
        const column: c_int = @intCast(col);
        const is_null = c.PQgetisnull(row.pg, row.index, column) == 1;
        switch (@typeInfo(T)) {
            .optional => |optional| {
                if (is_null) return null;
                return try row.decode(optional.child, column);
            },
            else => {
                if (is_null) return error.UnexpectedNull;
                return row.decode(T, column);
            },
        }
    }

    fn decode(row: Row, comptime T: type, column: c_int) ReadError!T {
        const text = c.PQgetvalue(row.pg, row.index, column)[0..@intCast(c.PQgetlength(row.pg, row.index, column))];
        const type_oid = c.PQftype(row.pg, column);
        switch (T) {
            []const u8 => return text,
            bool => {
                if (type_oid != libpq.oid.bool_) return error.ColumnTypeMismatch;
                if (std.mem.eql(u8, text, "t")) return true;
                if (std.mem.eql(u8, text, "f")) return false;
                return error.InvalidColumnValue;
            },
            i16, i32, i64 => {
                const expected: c.Oid = switch (T) {
                    i16 => libpq.oid.int2,
                    i32 => libpq.oid.int4,
                    i64 => libpq.oid.int8,
                    else => unreachable,
                };
                if (type_oid != expected) return error.ColumnTypeMismatch;
                return std.fmt.parseInt(T, text, 10) catch error.InvalidColumnValue;
            },
            f32, f64 => {
                const expected: c.Oid = if (T == f32) libpq.oid.float4 else libpq.oid.float8;
                if (type_oid != expected) return error.ColumnTypeMismatch;
                return std.fmt.parseFloat(T, text) catch error.InvalidColumnValue;
            },
            else => @compileError("unsupported column type: " ++ @typeName(T)),
        }
    }
};

/// A single row returned by `Conn.row`.
pub const QueryRow = struct {
    result: Result,
    row: Row,

    pub fn get(query_row: *const QueryRow, comptime T: type, col: usize) ReadError!T {
        return query_row.row.get(T, col);
    }

    /// Infallible here; the error union matches pg.zig, whose `deinit` can fail.
    pub fn deinit(query_row: *const QueryRow) error{}!void {
        query_row.result.deinit();
    }
};

/// Encodes a query parameter in PostgreSQL text format. The server infers
/// parameter types from context; cast in SQL (e.g. `$1::text`) where ambiguous.
fn encodeParam(arena: Allocator, value: anytype) Error![*c]const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (value) |inner| encodeParam(arena, inner) else null,
        .bool => return if (value) "t" else "f",
        .int, .comptime_int, .float, .comptime_float => {
            return (try std.fmt.allocPrintSentinel(arena, "{d}", .{value}, 0)).ptr;
        },
        .@"enum" => return @tagName(value),
        .pointer => {
            const bytes: []const u8 = value;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidParameter;
            return (try arena.dupeZ(u8, bytes)).ptr;
        },
        else => @compileError("unsupported parameter type: " ++ @typeName(T)),
    }
}

fn errorField(result: *const c.PGresult, code: u8) ?[]const u8 {
    const value = c.PQresultErrorField(result, code);
    if (value == null) return null;
    return std.mem.span(value);
}

fn connErrorMessage(pg: *const c.PGconn) []const u8 {
    return std.mem.trimEnd(u8, std.mem.span(c.PQerrorMessage(pg)), "\n");
}

fn logNotice(_: ?*anyopaque, message: [*c]const u8) callconv(.c) void {
    log.debug("{s}", .{std.mem.trimEnd(u8, std.mem.span(message), "\n")});
}

pub const testing = @import("db/testing.zig");

test "encodes parameters as PostgreSQL text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("42", std.mem.span(try encodeParam(a, @as(i32, 42))));
    try std.testing.expectEqualStrings("-7", std.mem.span(try encodeParam(a, -7)));
    try std.testing.expectEqualStrings("t", std.mem.span(try encodeParam(a, true)));
    try std.testing.expectEqualStrings("hi", std.mem.span(try encodeParam(a, "hi")));
    const slice: []const u8 = "multi\nline";
    try std.testing.expectEqualStrings("multi\nline", std.mem.span(try encodeParam(a, slice)));
    try std.testing.expectEqualStrings("active", std.mem.span(try encodeParam(a, @as(enum { active }, .active))));
    try std.testing.expect(try encodeParam(a, null) == null);
    try std.testing.expect(try encodeParam(a, @as(?i32, null)) == null);
    try std.testing.expectEqualStrings("5", std.mem.span(try encodeParam(a, @as(?i32, 5))));
}

test "rejects NUL bytes in string parameters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const with_nul: []const u8 = "a\x00b";
    try std.testing.expectError(error.InvalidParameter, encodeParam(arena.allocator(), with_nul));
}

test "pool runs queries and reads typed values" {
    const pool = try testing.pool(2);
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();

    var result = try conn.query(
        "SELECT 1::int2, 2::int4, 3::int8, true, 1.5::float8, 'text'::text, NULL::text",
        .{},
    );
    defer result.deinit();
    const row = (try result.next()).?;
    try std.testing.expectEqual(@as(i16, 1), try row.get(i16, 0));
    try std.testing.expectEqual(@as(i32, 2), try row.get(i32, 1));
    try std.testing.expectEqual(@as(i64, 3), try row.get(i64, 2));
    try std.testing.expectEqual(true, try row.get(bool, 3));
    try std.testing.expectEqual(@as(f64, 1.5), try row.get(f64, 4));
    try std.testing.expectEqualStrings("text", try row.get([]const u8, 5));
    try std.testing.expectEqual(null, try row.get(?[]const u8, 6));
    try std.testing.expectError(error.UnexpectedNull, row.get([]const u8, 6));
    try std.testing.expectError(error.ColumnTypeMismatch, row.get(i64, 1));
    try std.testing.expectError(error.ColumnOutOfRange, row.get(i32, 7));
    try std.testing.expectEqual(null, try result.next());
}

test "parameters round-trip, including multiline text and NULL" {
    const pool = try testing.pool(1);
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();

    _ = try conn.exec("CREATE TABLE notes (id bigserial PRIMARY KEY, body text, pinned boolean NOT NULL)", .{});
    try std.testing.expectEqual(@as(?i64, 1), try conn.exec(
        "INSERT INTO notes (body, pinned) VALUES ($1, $2)",
        .{ "first line\nsecond 'quoted' line", true },
    ));
    _ = try conn.exec("INSERT INTO notes (body, pinned) VALUES ($1, $2)", .{ null, false });

    var result = try conn.query("SELECT body, pinned FROM notes WHERE pinned = $1", .{true});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    const row = (try result.next()).?;
    try std.testing.expectEqualStrings("first line\nsecond 'quoted' line", try row.get([]const u8, 0));

    var missing = (try conn.row("SELECT body FROM notes WHERE pinned = $1", .{false})).?;
    defer missing.deinit() catch {};
    try std.testing.expectEqual(null, try missing.get(?[]const u8, 0));

    try std.testing.expectEqual(null, try conn.row("SELECT 1 FROM notes WHERE false", .{}));
    try std.testing.expectError(error.MoreThanOneRow, conn.row("SELECT 1 FROM notes", .{}));
}

test "PostgreSQL errors expose SQLSTATE details" {
    const pool = try testing.pool(1);
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();

    _ = try conn.exec("CREATE TABLE tags (name text PRIMARY KEY)", .{});
    _ = try conn.exec("INSERT INTO tags VALUES ($1)", .{"a"});
    try std.testing.expectError(error.PG, conn.exec("INSERT INTO tags VALUES ($1)", .{"a"}));
    const err = conn.err.?;
    try std.testing.expect(err.isUnique());
    try std.testing.expectEqualStrings("tags_pkey", err.constraint.?);

    // The next operation clears the previous error.
    _ = try conn.exec("SELECT 1", .{});
    try std.testing.expectEqual(null, conn.err);
}

test "released connections roll back open transactions" {
    const pool = try testing.pool(1);
    defer pool.deinit();
    // The rollback warning is expected here.
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    {
        const conn = try pool.acquire();
        defer conn.release();
        _ = try conn.exec("CREATE TABLE items (id int)", .{});
        try conn.begin();
        _ = try conn.exec("INSERT INTO items VALUES (1)", .{});
        // Released without commit.
    }
    const conn = try pool.acquire();
    defer conn.release();
    var count = (try conn.row("SELECT count(*) FROM items", .{})).?;
    defer count.deinit() catch {};
    try std.testing.expectEqual(@as(i64, 0), try count.get(i64, 0));
}
