//! Normalization for user-submitted text, shared by the query modules.

const std = @import("std");
const Allocator = std.mem.Allocator;

const whitespace = " \t\n\x0b\x0c";

/// Normalizes multiline text: converts CRLF and CR line endings to LF and
/// trims surrounding whitespace. Returns null when nothing remains.
pub fn multiline(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
        } else {
            out.appendAssumeCapacity(raw[i]);
        }
    }
    const trimmed = std.mem.trim(u8, out.items, whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Normalizes a single-line title: line breaks and tabs become spaces and
/// surrounding whitespace is trimmed. Returns null when nothing remains.
pub fn line(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const out = try arena.dupe(u8, raw);
    for (out) |*char| switch (char.*) {
        '\r', '\n', '\t', '\x0b', '\x0c' => char.* = ' ',
        else => {},
    };
    const trimmed = std.mem.trim(u8, out, " ");
    return if (trimmed.len == 0) null else trimmed;
}

const testing = std.testing;

test "multiline converts line endings and trims" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("one\ntwo\nthree", (try multiline(a, "  one\r\ntwo\rthree \r\n")).?);
    try testing.expectEqualStrings("keep  inner\n\nspace", (try multiline(a, "keep  inner\n\nspace")).?);
    try testing.expectEqual(null, try multiline(a, " \r\n\t "));
    try testing.expectEqual(null, try multiline(a, ""));
}

test "line flattens line breaks and trims" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("To  Do", (try line(a, " To\r\nDo\t")).?);
    try testing.expectEqualStrings("Done", (try line(a, "Done")).?);
    try testing.expectEqual(null, try line(a, " \n\t "));
}
