//! Working-memory pages and HTMX partials. Entries are created from the
//! composer dialog, edited inline, and deleted individually or all at once.
//! SQL lives in `working_memory.zig`.

const std = @import("std");
const http = @import("../http.zig");
const template = @import("../template.zig");
const working_memory = @import("../working_memory.zig");

const Io = std.Io;
const Context = http.Context;
const Entry = working_memory.Entry;

const PageStart = template.Template(@embedFile("../public/working-memory/page-start.html"));
const PageEnd = template.Template(@embedFile("../public/working-memory/page-end.html"));
const EntryView = template.Template(@embedFile("../public/working-memory/entry.html"));
const EntryEdit = template.Template(@embedFile("../public/working-memory/entry-edit.html"));
const EntryMissing = template.Template(@embedFile("../public/working-memory/entry-missing.html"));
const ComposerError = template.Template(@embedFile("../public/working-memory/composer-error.html"));

/// GET /
pub fn index(ctx: *Context) !void {
    const entries = try working_memory.list(try ctx.dbConn(), ctx.arena);
    return ctx.page(.{ .active = .working_memory }, writePage, .{entries});
}

/// POST /entries: responds 201 with the new entry as an out-of-band swap into
/// the list (the main swap target, the composer's error area, is cleared).
pub fn create(ctx: *Context) !void {
    const body = try ctx.readForm();
    const content = try working_memory.normalize(ctx.arena, body.get("content") orelse "") orelse
        return blank(ctx);
    const entry = working_memory.create(try ctx.dbConn(), ctx.arena, content) catch |err| switch (err) {
        error.BlankContent => return blank(ctx),
        else => |e| return e,
    };
    return ctx.html(.created, writeCreated, .{entry});
}

/// DELETE /entries
pub fn clear(ctx: *Context) !void {
    try working_memory.deleteAll(try ctx.dbConn());
    return ctx.html(.ok, writeNothing, .{});
}

/// GET /entries/{id}: the read-only entry, used to leave edit mode.
pub fn show(ctx: *Context, id_text: []const u8) !void {
    const entry = try findEntry(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeEntry, .{entry});
}

/// GET /entries/{id}/edit
pub fn edit(ctx: *Context, id_text: []const u8) !void {
    const entry = try findEntry(ctx, id_text) orelse return missing(ctx);
    return ctx.html(.ok, writeEdit, .{entry});
}

/// PUT /entries/{id}: saving blank content keeps the existing text, matching
/// the original app, which treats clearing an entry as cancelling the edit.
pub fn update(ctx: *Context, id_text: []const u8) !void {
    const id = parseId(id_text) orelse return missing(ctx);
    const body = try ctx.readForm();
    const conn = try ctx.dbConn();
    const content = try working_memory.normalize(ctx.arena, body.get("content") orelse "") orelse
        return show(ctx, id_text);
    const entry = working_memory.update(conn, ctx.arena, id, content) catch |err| switch (err) {
        error.BlankContent => return show(ctx, id_text),
        else => |e| return e,
    } orelse return missing(ctx);
    return ctx.html(.ok, writeEntry, .{entry});
}

/// DELETE /entries/{id}: idempotent; the row is removed client-side either way.
pub fn destroy(ctx: *Context, id_text: []const u8) !void {
    if (parseId(id_text)) |id| _ = try working_memory.delete(try ctx.dbConn(), id);
    // 200 rather than 204: HTMX skips swapping (and so deleting) on 204.
    return ctx.html(.ok, writeNothing, .{});
}

fn findEntry(ctx: *Context, id_text: []const u8) !?Entry {
    const id = parseId(id_text) orelse return null;
    return working_memory.find(try ctx.dbConn(), ctx.arena, id);
}

fn blank(ctx: *Context) !void {
    return ctx.html(.unprocessable_entity, ComposerError.render, .{.{ .message = "Entry can't be blank." }});
}

fn missing(ctx: *Context) !void {
    return ctx.html(.not_found, EntryMissing.render, .{.{}});
}

const parseId = http.parseId;

fn writePage(writer: *Io.Writer, entries: []const Entry) Io.Writer.Error!void {
    try PageStart.render(writer, .{});
    for (entries) |entry| try writeEntry(writer, entry);
    try PageEnd.render(writer, .{});
}

fn writeCreated(writer: *Io.Writer, entry: Entry) Io.Writer.Error!void {
    // The wrapper is stripped by HTMX; its children are prepended to the list.
    try writer.writeAll("<div hx-swap-oob=\"afterbegin:#entries\">\n");
    try writeEntry(writer, entry);
    try writer.writeAll("</div>\n");
}

fn writeEntry(writer: *Io.Writer, entry: Entry) Io.Writer.Error!void {
    var id_buffer: [20]u8 = undefined;
    try EntryView.render(writer, .{
        .id = formatId(&id_buffer, entry.id),
        .content = entry.content,
        .updated_at = entry.updated_at,
    });
}

