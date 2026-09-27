const std = @import("std");
const template = @import("template.zig");

const Start = template.Template(@embedFile("public/layout/start.html"));
const Main = template.Template(@embedFile("public/layout/main.html"));
const End = template.Template(@embedFile("public/layout/end.html"));
const NavLink = template.Template(@embedFile("public/components/nav-link.html"));
const NavLinkActive = template.Template(@embedFile("public/components/nav-link-active.html"));

pub const Section = enum { working_memory, boards };

const NavItem = struct {
    section: Section,
    title: []const u8,
    url: []const u8,
};

const nav_items = [_]NavItem{
    .{ .section = .working_memory, .title = "Working Memory", .url = "/" },
    .{ .section = .boards, .title = "Boards", .url = "/boards" },
};

pub const Options = struct {
    title: []const u8,
    /// Navigation section to highlight, or null for pages outside the nav.
    active: ?Section,
};

/// Writes the document head, header, and navigation, leaving the writer
/// positioned inside the page's main content container.
pub fn writeStart(writer: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    try Start.render(writer, .{ .title = options.title });
    for (nav_items) |item| {
        const values = .{ .title = item.title, .url = item.url };
        if (options.active == item.section) {
            try NavLinkActive.render(writer, values);
        } else {
            try NavLink.render(writer, values);
        }
    }
    try Main.render(writer, .{});
}

/// Closes the elements opened by `writeStart`.
pub fn writeEnd(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try End.render(writer, .{});
}

test "marks only the active section as current" {
    var buffer: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeStart(&writer, .{ .title = "T & T", .active = .boards });
    try writeEnd(&writer);
    const html = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>T &amp; T</title>") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "aria-current=\"page\""));
    const current = std.mem.indexOf(u8, html, "aria-current=\"page\"").?;
    const boards = std.mem.indexOf(u8, html, "href=\"/boards\"").?;
    try std.testing.expect(boards < current);
    try std.testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
}

test "renders no current section when none is active" {
    var buffer: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeStart(&writer, .{ .title = "T", .active = null });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "aria-current") == null);
}
