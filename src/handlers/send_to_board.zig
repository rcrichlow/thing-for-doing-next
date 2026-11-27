//! Working-memory send dialog. Picker changes and inline creation replace only
//! the dialog's fields; the dialog itself stays open across HTMX swaps.
const std = @import("std");
const http = @import("../http.zig");
const template = @import("../template.zig");
const working_memory = @import("../working_memory.zig");
const boards = @import("../boards.zig");
const lists = @import("../lists.zig");
const cards = @import("../cards.zig");
const Id = @import("lists.zig").Id;
const Io = std.Io;
const Context = http.Context;

fn T(comptime name: []const u8) type {
    return template.Template(@embedFile("../public/send-to-board/" ++ name ++ ".html"));
}

const State = struct {
    entry_id: i64,
    boards: []const boards.Board,
    lists: []const lists.List,
    board_id: ?i64 = null,
    list_id: ?i64 = null,
    new_board: bool = false,
    new_list: bool = false,
    title: []const u8 = "",
    message: []const u8 = "",
};

fn load(ctx: *Context, entry_id: i64, board_text: []const u8, list_text: []const u8) !State {
    const conn = try ctx.dbConn();
    const active = try boards.listActive(conn, ctx.arena);
    var state: State = .{ .entry_id = entry_id, .boards = active, .lists = &.{} };
    state.new_board = std.mem.eql(u8, board_text, "new");
    if (http.parseId(board_text)) |id| {
        for (active) |board| if (board.id == id) {
            state.board_id = id;
            state.lists = try lists.forBoard(conn, ctx.arena, id);
            break;
        };
    }
    if (state.board_id != null) {
        state.new_list = std.mem.eql(u8, list_text, "new");
        if (http.parseId(list_text)) |id| {
            for (state.lists) |list| if (list.id == id) {
                state.list_id = id;
                break;
            };
        }
    }
    return state;
}

fn entry(ctx: *Context, id_text: []const u8) !?working_memory.Entry {
    const id = http.parseId(id_text) orelse return null;
    return working_memory.find(try ctx.dbConn(), ctx.arena, id);
}

fn missing(ctx: *Context) !void {
    return ctx.htmlWithHeaders(.not_found, &.{
        .{ .name = "HX-Retarget", .value = "#modal-root" },
        .{ .name = "HX-Reswap", .value = "innerHTML" },
    }, T("missing").render, .{.{}});
}

pub fn dialog(ctx: *Context, id_text: []const u8) !void {
    const item = try entry(ctx, id_text) orelse return missing(ctx);
    const state = try load(ctx, item.id, "", "");
    return ctx.html(.ok, writeDialog, .{ item, state });
}

pub fn fields(ctx: *Context, id_text: []const u8) !void {
    const item = try entry(ctx, id_text) orelse return missing(ctx);
    const query = try ctx.queryForm();
    const state = try load(ctx, item.id, query.get("board_id") orelse "", query.get("list_id") orelse "");
    return ctx.html(.ok, writeFields, .{state});
}

