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

pub const ReorderError = Error || error{InvalidTarget};

/// Gives `list_id` the cards `card_ids`, in that order, as when a card is
/// dropped into it. Listed cards from other lists on the board move into it;
/// unknown cards, cards on other boards, and repeats are ignored, and cards
/// already in the list but not listed keep their order after the rest. Every
/// affected list is renumbered from 0. The list must be on `board_id`.
/// Returns the other lists cards came from.
pub fn reorder(conn: *db.Conn, arena: Allocator, board_id: i64, list_id: i64, card_ids: []const i64) ReorderError![]i64 {
    const ids = try arrayLiteral(arena, card_ids);
    try conn.begin();
    errdefer conn.rollback() catch {};
    {
        // Locking the board serializes reorders on it, and the list row
        // keeps it from being deleted until the cards are in place.
        var row = try conn.row(
            "SELECT 1 FROM lists l JOIN boards b ON b.id = l.board_id WHERE l.id = $1 AND b.id = $2 FOR UPDATE",
            .{ list_id, board_id },
        ) orelse return error.InvalidTarget;
        row.deinit() catch {};
    }
    const holding = try listsHolding(conn, arena, board_id, card_ids);
    var sources: std.ArrayList(i64) = .empty;
    for (holding) |id| if (id != list_id) try sources.append(arena, id);
    _ = try conn.exec(
        \\WITH wanted AS (
        \\    SELECT DISTINCT ON (c.id) c.id, w.n
        \\    FROM unnest($1::bigint[]) WITH ORDINALITY AS w(id, n)
        \\    JOIN cards c ON c.id = w.id JOIN lists l ON l.id = c.list_id
        \\    WHERE l.board_id = $3
        \\    ORDER BY c.id, w.n
        \\), ordered AS (
        \\    SELECT id, (row_number() OVER (ORDER BY listed DESC, n, id) - 1)::integer AS position
        \\    FROM (
        \\        SELECT id, true AS listed, n FROM wanted
        \\        UNION ALL
        \\        SELECT id, false, position::bigint FROM cards
        \\        WHERE list_id = $2 AND id NOT IN (SELECT id FROM wanted)
        \\    ) cards_in_list
        \\)
        \\UPDATE cards c SET list_id = $2, position = o.position,
        \\    updated_at = CASE WHEN c.list_id <> $2 THEN now() ELSE c.updated_at END
        \\FROM ordered o
        \\WHERE c.id = o.id AND (c.list_id <> $2 OR c.position <> o.position)
    , .{ ids, list_id, board_id });
    if (sources.items.len > 0) {
        _ = try conn.exec(
            \\UPDATE cards c SET position = o.position
            \\FROM (SELECT id, (row_number() OVER (PARTITION BY list_id ORDER BY position, id) - 1)::integer AS position
            \\      FROM cards WHERE list_id = ANY($1::bigint[])) o
            \\WHERE c.id = o.id AND c.position <> o.position
        , .{try arrayLiteral(arena, sources.items)});
    }
    try conn.commit();
    return sources.items;
}

/// The lists on `board_id` that hold any of `card_ids`, in id order.
pub fn listsHolding(conn: *db.Conn, arena: Allocator, board_id: i64, card_ids: []const i64) Error![]i64 {
    var result = try conn.query(
        \\SELECT DISTINCT c.list_id FROM cards c JOIN lists l ON l.id = c.list_id
        \\WHERE c.id = ANY($1::bigint[]) AND l.board_id = $2
        \\ORDER BY c.list_id
    , .{ try arrayLiteral(arena, card_ids), board_id });
    defer result.deinit();
    const ids = try arena.alloc(i64, result.row_count);
    for (ids) |*id| id.* = try (try result.next()).?.get(i64, 0);
    return ids;
}

/// Formats ids as a PostgreSQL array literal, `{1,2,3}`.
fn arrayLiteral(arena: Allocator, ids: []const i64) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    for (ids, 0..) |id, i| try out.print(arena, "{s}{d}", .{ if (i == 0) "" else ",", id });
    try out.append(arena, '}');
    return out.items;
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

test "reordering sets a list's cards and renumbers the lists they left" {
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
    const shipped = (try create(conn, a, done.id, "shipped")).?;

    // Within a list.
    try testing.expectEqual(@as(usize, 0), (try reorder(conn, a, board.id, todo.id, &.{ two.id, three.id, one.id })).len);
    try testing.expectEqualStrings("two three one", try titles(conn, a, todo.id));

    // Into another list, leaving a renumbered gap behind.
    const sources = try reorder(conn, a, board.id, done.id, &.{ three.id, shipped.id });
    try testing.expectEqualSlices(i64, &.{todo.id}, sources);
    try testing.expectEqualStrings("three shipped", try titles(conn, a, done.id));
    try testing.expectEqualStrings("two one", try titles(conn, a, todo.id));
    try testing.expectEqualStrings("0 1", try positions(conn, a, todo.id));

    // Unlisted cards stay after the listed ones; unknown ids and repeats are
    // ignored.
    _ = try reorder(conn, a, board.id, done.id, &.{ one.id, one.id, 999 });
    try testing.expectEqualStrings("one three shipped", try titles(conn, a, done.id));
    try testing.expectEqualStrings("0 1 2", try positions(conn, a, done.id));
    try testing.expectEqualStrings("two", try titles(conn, a, todo.id));

    // Cards and lists on other boards are left alone.
    const other_board = try boards.create(conn, a, "Other");
    const elsewhere = (try lists.create(conn, a, other_board.id, "Elsewhere")).?;
    const stranger = (try create(conn, a, elsewhere.id, "stranger")).?;
    _ = try reorder(conn, a, board.id, todo.id, &.{ stranger.id, two.id });
    try testing.expectEqualStrings("two", try titles(conn, a, todo.id));
    try testing.expectEqualStrings("stranger", try titles(conn, a, elsewhere.id));
    try testing.expectError(error.InvalidTarget, reorder(conn, a, board.id, elsewhere.id, &.{two.id}));
    try testing.expectError(error.InvalidTarget, reorder(conn, a, board.id, elsewhere.id + 1000, &.{two.id}));
    try testing.expectEqualStrings("two", try titles(conn, a, todo.id));

    // Emptying a list.
    _ = try reorder(conn, a, board.id, done.id, &.{ two.id, one.id, three.id, shipped.id });
    try testing.expectEqual(@as(usize, 0), (try forList(conn, a, todo.id)).len);
    try testing.expectEqualStrings("two one three shipped", try titles(conn, a, done.id));
}

test "normalizeDescription trims and keeps blank as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\nb", try normalizeDescription(arena.allocator(), " a\r\nb "));
    try testing.expectEqualStrings("", try normalizeDescription(arena.allocator(), " \n "));
}
