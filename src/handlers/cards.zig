//! Cards on the board page: the add-card form at the bottom of each list and
//! the card details dialog. SQL lives in `cards.zig`.
//!
//! The dialog is loaded into the board page's `#modal-root`. Saving a field
//! answers with that field and an update of the card's list column, so the
//! board behind the dialog stays current.

const std = @import("std");
const http = @import("../http.zig");
const template = @import("../template.zig");
const cards = @import("../cards.zig");
const lists = @import("../lists.zig");
const list_handlers = @import("lists.zig");

const Io = std.Io;
const Context = http.Context;
const Card = cards.Card;
const Column = list_handlers.Column;
const Id = list_handlers.Id;

fn Tmpl(comptime name: []const u8) type {
    return template.Template(@embedFile("../public/cards/" ++ name ++ ".html"));
}

const AddButton = Tmpl("add-button");
const Form = Tmpl("form");
const DetailStart = Tmpl("detail-start");
const DetailMiddle = Tmpl("detail-middle");
const DetailEnd = Tmpl("detail-end");
const Title = Tmpl("title");
const TitleEdit = Tmpl("title-edit");
const Description = Tmpl("description");
const DescriptionEmpty = Tmpl("description-empty");
const DescriptionEdit = Tmpl("description-edit");
const Missing = Tmpl("missing");

/// GET /lists/{id}/cards/new: the add-card form, replacing its button.
pub fn newForm(ctx: *Context, list_id_text: []const u8) !void {
    const list_id = http.parseId(list_id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeForm, .{ list_id, "", "" });
}

/// GET /lists/{id}/cards/button: the "Add a card" button, used to cancel.
pub fn addButton(ctx: *Context, list_id_text: []const u8) !void {
    const list_id = http.parseId(list_id_text) orelse return missing(ctx);
    var id: Id = .{};
    return ctx.html(.ok, AddButton.render, .{.{ .list_id = id.of(list_id) }});
}

/// POST /lists/{id}/cards: adds the card to the end of the list and
/// re-renders the column, closing the form as in the original app.
pub fn create(ctx: *Context, list_id_text: []const u8) !void {
    const list_id = http.parseId(list_id_text) orelse return listMissing(ctx);
    const body = try ctx.readForm();
    const raw = body.get("title") orelse "";
    const title = try cards.normalizeTitle(ctx.arena, raw) orelse return blankCreate(ctx, list_id, raw);
    _ = cards.create(try ctx.dbConn(), ctx.arena, list_id, title) catch |err| switch (err) {
        error.BlankTitle => return blankCreate(ctx, list_id, raw),
        else => |e| return e,
    } orelse return listMissing(ctx);
    const column = try list_handlers.loadColumn(ctx, list_id) orelse return listMissing(ctx);
    const target = try std.fmt.allocPrint(ctx.arena, "#list-{d}", .{list_id});
    return ctx.htmlWithHeaders(.created, &.{
        .{ .name = "HX-Retarget", .value = target },
        .{ .name = "HX-Reswap", .value = "outerHTML" },
    }, list_handlers.writeColumn, .{column});
}

/// GET /cards/{id}: the card details dialog.
pub fn show(ctx: *Context, id_text: []const u8) !void {
    const card = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeDetail, .{card});
}

/// GET /cards/{id}/title: the read-only title, used to cancel editing.
pub fn showTitle(ctx: *Context, id_text: []const u8) !void {
    const card = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitle, .{card});
}

/// GET /cards/{id}/title/edit
pub fn editTitle(ctx: *Context, id_text: []const u8) !void {
    const card = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitleEdit, .{card});
}

/// PUT /cards/{id}/title: a blank title keeps the old one.
pub fn updateTitle(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const title = try cards.normalizeTitle(ctx.arena, body.get("title") orelse "") orelse
        return showTitle(ctx, id_text);
    const card = cards.updateTitle(try ctx.dbConn(), ctx.arena, id, title) catch |err| switch (err) {
        error.BlankTitle => return showTitle(ctx, id_text),
        else => |e| return e,
    } orelse return missing(ctx);
    return ctx.html(.ok, writeSavedTitle, .{ card, try list_handlers.loadColumn(ctx, card.list_id) });
}