pub fn createBoard(ctx: *Context, id_text: []const u8) !void {
    const item = try entry(ctx, id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const raw = body.get("title") orelse "";
    const title = try boards.normalizeTitle(ctx.arena, raw) orelse return createError(ctx, item.id, "new", "", raw, "Board name can't be blank.");
    const board = boards.create(try ctx.dbConn(), ctx.arena, title) catch |err| switch (err) {
        error.BlankTitle => return createError(ctx, item.id, "new", "", raw, "Board name can't be blank."),
        else => |e| return e,
    };
    var id: Id = .{};
    return ctx.html(.created, writeFields, .{try load(ctx, item.id, id.of(board.id), "")});
}

pub fn createList(ctx: *Context, id_text: []const u8) !void {
    const item = try entry(ctx, id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const board_text = body.get("board_id") orelse "";
    const raw = body.get("title") orelse "";
    const state = try load(ctx, item.id, board_text, "new");
    const board_id = state.board_id orelse return createError(ctx, item.id, "", "", "", "That board is no longer available. Choose another board.");
    const title = try lists.normalizeTitle(ctx.arena, raw) orelse return createError(ctx, item.id, board_text, "new", raw, "List name can't be blank.");
    const list = lists.createOnActiveBoard(try ctx.dbConn(), ctx.arena, board_id, title) catch |err| switch (err) {
        error.BlankTitle => return createError(ctx, item.id, board_text, "new", raw, "List name can't be blank."),
        else => |e| return e,
    } orelse return createError(ctx, item.id, "", "", "", "That board is no longer available. Choose another board.");
    var id: Id = .{};
    return ctx.html(.created, writeFields, .{try load(ctx, item.id, board_text, id.of(list.id))});
}

pub fn send(ctx: *Context, id_text: []const u8) !void {
    const item = try entry(ctx, id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const board_text = body.get("board_id") orelse "";
    const list_text = body.get("list_id") orelse "";
    const board_id = http.parseId(board_text) orelse return createError(ctx, item.id, board_text, "", "", "Choose a board and list.");
    const list_id = http.parseId(list_text) orelse return createError(ctx, item.id, board_text, "", "", "Choose a board and list.");
    const title = try cards.normalizeTitle(ctx.arena, item.content) orelse return createError(ctx, item.id, board_text, list_text, "", "Entry can't be used as a card title.");
    const created = working_memory.sendToBoard(try ctx.dbConn(), item.id, board_id, list_id, title) catch |err| switch (err) {
        error.BlankContent => return createError(ctx, item.id, board_text, list_text, "", "Entry can't be used as a card title."),
        else => |e| return e,
    };
    if (!created) return createError(ctx, item.id, board_text, list_text, "", "That destination is no longer available. Choose a board and list.");
    return ctx.htmlWithHeaders(.created, &.{
        .{ .name = "HX-Retarget", .value = "#modal-root" },
        .{ .name = "HX-Reswap", .value = "innerHTML" },
    }, writeNothing, .{});
}

fn createError(ctx: *Context, entry_id: i64, board_text: []const u8, list_text: []const u8, title: []const u8, message: []const u8) !void {
    var state = try load(ctx, entry_id, board_text, list_text);
    state.title = title;
    state.message = message;
    return ctx.html(.unprocessable_entity, writeFields, .{state});
}

fn writeDialog(writer: *Io.Writer, item: working_memory.Entry, state: State) Io.Writer.Error!void {
    try T("dialog-start").render(writer, .{ .content = item.content });
    try writeFields(writer, state);
    try T("dialog-end").render(writer, .{});
}

fn writeFields(writer: *Io.Writer, state: State) Io.Writer.Error!void {
    var entry_id: Id = .{};
    const id = entry_id.of(state.entry_id);
    try T("fields-start").render(writer, .{ .id = id });
    for (state.boards) |board| {
        var option_id: Id = .{};
        try T("option").render(writer, .{ .id = option_id.of(board.id), .title = board.title, .selected = selected(state.board_id == board.id) });
    }
    try T("board-end").render(writer, .{ .selected = selected(state.new_board) });
    try T("list-start").render(writer, .{ .id = id, .disabled = disabled(state.board_id == null) });
    for (state.lists) |list| {
        var option_id: Id = .{};
        try T("option").render(writer, .{ .id = option_id.of(list.id), .title = list.title, .selected = selected(state.list_id == list.id) });
    }
    try T("list-end").render(writer, .{ .selected = selected(state.new_list) });
    if (state.new_board) try T("create-board").render(writer, .{ .id = id, .title = state.title });
    if (state.new_list) {
        var board_id: Id = .{};
        try T("create-list").render(writer, .{ .id = id, .board_id = board_id.of(state.board_id.?), .title = state.title });
    }
    try T("fields-end").render(writer, .{ .disabled = disabled(state.list_id == null), .message = state.message });
}

fn selected(value: bool) []const u8 {
    return if (value) "selected" else "";
}
fn disabled(value: bool) []const u8 {
    return if (value) "disabled" else "";
}
fn writeNothing(_: *Io.Writer) Io.Writer.Error!void {}

const testing = std.testing;
fn formRequest(comptime path: []const u8, comptime body: []const u8) []const u8 {
    return "POST " ++ path ++ " HTTP/1.1\r\nHost: test\r\nContent-Type: application/x-www-form-urlencoded\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}
fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "send picker creates destinations and copies an entry only to a valid active board" {
    const pool = try working_memory.testPool();
    defer pool.deinit();
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try working_memory.create(conn, a, "one <two>\nthree");
        const other = try boards.create(conn, a, "Other");
        _ = try lists.create(conn, a, other.id, "Other list");
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /entries/1/send HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try dialog(&t.ctx, "1");
        try testing.expect(contains(try t.body(), "one &lt;two&gt;\nthree"));
        try testing.expect(contains(try t.body(), "Other</option>"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send/board", "title=+New+%26+Board+"), pool);
        defer t.deinit();
        try createBoard(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 201), try t.status());
        try testing.expect(contains(try t.body(), "value=\"2\" selected>New &amp; Board"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send/list", "board_id=2&title=+"), pool);
        defer t.deinit();
        try createList(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(contains(try t.body(), "List name can&#39;t be blank"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send/list", "board_id=2&title=Tasks"), pool);
        defer t.deinit();
        try createList(&t.ctx, "1");
        try testing.expect(contains(try t.body(), "value=\"2\" selected>Tasks"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send", "board_id=2&list_id=1"), pool);
        defer t.deinit();
        try send(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(contains(try t.body(), "destination is no longer available"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send", "board_id=2&list_id=2"), pool);
        defer t.deinit();
        try send(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 201), try t.status());
        try testing.expect(contains(t.response(), "HX-Retarget: #modal-root"));
    }
    {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try testing.expectEqualStrings("one <two>\nthree", (try working_memory.find(conn, a, 1)).?.content);
        const saved = try cards.forList(conn, a, 2);
        try testing.expectEqual(@as(usize, 1), saved.len);
        try testing.expectEqualStrings("one <two> three", saved[0].title);
        _ = try boards.archive(conn, 2);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send", "board_id=2&list_id=2"), pool);
        defer t.deinit();
        try send(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("/entries/1/send/list", "board_id=2&title=Nope"), pool);
        defer t.deinit();
        try createList(&t.ctx, "1");
        try testing.expectEqual(@as(u16, 422), try t.status());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /entries/999/send HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try dialog(&t.ctx, "999");
        try testing.expectEqual(@as(u16, 404), try t.status());
        try testing.expect(contains(try t.body(), "This entry no longer exists"));
    }
}
