//! Named SQL statements from embedded `.sql` files in `src/queries/`. Each
//! statement starts with a `-- name: identifier` line and runs until the next
//! one:
//!
//!     -- name: find
//!     SELECT id, title FROM boards WHERE id = $1;
//!
//! `load(@embedFile("queries/boards.sql"))` parses the file at comptime and
//! returns a value with one comptime `[:0]const u8` field per statement, so a
//! misspelled name fails the build. Lines before the first statement may only
//! be blank or comments. Trailing comment lines and a trailing `;` are dropped
//! from each statement.

const std = @import("std");

const marker = "-- name:";

pub fn load(comptime source: []const u8) Queries(source) {
    return .{};
}

pub fn Queries(comptime source: []const u8) type {
    const statements = parse(source);
    var names: [statements.len][]const u8 = undefined;
    var attrs: [statements.len]std.builtin.Type.StructField.Attributes = undefined;
    for (statements, 0..) |statement, i| {
        names[i] = statement.name;
        attrs[i] = .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&statements[i].sql) };
    }
    return @Struct(.auto, null, &names, &@splat([:0]const u8), &attrs);
}

const Statement = struct { name: []const u8, sql: [:0]const u8 };

fn parse(comptime source: []const u8) []const Statement {
    @setEvalBranchQuota(source.len * 50 + 1000);
    var statements: []const Statement = &.{};
    var name: ?[]const u8 = null;
    var body_start: usize = 0;
    var pos: usize = 0;
    while (pos < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[pos..end], " \t\r");
        if (std.mem.startsWith(u8, line, marker)) {
            if (name) |previous| {
                statements = statements ++ .{finish(previous, source[body_start..pos])};
            }
            const next = std.mem.trim(u8, line[marker.len..], " \t");
            checkName(next);
            for (statements) |existing| if (std.mem.eql(u8, existing.name, next)) {
                @compileError("sql: duplicate query name '" ++ next ++ "'");
            };
            name = next;
            body_start = @min(end + 1, source.len);
        } else if (name == null and line.len > 0 and !std.mem.startsWith(u8, line, "--")) {
            @compileError("sql: statement before the first '" ++ marker ++ "' line: " ++ line);
        }
        pos = end + 1;
    }
    const last = name orelse @compileError("sql: no '" ++ marker ++ "' lines found");
    return statements ++ .{finish(last, source[body_start..])};
}

fn finish(comptime name: []const u8, comptime body: []const u8) Statement {
    var text = std.mem.trim(u8, body, " \t\r\n");
    while (text.len > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |newline| newline + 1 else 0;
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, text[line_start..], " \t"), "--")) break;
        text = std.mem.trimEnd(u8, text[0..line_start], " \t\r\n");
    }
    if (std.mem.endsWith(u8, text, ";")) text = std.mem.trimEnd(u8, text[0 .. text.len - 1], " \t\r\n");
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "--")) break;
    } else @compileError("sql: query '" ++ name ++ "' is empty");
    return .{ .name = name, .sql = std.fmt.comptimePrint("{s}", .{text}) };
}

fn checkName(comptime name: []const u8) void {
    const valid = name.len > 0 and !std.ascii.isDigit(name[0]) and for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') break false;
    } else true;
    if (!valid) @compileError("sql: query name '" ++ name ++ "' must be a snake_case identifier");
}

const testing = std.testing;

test "loads named statements" {
    const q = load(
        \\-- Header comments are allowed.
        \\
        \\-- name: find
        \\SELECT id
        \\FROM boards WHERE id = $1; -- inline comments stay
        \\
        \\-- name: count
        \\-- Comments under the marker stay with the statement.
        \\SELECT count(*) FROM boards;
        \\
        \\-- A note about the next statement is dropped from this one.
        \\
        \\-- name: delete
        \\DELETE FROM boards
    );
    try testing.expectEqualStrings("SELECT id\nFROM boards WHERE id = $1; -- inline comments stay", q.find);
    try testing.expectEqualStrings("-- Comments under the marker stay with the statement.\nSELECT count(*) FROM boards", q.count);
    try testing.expectEqualStrings("DELETE FROM boards", q.delete);
    try testing.expectEqual(0, q.delete[q.delete.len]);
    try testing.expectEqual(3, @typeInfo(@TypeOf(q)).@"struct".fields.len);
}
