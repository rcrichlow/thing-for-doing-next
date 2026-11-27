//! Boards index, archived boards, and the board page header: create, rename,
//! archive, unarchive, and permanently delete. SQL lives in `boards.zig`.
//!
//! Actions that can be triggered from the board page take `?from=board` and
//! answer with `HX-Redirect: /boards`; from the index or archived grid they
//! remove the board's card instead.

const std = @import("std");
const http = @import("../http.zig");
const template = @import("../template.zig");
const boards = @import("../boards.zig");
const list_handlers = @import("lists.zig");

const Io = std.Io;
const Context = http.Context;
const Board = boards.Board;
const parseId = http.parseId;

fn Tmpl(comptime name: []const u8) type {
    return template.Template(@embedFile("../public/boards/" ++ name ++ ".html"));
}

const IndexStart = Tmpl("index-start");
const GridEnd = Tmpl("grid-end");
const Empty = Tmpl("empty");
const Card = Tmpl("card");
const CreateTile = Tmpl("create-tile");
const CreateForm = Tmpl("create-form");
const ArchivedStart = Tmpl("archived-start");
const ArchivedEmpty = Tmpl("archived-empty");
const ArchivedCard = Tmpl("archived-card");
const ShowStart = Tmpl("show-start");
const ArchivedBanner = Tmpl("archived-banner");
const HeaderStart = Tmpl("header-start");
const ArchivedPill = Tmpl("archived-pill");
const HeaderMiddle = Tmpl("header-middle");
const Actions = Tmpl("actions");
const HeaderEnd = Tmpl("header-end");
const Title = Tmpl("title");
const TitleEdit = Tmpl("title-edit");
const NotFound = Tmpl("not-found");
const CardMoveForm = Tmpl("card-move-form");
const ListMoveForm = Tmpl("list-move-form");
const Missing = Tmpl("missing");

/// GET /boards
pub fn index(ctx: *Context) !void {
    const active = try boards.listActive(try ctx.dbConn(), ctx.arena);
    return ctx.page(.{ .active = .boards }, writeIndex, .{active});
}

/// GET /boards/new: the inline create form, replacing the create tile.
pub fn newForm(ctx: *Context) !void {
    return ctx.html(.ok, CreateForm.render, .{.{ .title = "", .message = "" }});
}

/// GET /boards/tile: the idle create tile, used to cancel the form.
pub fn createTile(ctx: *Context) !void {
    return ctx.html(.ok, CreateTile.render, .{.{}});
}

/// POST /boards: responds 201 with the new board's card followed by a fresh
/// create tile, replacing the form.
pub fn create(ctx: *Context) !void {
    const body = try ctx.readForm();
    const raw = body.get("title") orelse "";
    const title = try boards.normalizeTitle(ctx.arena, raw) orelse return blankCreate(ctx, raw);
    const board = boards.create(try ctx.dbConn(), ctx.arena, title) catch |err| switch (err) {
        error.BlankTitle => return blankCreate(ctx, raw),
        else => |e| return e,
    };
    return ctx.html(.created, writeCreated, .{board});
}

/// GET /boards/archived
pub fn archived(ctx: *Context) !void {
    const list = try boards.listArchived(try ctx.dbConn(), ctx.arena);
    return ctx.page(.{ .active = .boards, .title = "Archived Boards · " ++ http.app_title }, writeArchived, .{list});
}

/// GET /boards/{id}
pub fn show(ctx: *Context, id_text: []const u8) !void {
    const board = try findBoard(ctx, id_text) orelse
        return ctx.page(.{ .active = .boards, .status = .not_found }, NotFound.render, .{.{}});
    const page_title = try ctx.arena.print("{s} · {s}", .{ board.title, http.app_title });
    const columns = try list_handlers.loadColumns(ctx, board.id);
    return ctx.page(.{ .active = .boards, .title = page_title }, writeShow, .{ board, columns });
}

/// GET /boards/{id}/title: the read-only title, used to cancel editing.
pub fn showTitle(ctx: *Context, id_text: []const u8) !void {
    const board = try findBoard(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitle, .{board});
}

/// GET /boards/{id}/title/edit
pub fn editTitle(ctx: *Context, id_text: []const u8) !void {
    const board = try findBoard(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeTitleEdit, .{board});
}

