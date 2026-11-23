//! Cards: SQL and row mapping. Cards are ordered by `position` within their
//! list; new cards go at the end.

const std = @import("std");
const db = @import("db.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

pub const Card = struct {
    id: i64,
    list_id: i64,
    title: []const u8,
    /// Empty when the card has no description.
    description: []const u8,
};

pub const Error = db.Error || db.ReadError;
pub const WriteError = Error || error{BlankTitle};

/// Normalizes a submitted title; see `text.line`.
pub const normalizeTitle = text.line;

/// Normalizes a submitted description; blank becomes empty.
pub fn normalizeDescription(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    return try text.multiline(arena, raw) orelse "";
}

const columns = "c.id, c.list_id, c.title, c.description";
const order = " ORDER BY c.list_id, c.position, c.id";

/// Every card on a board, grouped by list and in position order.
pub fn forBoard(conn: *db.Conn, arena: Allocator, board_id: i64) Error![]Card {
    return list(conn, arena, "SELECT " ++ columns ++
        " FROM cards c JOIN lists l ON l.id = c.list_id WHERE l.board_id = $1" ++ order, .{board_id});
}

pub fn forList(conn: *db.Conn, arena: Allocator, list_id: i64) Error![]Card {
    return list(conn, arena, "SELECT " ++ columns ++ " FROM cards c WHERE c.list_id = $1" ++ order, .{list_id});
}

pub fn find(conn: *db.Conn, arena: Allocator, id: i64) Error!?Card {
    var row = try conn.row("SELECT " ++ columns ++ " FROM cards c WHERE c.id = $1", .{id}) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Adds a card to the end of a list from a title already passed through
/// `normalizeTitle`. Returns null if the list does not exist.
pub fn create(conn: *db.Conn, arena: Allocator, list_id: i64, title: []const u8) WriteError!?Card {
    var row = (conn.row(
        \\INSERT INTO cards (list_id, title, position)
        \\SELECT l.id, $2, coalesce((SELECT max(position) + 1 FROM cards WHERE list_id = l.id), 0)
        \\FROM lists l WHERE l.id = $1
        \\RETURNING id, list_id, title, description
    , .{ list_id, title }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns null if the card does not exist.
pub fn updateTitle(conn: *db.Conn, arena: Allocator, id: i64, title: []const u8) WriteError!?Card {
    var row = (conn.row(
        \\UPDATE cards c SET title = $2,
        \\    updated_at = CASE WHEN c.title = $2 THEN c.updated_at ELSE now() END
        \\WHERE c.id = $1 RETURNING
    ++ " " ++ columns, .{ id, title }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns null if the card does not exist.
pub fn updateDescription(conn: *db.Conn, arena: Allocator, id: i64, description: []const u8) Error!?Card {
    var row = try conn.row(
        \\UPDATE cards c SET description = $2,
        \\    updated_at = CASE WHEN c.description = $2 THEN c.updated_at ELSE now() END
        \\WHERE c.id = $1 RETURNING
    ++ " " ++ columns, .{ id, description }) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns the deleted card's list id, or null if it did not exist.
pub fn delete(conn: *db.Conn, id: i64) Error!?i64 {
    var row = try conn.row("DELETE FROM cards WHERE id = $1 RETURNING list_id", .{id}) orelse return null;
    defer row.deinit() catch {};
    return try row.get(i64, 0);
}

fn list(conn: *db.Conn, arena: Allocator, comptime sql: [:0]const u8, args: anytype) Error![]Card {
    var result = try conn.query(sql, args);
    defer result.deinit();
    const items = try arena.alloc(Card, result.row_count);
    for (items) |*item| item.* = try fromRow(arena, (try result.next()).?);
    return items;
}

fn fromRow(arena: Allocator, row: db.Row) Error!Card {
    return .{
        .id = try row.get(i64, 0),
        .list_id = try row.get(i64, 1),
        .title = try arena.dupe(u8, try row.get([]const u8, 2)),
        .description = try arena.dupe(u8, try row.get([]const u8, 3)),
    };
}

fn blankOr(conn: *db.Conn, err: db.Error) WriteError {
    // The title CHECK rejects whitespace-only text the normalizer missed.
    if (err == error.PG) if (conn.err) |pg_err| if (pg_err.isCheckViolation()) return error.BlankTitle;
    return err;
}

const testing = std.testing;

test "cards append in order, update, delete, and cascade with their list" {
    const boards = @import("boards.zig");
    const lists = @import("lists.zig");
    const pool = try boards.testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const board = try boards.create(conn, a, "Board");
    const todo = (try lists.create(conn, a, board.id, "To do")).?;
    const done = (try lists.create(conn, a, board.id, "Done")).?;
    const first = (try create(conn, a, todo.id, "First")).?;
    _ = (try create(conn, a, done.id, "Elsewhere")).?;
    const second = (try create(conn, a, todo.id, "Second")).?;
    try testing.expectEqualStrings("", first.description);
    try testing.expectEqual(null, try create(conn, a, done.id + 1000, "Missing"));
    try testing.expectError(error.BlankTitle, create(conn, a, todo.id, " "));

    const in_todo = try forList(conn, a, todo.id);
    try testing.expectEqual(@as(usize, 2), in_todo.len);
    try testing.expectEqual(first.id, in_todo[0].id);
    try testing.expectEqual(second.id, in_todo[1].id);
    try testing.expectEqual(@as(usize, 3), (try forBoard(conn, a, board.id)).len);

    try testing.expectEqualStrings("Renamed", (try updateTitle(conn, a, first.id, "Renamed")).?.title);
    try testing.expectError(error.BlankTitle, updateTitle(conn, a, first.id, "\t"));
    try testing.expectEqualStrings("Line\nnext", (try updateDescription(conn, a, first.id, "Line\nnext")).?.description);
    try testing.expectEqual(null, try updateDescription(conn, a, first.id + 1000, "x"));

    try testing.expectEqual(todo.id, (try delete(conn, second.id)).?);
    try testing.expectEqual(null, try delete(conn, second.id));
    try testing.expectEqual(@as(usize, 1), (try forList(conn, a, todo.id)).len);

    _ = try lists.delete(conn, todo.id);
    try testing.expectEqual(null, try find(conn, a, first.id));
}

test "normalizeDescription trims and keeps blank as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\nb", try normalizeDescription(arena.allocator(), " a\r\nb "));
    try testing.expectEqualStrings("", try normalizeDescription(arena.allocator(), " \n "));
}
