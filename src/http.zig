//! Request context and response helpers shared by `main.zig`'s router and the
//! feature handler modules in `handlers/`.

const std = @import("std");
const db = @import("db.zig");
const form = @import("form.zig");
const layout = @import("layout.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
pub const Request = http.Server.Request;

pub const app_title = "Thing for Doing Next";
pub const text_type = "text/plain; charset=utf-8";
pub const html_type = "text/html; charset=utf-8";
/// Largest request body accepted by `Context.readBody`.
pub const max_body_bytes = 64 * 1024;

pub const ResponseError = Allocator.Error || Request.ExpectContinueError;

pub const ResponseOptions = struct {
    status: http.Status = .ok,
    content_type: []const u8,
    cache_control: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    /// Additional headers, e.g. `HX-Redirect`.
    headers: []const http.Header = &.{},
};

pub const PageOptions = struct {
    /// Navigation section to highlight.
    active: ?layout.Section,
    /// Document title; defaults to the app name.
    title: []const u8 = app_title,
    status: http.Status = .ok,
    width: layout.Width = .contained,
};

pub const Context = struct {
    arena: Allocator,
    request: *Request,
    method: http.Method,
    /// Target path without the query string. Not percent-decoded.
    path: []const u8,
    /// Raw query string without the leading `?`; empty if absent.
    query: []const u8,
    content_type: ?[]const u8,
    db_pool: ?*db.Pool,
    /// Acquired on first use by `dbConn` and released by `deinit`.
    db_conn: ?*db.Conn = null,

    /// Copies the request head strings into `arena`, since reading the body
    /// invalidates them.
    pub fn init(arena: Allocator, request: *Request, db_pool: ?*db.Pool) Allocator.Error!Context {
        const target = request.head.target;
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        return .{
            .arena = arena,
            .request = request,
            .method = request.head.method,
            .path = try arena.dupe(u8, if (query_start) |i| target[0..i] else target),
            .query = try arena.dupe(u8, if (query_start) |i| target[i + 1 ..] else ""),
            .content_type = if (request.head.content_type) |value| try arena.dupe(u8, value) else null,
            .db_pool = db_pool,
        };
    }

    pub fn deinit(ctx: *Context) void {
        if (ctx.db_conn) |conn| conn.release();
        ctx.db_conn = null;
    }

    /// Returns this request's database connection, acquiring it on first use.
    /// Handlers pass it to query modules and never hold a second connection.
    pub fn dbConn(ctx: *Context) !*db.Conn {
        if (ctx.db_conn) |conn| return conn;
        const pool = ctx.db_pool orelse return error.DatabaseUnavailable;
        ctx.db_conn = try pool.acquire();
        return ctx.db_conn.?;
    }

    pub fn queryForm(ctx: *const Context) form.ParseError!form.Form {
        return form.parse(ctx.arena, ctx.query);
    }

    /// Reads and decodes an `application/x-www-form-urlencoded` request body.
    pub fn readForm(ctx: *Context) !form.Form {
        const content_type = ctx.content_type orelse return error.UnsupportedMediaType;
        const media_type = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
        if (!std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded")) {
            return error.UnsupportedMediaType;
        }
        return form.parse(ctx.arena, try ctx.readBody());
    }

    /// Reads the entire request body, up to `max_body_bytes`.
    pub fn readBody(ctx: *Context) ![]const u8 {
        const head = &ctx.request.head;
        if (head.transfer_compression != .identity) return error.UnsupportedMediaType;
        if (head.content_length) |length| {
            if (length > max_body_bytes) return error.PayloadTooLarge;
        }
        // The server keeps a reference to this buffer until the body is
        // consumed, so it must live as long as the request.
        const transfer_buffer = try ctx.arena.alloc(u8, 1024);
        const body_reader = try ctx.request.readerExpectContinue(transfer_buffer);
        return body_reader.allocRemaining(ctx.arena, .limited(max_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => error.PayloadTooLarge,
            error.ReadFailed, error.OutOfMemory => |e| e,
        };
    }

    pub fn respond(ctx: *Context, body: []const u8, options: ResponseOptions) ResponseError!void {
        const headers = try ctx.arena.alloc(http.Header, 3 + options.headers.len);
        var count: usize = 0;
        headers[count] = .{ .name = "content-type", .value = options.content_type };
        count += 1;
        if (options.cache_control) |value| {
            headers[count] = .{ .name = "cache-control", .value = value };
            count += 1;
        }
        if (options.allow) |value| {
            headers[count] = .{ .name = "allow", .value = value };
            count += 1;
        }
        @memcpy(headers[count..][0..options.headers.len], options.headers);
        count += options.headers.len;
        return ctx.request.respond(body, .{ .status = options.status, .extra_headers = headers[0..count] });
    }

    pub fn methodNotAllowed(ctx: *Context, allow: []const u8) ResponseError!void {
        return ctx.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .content_type = text_type,
            .allow = allow,
        });
    }

    pub fn notFound(ctx: *Context) ResponseError!void {
        return ctx.respond("not found\n", .{ .status = .not_found, .content_type = text_type });
    }

    /// Renders an HTML fragment by calling `render(writer, args...)` and
    /// responds with it. Used for HTMX partial responses.
    pub fn html(ctx: *Context, status: http.Status, comptime render: anytype, args: anytype) ResponseError!void {
        var out: Io.Writer.Allocating = .init(ctx.arena);
        // Writing to an allocating writer only fails when allocation fails.
        @call(.auto, render, .{&out.writer} ++ args) catch return error.OutOfMemory;
        return ctx.respond(out.written(), .{ .status = status, .content_type = html_type });
    }

    /// Like `html`, with additional response headers such as `HX-Retarget`.
    pub fn htmlWithHeaders(
        ctx: *Context,
        status: http.Status,
        headers: []const http.Header,
        comptime render: anytype,
        args: anytype,
    ) ResponseError!void {
        var out: Io.Writer.Allocating = .init(ctx.arena);
        @call(.auto, render, .{&out.writer} ++ args) catch return error.OutOfMemory;
        return ctx.respond(out.written(), .{ .status = status, .content_type = html_type, .headers = headers });
    }

    /// Responds with an empty body that tells HTMX to navigate to `location`.
    pub fn redirect(ctx: *Context, location: []const u8) ResponseError!void {
        return ctx.respond("", .{
            .content_type = html_type,
            .headers = &.{.{ .name = "HX-Redirect", .value = location }},
        });
    }

    /// Renders a full page: the shared layout around `render(writer, args...)`.
    pub fn page(ctx: *Context, options: PageOptions, comptime render: anytype, args: anytype) ResponseError!void {
        var out: Io.Writer.Allocating = .init(ctx.arena);
        renderPage(&out.writer, options, render, args) catch return error.OutOfMemory;
        return ctx.respond(out.written(), .{ .status = options.status, .content_type = html_type });
    }
};

