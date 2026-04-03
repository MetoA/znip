const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // TODO fetch from file/command
    const code =
        \\pub fn main() !void {
        \\  std.debug.print("MATCH: start_byte={} end_byte={} tag={s}\n something else", .{ match.start_byte, match.end_byte, match.tag });
        \\  {
        \\      std.debug.print("Hello one two three something long", .{});
        \\  }
        \\}
    ;
    
    _ = code;
    
    var cli_config = cli.parse(allocator) catch {
        std.process.exit(1);
    };
    defer cli_config.deinit(allocator);
    
    std.log.debug("----- CLI CONFIG ----", .{});
    std.log.debug("Help {}", .{cli_config.help});
    std.log.debug("File Name {s}", .{cli_config.file_path orelse "none"});
    std.log.debug("Start {d}", .{cli_config.starting_line orelse 1});
    std.log.debug("End {d}", .{cli_config.ending_line orelse 9999});
    std.log.debug("From Clipboard {}", .{cli_config.from_clipboard});
    std.log.debug("To Clipboard {}", .{cli_config.to_clipboard});
    std.log.debug("Interactive {}", .{cli_config.interactive});

    // try znip.renderImage(code);
}