/// GET /cards/{id}/description: the read-only description, used to cancel.
pub fn showDescription(ctx: *Context, id_text: []const u8) !void {
    const card = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeDescription, .{card});
}

/// GET /cards/{id}/description/edit
pub fn editDescription(ctx: *Context, id_text: []const u8) !void {
    const card = try find(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeDescriptionEdit, .{card});
}

/// PUT /cards/{id}/description: blank clears the description.
pub fn updateDescription(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const description = try cards.normalizeDescription(ctx.arena, body.get("description") orelse "");
    const card = try cards.updateDescription(try ctx.dbConn(), ctx.arena, id, description) orelse
        return missing(ctx);
    return ctx.html(.ok, writeSavedDescription, .{ card, try list_handlers.loadColumn(ctx, card.list_id) });
}

/// DELETE /cards/{id}: closes the dialog and updates the card's column.
/// Idempotent.
pub fn destroy(ctx: *Context, id_text: []const u8) !void {
    const id = http.parseId(id_text) orelse return ctx.html(.ok, writeDeleted, .{@as(?Column, null)});
    const list_id = try cards.delete(try ctx.dbConn(), id) orelse
        return ctx.html(.ok, writeDeleted, .{@as(?Column, null)});
    return ctx.html(.ok, writeDeleted, .{try list_handlers.loadColumn(ctx, list_id)});
}

/// PUT /boards/{id}/card-order (list_id, from_list_id, then card_id for each
/// card in the list's new order): sent by the board's card move form after a
/// card is dropped or moved with the keyboard. `from_list_id` is the list the
/// card left. The page has already moved the card, so the response
/// re-renders that list, the list, and any other lists its cards came from,
/// keeping their counts and delete buttons current. If the list is gone or
/// not on the board, it answers 404 removing that column and re-rendering
/// the lists the cards are really in.
pub fn reorder(ctx: *Context, board_id_text: []const u8) !void {
    const board_id = http.parseId(board_id_text) orelse return listMissing(ctx);
    const body = try ctx.readForm();
    const list_id = http.parseId(body.get("list_id") orelse "") orelse return error.InvalidForm;
    const from_list_id = http.parseId(body.get("from_list_id") orelse "") orelse return error.InvalidForm;
    var card_ids: std.ArrayList(i64) = .empty;
    for (body.fields) |field| {
        if (!std.mem.eql(u8, field.name, "card_id")) continue;
        try card_ids.append(ctx.arena, http.parseId(field.value) orelse return error.InvalidForm);
    }
    const conn = try ctx.dbConn();
    const sources = cards.reorder(conn, ctx.arena, board_id, list_id, card_ids.items) catch |err| switch (err) {
        error.InvalidTarget => {
            const holding = try cards.listsHolding(conn, ctx.arena, board_id, card_ids.items);
            const columns = try loadColumns(ctx, board_id, &.{ holding, &.{from_list_id} });
            return ctx.html(.not_found, writeReordered, .{ list_id, columns });
        },
        else => |e| return e,
    };
    const columns = try loadColumns(ctx, board_id, &.{ &.{ list_id, from_list_id }, sources });
    return ctx.html(.ok, writeReordered, .{ null, columns });
}

/// The columns for each list in `groups`, once each, skipping lists that no
/// longer exist or are on another board.
fn loadColumns(ctx: *Context, board_id: i64, groups: []const []const i64) ![]Column {
    var columns: std.ArrayList(Column) = .empty;
    for (groups) |list_ids| for (list_ids) |list_id| {
        for (columns.items) |column| {
            if (column.list.id == list_id) break;
        } else {
            const column = try list_handlers.loadColumn(ctx, list_id) orelse continue;
            if (column.list.board_id == board_id) try columns.append(ctx.arena, column);
        }
    };
    return columns.items;
}

fn find(ctx: *Context, id_text: []const u8) !?Card {
    const id = http.parseId(id_text) orelse return null;
    return cards.find(try ctx.dbConn(), ctx.arena, id);
}

fn blankCreate(ctx: *Context, list_id: i64, raw: []const u8) !void {
    return ctx.html(.unprocessable_entity, writeForm, .{ list_id, raw, "Title can't be blank." });
}

fn missing(ctx: *Context) !void {
    return ctx.html(.not_found, Missing.render, .{.{}});
}

