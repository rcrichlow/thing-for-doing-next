//! Working-memory entries: row mapping for `queries/working_memory.sql`.
//! Handlers call these functions and never write SQL themselves.

const std = @import("std");
const db = @import("db.zig");
const sql = @import("sql.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: i64,
    content: []const u8,
    /// Last change as an ISO 8601 UTC timestamp, e.g. "2026-09-27T18:44:18Z".
    updated_at: []const u8,
};

pub const Error = db.Error || db.ReadError;

const q = sql.load(@embedFile("queries/working_memory.sql"));

/// Returns entries newest first. Strings are copied into `arena`.
pub fn list(conn: *db.Conn, arena: Allocator) Error![]Entry {
    var result = try conn.query(q.list, .{});
    defer result.deinit();
    const entries = try arena.alloc(Entry, result.row_count);
    for (entries) |*entry| entry.* = try fromRow(arena, (try result.next()).?);
    return entries;
}

pub fn find(conn: *db.Conn, arena: Allocator, id: i64) Error!?Entry {
    var row = try conn.row(q.find, .{id}) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Creates an entry from content already passed through `normalize`.
/// Returns `error.BlankContent` if the database still considers it blank
/// (e.g. only Unicode spaces).
pub fn create(conn: *db.Conn, arena: Allocator, content: []const u8) (Error || error{BlankContent})!Entry {
    var row = (conn.row(q.create, .{content}) catch |err| return blankOr(conn, err)).?;
    defer row.deinit() catch {};
    return fromRow(arena, row.row);
}

/// Replaces an entry's content, leaving `updated_at` alone when the content is
/// unchanged. Returns null if the entry does not exist.
pub fn update(conn: *db.Conn, arena: Allocator, id: i64, content: []const u8) (Error || error{BlankContent})!?Entry {
    var row = (conn.row(q.update, .{ id, content }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns whether an entry was deleted.
pub fn delete(conn: *db.Conn, id: i64) Error!bool {
    const affected = try conn.exec(q.delete, .{id});
    return (affected orelse 0) > 0;
}

pub fn deleteAll(conn: *db.Conn) Error!void {
    _ = try conn.exec(q.delete_all, .{});
}

/// Normalizes submitted content; see `text.multiline`.
pub const normalize = text.multiline;

fn fromRow(arena: Allocator, row: db.Row) Error!Entry {
    return .{
        .id = try row.get(i64, 0),
        .content = try arena.dupe(u8, try row.get([]const u8, 1)),
        .updated_at = try arena.dupe(u8, try row.get([]const u8, 2)),
    };
}

fn blankOr(conn: *db.Conn, err: db.Error) (Error || error{BlankContent}) {
    // The content CHECK rejects whitespace-only text the normalizer missed.
    if (err == error.PG) if (conn.err) |pg_err| if (pg_err.isCheckViolation()) return error.BlankContent;
    return err;
}

const testing = std.testing;

/// Opens a test pool with the application schema migrated.
pub fn testPool() !*db.Pool {
    return @import("migrate.zig").testPool(1);
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
