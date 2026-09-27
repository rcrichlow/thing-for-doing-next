const std = @import("std");
const form = @import("form.zig");
const layout = @import("layout.zig");
const template = @import("template.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const Request = http.Server.Request;

const app_title = "Thing for Doing Next";
const app_css = @embedFile("public/app.css");
const htmx_js = @embedFile("public/htmx-4.0.0-beta6.min.js");
const WorkingMemoryPage = template.Template(@embedFile("public/pages/working-memory.html"));
const BoardsPage = template.Template(@embedFile("public/pages/boards.html"));

/// Upper bound on concurrently running tasks. `Io.Threaded` applies this limit
/// process-wide to every `concurrent` task, so it caps open connections and any
/// other concurrent work together.
const max_concurrent_tasks = 16;
/// Largest request body accepted by `Context.readBody`.
const max_body_bytes = 64 * 1024;
/// Per-connection arena memory kept between requests on a keep-alive connection.
const retained_arena_bytes = 256 * 1024;

const Config = struct {
    port: u16,

    fn fromEnvironment() !Config {
        const port_text = std.c.getenv("PORT") orelse return parse(null);
        return parse(std.mem.span(port_text));
    }

    fn parse(port_text: ?[]const u8) !Config {
        const text = port_text orelse return .{ .port = 3000 };
        return .{ .port = try std.fmt.parseInt(u16, text, 10) };
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();
    var threaded = Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(max_concurrent_tasks) });
    defer threaded.deinit();
    const io = threaded.io();

    const config = try Config.fromEnvironment();
    const address = try Io.net.IpAddress.parse("0.0.0.0", config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var connections: Io.Group = .init;
    defer connections.cancel(io);

    std.log.info("listening on http://0.0.0.0:{d}", .{config.port});
    while (true) {
        const stream = try listener.accept(io);
        connections.concurrent(io, handleConnection, .{ io, gpa, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => rejectAtCapacity(io, stream),
        };
    }
}

/// Answers a connection that could not be scheduled with 503 and closes it.
/// Runs on the accept loop, so it writes a single small response and never
/// reads from the client.
fn rejectAtCapacity(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    std.log.warn("rejecting connection: at capacity ({d} concurrent tasks)", .{max_concurrent_tasks});

    const body = "server at capacity\n";
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 503 Service Unavailable\r\n" ++
            "connection: close\r\n" ++
            "retry-after: 1\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    var send_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch return;
    stream.shutdown(io, .send) catch {};
}

fn handleConnection(io: Io, gpa: Allocator, stream: Io.net.Stream) void {
    serveConnection(io, gpa, stream) catch |err| std.log.err("connection failed: {t}", .{err});
}

fn serveConnection(io: Io, gpa: Allocator, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var receive_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &receive_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = http.Server.init(&reader.interface, &writer.interface);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    while (server.reader.state == .ready) {
        _ = arena.reset(.{ .retain_with_limit = retained_arena_bytes });
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try handleRequest(arena.allocator(), &request);
    }
}

/// Maps errors a handler may return to 4xx statuses. Any other error becomes a
/// 500, except `WriteFailed`, which means the client is gone.
fn clientErrorStatus(err: anyerror) ?http.Status {
    return switch (err) {
        error.PayloadTooLarge => .payload_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.InvalidForm => .bad_request,
        else => null,
    };
}

/// Responds to a single request. Handlers render into memory and respond
/// last, so any error they return means no response bytes have been written.
fn handleRequest(arena: Allocator, request: *Request) !void {
    // std.http.Server asserts when discarding a body with no declared length,
    // so such requests must be answered without keep-alive before routing.
    if (request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and
        request.head.content_length == null)
    {
        return respondError(request, .length_required);
    }

    var ctx = try Context.init(arena, request);
    route(&ctx) catch |err| switch (err) {
        error.WriteFailed => return err,
        error.HttpExpectationFailed => {
            request.head.expect = null;
            return respondError(request, .expectation_failed);
        },
        else => {
            if (clientErrorStatus(err)) |status| return respondError(request, status);
            std.log.err("{t} {s} failed: {t}", .{ ctx.method, ctx.path, err });
            return respondError(request, .internal_server_error);
        },
    };
}

/// Sends a plain-text error and closes the connection, since the state of any
/// request body is unknown.
fn respondError(request: *Request, status: http.Status) Request.ExpectContinueError!void {
    var body_buffer: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer, "{s}\n", .{status.phrase() orelse "error"}) catch unreachable;
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = text_type }},
    });
}