fn listMissing(ctx: *Context) !void {
    return ctx.html(.not_found, template.Template(@embedFile("../public/lists/missing.html")).render, .{.{}});
}

fn writeForm(writer: *Io.Writer, list_id: i64, title: []const u8, message: []const u8) Io.Writer.Error!void {
    var id: Id = .{};
    try Form.render(writer, .{ .list_id = id.of(list_id), .title = title, .message = message });
}

fn writeDetail(writer: *Io.Writer, card: Card) Io.Writer.Error!void {
    var id: Id = .{};
    try DetailStart.render(writer, .{});
    try writeTitle(writer, card);
    try DetailMiddle.render(writer, .{});
    try writeDescription(writer, card);
    try DetailEnd.render(writer, .{ .id = id.of(card.id) });
}

fn writeSavedTitle(writer: *Io.Writer, card: Card, column: ?Column) Io.Writer.Error!void {
    try writeTitle(writer, card);
    if (column) |c| try list_handlers.writeColumnUpdate(writer, c);
}

fn writeSavedDescription(writer: *Io.Writer, card: Card, column: ?Column) Io.Writer.Error!void {
    try writeDescription(writer, card);
    if (column) |c| try list_handlers.writeColumnUpdate(writer, c);
}

fn writeDeleted(writer: *Io.Writer, column: ?Column) Io.Writer.Error!void {
    if (column) |c| try list_handlers.writeColumnUpdate(writer, c);
    try list_handlers.writeCloseDialog(writer);
}

fn writeReordered(writer: *Io.Writer, removed_list_id: ?i64, columns: []const Column) Io.Writer.Error!void {
    if (removed_list_id) |id| try list_handlers.writeColumnRemoval(writer, id);
    for (columns) |column| try list_handlers.writeColumnUpdate(writer, column);
}

fn writeTitle(writer: *Io.Writer, card: Card) Io.Writer.Error!void {
    var id: Id = .{};
    try Title.render(writer, .{ .id = id.of(card.id), .title = card.title });
}

fn writeTitleEdit(writer: *Io.Writer, card: Card) Io.Writer.Error!void {
    var id: Id = .{};
    try TitleEdit.render(writer, .{ .id = id.of(card.id), .title = card.title });
}

fn writeDescription(writer: *Io.Writer, card: Card) Io.Writer.Error!void {
    var id: Id = .{};
    if (card.description.len == 0) return DescriptionEmpty.render(writer, .{ .id = id.of(card.id) });
    try Description.render(writer, .{ .id = id.of(card.id), .description = card.description });
}

fn writeDescriptionEdit(writer: *Io.Writer, card: Card) Io.Writer.Error!void {
    var id: Id = .{};
    try DescriptionEdit.render(writer, .{ .id = id.of(card.id), .description = card.description });
}

const testing = std.testing;
const boards = @import("../boards.zig");

