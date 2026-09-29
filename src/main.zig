const std = @import("std");
const db = @import("db.zig");
const form = @import("form.zig");
const http = @import("http.zig");
const layout = @import("layout.zig");
const migrate = @import("migrate.zig");
const migrations = @import("migrations");
const template = @import("template.zig");
const boards = @import("handlers/boards.zig");
const working_memory = @import("handlers/working_memory.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = http.Context;
const Request = http.Request;
const Status = std.http.Status;
const pathParam = http.pathParam;

const app_css = @embedFile("public/app.css");
const app_js = @embedFile("public/app.js");
const htmx_js = @embedFile("public/htmx-4.0.0-beta6.min.js");

/// Upper bound on concurrently running tasks. `Io.Threaded` applies this limit
/// process-wide to every `concurrent` task, so it caps open connections and any
/// other concurrent work together.
const max_concurrent_tasks = 16;
/// One database connection per possible concurrent request, so a request that
/// holds at most one connection never waits for the pool.
const db_pool_size = max_concurrent_tasks;
/// Per-connection arena memory kept between requests on a keep-alive connection.
const retained_arena_bytes = 256 * 1024;

const Config = struct {
    port: u16,
    database_url: [:0]const u8,

    fn fromEnvironment() !Config {
        const database_url = std.c.getenv("DATABASE_URL") orelse {
            std.log.err("DATABASE_URL is not set", .{});
            return error.MissingDatabaseUrl;
        };
        const port_text = std.c.getenv("PORT");
        return .{
            .port = try parsePort(if (port_text) |text| std.mem.span(text) else null),
            .database_url = std.mem.span(database_url),
        };
    }

    fn parsePort(port_text: ?[]const u8) !u16 {
        const text = port_text orelse return 3000;
        return std.fmt.parseInt(u16, text, 10);
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

    const pool = try db.Pool.init(io, gpa, .{ .url = config.database_url, .size = db_pool_size });
    defer pool.deinit();
    try runMigrations(pool);

    const address = try Io.net.IpAddress.parse("0.0.0.0", config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var connections: Io.Group = .init;
    defer connections.cancel(io);

    const app: App = .{ .io = io, .gpa = gpa, .pool = pool };
    std.log.info("listening on http://0.0.0.0:{d}", .{config.port});
    while (true) {
        const stream = try listener.accept(io);
        connections.concurrent(io, handleConnection, .{ &app, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => rejectAtCapacity(io, stream),
        };
    }
}

/// Process-wide state shared by every connection task.
const App = struct {
    io: Io,
    gpa: Allocator,
    pool: *db.Pool,
};

fn runMigrations(pool: *db.Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();

    var diagnostics: migrate.Diagnostics = .{};
    const applied = migrate.run(conn, &migrations.all, &diagnostics) catch |err| {
        if (diagnostics.failed_version) |version| {
            std.log.err("migration {s} failed: {t} {s} {s}", .{ version, err, diagnostics.code(), diagnostics.message() });
        } else {
            std.log.err("running migrations failed: {t}", .{err});
        }
        return err;
    };
    std.log.info("migrations up to date ({d} applied, {d} total)", .{ applied, migrations.all.len });
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

fn handleConnection(app: *const App, stream: Io.net.Stream) void {
    serveConnection(app, stream) catch |err| std.log.err("connection failed: {t}", .{err});
}

fn serveConnection(app: *const App, stream: Io.net.Stream) !void {
    const io = app.io;
    defer stream.close(io);

    var receive_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &receive_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();

    while (server.reader.state == .ready) {
        _ = arena.reset(.{ .retain_with_limit = retained_arena_bytes });
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try handleRequest(arena.allocator(), &request, app.pool);
    }
}

/// Maps errors a handler may return to 4xx statuses. Any other error becomes a
/// 500, except `WriteFailed`, which means the client is gone.
fn clientErrorStatus(err: anyerror) ?Status {
    return switch (err) {
        error.PayloadTooLarge => .payload_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.InvalidForm => .bad_request,
        else => null,
    };
}

/// Responds to a single request. Handlers render into memory and respond
/// last, so any error they return means no response bytes have been written.
fn handleRequest(arena: Allocator, request: *Request, pool: ?*db.Pool) !void {
    // std.http.Server asserts when discarding a body with no declared length,
    // so such requests must be answered without keep-alive before routing.
    if (request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and
        request.head.content_length == null)
    {
        return respondError(request, .length_required);
    }

    var ctx = try Context.init(arena, request, pool);
    defer ctx.deinit();
    route(&ctx) catch |err| switch (err) {
        error.WriteFailed => return err,
        error.HttpExpectationFailed => {
            request.head.expect = null;
            return respondError(request, .expectation_failed);
        },
        else => {
            if (clientErrorStatus(err)) |status| return respondError(request, status);
            std.log.err("{t} {s} failed: {t}", .{ ctx.method, ctx.path, err });
            if (ctx.db_conn) |conn| if (conn.err) |pg_err| {
                std.log.err("PostgreSQL {s}: {s}", .{ pg_err.code, pg_err.message });
            };
            return respondError(request, .internal_server_error);
        },
    };
}

/// Sends a plain-text error and closes the connection, since the state of any
/// request body is unknown.
fn respondError(request: *Request, status: Status) Request.ExpectContinueError!void {
    var body_buffer: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer, "{s}\n", .{status.phrase() orelse "error"}) catch unreachable;
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = http.text_type }},
    });
}