fn renderPage(writer: *Io.Writer, options: PageOptions, comptime render: anytype, args: anytype) Io.Writer.Error!void {
    try layout.writeStart(writer, .{ .title = options.title, .active = options.active, .width = options.width });
    try @call(.auto, render, .{writer} ++ args);
    try layout.writeEnd(writer, options.width);
}

/// Returns the segment captured by the single `{name}` placeholder in
/// `pattern` if `path` matches, or null. Captures never contain `/`.
pub fn pathParam(comptime pattern: []const u8, path: []const u8) ?[]const u8 {
    const open = comptime std.mem.indexOfScalar(u8, pattern, '{') orelse
        @compileError("pathParam pattern needs a {name} placeholder; compare static paths directly");
    const close = comptime std.mem.indexOfScalarPos(u8, pattern, open, '}') orelse
        @compileError("unclosed placeholder in route pattern");
    const prefix = pattern[0..open];
    const suffix = pattern[close + 1 ..];
    comptime if (std.mem.indexOfScalar(u8, suffix, '{') != null) {
        @compileError("route patterns support a single placeholder");
    };

    if (path.len <= prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const segment = path[prefix.len .. path.len - suffix.len];
    if (std.mem.indexOfScalar(u8, segment, '/') != null) return null;
    return segment;
}

/// Parses a path segment as a record id. Accepts only canonical positive
/// decimal ids; callers treat anything else as not found.
pub fn parseId(text: []const u8) ?i64 {
    if (text.len == 0 or text.len > 18 or text[0] == '0') return null;
    for (text) |char| if (!std.ascii.isDigit(char)) return null;
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// Test helper: parses a raw HTTP request into a `Context` whose response is
/// captured in memory.
pub const TestRequest = struct {
    arena: std.heap.ArenaAllocator,
    in: Io.Reader,
    out: Io.Writer.Allocating,
    server: http.Server,
    request: Request,
    ctx: Context,

    /// `self` must not move after `init`.
    pub fn init(self: *TestRequest, raw_request: []const u8, db_pool: ?*db.Pool) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.in = .fixed(raw_request);
        self.out = .init(self.arena.allocator());
        self.server = http.Server.init(&self.in, &self.out.writer);
        self.request = try self.server.receiveHead();
        self.ctx = try Context.init(self.arena.allocator(), &self.request, db_pool);
    }

    pub fn deinit(self: *TestRequest) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    /// The raw response bytes written so far.
    pub fn response(self: *TestRequest) []const u8 {
        return self.out.written();
    }

    pub fn status(self: *TestRequest) !u16 {
        const raw = self.response();
        if (raw.len < 12 or !std.mem.startsWith(u8, raw, "HTTP/1.1 ")) return error.TestUnexpectedResult;
        return std.fmt.parseInt(u16, raw[9..12], 10);
    }

    pub fn body(self: *TestRequest) ![]const u8 {
        const raw = self.response();
        const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.TestUnexpectedResult;
        return raw[head_end + 4 ..];
    }
};

const testing = std.testing;

test "context splits path and query" {
    var t: TestRequest = undefined;
    try t.init("GET /entries/7?sort=new&q=a+b HTTP/1.1\r\nHost: test\r\n\r\n", null);
    defer t.deinit();
    try testing.expectEqualStrings("/entries/7", t.ctx.path);
    try testing.expectEqualStrings("sort=new&q=a+b", t.ctx.query);
    const query = try t.ctx.queryForm();
    try testing.expectEqualStrings("a b", query.get("q").?);
}

test "reads a urlencoded form body" {
    var t: TestRequest = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded; charset=UTF-8\r\n" ++
        "Content-Length: 22\r\n\r\nbody=first%0Asecond+it", null);
    defer t.deinit();
    const body = try t.ctx.readForm();
    try testing.expectEqualStrings("first\nsecond it", body.get("body").?);
    // Path must survive body reading invalidating the request head strings.
    try testing.expectEqualStrings("/entries", t.ctx.path);
}