/// PUT /boards/{id}/title: re-renders the whole header, since its archive and
/// delete confirmations quote the title. A blank title keeps the old one.
pub fn rename(ctx: *Context, id_text: []const u8) !void {
    const id = parseId(id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const conn = try ctx.dbConn();
    const title = try boards.normalizeTitle(ctx.arena, body.get("title") orelse "") orelse
        return showTitle(ctx, id_text);
    const board = boards.rename(conn, ctx.arena, id, title) catch |err| switch (err) {
        error.BlankTitle => return showTitle(ctx, id_text),
        else => |e| return e,
    } orelse return missing(ctx);
    return ctx.htmlWithHeaders(.ok, &.{
        .{ .name = "HX-Retarget", .value = "#board-header" },
        .{ .name = "HX-Reswap", .value = "outerHTML" },
    }, writeHeader, .{board});
}

/// POST /boards/{id}/archive
pub fn archive(ctx: *Context, id_text: []const u8) !void {
    if (parseId(id_text)) |id| _ = try boards.archive(try ctx.dbConn(), id);
    if (try fromBoard(ctx)) return ctx.redirect("/boards");
    return removedFromIndex(ctx);
}

/// POST /boards/{id}/unarchive
pub fn unarchive(ctx: *Context, id_text: []const u8) !void {
    if (parseId(id_text)) |id| _ = try boards.unarchive(try ctx.dbConn(), id);
    if (try fromBoard(ctx)) return ctx.redirect("/boards");
    return removedFromArchived(ctx);
}

/// DELETE /boards/{id}: permanent. Idempotent, like the other removals.
pub fn destroy(ctx: *Context, id_text: []const u8) !void {
    if (parseId(id_text)) |id| _ = try boards.delete(try ctx.dbConn(), id);
    if (try fromBoard(ctx)) return ctx.redirect("/boards");
    return removedFromArchived(ctx);
}

fn fromBoard(ctx: *Context) !bool {
    const query = try ctx.queryForm();
    return std.mem.eql(u8, query.get("from") orelse "", "board");
}

/// The card is deleted client-side (200, not 204, so HTMX swaps). When the
/// last one goes, the grid shows its empty state instead.
fn removedFromIndex(ctx: *Context) !void {
    if ((try boards.listActive(try ctx.dbConn(), ctx.arena)).len > 0) return ctx.html(.ok, writeNothing, .{});
    return ctx.htmlWithHeaders(.ok, &.{
        .{ .name = "HX-Retarget", .value = "#boards-grid" },
        .{ .name = "HX-Reswap", .value = "innerHTML" },
    }, Empty.render, .{.{}});
}

fn removedFromArchived(ctx: *Context) !void {
    if (try boards.countArchived(try ctx.dbConn()) > 0) return ctx.html(.ok, writeNothing, .{});
    return ctx.htmlWithHeaders(.ok, &.{
        .{ .name = "HX-Retarget", .value = "#archived-grid" },
        .{ .name = "HX-Reswap", .value = "innerHTML" },
    }, ArchivedEmpty.render, .{.{}});
}

fn findBoard(ctx: *Context, id_text: []const u8) !?Board {
    const id = parseId(id_text) orelse return null;
    return boards.find(try ctx.dbConn(), ctx.arena, id);
}

fn blankCreate(ctx: *Context, raw: []const u8) !void {
    return ctx.html(.unprocessable_entity, CreateForm.render, .{.{ .title = raw, .message = "Title can't be blank." }});
}

fn missing(ctx: *Context) !void {
    return ctx.html(.not_found, Missing.render, .{.{}});
}

/// Formats ids for templates, which only accept strings.
const Id = struct {
    buffer: [20]u8 = undefined,
    fn of(id: *Id, value: i64) []const u8 {
        return std.mem.print(&id.buffer, "{d}", .{value}) catch unreachable;
    }
};

/// The date part of an ISO 8601 timestamp, shown until JavaScript localizes it.
fn datePart(timestamp: []const u8) []const u8 {
    return timestamp[0..@min(timestamp.len, 10)];
}

fn writeIndex(writer: *Io.Writer, active: []const Board) Io.Writer.Error!void {
    try IndexStart.render(writer, .{});
    if (active.len == 0) {
        try Empty.render(writer, .{});
    } else {
        for (active) |board| try writeCard(writer, board);
        try CreateTile.render(writer, .{});
    }
    try GridEnd.render(writer, .{});
}

fn writeCreated(writer: *Io.Writer, board: Board) Io.Writer.Error!void {
    try writeCard(writer, board);
    try CreateTile.render(writer, .{});
}

fn writeCard(writer: *Io.Writer, board: Board) Io.Writer.Error!void {
    var id: Id = .{};
    try Card.render(writer, .{
        .id = id.of(board.id),
        .title = board.title,
        .created_at = board.created_at,
        .created_date = datePart(board.created_at),
    });
}

fn writeArchived(writer: *Io.Writer, list: []const Board) Io.Writer.Error!void {
    try ArchivedStart.render(writer, .{});
    if (list.len == 0) try ArchivedEmpty.render(writer, .{});
    for (list) |board| {
        var id: Id = .{};
        const archived_at = board.archived_at orelse "";
        try ArchivedCard.render(writer, .{
            .id = id.of(board.id),
            .title = board.title,
            .archived_at = archived_at,
            .archived_date = datePart(archived_at),
        });
    }
    try GridEnd.render(writer, .{});
}

fn writeShow(writer: *Io.Writer, board: Board, columns: []const list_handlers.Column) Io.Writer.Error!void {
    try ShowStart.render(writer, .{});
    try writeHeader(writer, board);
    try writer.writeAll("<div class=\"min-h-0 flex-1 overflow-x-auto overflow-y-hidden p-6\" data-board-scroll>\n<div id=\"board-lists\" class=\"flex h-full items-start gap-6\">\n");
    try list_handlers.writeContents(writer, .{ .board_id = board.id, .columns = columns });
    // Card details and list deletion dialogs are loaded into `#modal-root`.
    try writer.writeAll("</div>\n</div>\n<div id=\"modal-root\"></div>\n");
    // app.js submits this form after moving a card in the page.
    var id: Id = .{};
    try CardMoveForm.render(writer, .{ .board_id = id.of(board.id) });
    try ListMoveForm.render(writer, .{ .board_id = id.of(board.id) });
    try writer.writeAll("</div>\n");
}

/// The archived banner (if archived) and the header bar, wrapped in
/// `#board-header` so a rename can replace them together.
fn writeHeader(writer: *Io.Writer, board: Board) Io.Writer.Error!void {
    var id: Id = .{};
    const values = .{ .id = id.of(board.id), .title = board.title };
    try writer.writeAll("<div id=\"board-header\">\n");
    if (board.isArchived()) try ArchivedBanner.render(writer, values);
    try HeaderStart.render(writer, .{});
    try writeTitle(writer, board);
    try HeaderMiddle.render(writer, .{});
    if (board.isArchived()) {
        try HeaderEnd.render(writer, .{ .back_url = "/boards/archived", .back_label = "Back to Archived" });
    } else {
        try Actions.render(writer, values);
        try HeaderEnd.render(writer, .{ .back_url = "/boards", .back_label = "Back to Boards" });
    }
    try writer.writeAll("</div>\n");
}

/// The title, with the archived pill beside it, as in the original app.
fn writeTitle(writer: *Io.Writer, board: Board) Io.Writer.Error!void {
    var id: Id = .{};
    try Title.render(writer, .{ .id = id.of(board.id), .title = board.title });
    if (board.isArchived()) try ArchivedPill.render(writer, .{});
    try writer.writeAll("</h1>\n");
}

fn writeTitleEdit(writer: *Io.Writer, board: Board) Io.Writer.Error!void {
    var id: Id = .{};
    try TitleEdit.render(writer, .{ .id = id.of(board.id), .title = board.title });
}

fn writeNothing(_: *Io.Writer) Io.Writer.Error!void {}

const testing = std.testing;

fn formRequest(comptime method: []const u8, comptime path: []const u8, comptime body: []const u8) []const u8 {
    return method ++ " " ++ path ++ " HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}

fn get(comptime path: []const u8) []const u8 {
    return "GET " ++ path ++ " HTTP/1.1\r\nHost: test\r\n\r\n";
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, haystack, needle) != null;
}

fn createBoard(pool: anytype, name: []const u8) !Board {
    const conn = try pool.acquire();
    defer conn.release();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const board = try boards.create(conn, arena.allocator(), name);
    // Only the id is used after the arena is freed.
    return .{ .id = board.id, .title = "", .created_at = "", .archived_at = null };
}

test "index shows an empty state, then boards with a create tile" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards"), pool);
        defer t.deinit();
        try index(&t.ctx);
        try testing.expect(contains(try t.body(), "No boards yet"));
        try testing.expect(!contains(try t.body(), "id=\"board-create\""));
    }
    _ = try createBoard(pool, "Home & \"Work\"");
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards"), pool);
        defer t.deinit();
        try index(&t.ctx);
        const body = try t.body();
        try testing.expect(!contains(body, "No boards yet"));
        try testing.expect(contains(body, ">Home &amp; &quot;Work&quot;</a>"));
        try testing.expect(contains(body, "hx-confirm=\"Archive board &quot;Home &amp; &quot;Work&quot;&quot;?\""));
        try testing.expect(contains(body, "id=\"board-create\""));
    }
}

