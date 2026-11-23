//! Page-local list CRUD on the board page. SQL lives in `lists.zig`.
//!
//! Creating a list re-renders every list in `#board-lists`, since the first
//! list replaces the board's empty state. Deleting the last list brings the
//! empty state back. Card changes re-render their list's column so its count
//! and delete behaviour stay current; `writeColumnUpdate` does that from any
//! response.

const std = @import("std");
const http = @import("../http.zig");
const template = @import("../template.zig");
const lists = @import("../lists.zig");
const boards = @import("../boards.zig");
const cards = @import("../cards.zig");

const Io = std.Io;
const Context = http.Context;
const List = lists.List;
const Card = cards.Card;

fn Tmpl(comptime name: []const u8) type {
    return template.Template(@embedFile("../public/lists/" ++ name ++ ".html"));
}

fn CardTmpl(comptime name: []const u8) type {
    return template.Template(@embedFile("../public/cards/" ++ name ++ ".html"));
}

const ListStart = Tmpl("list-start");
const DeleteButton = Tmpl("delete-button");
const DeleteDialogButton = Tmpl("delete-dialog-button");
const TitleStart = Tmpl("title-start");
const Title = Tmpl("title");
const TitleEdit = Tmpl("title-edit");
const BodyStart = Tmpl("body-start");
const NoCards = Tmpl("no-cards");
const FooterStart = Tmpl("footer-start");
const ListEnd = Tmpl("list-end");
const AddList = Tmpl("add-list");
const Empty = Tmpl("empty");
const Missing = Tmpl("missing");
const DeleteDialogStart = Tmpl("delete-dialog-start");
const DeleteDialogOption = Tmpl("delete-dialog-option");
const DeleteDialogEnd = Tmpl("delete-dialog-end");
const CardItem = CardTmpl("card");
const AddCardButton = CardTmpl("add-button");

/// A list with its cards, in position order.
pub const Column = struct {
    list: List,
    cards: []const Card,
};

/// The contents of `#board-lists`: each column, then the add-list form, or
/// the empty state when there are none. `title` and `message` refill the
/// form after a failed submission.
pub const Contents = struct {
    board_id: i64,
    columns: []const Column,
    title: []const u8 = "",
    message: []const u8 = "",
};

/// Every list on a board with its cards.
pub fn loadColumns(ctx: *Context, board_id: i64) ![]Column {
    const conn = try ctx.dbConn();
    const items = try lists.forBoard(conn, ctx.arena, board_id);
    // Both queries are ordered by list id, so one pass groups the cards.
    const all_cards = try cards.forBoard(conn, ctx.arena, board_id);
    const columns = try ctx.arena.alloc(Column, items.len);
    var start: usize = 0;
    for (items, columns) |item, *column| {
        while (start < all_cards.len and all_cards[start].list_id < item.id) start += 1;
        var end = start;
        while (end < all_cards.len and all_cards[end].list_id == item.id) end += 1;
        column.* = .{ .list = item, .cards = all_cards[start..end] };
        start = end;
    }
    return columns;
}

/// A single list with its cards, or null if the list does not exist.
pub fn loadColumn(ctx: *Context, list_id: i64) !?Column {
    const conn = try ctx.dbConn();
    const item = try lists.find(conn, ctx.arena, list_id) orelse return null;
    return .{ .list = item, .cards = try cards.forList(conn, ctx.arena, list_id) };
}

/// POST /boards/{id}/lists
pub fn create(ctx: *Context, id_text: []const u8) !void {
    const board_id = http.parseId(id_text) orelse return missing(ctx);
    const conn = try ctx.dbConn();
    if (try boards.find(conn, ctx.arena, board_id) == null) return missing(ctx);
    const body = try ctx.readForm();
    const raw = body.get("title") orelse "";
    const title = try lists.normalizeTitle(ctx.arena, raw) orelse return blankCreate(ctx, board_id, raw);
    _ = lists.create(conn, ctx.arena, board_id, title) catch |err| switch (err) {
        error.BlankTitle => return blankCreate(ctx, board_id, raw),
        else => |e| return e,
    } orelse return missing(ctx);
    const columns = try loadColumns(ctx, board_id);
    return ctx.html(.created, writeContents, .{Contents{ .board_id = board_id, .columns = columns }});
}

