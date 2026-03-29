const std = @import("std");
const znip = @import("znip");

pub fn main() !void {

    // TODO fetch from file/command
    const code =
        \\pub fn main() !void {
        \\  std.debug.print("MATCH: start_byte={} end_byte={} tag={s}\n something else", .{ match.start_byte, match.end_byte, match.tag });
        \\  {
        \\      std.debug.print("Hello one two three something long", .{});
        \\  }
        \\  std.debug.print("MATCH: start_byte={} end_byte={} tag={s}\n something else", .{ match.start_byte, match.end_byte, match.tag });
        \\  {
        \\      std.debug.print("Hello one two three something long", .{});
        \\  }
        \\}
    ;

    try znip.renderImage(code);
}
