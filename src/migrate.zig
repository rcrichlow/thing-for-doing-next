//! Applies embedded SQL migrations in filename order. Each migration runs in
//! its own transaction together with its `schema_migrations` record, so a
//! failure leaves no partial migration applied. Migrations are forward-only and
//! must not contain their own transaction control statements.

const std = @import("std");
const db = @import("db.zig");

pub const Migration = @import("migrations").Migration;
const log = std.log.scoped(.migrate);

/// Arbitrary key for `pg_advisory_lock`, serializing concurrent app starts.
const lock_key: i64 = 0x7466_646e_6d69_6772; // "tfdnmigr"

pub const Diagnostics = struct {
    /// Version of the migration that failed, if any.
    failed_version: ?[]const u8 = null,
    code_buffer: [5]u8 = undefined,
    code_len: usize = 0,
    message_buffer: [1024]u8 = undefined,
    message_len: usize = 0,

    /// SQLSTATE when the failure was reported by PostgreSQL, else empty.
    pub fn code(diagnostics: *const Diagnostics) []const u8 {
        return diagnostics.code_buffer[0..diagnostics.code_len];
    }

    /// PostgreSQL's error message, possibly truncated, else empty.
    pub fn message(diagnostics: *const Diagnostics) []const u8 {
        return diagnostics.message_buffer[0..diagnostics.message_len];
    }

    /// Copies error details, since rolling back clears `conn.err`.
    fn record(diagnostics: *Diagnostics, version: []const u8, pg_err: ?db.PgError) void {
        diagnostics.failed_version = version;
        const err = pg_err orelse return;
        diagnostics.code_len = @min(err.code.len, diagnostics.code_buffer.len);
        @memcpy(diagnostics.code_buffer[0..diagnostics.code_len], err.code[0..diagnostics.code_len]);
        diagnostics.message_len = @min(err.message.len, diagnostics.message_buffer.len);
        @memcpy(diagnostics.message_buffer[0..diagnostics.message_len], err.message[0..diagnostics.message_len]);
    }
};

/// Applies pending `migrations` and returns how many were applied. Stops at
/// the first failing migration, rolls it back, and records it in `diagnostics`.
pub fn run(conn: *db.Conn, migrations: []const Migration, diagnostics: *Diagnostics) !usize {
    diagnostics.* = .{};
    try validate(migrations);

    _ = try conn.exec("SELECT pg_advisory_lock($1)", .{lock_key});
    defer unlock(conn);

    _ = try conn.exec(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version text PRIMARY KEY,
        \\  applied_at timestamptz NOT NULL DEFAULT now()
        \\)
    , .{});

    var applied_count: usize = 0;
    for (migrations) |migration| {
        if (try isApplied(conn, migration.version)) continue;
        apply(conn, migration) catch |err| {
            diagnostics.record(migration.version, conn.err);
            conn.rollback() catch {};
            return err;
        };
        log.info("applied migration {s}", .{migration.version});
        applied_count += 1;
    }
    return applied_count;
}

fn unlock(conn: *db.Conn) void {
    _ = conn.exec("SELECT pg_advisory_unlock($1)", .{lock_key}) catch |err| {
        log.warn("releasing migration lock failed: {t}", .{err});
    };
}

fn isApplied(conn: *db.Conn, version: []const u8) !bool {
    var found = try conn.row("SELECT 1 FROM schema_migrations WHERE version = $1", .{version}) orelse return false;
    found.deinit() catch {};
    return true;
}

fn apply(conn: *db.Conn, migration: Migration) !void {
    try conn.begin();
    _ = try conn.exec(migration.sql, .{});
    _ = try conn.exec("INSERT INTO schema_migrations (version) VALUES ($1)", .{migration.version});
    try conn.commit();
}

/// Build-generated lists are sorted and unique; this guards hand-built lists.
fn validate(migrations: []const Migration) error{InvalidMigrationList}!void {
    for (migrations, 0..) |migration, i| {
        if (migration.version.len == 0) return error.InvalidMigrationList;
        if (i > 0 and !std.mem.lessThan(u8, migrations[i - 1].version, migration.version)) {
            return error.InvalidMigrationList;
        }
    }
}

test "rejects unsorted or duplicate migration lists" {
    try std.testing.expectError(error.InvalidMigrationList, validate(&.{
        .{ .version = "002_b", .sql = "" },
        .{ .version = "001_a", .sql = "" },
    }));
    try std.testing.expectError(error.InvalidMigrationList, validate(&.{
        .{ .version = "001_a", .sql = "" },
        .{ .version = "001_a", .sql = "" },
    }));
    try validate(&.{
        .{ .version = "001_a", .sql = "" },
        .{ .version = "002_b", .sql = "" },
    });
}

test "applies pending migrations once, in order" {
    const pool = try db.testing.pool(1);
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();

    const first = [_]Migration{
        .{ .version = "001_create", .sql = "CREATE TABLE things (id int PRIMARY KEY);" },
        .{ .version = "002_seed", .sql = "INSERT INTO things VALUES (1); INSERT INTO things VALUES (2);" },
    };
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(@as(usize, 2), try run(conn, &first, &diagnostics));
    try std.testing.expectEqual(@as(usize, 0), try run(conn, &first, &diagnostics));

    const second = first ++ [_]Migration{
        .{ .version = "003_more", .sql = "INSERT INTO things VALUES (3);" },
    };
    try std.testing.expectEqual(@as(usize, 1), try run(conn, &second, &diagnostics));
    try std.testing.expectEqual(null, diagnostics.failed_version);

    var count = (try conn.row("SELECT count(*) FROM things", .{})).?;
    defer count.deinit() catch {};
    try std.testing.expectEqual(@as(i64, 3), try count.get(i64, 0));
}

test "a failing migration is rolled back and stops the run" {
    const pool = try db.testing.pool(1);
    defer pool.deinit();
    const conn = try pool.acquire();
    defer conn.release();

    const migrations = [_]Migration{
        .{ .version = "001_ok", .sql = "CREATE TABLE ok (id int);" },
        .{ .version = "002_broken", .sql = "CREATE TABLE half (id int); SELECT * FROM missing_table;" },
        .{ .version = "003_never", .sql = "CREATE TABLE never (id int);" },
    };
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.PG, run(conn, &migrations, &diagnostics));
    try std.testing.expectEqualStrings("002_broken", diagnostics.failed_version.?);
    try std.testing.expectEqualStrings("42P01", diagnostics.code());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message(), "missing_table") != null);

    var tables = try conn.query(
        "SELECT table_name::text FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1",
        .{},
    );
    defer tables.deinit();
    try std.testing.expectEqualStrings("ok", try (try tables.next()).?.get([]const u8, 0));
    try std.testing.expectEqualStrings("schema_migrations", try (try tables.next()).?.get([]const u8, 0));
    try std.testing.expectEqual(null, try tables.next());

    var versions = (try conn.row("SELECT string_agg(version, ',' ORDER BY version) FROM schema_migrations", .{})).?;
    defer versions.deinit() catch {};
    try std.testing.expectEqualStrings("001_ok", try versions.get([]const u8, 0));
}
