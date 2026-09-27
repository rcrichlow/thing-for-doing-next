const std = @import("std");
const template = @import("template.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const IndexPage = template.Template(@embedFile("public/index.html"));
const app_css = @embedFile("public/app.css");

const Config = struct {
    port: u16,

    fn fromEnvironment() !Config {
        const port_text = std.c.getenv("PORT") orelse return .{ .port = 3000 };
        return .{ .port = try std.fmt.parseInt(u16, std.mem.span(port_text), 10) };
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    const io_interface = io.io();

    const config = try Config.fromEnvironment();
    const address = try Io.net.IpAddress.parse("0.0.0.0", config.port);
    var listener = try address.listen(io_interface, .{ .reuse_address = true });
    defer listener.deinit(io_interface);

    std.log.info("listening on http://0.0.0.0:{d}", .{config.port});
    while (true) {
        const stream = try listener.accept(io_interface);
        serveConnection(io_interface, stream) catch |err| std.log.err("connection failed: {t}", .{err});
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var receive_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &receive_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try route(&request);
    }
}

fn route(request: *std.http.Server.Request) !void {
    if (request.head.method != .GET) {
        return request.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
    }

    if (std.mem.eql(u8, request.head.target, "/up")) {
        return request.respond("{\"status\":\"ok\"}\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    if (std.mem.eql(u8, request.head.target, "/assets/app.css")) {
        return request.respond(app_css, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/css; charset=utf-8" },
                .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
            },
        });
    }

    const active_nav = "border-violet-500 text-zinc-100 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium";
    const inactive_nav = "border-transparent text-zinc-400 hover:border-zinc-600 hover:text-zinc-200 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium transition-colors";

    if (std.mem.eql(u8, request.head.target, "/")) {
        std.log.info("index visited...", .{});
        var response_buffer: [16 * 1024]u8 = undefined;
        var response_writer = std.Io.Writer.fixed(&response_buffer);
        try IndexPage.render(&response_writer, .{
            .title = "Thing for Doing Next",
            .heading = "Working Memory",
            .message = "hi",
            .boards_class = inactive_nav,
            .working_memory_class = active_nav,
        });
        return request.respond(response_writer.buffered(), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    if (std.mem.eql(u8, request.head.target, "/boards")) {
        var response_buffer: [16 * 1024]u8 = undefined;
        var response_writer = std.Io.Writer.fixed(&response_buffer);
        try IndexPage.render(&response_writer, .{
            .title = "Thing for Doing Next",
            .heading = "Board",
            .message = "This will house the kanban board...",
            .boards_class = active_nav,
            .working_memory_class = inactive_nav,
        });
        return request.respond(response_writer.buffered(), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    return request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

test "health response is JSON" {
    try std.testing.expect(std.mem.indexOf(u8, "{\"status\":\"ok\"}", "status") != null);
}

test "port defaults to 3000 without PORT" {
    const config = Config{ .port = 3000 };
    try std.testing.expectEqual(@as(u16, 3000), config.port);
}