test "create returns the card and a fresh tile, and rejects blank titles" {
    const pool = try boards.testPool();
    defer pool.deinit();
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards", "title=+Plans%0A2027+"), pool);
        defer t.deinit();
        try create(&t.ctx);
        try testing.expectEqual(@as(u16, 201), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, ">Plans 2027</a>"));
        try testing.expect(contains(body, "hx-get=\"/boards/new\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/boards", "title=%20"), pool);
        defer t.deinit();
        try create(&t.ctx);
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(contains(try t.body(), "Title can&#39;t be blank."));
    }
}

test "board page renders the header, and missing boards are 404 pages" {
    const pool = try boards.testPool();
    defer pool.deinit();
    const board = try createBoard(pool, "Roadmap");
    var id: Id = .{};
    const id_text = id.of(board.id);
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards/1"), pool);
        defer t.deinit();
        try show(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        const body = try t.body();
        try testing.expect(contains(body, "<title>Roadmap · Thing for Doing Next</title>"));
        try testing.expect(contains(body, "id=\"board-actions\""));
        try testing.expect(contains(body, "Back to Boards"));
        try testing.expect(!contains(body, "This board is archived."));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards/999999"), pool);
        defer t.deinit();
        try show(&t.ctx, "999999");
        try testing.expectEqual(@as(u16, 404), try t.status());
        try testing.expect(contains(try t.body(), "Board not found"));
    }
}

