//! Helpers for integration tests that need PostgreSQL.

const std = @import("std");
const db = @import("../db.zig");

/// Opens a pool against `TEST_DATABASE_URL` with a freshly reset `public`
/// schema, or skips the test when the variable is unset. Refuses to reset a
/// database whose name does not end in `_test`.
pub fn pool(size: usize) !*db.Pool {
    const url = std.c.getenv("TEST_DATABASE_URL") orelse return error.SkipZigTest;
    const test_pool = try db.Pool.init(std.testing.io, std.testing.allocator, .{
        .url = std.mem.span(url),
        .size = size,
    });
    errdefer test_pool.deinit();

    const conn = try test_pool.acquire();
    defer conn.release();

    var name_row = (try conn.row("SELECT current_database()", .{})).?;
    defer name_row.deinit() catch {};
    const name = try name_row.get([]const u8, 0);
    if (!std.mem.endsWith(u8, name, "_test")) {
        std.debug.print("TEST_DATABASE_URL points at '{s}', which does not end in _test\n", .{name});
        return error.NotATestDatabase;
    }

    _ = try conn.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public;", .{});
    return test_pool;
}