fn writeEdit(writer: *Io.Writer, entry: Entry) Io.Writer.Error!void {
    var id_buffer: [20]u8 = undefined;
    try EntryEdit.render(writer, .{ .id = formatId(&id_buffer, entry.id), .content = entry.content });
}

fn writeNothing(_: *Io.Writer) Io.Writer.Error!void {}

fn formatId(buffer: *[20]u8, id: i64) []const u8 {
    return std.mem.print(buffer, "{d}", .{id}) catch unreachable;
}

const testing = std.testing;

test "entries render escaped with preserved newlines" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeEntry(&out.writer, .{ .id = 7, .content = "<b>hi</b>\nthere", .updated_at = "2026-01-01T00:00:00Z" });
    const html = out.written();
    try testing.expect(std.mem.find(u8, html, "id=\"entry-7\"") != null);
    try testing.expect(std.mem.find(u8, html, "hx-get=\"/entries/7/edit\"") != null);
    try testing.expect(std.mem.find(u8, html, ">&lt;b&gt;hi&lt;/b&gt;\nthere</button>") != null);
}

test "edit form puts content after the textarea's ignored leading newline" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeEdit(&out.writer, .{ .id = 3, .content = "a & b", .updated_at = "" });
    try testing.expect(std.mem.find(u8, out.written(), ">\na &amp; b</textarea>") != null);
}

fn formRequest(comptime method: []const u8, comptime path: []const u8, comptime body: []const u8) []const u8 {
    return method ++ " " ++ path ++ " HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}

test "create responds 201 with an out-of-band entry and rejects blank content" {
    const pool = try working_memory.testPool();
    defer pool.deinit();

    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/entries", "content=+first%0D%0Asecond+"), pool);
        defer t.deinit();
        try create(&t.ctx);
        try testing.expectEqual(@as(u16, 201), try t.status());
        const body = try t.body();
        try testing.expect(std.mem.startsWith(u8, body, "<div hx-swap-oob=\"afterbegin:#entries\">"));
        try testing.expect(std.mem.find(u8, body, ">first\nsecond</button>") != null);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("POST", "/entries", "content=%20%0A"), pool);
        defer t.deinit();
        try create(&t.ctx);
        try testing.expectEqual(@as(u16, 422), try t.status());
        try testing.expect(std.mem.find(u8, try t.body(), "Entry can&#39;t be blank.") != null);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET / HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try index(&t.ctx);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try t.body(), "data-testid=\"wm-entry-"));
    }
}

test "edit, update, and show round-trip an entry" {
    const pool = try working_memory.testPool();
    defer pool.deinit();
    const id = blk: {
        const conn = try pool.acquire();
        defer conn.release();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        break :blk (try working_memory.create(conn, arena.allocator(), "original")).id;
    };
    var id_buffer: [20]u8 = undefined;
    const id_text = formatId(&id_buffer, id);

    {
        var t: http.TestRequest = undefined;
        try t.init("GET /entries/x/edit HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try edit(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expect(std.mem.find(u8, try t.body(), ">\noriginal</textarea>") != null);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/entries/x", "content=revised"), pool);
        defer t.deinit();
        try update(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expect(std.mem.find(u8, try t.body(), ">revised</button>") != null);
    }
    {
        // Blank content leaves the entry unchanged.
        var t: http.TestRequest = undefined;
        try t.init(formRequest("PUT", "/entries/x", "content=+"), pool);
        defer t.deinit();
        try update(&t.ctx, id_text);
        try testing.expectEqual(@as(u16, 200), try t.status());
        try testing.expect(std.mem.find(u8, try t.body(), ">revised</button>") != null);
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("GET /entries/x HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try show(&t.ctx, "999999");
        try testing.expectEqual(@as(u16, 404), try t.status());
        try testing.expect(std.mem.find(u8, try t.body(), "no longer exists") != null);
    }
}

test "destroy and clear remove entries" {
    const pool = try working_memory.testPool();
    defer pool.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first, const second = blk: {
        const conn = try pool.acquire();
        defer conn.release();
        break :blk .{
            try working_memory.create(conn, a, "one"),
            try working_memory.create(conn, a, "two"),
        };
    };
    _ = second;

    var id_buffer: [20]u8 = undefined;
    for (0..2) |_| {
        // Deleting twice succeeds both times.
        var t: http.TestRequest = undefined;
        try t.init("DELETE /entries/x HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try destroy(&t.ctx, formatId(&id_buffer, first.id));
        try testing.expectEqual(@as(u16, 200), try t.status());
    }
    {
        var t: http.TestRequest = undefined;
        try t.init("DELETE /entries HTTP/1.1\r\nHost: test\r\n\r\n", pool);
        defer t.deinit();
        try clear(&t.ctx);
        try testing.expectEqual(@as(u16, 200), try t.status());
    }
    const conn = try pool.acquire();
    defer conn.release();
    try testing.expectEqual(@as(usize, 0), (try working_memory.list(conn, a)).len);
}