/// GET /lists/{id}: the read-only title, used to cancel editing.
pub fn show(ctx: *Context, id_text: []const u8) !void {
    const item = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitle, .{item});
}

/// GET /lists/{id}/edit
pub fn edit(ctx: *Context, id_text: []const u8) !void {
    const item = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitleEdit, .{item});
}

/// PUT /lists/{id}: re-renders the whole column, since its delete button
/// names the title. A blank title keeps the old one.
pub fn rename(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const title = try lists.normalizeTitle(ctx.arena, body.get("title") orelse "") orelse
        return show(ctx, id_text);
    _ = lists.rename(try ctx.dbConn(), ctx.arena, id, title) catch |err| switch (err) {
        error.BlankTitle => return show(ctx, id_text),
        else => |e| return e,
    } orelse return missing(ctx);
    const column = try loadColumn(ctx, id) orelse return missing(ctx);
    const target = try std.fmt.allocPrint(ctx.arena, "#list-{d}", .{id});
    return ctx.htmlWithHeaders(.ok, &.{
        .{ .name = "HX-Retarget", .value = target },
        .{ .name = "HX-Reswap", .value = "outerHTML" },
    }, writeColumn, .{column});
}

/// GET /lists/{id}/delete: the dialog for deleting a list that has cards,
/// offering to move them to another list on the board.
pub fn deleteDialog(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return missing(ctx);
    const column = try loadColumn(ctx, id) orelse return missing(ctx);
    const others = try lists.forBoard(try ctx.dbConn(), ctx.arena, column.list.board_id);
    return ctx.html(.ok, writeDeleteDialog, .{ column, others });
}

/// DELETE /lists/{id}[?transfer_list_id=N]: removes the column (200, not 204,
/// so HTMX swaps), first moving its cards to the end of the transfer list
/// when one is chosen. Closes the delete dialog. Idempotent.
pub fn destroy(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return ctx.html(.ok, writeCloseDialog, .{});
    const query = try ctx.queryForm();
    const transfer_text = query.get("transfer_list_id") orelse "";
    const conn = try ctx.dbConn();

    var transfer_to: ?i64 = null;
    const deleted: ?i64 = if (transfer_text.len == 0) try lists.delete(conn, id) else blk: {
        const target_id = http.parseId(transfer_text) orelse return invalidTransfer(ctx, id);
        transfer_to = target_id;
        break :blk lists.deleteTransferring(conn, id, target_id) catch |err| switch (err) {
            error.InvalidTransferTarget => return invalidTransfer(ctx, id),
            else => |e| return e,
        };
    };
    const board_id = deleted orelse return ctx.html(.ok, writeRemoved, .{ id, @as(?Column, null) });

    if (try lists.count(conn, board_id) == 0) {
        return ctx.htmlWithHeaders(.ok, &.{
            .{ .name = "HX-Retarget", .value = "#board-lists" },
            .{ .name = "HX-Reswap", .value = "innerHTML" },
        }, writeEmptied, .{board_id});
    }
    const target = if (transfer_to) |target_id| try loadColumn(ctx, target_id) else null;
    return ctx.html(.ok, writeRemoved, .{ id, target });
}

/// The chosen list is gone or on another board: show the dialog again with
/// the board's current lists.
fn invalidTransfer(ctx: *Context, id: i64) !void {
    const column = try loadColumn(ctx, id) orelse return ctx.html(.ok, writeRemoved, .{ id, @as(?Column, null) });
    const others = try lists.forBoard(try ctx.dbConn(), ctx.arena, column.list.board_id);
    return ctx.htmlWithHeaders(.unprocessable_entity, &.{
        .{ .name = "HX-Retarget", .value = "#modal-root" },
        .{ .name = "HX-Reswap", .value = "innerHTML" },
    }, writeDeleteDialog, .{ column, others });
}

fn find(ctx: *Context, id_text: []const u8) !?List {
    const id = http.parseId(id_text) orelse return null;
    return lists.find(try ctx.dbConn(), ctx.arena, id);
}

fn blankCreate(ctx: *Context, board_id: i64, raw: []const u8) !void {
    const columns = try loadColumns(ctx, board_id);
    return ctx.html(.unprocessable_entity, writeContents, .{Contents{
        .board_id = board_id,
        .columns = columns,
        .title = raw,
        .message = "Title can't be blank.",
    }});
}

