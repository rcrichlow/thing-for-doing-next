//! Board lists, shown in their persisted order: row mapping for
//! `queries/lists.sql`.
const std = @import("std");
const db = @import("db.zig");
const sql = @import("sql.zig");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;

pub const List = struct { id: i64, board_id: i64, title: []const u8 };
pub const Error = db.Error || db.ReadError;
pub const WriteError = Error || error{BlankTitle};
pub const normalizeTitle = text.line;

const q = sql.load(@embedFile("queries/lists.sql"));

pub fn forBoard(conn: *db.Conn, arena: Allocator, board_id: i64) Error![]List {
    var result = try conn.query(q.for_board, .{board_id});
    defer result.deinit();
    const items = try arena.alloc(List, result.row_count);
    for (items) |*item| item.* = try fromRow(arena, (try result.next()).?);
    return items;
}

pub fn find(conn: *db.Conn, arena: Allocator, id: i64) Error!?List {
    var row = try conn.row(q.find, .{id}) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns null if the board no longer exists.
pub fn create(conn: *db.Conn, arena: Allocator, board_id: i64, title: []const u8) WriteError!?List {
    return createLocked(conn, arena, board_id, title, q.create);
}

/// Like create, but only accepts an active board.
pub fn createOnActiveBoard(conn: *db.Conn, arena: Allocator, board_id: i64, title: []const u8) WriteError!?List {
    return createLocked(conn, arena, board_id, title, q.create_on_active_board);
}

fn createLocked(conn: *db.Conn, arena: Allocator, board_id: i64, title: []const u8, comptime query: [:0]const u8) WriteError!?List {
    try conn.begin();
    errdefer conn.rollback() catch {};
    if (!try lockBoard(conn, board_id)) {
        try conn.rollback();
        return null;
    }
    const item = blk: {
        var row = (conn.row(query, .{ board_id, title }) catch |err| return blankOr(conn, err)) orelse {
            try conn.rollback();
            return null;
        };
        defer row.deinit() catch {};
        break :blk try fromRow(arena, row.row);
    };
    try conn.commit();
    return item;
}

fn lockBoard(conn: *db.Conn, board_id: i64) Error!bool {
    var row = try conn.row(q.lock_board, .{board_id}) orelse return false;
    defer row.deinit() catch {};
    return true;
}

/// Moves a list next to another list on the same board. Returns false if
/// either list or the board is gone, or the anchor is not on that board.
pub fn reorder(conn: *db.Conn, board_id: i64, list_id: i64, anchor_id: i64, before: bool) Error!bool {
    if (list_id == anchor_id) return false;
    try conn.begin();
    errdefer conn.rollback() catch {};
    if (!try lockBoard(conn, board_id)) {
        try conn.rollback();
        return false;
    }
    var locked = try conn.query(q.lock_reorder_lists, .{ board_id, list_id, anchor_id });
    const both_exist = locked.row_count == 2;
    locked.deinit();
    if (!both_exist) {
        try conn.rollback();
        return false;
    }
    _ = try conn.exec(q.reorder, .{ board_id, list_id, anchor_id, before });
    try conn.commit();
    return true;
}

pub fn rename(conn: *db.Conn, arena: Allocator, id: i64, title: []const u8) WriteError!?List {
    var row = (conn.row(q.rename, .{ id, title }) catch |err| return blankOr(conn, err)) orelse return null;
    defer row.deinit() catch {};
    return try fromRow(arena, row.row);
}

/// Returns the deleted list's board id, or null if it did not exist.
pub fn delete(conn: *db.Conn, id: i64) Error!?i64 {
    var row = try conn.row(q.delete, .{id}) orelse return null;
    defer row.deinit() catch {};
    return try row.get(i64, 0);
}

pub fn count(conn: *db.Conn, board_id: i64) Error!i64 {
    var row = (try conn.row(q.count, .{board_id})).?;
    defer row.deinit() catch {};
    return row.get(i64, 0);
}

pub const TransferError = Error || error{InvalidTransferTarget};

/// Moves a list's cards, in order, to the end of `target_id`, then deletes
/// the list. The target must be another list on the same board. Returns the
/// board id, or null if the list did not exist.
pub fn deleteTransferring(conn: *db.Conn, id: i64, target_id: i64) TransferError!?i64 {
    try conn.begin();
    errdefer conn.rollback() catch {};

    const board_id = blk: {
        var row = try conn.row(q.lock_for_transfer, .{id}) orelse {
            try conn.rollback();
            return null;
        };
        defer row.deinit() catch {};
        break :blk try row.get(i64, 0);
    };
    {
        var row = try conn.row(q.lock_transfer_target, .{ target_id, board_id, id }) orelse return error.InvalidTransferTarget;
        row.deinit() catch {};
    }
    _ = try conn.exec(q.transfer_cards, .{ id, target_id });
    _ = try conn.exec(q.delete, .{id});
    try conn.commit();
    return board_id;
}

fn fromRow(arena: Allocator, row: db.Row) Error!List {
    return .{
        .id = try row.get(i64, 0),
        .board_id = try row.get(i64, 1),
        .title = try arena.dupe(u8, try row.get([]const u8, 2)),
    };
}

fn blankOr(conn: *db.Conn, err: db.Error) WriteError {
    if (err == error.PG) if (conn.err) |pg_err| if (pg_err.isCheckViolation()) return error.BlankTitle;
    return err;
}

test "lists are ordered, isolated by board, and cascade on board deletion" {
    const testing = std.testing;
    const boards = @import("boards.zig");
    const pool = try boards.testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try boards.create(conn, a, "First board");
    const second = try boards.create(conn, a, "Second board");
    const one = (try create(conn, a, first.id, "One")).?;
    _ = try create(conn, a, second.id, "Other");
    const two = (try create(conn, a, first.id, "Two")).?;
    const items = try forBoard(conn, a, first.id);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(one.id, items[0].id);
    try testing.expectEqual(two.id, items[1].id);
    try testing.expectEqualStrings("Changed", (try rename(conn, a, one.id, "Changed")).?.title);
    try testing.expectError(error.BlankTitle, create(conn, a, first.id, "\t"));
    try testing.expectError(error.BlankTitle, rename(conn, a, one.id, " "));
    try testing.expectEqual(null, try create(conn, a, second.id + 1000, "Missing"));
    try testing.expectEqual(null, try rename(conn, a, two.id + 1000, "Missing"));
    try testing.expectEqual(@as(i64, 2), try count(conn, first.id));
    try testing.expectEqual(first.id, (try delete(conn, one.id)).?);
    try testing.expectEqual(null, try delete(conn, one.id));
    try testing.expectEqual(@as(i64, 1), try count(conn, first.id));
    try testing.expect(try boards.delete(conn, first.id));
    try testing.expectEqual(null, try find(conn, a, two.id));
    try testing.expectEqual(@as(usize, 1), (try forBoard(conn, a, second.id)).len);
}

test "list reorder persists, stays on its board, and new lists append" {
    const testing = std.testing;
    const boards = @import("boards.zig");
    const pool = try boards.testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const board = try boards.create(conn, a, "Board");
    const other_board = try boards.create(conn, a, "Other");
    const one = (try create(conn, a, board.id, "One")).?;
    const two = (try create(conn, a, board.id, "Two")).?;
    const three = (try create(conn, a, board.id, "Three")).?;
    const foreign = (try create(conn, a, other_board.id, "Foreign")).?;

    try testing.expect(try reorder(conn, board.id, three.id, one.id, true));
    var items = try forBoard(conn, a, board.id);
    try testing.expectEqualSlices(i64, &.{ three.id, one.id, two.id }, &.{ items[0].id, items[1].id, items[2].id });
    try testing.expect(try reorder(conn, board.id, three.id, two.id, false));
    items = try forBoard(conn, a, board.id);
    try testing.expectEqualSlices(i64, &.{ one.id, two.id, three.id }, &.{ items[0].id, items[1].id, items[2].id });
    try testing.expect(!try reorder(conn, board.id, foreign.id, one.id, true));
    try testing.expect(!try reorder(conn, board.id, one.id, foreign.id, true));
    try testing.expect(!try reorder(conn, board.id, one.id, one.id, true));
    try testing.expect(!try reorder(conn, board.id + 1000, one.id, two.id, true));
    try testing.expect(try reorder(conn, board.id, three.id, one.id, true));
    const four = (try createOnActiveBoard(conn, a, board.id, "Four")).?;
    items = try forBoard(conn, a, board.id);
    try testing.expectEqualSlices(i64, &.{ three.id, one.id, two.id, four.id }, &.{ items[0].id, items[1].id, items[2].id, items[3].id });
    try testing.expectEqual(foreign.id, (try forBoard(conn, a, other_board.id))[0].id);
}

test "deleting a list can transfer its cards to the end of another list on the board" {
    const testing = std.testing;
    const boards = @import("boards.zig");
    const cards = @import("cards.zig");
    const pool = try boards.testPool();
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const board = try boards.create(conn, a, "Board");
    const other_board = try boards.create(conn, a, "Other");
    const source = (try create(conn, a, board.id, "Source")).?;
    const target = (try create(conn, a, board.id, "Target")).?;
    const foreign = (try create(conn, a, other_board.id, "Foreign")).?;
    _ = try cards.create(conn, a, target.id, "Existing");
    _ = try cards.create(conn, a, source.id, "Moved 1");
    _ = try cards.create(conn, a, source.id, "Moved 2");

    try testing.expectError(error.InvalidTransferTarget, deleteTransferring(conn, source.id, foreign.id));
    try testing.expectError(error.InvalidTransferTarget, deleteTransferring(conn, source.id, source.id));
    try testing.expect(try find(conn, a, source.id) != null);

    try testing.expectEqual(board.id, (try deleteTransferring(conn, source.id, target.id)).?);
    try testing.expectEqual(null, try find(conn, a, source.id));
    const moved = try cards.forList(conn, a, target.id);
    try testing.expectEqual(@as(usize, 3), moved.len);
    try testing.expectEqualStrings("Existing", moved[0].title);
    try testing.expectEqualStrings("Moved 1", moved[1].title);
    try testing.expectEqualStrings("Moved 2", moved[2].title);
    try testing.expectEqual(null, try deleteTransferring(conn, source.id, target.id));
}
