const std = @import("std");

/// Renders `{{field}}` placeholders from an embedded template. Field values must
/// be byte strings and are escaped for HTML text and quoted attribute contexts.
pub fn Template(comptime source: []const u8) type {
    return struct {
        pub fn render(writer: *std.Io.Writer, values: anytype) std.Io.Writer.Error!void {
            // Placeholder discovery is performed at comptime and must scan the
            // whole template, including any embedded third-party scripts.
            @setEvalBranchQuota(source.len * 4);

            const Values = @TypeOf(values);
            const values_info = @typeInfo(Values);
            if (values_info != .@"struct") {
                @compileError("template values must be a struct or tuple");
            }

            comptime var cursor = 0;
            inline while (comptime std.mem.indexOfPos(u8, source, cursor, "{{")) |open| {
                try writer.writeAll(source[cursor..open]);

                const name_start = open + 2;
                const close = comptime std.mem.indexOfPos(u8, source, name_start, "}}") orelse
                    @compileError("unclosed template placeholder");
                const name = source[name_start..close];
                if (comptime name.len == 0) @compileError("template placeholder cannot be empty");
                if (comptime std.mem.indexOfScalar(u8, name, '{') != null) {
                    @compileError("nested template placeholders are not supported");
                }

                if (!@hasField(Values, name)) {
                    @compileError("template has no value named '" ++ name ++ "'");
                }
                try writeEscaped(writer, @field(values, name));
                cursor = close + 2;
            }
            try writer.writeAll(source[cursor..]);
        }
    };
}

fn writeEscaped(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

test "renders escaped placeholders" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const page = Template("<h1>{{title}}</h1><p>{{message}}</p>");

    try page.render(&writer, .{
        .title = "A < B",
        .message = "'hello' & \"goodbye\"",
    });

    try std.testing.expectEqualStrings(
        "<h1>A &lt; B</h1><p>&#39;hello&#39; &amp; &quot;goodbye&quot;</p>",
        writer.buffered(),
    );
}
