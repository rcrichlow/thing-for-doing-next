//! Boards: SQL and row mapping. Active boards are listed in creation order;
//! archived boards most recently archived first.

const std = @import("std");
const db = @import("db.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

pub const Board = struct {
    id: i64,
    title: []const u8,
    /// ISO 8601 UTC timestamps, e.g. "2026-09-27T18:44:18Z".
    created_at: []const u8,
    archived_at: ?[]const u8,

    pub fn isArchived(board: Board) bool {
        return board.archived_at != null;
    }
};

pub const Error = db.Error || db.ReadError;
pub const WriteError = Error || error{BlankTitle};

/// Normalizes a submitted title; see `text.line`.
pub const normalizeTitle = text.line;

fn iso(comptime column: []const u8) []const u8 {
    return "to_char(" ++ column ++ " AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')";
}

const columns = "id, title, " ++ iso("created_at") ++ ", " ++ iso("archived_at");

pub fn listActive(conn: *db.Conn, arena: Allocator) Error![]Board {
    return list(conn, arena, "SELECT " ++ columns ++ " FROM boards WHERE archived_at IS NULL ORDER BY id");
}

pub fn listArchived(conn: *db.Conn, arena: Allocator) Error![]Board {
    return list(conn, arena, "SELECT " ++ columns ++
        " FROM boards WHERE archived_at IS NOT NULL ORDER BY archived_at DESC, id DESC");
}

pub fn countArchived(conn: *db.Conn) Error!i64 {
    var row = (try conn.row("SELECT count(*) FROM boards WHERE archived_at IS NOT NULL", .{})).?;
    defer row.deinit() catch {};
    return row.get(i64, 0);
}

pub fn find(conn: *db.Conn, arena: Allocator, id: i64) Error!?Board {
    var row = try conn.row("SELECT " ++ columns ++ " FROM boards WHERE id = $1", .{id}) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Creates a board from a title already passed through `normalizeTitle`.
pub fn create(conn: *db.Conn, arena: Allocator, title: []const u8) WriteError!Board {
    var row = (conn.row("INSERT INTO boards (title) VALUES ($1) RETURNING " ++ columns, .{title}) catch |err|
        return blankOr(conn, err)).?;
    defer row.deinit() catch {};
    return fromRow(arena, row.row);
}

/// Renames a board, leaving `updated_at` alone when the title is unchanged.
/// Returns null if the board does not exist.
pub fn rename(conn: *db.Conn, arena: Allocator, id: i64, title: []const u8) WriteError!?Board {
    var row = (conn.row(
        \\UPDATE boards
        \\SET title = $2,
        \\    updated_at = CASE WHEN title = $2 THEN updated_at ELSE now() END
        \\WHERE id = $1
        \\RETURNING
    ++ " " ++ columns, .{ id, title }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Archives a board, keeping the original time if it is already archived.
/// Returns whether the board exists.
pub fn archive(conn: *db.Conn, id: i64) Error!bool {
    return affected(try conn.exec(
        "UPDATE boards SET archived_at = coalesce(archived_at, now()) WHERE id = $1",
        .{id},
    ));
}

/// Returns whether the board exists.
pub fn unarchive(conn: *db.Conn, id: i64) Error!bool {
    return affected(try conn.exec("UPDATE boards SET archived_at = NULL WHERE id = $1", .{id}));
}

/// Permanently deletes a board and everything on it. Returns whether it existed.
pub fn delete(conn: *db.Conn, id: i64) Error!bool {
    return affected(try conn.exec("DELETE FROM boards WHERE id = $1", .{id}));
}

fn list(conn: *db.Conn, arena: Allocator, comptime sql: [:0]const u8) Error![]Board {
    var result = try conn.query(sql, .{});
    defer result.deinit();
    const boards = try arena.alloc(Board, result.row_count);
    for (boards) |*board| board.* = try fromRow(arena, (try result.next()).?);
    return boards;
}

fn fromRow(arena: Allocator, row: db.Row) Error!Board {
    return .{
        .id = try row.get(i64, 0),
        .title = try arena.dupe(u8, try row.get([]const u8, 1)),
        .created_at = try arena.dupe(u8, try row.get([]const u8, 2)),
        .archived_at = if (try row.get(?[]const u8, 3)) |value| try arena.dupe(u8, value) else null,
    };
}

fn affected(count: ?i64) bool {
    return (count orelse 0) > 0;
}

fn blankOr(conn: *db.Conn, err: db.Error) WriteError {
    // The title CHECK rejects whitespace-only text the normalizer missed.
    if (err == error.PG) if (conn.err) |pg_err| if (pg_err.isCheckViolation()) return error.BlankTitle;
    return err;
}

const testing = std.testing;

pub fn testPool() !*db.Pool {
    return @import("migrate.zig").testPool(1);
}

test "creates, renames, archives, unarchives, and deletes boards" {
    const pool = try testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try create(conn, a, "First");
    const second = try create(conn, a, "Second");
    try testing.expect(!first.isArchived());
    try testing.expectEqual(@as(usize, 20), first.created_at.len);

    const active = try listActive(conn, a);
    try testing.expectEqual(@as(usize, 2), active.len);
    try testing.expectEqualStrings("First", active[0].title);
    try testing.expectEqualStrings("Second", active[1].title);

    try testing.expectEqualStrings("Renamed", (try rename(conn, a, first.id, "Renamed")).?.title);
    try testing.expectEqual(null, try rename(conn, a, first.id + 1000, "Missing"));
    try testing.expectError(error.BlankTitle, rename(conn, a, first.id, " "));

    try testing.expect(try archive(conn, first.id));
    try testing.expect((try find(conn, a, first.id)).?.isArchived());
    // Archiving again keeps the original time.
    _ = try conn.exec("UPDATE boards SET archived_at = '2000-01-01Z' WHERE id = $1", .{first.id});
    try testing.expect(try archive(conn, first.id));
    try testing.expectEqualStrings("2000-01-01T00:00:00Z", (try find(conn, a, first.id)).?.archived_at.?);
    try testing.expect(try archive(conn, second.id));
    try testing.expect(!try archive(conn, second.id + 1000));

    // Most recently archived first.
    const archived = try listArchived(conn, a);
    try testing.expectEqual(@as(usize, 2), archived.len);
    try testing.expectEqualStrings("Second", archived[0].title);
    try testing.expectEqual(@as(i64, 2), try countArchived(conn));
    try testing.expectEqual(@as(usize, 0), (try listActive(conn, a)).len);

    try testing.expect(try unarchive(conn, first.id));
    try testing.expectEqualStrings("Renamed", (try listActive(conn, a))[0].title);

    try testing.expect(try delete(conn, second.id));
    try testing.expect(!try delete(conn, second.id));
    try testing.expectEqual(null, try find(conn, a, second.id));
}

test "the database rejects blank titles" {
    const pool = try testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BlankTitle, create(conn, arena.allocator(), "\t"));
}