fn formRequest(comptime method: []const u8, comptime path: []const u8, comptime body: []const u8) []const u8 {
    return method ++ " " ++ path ++ " HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}

fn get(comptime path: []const u8) []const u8 {
    return "GET " ++ path ++ " HTTP/1.1\r\nHost: test\r\n\r\n";
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "add a card, edit its details, and delete it" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const board = try boards.create(conn, arena.allocator(), "Board");
        _ = try lists.create(conn, arena.allocator(), board.id, "To do");
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/lists/1/cards", "title=+"), pool);
        defer t.deinit();
        try create(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(contains(try t.body(), "Title can&#39;t be blank."));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/lists/1/cards", "title=Write+%3Cspec%3E"), pool);
        defer t.deinit();
        try create(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 201), try t.status());
        try testing.expect(contains(t.response(), "HX-Retarget: #list-1\r\n"));
        const body = try t.body();
        try testing.expect(contains(body, ">Write &lt;spec&gt;</span>"));
        try testing.expect(contains(body, "1 card<"));
        // The only list can't move its cards, so it confirms in the browser.
        try testing.expect(contains(body, "All cards in it will also be deleted."));
        try testing.expect(!contains(body, "hx-get=\"/lists/1/delete\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/cards/1"), pool);
        defer t.deinit();
        try show(&t.ctx, "1");
        const body = try t.body();
        try testing.expect(contains(body, "data-modal"));
        try testing.expect(contains(body, "Click to add description"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/cards/1/description", "description=+Line+one%0D%0ALine+two+"), pool);
        defer t.deinit();
        try updateDescription(&t.ctx, "1");
        const body = try t.body();
        try testing.expect(contains(body, ">Line one\nLine two</button>"));
        try testing.expect(contains(body, "hx-target=\"#list-1\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/cards/1/title", "title=+"), pool);
        defer t.deinit();
        try updateTitle(&t.ctx, "1");
        try testing.expect(contains(try t.body(), ">Write &lt;spec&gt;</button>"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/cards/1/title", "title=Ship+it"), pool);
        defer t.deinit();
        try updateTitle(&t.ctx, "1");
        const body = try t.body();
        try testing.expect(contains(body, ">Ship it</button>"));
        try testing.expect(contains(body, ">Ship it</span>"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/cards/1/description", "description=+"), pool);
        defer t.deinit();
        try updateDescription(&t.ctx, "1");
        try testing.expect(contains(try t.body(), "Click to add description"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("DELETE /cards/1 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, "1");
        const body = try t.body();
        try testing.expect(contains(body, "No cards yet"));
        try testing.expect(contains(body, "hx-delete=\"/lists/1\""));
        try testing.expect(contains(body, "This action cannot be undone."));
        try testing.expect(!contains(body, "All cards in it"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/cards/1"), pool);
        defer t.deinit();
        try show(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 404), try t.status());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/lists/99/cards", "title=Lost"), pool);
        defer t.deinit();
        try create(&t.ctx, "99");
        try testing.expectEqual(@as(u16, 404), try t.status());
    }
}

test "reordering re-renders the list and the lists its cards came from" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const board = try boards.create(conn, a, "Board");
        const todo = (try lists.create(conn, a, board.id, "To do")).?;
        _ = (try lists.create(conn, a, board.id, "Done")).?;
        _ = try cards.create(conn, a, todo.id, "First");
        _ = try cards.create(conn, a, todo.id, "Second");
        const other = try boards.create(conn, a, "Other");
        _ = (try lists.create(conn, a, other.id, "Elsewhere")).?;
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=1&from_list_id=1&card_id=2&card_id=1"), pool);
        defer t.deinit();
        try reorder(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "hx-target=\"#list-1\" hx-swap=\"outerHTML\""));
        try testing.expect(!contains(body, "#list-2\""));
        const second = std.mem.indexOf(u8, body, ">Second</span>").?;
        try testing.expect(second < std.mem.indexOf(u8, body, ">First</span>").?);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=2&from_list_id=1&card_id=1"), pool);
        defer t.deinit();
        try reorder(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "hx-target=\"#list-2\" hx-swap=\"outerHTML\""));
        try testing.expect(contains(body, "hx-target=\"#list-1\" hx-swap=\"outerHTML\""));
        try testing.expect(contains(body, "1 card<"));
        try testing.expect(!contains(body, "hx-swap=\"delete\""));
    }
    {
        // A card deleted elsewhere is ignored, and the list it was dragged
        // from is still re-rendered.
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=2&from_list_id=1&card_id=99"), pool);
        defer t.deinit();
        try reorder(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "hx-target=\"#list-1\" hx-swap=\"outerHTML\""));
        try testing.expect(contains(body, "hx-target=\"#list-2\" hx-swap=\"outerHTML\""));
    }
    {
        // A list on another board: its column goes, and the card's real
        // column is re-rendered.
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=3&from_list_id=2&card_id=1"), pool);
        defer t.deinit();
        try reorder(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 404), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "hx-target=\"#list-3\" hx-swap=\"delete\""));
        try testing.expect(contains(body, "hx-target=\"#list-2\" hx-swap=\"outerHTML\""));
        try testing.expect(contains(body, ">First</span>"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=1&from_list_id=1&card_id=x"), pool);
        defer t.deinit();
        try testing.expectError(error.InvalidForm, reorder(&t.ctx, "1"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/card-order", "list_id=1&card_id=1"), pool);
        defer t.deinit();
        try testing.expectError(error.InvalidForm, reorder(&t.ctx, "1"));
    }
}
