//! Decoding for `application/x-www-form-urlencoded` data, used for both request
//! bodies and query strings.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Form = struct {
    fields: []const Field,

    pub const empty: Form = .{ .fields = &.{} };

    /// Returns the first value for `name`, if present.
    pub fn get(form: Form, name: []const u8) ?[]const u8 {
        for (form.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }
};

pub const ParseError = error{ InvalidForm, OutOfMemory };

/// Parses urlencoded pairs. Decoded names and values are allocated from
/// `arena` or alias `encoded`, so both must outlive the returned `Form`.
/// Rejects malformed percent escapes and non-UTF-8 results.
pub fn parse(arena: Allocator, encoded: []const u8) ParseError!Form {
    var fields: std.ArrayList(Field) = .empty;
    var pairs = std.mem.splitScalar(u8, encoded, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, pair, '=');
        const raw_name = if (separator) |i| pair[0..i] else pair;
        const raw_value = if (separator) |i| pair[i + 1 ..] else "";
        try fields.append(arena, .{
            .name = try decode(arena, raw_name),
            .value = try decode(arena, raw_value),
        });
    }
    return .{ .fields = try fields.toOwnedSlice(arena) };
}

fn decode(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    const decoded = if (std.mem.indexOfAny(u8, raw, "%+") == null) raw else blk: {
        const out = try arena.alloc(u8, raw.len);
        var read: usize = 0;
        var written: usize = 0;
        while (read < raw.len) : (written += 1) {
            switch (raw[read]) {
                '+' => {
                    out[written] = ' ';
                    read += 1;
                },
                '%' => {
                    if (raw.len - read < 3) return error.InvalidForm;
                    const high = std.fmt.charToDigit(raw[read + 1], 16) catch return error.InvalidForm;
                    const low = std.fmt.charToDigit(raw[read + 2], 16) catch return error.InvalidForm;
                    out[written] = high << 4 | low;
                    read += 3;
                },
                else => |byte| {
                    out[written] = byte;
                    read += 1;
                },
            }
        }
        break :blk out[0..written];
    };
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidForm;
    return decoded;
}

const testing = std.testing;

test "parses pairs with plus and percent escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const form = try parse(arena.allocator(), "body=line+one%0Aline%20two&empty=&flag&k%C3%A9y=caf%C3%A9");
    try testing.expectEqualStrings("line one\nline two", form.get("body").?);
    try testing.expectEqualStrings("", form.get("empty").?);
    try testing.expectEqualStrings("", form.get("flag").?);
    try testing.expectEqualStrings("café", form.get("kéy").?);
    try testing.expectEqual(null, form.get("missing"));
}

test "keeps literal equals signs in values and returns the first duplicate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const form = try parse(arena.allocator(), "a=1=2&a=3&&");
    try testing.expectEqual(@as(usize, 2), form.fields.len);
    try testing.expectEqualStrings("1=2", form.get("a").?);
}

test "empty input yields no fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const form = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), form.fields.len);
}

test "rejects malformed escapes and invalid UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidForm, parse(a, "a=%"));
    try testing.expectError(error.InvalidForm, parse(a, "a=%4"));
    try testing.expectError(error.InvalidForm, parse(a, "a=%zz"));
    try testing.expectError(error.InvalidForm, parse(a, "a=%+1"));
    try testing.expectError(error.InvalidForm, parse(a, "a=%FF"));
}