const text_type = "text/plain; charset=utf-8";
const html_type = "text/html; charset=utf-8";

const Context = struct {
    arena: Allocator,
    request: *Request,
    method: http.Method,
    /// Target path without the query string. Not percent-decoded.
    path: []const u8,
    /// Raw query string without the leading `?`; empty if absent.
    query: []const u8,
    content_type: ?[]const u8,

    /// Copies the request head strings into `arena`, since reading the body
    /// invalidates them.
    fn init(arena: Allocator, request: *Request) Allocator.Error!Context {
        const target = request.head.target;
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        return .{
            .arena = arena,
            .request = request,
            .method = request.head.method,
            .path = try arena.dupe(u8, if (query_start) |i| target[0..i] else target),
            .query = try arena.dupe(u8, if (query_start) |i| target[i + 1 ..] else ""),
            .content_type = if (request.head.content_type) |value| try arena.dupe(u8, value) else null,
        };
    }

    fn queryForm(ctx: *const Context) form.ParseError!form.Form {
        return form.parse(ctx.arena, ctx.query);
    }

    /// Reads and decodes an `application/x-www-form-urlencoded` request body.
    fn readForm(ctx: *Context) !form.Form {
        const content_type = ctx.content_type orelse return error.UnsupportedMediaType;
        const media_type = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
        if (!std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded")) {
            return error.UnsupportedMediaType;
        }
        return form.parse(ctx.arena, try ctx.readBody());
    }

    /// Reads the entire request body, up to `max_body_bytes`.
    fn readBody(ctx: *Context) ![]const u8 {
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

    fn respond(ctx: *Context, body: []const u8, options: ResponseOptions) Request.ExpectContinueError!void {
        var headers: [3]http.Header = undefined;
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
        return ctx.request.respond(body, .{ .status = options.status, .extra_headers = headers[0..count] });
    }

    fn methodNotAllowed(ctx: *Context, allow: []const u8) Request.ExpectContinueError!void {
        return ctx.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .content_type = text_type,
            .allow = allow,
        });
    }

    /// Renders `Body` inside the shared layout and responds with the result.
    fn page(
        ctx: *Context,
        active: ?layout.Section,
        comptime Body: type,
        values: anytype,
    ) (Allocator.Error || Request.ExpectContinueError)!void {
        var html: Io.Writer.Allocating = .init(ctx.arena);
        // Writing to an allocating writer only fails when allocation fails.
        renderPage(&html.writer, active, Body, values) catch return error.OutOfMemory;
        return ctx.respond(html.written(), .{ .content_type = html_type });
    }
};

const ResponseOptions = struct {
    status: http.Status = .ok,
    content_type: []const u8,
    cache_control: ?[]const u8 = null,
    allow: ?[]const u8 = null,
};

fn renderPage(writer: *Io.Writer, active: ?layout.Section, comptime Body: type, values: anytype) Io.Writer.Error!void {
    try layout.writeStart(writer, .{ .title = app_title, .active = active });
    try Body.render(writer, values);
    try layout.writeEnd(writer);
}