fn missing(ctx: *Context) !void {
    return ctx.html(.not_found, Missing.render, .{.{}});
}

/// Formats ids for templates, which only accept strings.
pub const Id = struct {
    buffer: [20]u8 = undefined,
    pub fn of(id: *Id, value: i64) []const u8 {
        return std.fmt.bufPrint(&id.buffer, "{d}", .{value}) catch unreachable;
    }
};

/// "1 card", "3 cards".
fn cardCount(buffer: *[32]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) "card" else "cards" }) catch unreachable;
}

pub fn writeContents(writer: *Io.Writer, contents: Contents) Io.Writer.Error!void {
    var id: Id = .{};
    const form = .{ .board_id = id.of(contents.board_id), .title = contents.title, .message = contents.message };
    if (contents.columns.len == 0) return Empty.render(writer, form);
    for (contents.columns) |column| try writeColumn(writer, column);
    try AddList.render(writer, form);
}

pub fn writeColumn(writer: *Io.Writer, column: Column) Io.Writer.Error!void {
    var id: Id = .{};
    const list_id = id.of(column.list.id);
    try ListStart.render(writer, .{ .id = list_id });
    const values = .{ .id = list_id, .title = column.list.title };
    // Lists with cards open a dialog that can move them elsewhere first.
    if (column.cards.len == 0) try DeleteButton.render(writer, values) else try DeleteDialogButton.render(writer, values);
    try TitleStart.render(writer, .{});
    try writeTitle(writer, column.list);
    var count: [32]u8 = undefined;
    try BodyStart.render(writer, .{ .count = cardCount(&count, column.cards.len) });
    if (column.cards.len == 0) try NoCards.render(writer, .{});
    for (column.cards) |card| {
        var card_id: Id = .{};
        try CardItem.render(writer, .{ .id = card_id.of(card.id), .title = card.title, .description = card.description });
    }
    try FooterStart.render(writer, .{});
    try AddCardButton.render(writer, .{ .list_id = list_id });
    try ListEnd.render(writer, .{});
}

/// Replaces a column from a response whose main content goes elsewhere.
pub fn writeColumnUpdate(writer: *Io.Writer, column: Column) Io.Writer.Error!void {
    try writer.print("<template hx type=\"partial\" hx-target=\"#list-{d}\" hx-swap=\"outerHTML\">\n", .{column.list.id});
    try writeColumn(writer, column);
    try writer.writeAll("</template>\n");
}

/// Removes any open dialog. Responses made only of partials skip their main
/// swap, so removals are partials too.
pub fn writeCloseDialog(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("<template hx type=\"partial\" hx-target=\"#modal-root\" hx-swap=\"innerHTML\"></template>\n");
}

/// Removes the deleted column, updates the transfer target, and closes the
/// delete dialog.
fn writeRemoved(writer: *Io.Writer, removed_id: i64, target: ?Column) Io.Writer.Error!void {
    try writer.print("<template hx type=\"partial\" hx-target=\"#list-{d}\" hx-swap=\"delete\"></template>\n", .{removed_id});
    if (target) |column| try writeColumnUpdate(writer, column);
    try writeCloseDialog(writer);
}

fn writeEmptied(writer: *Io.Writer, board_id: i64) Io.Writer.Error!void {
    try writeContents(writer, .{ .board_id = board_id, .columns = &.{} });
    try writeCloseDialog(writer);
}

fn writeDeleteDialog(writer: *Io.Writer, column: Column, board_lists: []const List) Io.Writer.Error!void {
    var id: Id = .{};
    var count: [32]u8 = undefined;
    try DeleteDialogStart.render(writer, .{
        .id = id.of(column.list.id),
        .title = column.list.title,
        .count = cardCount(&count, column.cards.len),
    });
    for (board_lists) |other| {
        if (other.id == column.list.id) continue;
        var other_id: Id = .{};
        try DeleteDialogOption.render(writer, .{ .id = other_id.of(other.id), .title = other.title });
    }
    try DeleteDialogEnd.render(writer, .{});
}