const read_methods = "GET, HEAD";

fn route(ctx: *Context) !void {
    const path = ctx.path;

    if (std.mem.eql(u8, path, "/up")) return switch (ctx.method) {
        .GET, .HEAD => ctx.respond("{\"status\":\"ok\"}\n", .{ .content_type = "application/json" }),
        else => ctx.methodNotAllowed(read_methods),
    };

    // Not /assets/app.css: an early build served that URL as immutable, so
    // browsers that loaded it keep a stale copy for a year.
    if (std.mem.eql(u8, path, "/assets/styles.css")) return asset(ctx, app_css, "text/css; charset=utf-8", revalidate);
    if (std.mem.eql(u8, path, "/assets/app.js")) return asset(ctx, app_js, js_type, revalidate);
    if (std.mem.eql(u8, path, "/assets/htmx-4.0.0-beta6.min.js")) return asset(ctx, htmx_js, js_type, immutable);

    if (std.mem.eql(u8, path, "/")) return switch (ctx.method) {
        .GET, .HEAD => working_memory.index(ctx),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/entries")) return switch (ctx.method) {
        .POST => working_memory.create(ctx),
        .DELETE => working_memory.clear(ctx),
        else => ctx.methodNotAllowed("POST, DELETE"),
    };

    if (pathParam("/entries/{id}/edit", path)) |id| return switch (ctx.method) {
        .GET, .HEAD => working_memory.edit(ctx, id),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (pathParam("/entries/{id}", path)) |id| return switch (ctx.method) {
        .GET, .HEAD => working_memory.show(ctx, id),
        .PUT => working_memory.update(ctx, id),
        .DELETE => working_memory.destroy(ctx, id),
        else => ctx.methodNotAllowed("GET, HEAD, PUT, DELETE"),
    };

    if (std.mem.eql(u8, path, "/boards")) return switch (ctx.method) {
        .GET, .HEAD => boards.index(ctx),
        .POST => boards.create(ctx),
        else => ctx.methodNotAllowed("GET, HEAD, POST"),
    };

    if (std.mem.eql(u8, path, "/boards/new")) return switch (ctx.method) {
        .GET, .HEAD => boards.newForm(ctx),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/boards/tile")) return switch (ctx.method) {
        .GET, .HEAD => boards.createTile(ctx),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (std.mem.eql(u8, path, "/boards/archived")) return switch (ctx.method) {
        .GET, .HEAD => boards.archived(ctx),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (pathParam("/boards/{id}", path)) |id| return switch (ctx.method) {
        .GET, .HEAD => boards.show(ctx, id),
        .DELETE => boards.destroy(ctx, id),
        else => ctx.methodNotAllowed("GET, HEAD, DELETE"),
    };

    if (pathParam("/boards/{id}/title", path)) |id| return switch (ctx.method) {
        .GET, .HEAD => boards.showTitle(ctx, id),
        .PUT => boards.rename(ctx, id),
        else => ctx.methodNotAllowed("GET, HEAD, PUT"),
    };

    if (pathParam("/boards/{id}/title/edit", path)) |id| return switch (ctx.method) {
        .GET, .HEAD => boards.editTitle(ctx, id),
        else => ctx.methodNotAllowed(read_methods),
    };

    if (pathParam("/boards/{id}/archive", path)) |id| return switch (ctx.method) {
        .POST => boards.archive(ctx, id),
        else => ctx.methodNotAllowed("POST"),
    };

    if (pathParam("/boards/{id}/unarchive", path)) |id| return switch (ctx.method) {
        .POST => boards.unarchive(ctx, id),
        else => ctx.methodNotAllowed("POST"),
    };

    return ctx.notFound();
}

const js_type = "text/javascript; charset=utf-8";
/// First-party assets change with every build, so browsers revalidate them.
const revalidate = "no-cache";
/// Vendored assets carry their version in the URL.
const immutable = "public, max-age=31536000, immutable";

fn asset(ctx: *Context, body: []const u8, content_type: []const u8, cache_control: []const u8) !void {
    return switch (ctx.method) {
        .GET, .HEAD => ctx.respond(body, .{ .content_type = content_type, .cache_control = cache_control }),
        else => ctx.methodNotAllowed(read_methods),
    };
}

test {
    _ = db;
    _ = form;
    _ = http;
    _ = layout;
    _ = migrate;
    _ = template;
    _ = working_memory;
    _ = boards;
    _ = @import("working_memory.zig");
    _ = @import("boards.zig");
    _ = @import("text.zig");
}

const testing = std.testing;

/// Feeds a raw HTTP request through `handleRequest` and returns the raw
/// response bytes written into `out_buffer`.
fn testRequest(raw_request: []const u8, out_buffer: []u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(raw_request);
    var out: Io.Writer = .fixed(out_buffer);
    var server = std.http.Server.init(&in, &out);
    var request = try server.receiveHead();
    try handleRequest(arena.allocator(), &request, null);
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
    const response = try testRequest("GET /up?from=test HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-type: application/json\r\n");
}

test "board routes enforce methods" {
    var buffer: [1024]u8 = undefined;
    var response = try testRequest("GET /boards/1/archive HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try expectHeader(response, "allow: POST\r\n");
    response = try testRequest("PUT /boards/1 HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", &buffer);
    try expectHeader(response, "allow: GET, HEAD, DELETE\r\n");
}

test "entry routes enforce methods and match ids" {
    var buffer: [1024]u8 = undefined;
    var response = try testRequest("PATCH /entries/1 HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try expectHeader(response, "allow: GET, HEAD, PUT, DELETE\r\n");
    response = try testRequest("GET /entries HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try expectHeader(response, "allow: POST, DELETE\r\n");
    response = try testRequest("GET /entries/1/2 HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 Not Found\r\n"));
}

test "serves the stylesheet with revalidation at its current URL" {
    var buffer: [64 * 1024]u8 = undefined;
    var response = try testRequest("GET /assets/styles.css HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-type: text/css; charset=utf-8\r\n");
    try expectHeader(response, "cache-control: no-cache\r\n");
    response = try testRequest("GET /assets/app.css HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 Not Found\r\n"));
}

test "serves first-party JavaScript with revalidation" {
    var buffer: [64 * 1024]u8 = undefined;
    const response = try testRequest("GET /assets/app.js HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try expectHeader(response, "content-type: text/javascript; charset=utf-8\r\n");
    try expectHeader(response, "cache-control: no-cache\r\n");
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
    try testing.expectEqual(Status.payload_too_large, clientErrorStatus(error.PayloadTooLarge).?);
    try testing.expectEqual(Status.unsupported_media_type, clientErrorStatus(error.UnsupportedMediaType).?);
    try testing.expectEqual(Status.bad_request, clientErrorStatus(error.InvalidForm).?);
    try testing.expectEqual(null, clientErrorStatus(error.OutOfMemory));
}

test "port defaults to 3000 without PORT" {
    try testing.expectEqual(@as(u16, 3000), try Config.parsePort(null));
}

test "port is parsed from PORT" {
    try testing.expectEqual(@as(u16, 8080), try Config.parsePort("8080"));
}

test "invalid PORT is rejected" {
    try testing.expectError(error.InvalidCharacter, Config.parsePort("abc"));
    try testing.expectError(error.Overflow, Config.parsePort("70000"));
}

test "embedded migrations are sorted and unique" {
    for (migrations.all[0..], 0..) |migration, i| {
        if (i > 0) try testing.expect(std.mem.lessThan(u8, migrations.all[i - 1].version, migration.version));
    }
}
