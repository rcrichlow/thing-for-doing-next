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

/// The lists a moved card left and joined; the same list for a reorder.
pub const Move = struct { from_list_id: i64, to_list_id: i64 };

pub const MoveError = Error || error{InvalidTarget};

/// Moves a card to `position` (0-based, clamped) among the other cards of
/// `list_id`, which must be on the card's board, and renumbers the affected
/// lists from 0. Returns null if the card does not exist.
pub fn move(conn: *db.Conn, id: i64, list_id: i64, position: i64) MoveError!?Move {
    while (true) {
        try conn.begin();
        errdefer conn.rollback() catch {};
        const from_list_id = try lockForMove(conn, id, list_id) orelse {
            try conn.rollback();
            return null;
        };
        // The card moved while its lists were being locked.
        if (from_list_id == 0) {
            try conn.rollback();
            continue;
        }

        _ = try conn.exec(
            \\UPDATE cards c SET list_id = $2, position = o.position,
            \\    updated_at = CASE WHEN c.id = $1 AND (c.list_id <> $2 OR c.position <> o.position)
            \\        THEN now() ELSE c.updated_at END
            \\FROM (
            \\    SELECT id, (n + CASE WHEN n >= t.at THEN 1 ELSE 0 END)::integer AS position
            \\    FROM (SELECT id, row_number() OVER (ORDER BY position, id) - 1 AS n
            \\          FROM cards WHERE list_id = $2 AND id <> $1) others,
            \\         (SELECT least(greatest($3::bigint, 0), count(*)) AS at
            \\          FROM cards WHERE list_id = $2 AND id <> $1) t
            \\    UNION ALL
            \\    SELECT $1::bigint, least(greatest($3::bigint, 0), count(*))::integer
            \\    FROM cards WHERE list_id = $2 AND id <> $1
            \\) o
            \\WHERE c.id = o.id
        , .{ id, list_id, position });
        if (from_list_id != list_id) {
            _ = try conn.exec(
                \\UPDATE cards c SET position = o.position
                \\FROM (SELECT id, (row_number() OVER (ORDER BY position, id) - 1)::integer AS position
                \\      FROM cards WHERE list_id = $1) o
                \\WHERE c.id = o.id AND c.position <> o.position
            , .{from_list_id});
        }
        try conn.commit();
        return .{ .from_list_id = from_list_id, .to_list_id = list_id };
    }
}

/// Locks the card's list and the target list, in id order as
/// `lists.deleteTransferring` does, and then the card. Returns the card's
/// list id, null if the card does not exist, or 0 if it changed lists
/// before they were locked.
fn lockForMove(conn: *db.Conn, id: i64, list_id: i64) MoveError!?i64 {
    const from_list_id, const board_id = blk: {
        var row = try conn.row(
            "SELECT c.list_id, l.board_id FROM cards c JOIN lists l ON l.id = c.list_id WHERE c.id = $1",
            .{id},
        ) orelse return null;
        defer row.deinit() catch {};
        break :blk .{ try row.get(i64, 0), try row.get(i64, 1) };
    };
    {
        var result = try conn.query(
            "SELECT id, board_id FROM lists WHERE id IN ($1, $2) ORDER BY id FOR UPDATE",
            .{ from_list_id, list_id },
        );
        defer result.deinit();
        var target_ok = false;
        while (try result.next()) |row| {
            if (try row.get(i64, 0) == list_id and try row.get(i64, 1) == board_id) target_ok = true;
        }
        if (!target_ok) return error.InvalidTarget;
    }
    var row = try conn.row("SELECT list_id FROM cards WHERE id = $1 FOR UPDATE", .{id}) orelse return null;
    defer row.deinit() catch {};
    return if (try row.get(i64, 0) == from_list_id) from_list_id else 0;
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

/// The titles of a list's cards, in order, joined with spaces.
fn titles(conn: *db.Conn, a: Allocator, list_id: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try forList(conn, a, list_id), 0..) |card, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, card.title);
    }
    return out.items;
}

/// The positions of a list's cards, in order, as "0 1 2".
fn positions(conn: *db.Conn, a: Allocator, list_id: i64) ![]const u8 {
    var result = try conn.query("SELECT string_agg(position::text, ' ' ORDER BY position, id) FROM cards WHERE list_id = $1", .{list_id});
    defer result.deinit();
    return try a.dupe(u8, try (try result.next()).?.get([]const u8, 0));
}

test "moving cards reorders and renumbers the affected lists" {
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
    const one = (try create(conn, a, todo.id, "one")).?;
    const two = (try create(conn, a, todo.id, "two")).?;
    const three = (try create(conn, a, todo.id, "three")).?;
    _ = (try create(conn, a, done.id, "shipped")).?;

    try testing.expectEqual(Move{ .from_list_id = todo.id, .to_list_id = todo.id }, (try move(conn, one.id, todo.id, 2)).?);
    try testing.expectEqualStrings("two three one", try titles(conn, a, todo.id));
    _ = try move(conn, one.id, todo.id, 0);
    try testing.expectEqualStrings("one two three", try titles(conn, a, todo.id));

    try testing.expectEqual(Move{ .from_list_id = todo.id, .to_list_id = done.id }, (try move(conn, two.id, done.id, 0)).?);
    try testing.expectEqualStrings("one three", try titles(conn, a, todo.id));
    try testing.expectEqualStrings("0 1", try positions(conn, a, todo.id));
    try testing.expectEqualStrings("two shipped", try titles(conn, a, done.id));

    // Positions are clamped to the destination list.
    _ = try move(conn, three.id, done.id, 99);
    _ = try move(conn, one.id, done.id, -5);
    try testing.expectEqualStrings("one two shipped three", try titles(conn, a, done.id));
    try testing.expectEqualStrings("0 1 2 3", try positions(conn, a, done.id));
    try testing.expectEqual(@as(usize, 0), (try forList(conn, a, todo.id)).len);

    // Into an empty list, and the target must be a list on the same board.
    _ = try move(conn, two.id, todo.id, 0);
    try testing.expectEqualStrings("two", try titles(conn, a, todo.id));
    const other = (try lists.create(conn, a, (try boards.create(conn, a, "Other")).id, "Elsewhere")).?;
    try testing.expectError(error.InvalidTarget, move(conn, two.id, other.id, 0));
    try testing.expectError(error.InvalidTarget, move(conn, two.id, other.id + 1000, 0));
    try testing.expectEqualStrings("two", try titles(conn, a, todo.id));
    try testing.expectEqual(null, try move(conn, three.id + 1000, todo.id, 0));
}

test "normalizeDescription trims and keeps blank as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\nb", try normalizeDescription(arena.allocator(), " a\r\nb "));
    try testing.expectEqualStrings("", try normalizeDescription(arena.allocator(), " \n "));
}