/// Returns the segment captured by the single `{name}` placeholder in
/// `pattern` if `path` matches, or null. Captures never contain `/`.
fn pathParam(comptime pattern: []const u8, path: []const u8) ?[]const u8 {
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

const read_methods = "GET, HEAD";

fn route(ctx: *Context) !void {
    const path = ctx.path;

    if (std.mem.eql(u8, path, "/up")) return switch (ctx.method) {
        .GET, .HEAD => ctx.respond("{\"status\":\"ok\"}\n", .{ .content_type = "application/json" }),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/assets/app.css")) return switch (ctx.method) {
        .GET, .HEAD => ctx.respond(app_css, .{
            .content_type = "text/css; charset=utf-8",
            .cache_control = "no-cache",
        }),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/assets/htmx-4.0.0-beta6.min.js")) return switch (ctx.method) {
        .GET, .HEAD => ctx.respond(htmx_js, .{
            .content_type = "text/javascript; charset=utf-8",
            .cache_control = "public, max-age=31536000, immutable",
        }),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/")) return switch (ctx.method) {
        .GET, .HEAD => ctx.page(.working_memory, WorkingMemoryPage, .{}),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/boards")) return switch (ctx.method) {
        .GET, .HEAD => ctx.page(.boards, BoardsPage, .{}),
        else => ctx.methodNotAllowed(read_methods),
    };

    return ctx.respond("not found\n", .{ .status = .not_found, .content_type = text_type });
}

test {
    _ = form;
    _ = layout;
    _ = template;
}

const testing = std.testing;

/// Feeds a raw HTTP request through `handleRequest` and returns the raw
/// response bytes written into `out_buffer`.
fn testRequest(raw_request: []const u8, out_buffer: []u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(raw_request);
    var out: Io.Writer = .fixed(out_buffer);
    var server = http.Server.init(&in, &out);
    var request = try server.receiveHead();
    try handleRequest(arena.allocator(), &request);
    return out.buffered();
}

fn expectHeader(response: []const u8, header: []const u8) !void {
    const head_end = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 2;
    if (std.mem.indexOf(u8, response[0..head_end], header) == null) {
        std.debug.print("missing header '{s}' in:\n{s}\n", .{ header, response[0..head_end] });
        return error.TestUnexpectedResult;
    }
}

test "health check responds with JSON status" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("GET /up HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-type: application/json\r\n");
    try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\n{\"status\":\"ok\"}\n"));
}

test "HEAD omits the body but keeps the length" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("HEAD /up HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-length: 16\r\n");
    try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\n"));
}

test "query strings do not affect routing" {
    var buffer: [16 * 1024]u8 = undefined;
    const response = try testRequest("GET /?from=test HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-type: text/html; charset=utf-8\r\n");
    try testing.expect(std.mem.indexOf(u8, response, "Working Memory</h1>") != null);
}

test "pages highlight their navigation section" {
    var buffer: [16 * 1024]u8 = undefined;
    const response = try testRequest("GET /boards HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.indexOf(u8, response, "href=\"/boards\"\n    aria-current=\"page\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Boards</h1>") != null);
}

test "unknown path responds 404" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("GET /nope HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 Not Found\r\n"));
}

test "unsupported method responds 405 with Allow" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("DELETE /up HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try expectHeader(response, "allow: GET, HEAD\r\n");
}

test "body without a length responds 411 and closes" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("POST /up HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 411 Length Required\r\n"));
    try expectHeader(response, "connection: close\r\n");
}

test "body with a length is discarded for 405" {
    var buffer: [1024]u8 = undefined;
    const response = try testRequest("POST /up HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\na=b", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 405 Method Not Allowed\r\n"));
}

test "client errors map to 4xx statuses" {
    try testing.expectEqual(http.Status.payload_too_large, clientErrorStatus(error.PayloadTooLarge).?);
    try testing.expectEqual(http.Status.unsupported_media_type, clientErrorStatus(error.UnsupportedMediaType).?);
    try testing.expectEqual(http.Status.bad_request, clientErrorStatus(error.InvalidForm).?);
    try testing.expectEqual(null, clientErrorStatus(error.OutOfMemory));
}

/// Parses a raw request head and builds a Context for exercising body helpers.
const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    in: Io.Reader,
    out: Io.Writer,
    out_buffer: [256]u8,
    server: http.Server,
    request: Request,
    ctx: Context,

    fn init(self: *TestContext, raw_request: []const u8) !void {
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        self.in = .fixed(raw_request);
        self.out = .fixed(&self.out_buffer);
        self.server = http.Server.init(&self.in, &self.out);
        self.request = try self.server.receiveHead();
        self.ctx = try Context.init(self.arena.allocator(), &self.request);
    }

    fn deinit(self: *TestContext) void {
        self.arena.deinit();
    }
};

