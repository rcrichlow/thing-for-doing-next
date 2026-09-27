//! Working-memory entries: SQL and row mapping. Handlers call these functions
//! and never write SQL themselves.

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: i64,
    content: []const u8,
    /// Last change as an ISO 8601 UTC timestamp, e.g. "2026-09-27T18:44:18Z".
    updated_at: []const u8,
};

pub const Error = db.Error || db.ReadError;

const columns =
    \\id, content, to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
;

/// Returns entries newest first. Strings are copied into `arena`.
pub fn list(conn: *db.Conn, arena: Allocator) Error![]Entry {
    var result = try conn.query("SELECT " ++ columns ++ " FROM working_memory_entries ORDER BY id DESC", .{});
    defer result.deinit();
    const entries = try arena.alloc(Entry, result.row_count);
    for (entries) |*entry| entry.* = try fromRow(arena, (try result.next()).?);
    return entries;
}

pub fn find(conn: *db.Conn, arena: Allocator, id: i64) Error!?Entry {
    var row = try conn.row("SELECT " ++ columns ++ " FROM working_memory_entries WHERE id = $1", .{id}) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Creates an entry from content already passed through `normalize`.
/// Returns `error.BlankContent` if the database still considers it blank
/// (e.g. only Unicode spaces).
pub fn create(conn: *db.Conn, arena: Allocator, content: []const u8) (Error || error{BlankContent})!Entry {
    var row = (conn.row(
        "INSERT INTO working_memory_entries (content) VALUES ($1) RETURNING " ++ columns,
        .{content},
    ) catch |err| return blankOr(conn, err)).?;
    defer row.deinit() catch {};
    return fromRow(arena, row.row);
}

/// Replaces an entry's content, leaving `updated_at` alone when the content is
/// unchanged. Returns null if the entry does not exist.
pub fn update(conn: *db.Conn, arena: Allocator, id: i64, content: []const u8) (Error || error{BlankContent})!?Entry {
    var row = (conn.row(
        \\UPDATE working_memory_entries
        \\SET content = $2,
        \\    updated_at = CASE WHEN content = $2 THEN updated_at ELSE now() END
        \\WHERE id = $1
        \\RETURNING
    ++ " " ++ columns, .{ id, content }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns whether an entry was deleted.
pub fn delete(conn: *db.Conn, id: i64) Error!bool {
    const affected = try conn.exec("DELETE FROM working_memory_entries WHERE id = $1", .{id});
    return (affected orelse 0) > 0;
}

pub fn deleteAll(conn: *db.Conn) Error!void {
    _ = try conn.exec("DELETE FROM working_memory_entries", .{});
}

/// Normalizes submitted content: converts CRLF and CR line endings to LF and
/// trims surrounding whitespace. Returns null when nothing remains.
pub fn normalize(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
        } else {
            out.appendAssumeCapacity(raw[i]);
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\n\x0b\x0c");
    return if (trimmed.len == 0) null else trimmed;
}

fn fromRow(arena: Allocator, row: db.Row) Error!Entry {
    return .{
        .id = try row.get(i64, 0),
        .content = try arena.dupe(u8, try row.get([]const u8, 1)),
        .updated_at = try arena.dupe(u8, try row.get([]const u8, 2)),
    };
}

fn blankOr(conn: *db.Conn, err: db.Error) (Error || error{BlankContent}) {
    if (err == error.PG) if (conn.err) |pg_err| {
        // check_violation: the content CHECK rejected whitespace-only text.
        if (std.mem.eql(u8, pg_err.code, "23514")) return error.BlankContent;
    };
    return err;
}

const testing = std.testing;

/// Opens a test pool with the application schema migrated.
pub fn testPool() !*db.Pool {
    const migrate = @import("migrate.zig");
    const pool = try db.testing.pool(1);
    errdefer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var diagnostics: migrate.Diagnostics = .{};
    _ = try migrate.run(conn, &@import("migrations").all, &diagnostics);
    return pool;
}

test "normalize converts line endings and trims" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("one\ntwo\nthree", (try normalize(a, "  one\r\ntwo\rthree \r\n")).?);
    try testing.expectEqualStrings("keep  inner\n\nspace", (try normalize(a, "keep  inner\n\nspace")).?);
    try testing.expectEqual(null, try normalize(a, " \r\n\t "));
    try testing.expectEqual(null, try normalize(a, ""));
}

test "creates, lists newest first, finds, updates, and deletes" {
    const pool = try testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try create(conn, a, "first");
    const second = try create(conn, a, "second\nline");
    try testing.expect(second.id > first.id);
    try testing.expectEqual(@as(usize, 20), first.updated_at.len);

    const entries = try list(conn, a);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("second\nline", entries[0].content);
    try testing.expectEqualStrings("first", entries[1].content);

    try testing.expectEqualStrings("first", (try find(conn, a, first.id)).?.content);
    try testing.expectEqual(null, try find(conn, a, first.id + 1000));

    const updated = (try update(conn, a, first.id, "first, revised")).?;
    try testing.expectEqualStrings("first, revised", updated.content);
    try testing.expectEqual(null, try update(conn, a, first.id + 1000, "missing"));

    try testing.expect(try delete(conn, first.id));
    try testing.expect(!try delete(conn, first.id));
    try deleteAll(conn);
    try testing.expectEqual(@as(usize, 0), (try list(conn, a)).len);
}

test "unchanged content keeps updated_at" {
    const pool = try testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entry = try create(conn, a, "same");
    _ = try conn.exec("UPDATE working_memory_entries SET updated_at = '2000-01-01Z' WHERE id = $1", .{entry.id});
    try testing.expectEqualStrings("2000-01-01T00:00:00Z", (try update(conn, a, entry.id, "same")).?.updated_at);
    try testing.expect(!std.mem.eql(u8, "2000-01-01T00:00:00Z", (try update(conn, a, entry.id, "changed")).?.updated_at));
}

test "the database rejects blank content" {
    const pool = try testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.BlankContent, create(conn, arena.allocator(), " \n "));
    const entry = try create(conn, arena.allocator(), "real");
    try testing.expectError(error.BlankContent, update(conn, arena.allocator(), entry.id, "\t"));
}