test "reads a chunked form body" {
    var t: TestRequest = undefined;
    try t.init("PUT /entries/1 HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n4\r\n=hey\r\n0\r\n\r\n", null);
    defer t.deinit();
    const body = try t.ctx.readForm();
    try testing.expectEqualStrings("hey", body.get("body").?);
}

test "rejects non-form content types" {
    var t: TestRequest = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", null);
    defer t.deinit();
    try testing.expectError(error.UnsupportedMediaType, t.ctx.readForm());
}

test "rejects oversized declared bodies" {
    var t: TestRequest = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 65537\r\n\r\n", null);
    defer t.deinit();
    try testing.expectError(error.PayloadTooLarge, t.ctx.readForm());
}

test "rejects oversized chunked bodies" {
    const chunk = "a" ** 0x8000;
    const raw = "POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "8000\r\n" ++ chunk ++ "\r\n8000\r\n" ++ chunk ++ "\r\n1\r\na\r\n0\r\n\r\n";
    var t: TestRequest = undefined;
    try t.init(raw, null);
    defer t.deinit();
    try testing.expectError(error.PayloadTooLarge, t.ctx.readForm());
}

test "database access without a pool is a server error" {
    var t: TestRequest = undefined;
    try t.init("GET / HTTP/1.1\r\nHost: test\r\n\r\n", null);
    defer t.deinit();
    try testing.expectError(error.DatabaseUnavailable, t.ctx.dbConn());
}

test "parseId accepts only canonical positive ids" {
    try testing.expectEqual(@as(?i64, 42), parseId("42"));
    try testing.expectEqual(null, parseId(""));
    try testing.expectEqual(null, parseId("0"));
    try testing.expectEqual(null, parseId("042"));
    try testing.expectEqual(null, parseId("+4"));
    try testing.expectEqual(null, parseId("-4"));
    try testing.expectEqual(null, parseId("4a"));
    try testing.expectEqual(null, parseId("9999999999999999999"));
}

test "path params capture one segment" {
    try testing.expectEqualStrings("42", pathParam("/entries/{id}", "/entries/42").?);
    try testing.expectEqualStrings("42", pathParam("/entries/{id}/edit", "/entries/42/edit").?);
    try testing.expectEqual(null, pathParam("/entries/{id}", "/entries/"));
    try testing.expectEqual(null, pathParam("/entries/{id}", "/entries/42/edit"));
    try testing.expectEqual(null, pathParam("/entries/{id}/edit", "/entries//edit"));
    try testing.expectEqual(null, pathParam("/entries/{id}", "/boards/42"));
}