fn writeTitle(writer: *Io.Writer, item: List) Io.Writer.Error!void {
    var id: Id = .{};
    try Title.render(writer, .{ .id = id.of(item.id), .title = item.title });
}

fn writeTitleEdit(writer: *Io.Writer, item: List) Io.Writer.Error!void {
    var id: Id = .{};
    try TitleEdit.render(writer, .{ .id = id.of(item.id), .title = item.title });
}

const testing = std.testing;

fn formRequest(comptime method: []const u8, comptime path: []const u8, comptime body: []const u8) []const u8 {
    return method ++ " " ++ path ++ " HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "create, edit, rename, and delete lists" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = try boards.create(conn, arena.allocator(), "Board");
    }
    {
        // Blank with no lists keeps the empty state, with the message.
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards/1/lists", "title=+"), pool);
        defer t.deinit();
        try create(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "Start your workflow"));
        try testing.expect(contains(body, "Title can&#39;t be blank."));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards/1/lists", "title=+To%0ADo+%26+More"), pool);
        defer t.deinit();
        try create(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 201), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, ">To Do &amp; More</button>"));
        try testing.expect(contains(body, "0 cards"));
        try testing.expect(contains(body, "Add a card"));
        try testing.expect(contains(body, "Add List"));
        try testing.expect(!contains(body, "Start your workflow"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards/1/lists", "title=Done"), pool);
        defer t.deinit();
        try create(&t.ctx, "1");
        const body = try t.body();
        const first = std.mem.indexOf(u8, body, "To Do &amp; More").?;
        try testing.expect(first < std.mem.indexOf(u8, body, ">Done</button>").?);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /lists/1/edit HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try edit(&t.ctx, "1");
        try testing.expect(contains(try t.body(), "value=\"To Do &amp; More\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/lists/1", "title=Doing"), pool);
        defer t.deinit();
        try rename(&t.ctx, "1");
        try testing.expect(contains(t.response(), "HX-Retarget: #list-1\r\n"));
        try testing.expect(contains(try t.body(), "aria-label=\"Delete Doing list\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/lists/1", "title=+"), pool);
        defer t.deinit();
        try rename(&t.ctx, "1");
        try testing.expect(!contains(t.response(), "HX-Retarget"));
        try testing.expect(contains(try t.body(), ">Doing</button>"));
    }
    {
        // Another list remains, so the column is simply removed.
        var t: http.TestRequest = undefined;
        try t.init("DELETE /lists/1 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(!contains(body, "data-testid=\"list-column\""));
        try testing.expect(contains(body, "hx-target=\"#list-1\" hx-swap=\"delete\""));
        try testing.expect(contains(body, "hx-target=\"#modal-root\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("DELETE /lists/2 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, "2");
        try testing.expect(contains(t.response(), "HX-Retarget: #board-lists\r\n"));
        try testing.expect(contains(try t.body(), "Start your workflow"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /lists/1 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try show(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 404), try t.status());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards/999/lists", "title=New"), pool);
        defer t.deinit();
        try create(&t.ctx, "999");
        try testing.expectEqual(@as(u16, 404), try t.status());
    }
}

test "lists with cards offer a transfer dialog, and deleting can move cards" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const board = try boards.create(conn, a, "Board");
        const source = (try lists.create(conn, a, board.id, "Source")).?;
        _ = (try lists.create(conn, a, board.id, "Target & Co")).?;
        _ = try cards.create(conn, a, source.id, "Moving card");
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /lists/1/delete HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try deleteDialog(&t.ctx, "1");
        const body = try t.body();
        try testing.expect(contains(body, "has 1 card."));
        try testing.expect(contains(body, "<option value=\"2\""));
        try testing.expect(contains(body, ">Target &amp; Co</option>"));
        try testing.expect(!contains(body, "<option value=\"1\""));
    }
    {
        // The source list itself is not a valid target.
        var t: http.TestRequest = undefined;
        try t.init("DELETE /lists/1?transfer_list_id=1 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(contains(t.response(), "HX-Retarget: #modal-root\r\n"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("DELETE /lists/1?transfer_list_id=2 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "hx-target=\"#list-2\""));
        try testing.expect(contains(body, ">Moving card</span>"));
        try testing.expect(contains(body, "1 card<"));
    }
}
