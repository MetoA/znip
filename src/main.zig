const std = @import("std");
const blend2d = @import("blend2d.zig");
const tree_sitter = @import("tree-sitter.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    const matches = try tree_sitter.codeMatches(allocator, code);
    for (matches.items) |match| {
        std.log.debug("MATCH: start_byte={} end_byte={} tag={s}", .{ match.start_byte, match.end_byte, match.tag });
    }
    const tokens = try tree_sitter.codeTokens(allocator, code, matches.items);
    for (tokens.items) |token| {
        std.log.debug("TOKEN: text={s} color={} is_newline={}", .{ token.text, token.color, token.is_newline });
    }
    blend2d.generateImage(tokens.items) catch |err| {
        std.log.err("ERROR: {}", .{err});
    };
}