test "context splits path and query" {
    var t: TestContext = undefined;
    try t.init("GET /entries/7?sort=new&q=a+b HTTP/1.1\r\nHost: test\r\n\r\n");
    defer t.deinit();
    try testing.expectEqualStrings("/entries/7", t.ctx.path);
    try testing.expectEqualStrings("sort=new&q=a+b", t.ctx.query);
    const query = try t.ctx.queryForm();
    try testing.expectEqualStrings("a b", query.get("q").?);
}

test "reads a urlencoded form body" {
    var t: TestContext = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded; charset=UTF-8\r\n" ++
        "Content-Length: 22\r\n\r\nbody=first%0Asecond+it");
    defer t.deinit();
    const body = try t.ctx.readForm();
    try testing.expectEqualStrings("first\nsecond it", body.get("body").?);
    // Path must survive body reading invalidating the request head strings.
    try testing.expectEqualStrings("/entries", t.ctx.path);
}

test "reads a chunked form body" {
    var t: TestContext = undefined;
    try t.init("PUT /entries/1 HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n4\r\n=hey\r\n0\r\n\r\n");
    defer t.deinit();
    const body = try t.ctx.readForm();
    try testing.expectEqualStrings("hey", body.get("body").?);
}

test "rejects non-form content types" {
    var t: TestContext = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    defer t.deinit();
    try testing.expectError(error.UnsupportedMediaType, t.ctx.readForm());
}

test "rejects oversized declared bodies" {
    var t: TestContext = undefined;
    try t.init("POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 65537\r\n\r\n");
    defer t.deinit();
    try testing.expectError(error.PayloadTooLarge, t.ctx.readForm());
}

test "rejects oversized chunked bodies" {
    const chunk = "a" ** 0x8000;
    const raw = "POST /entries HTTP/1.1\r\nHost: test\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "8000\r\n" ++ chunk ++ "\r\n8000\r\n" ++ chunk ++ "\r\n1\r\na\r\n0\r\n\r\n";
    var t: TestContext = undefined;
    try t.init(raw);
    defer t.deinit();
    try testing.expectError(error.PayloadTooLarge, t.ctx.readForm());
}

test "path params capture one segment" {
    try testing.expectEqualStrings("42", pathParam("/entries/{id}", "/entries/42").?);
    try testing.expectEqualStrings("42", pathParam("/entries/{id}/edit", "/entries/42/edit").?);
    try testing.expectEqual(null, pathParam("/entries/{id}", "/entries/"));
    try testing.expectEqual(null, pathParam("/entries/{id}", "/entries/42/edit"));
    try testing.expectEqual(null, pathParam("/entries/{id}/edit", "/entries//edit"));
    try testing.expectEqual(null, pathParam("/entries/{id}", "/boards/42"));
}

test "port defaults to 3000 without PORT" {
    const config = try Config.parse(null);
    try testing.expectEqual(@as(u16, 3000), config.port);
}

test "port is parsed from PORT" {
    const config = try Config.parse("8080");
    try testing.expectEqual(@as(u16, 8080), config.port);
}

test "invalid PORT is rejected" {
    try testing.expectError(error.InvalidCharacter, Config.parse("abc"));
    try testing.expectError(error.Overflow, Config.parse("70000"));
}