test "rename re-renders the header; blank keeps the old title" {
    const pool = try boards.testPool();
    defer pool.deinit();
    const board = try createBoard(pool, "Old");
    var id: Id = .{};
    const id_text = id.of(board.id);
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/title", "title=New"), pool);
        defer t.deinit();
        try rename(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expect(contains(t.response(), "HX-Retarget: #board-header\r\n"));
        const body = try t.body();
        try testing.expect(contains(body, ">New</button>"));
        try testing.expect(contains(body, "Archive board &quot;New&quot;?"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/boards/1/title", "title=+"), pool);
        defer t.deinit();
        try rename(&t.ctx, id_text);
        try testing.expect(!contains(t.response(), "HX-Retarget"));
        try testing.expect(contains(try t.body(), ">New</button>"));
    }
}

test "archive, unarchive, and delete remove cards or redirect from the board page" {
    const pool = try boards.testPool();
    defer pool.deinit();
    const first = try createBoard(pool, "First");
    _ = try createBoard(pool, "Second");
    var id: Id = .{};
    const id_text = id.of(first.id);
    {
        // Another active board remains, so the card is simply removed.
        var t: http.TestRequest = undefined;
        try t.init("POST /boards/1/archive HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", pool);
        defer t.deinit();
        try archive(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expectEqualStrings("", try t.body());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards/1"), pool);
        defer t.deinit();
        try show(&t.ctx, id_text);
        const body = try t.body();
        try testing.expect(contains(body, "This board is archived."));
        try testing.expect(contains(body, "Back to Archived"));
        try testing.expect(!contains(body, "id=\"board-actions\""));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("POST /boards/1/unarchive?from=board HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", pool);
        defer t.deinit();
        try unarchive(&t.ctx, id_text);
        try testing.expect(contains(t.response(), "HX-Redirect: /boards\r\n"));
    }
    {
        // Archive then delete from the archived page: the last archived board
        // is replaced by the empty state.
        var t: http.TestRequest = undefined;
        try t.init("POST /boards/1/archive HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", pool);
        defer t.deinit();
        try archive(&t.ctx, id_text);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("DELETE /boards/1 HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, id_text);
        try testing.expect(contains(t.response(), "HX-Retarget: #archived-grid\r\n"));
        try testing.expect(contains(try t.body(), "No archived boards"));
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(get("/boards/1"), pool);
        defer t.deinit();
        try show(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 404), try t.status());
    }
}
