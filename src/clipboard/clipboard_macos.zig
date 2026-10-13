/// Adapted from https://github.com/dgv/clipboard/blob/main/src/clipboard_macos.zig
const std = @import("std");
const unix = @import("clipboard_unix.zig");

pub fn read(allocator: std.mem.Allocator) ![]u8 {
    return unix.runReadCommand(allocator, &[_][]const u8{"pbpaste"});
}

/// Copies the PNG at `png_path` to the pasteboard with AppleScript, which
/// ships with macOS (unlike the Xcode command line tools a `swift -e` script
/// would need) and starts instantly.
pub fn write(allocator: std.mem.Allocator, png_path: []const u8) !void {
    // AppleScript needs an absolute path.
    const absolute = try std.fs.cwd().realpathAlloc(allocator, png_path);
    defer allocator.free(absolute);

    var proc = std.process.Child.init(
        &[_][]const u8{
            "osascript",
            "-e",
            "on run argv",
            "-e",
            "set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)",
            "-e",
            "end run",
            absolute,
        },
        allocator,
    );
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();
    const term = proc.wait() catch return error.ClipboardProcessFailed;
    if (term != .Exited or term.Exited != 0) return error.ClipboardProcessFailed;
}
