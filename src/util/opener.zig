const std = @import("std");
const builtin = @import("builtin");

pub fn open(allocator: std.mem.Allocator, path: []const u8) !void {
    // A relative path beginning with '-' would be read as an option by `open`
    // / `xdg-open`; anchoring it to the current directory makes it a path.
    const anchored = if (std.mem.startsWith(u8, path, "-"))
        try std.fmt.allocPrint(allocator, "./{s}", .{path})
    else
        path;
    defer if (anchored.ptr != path.ptr) allocator.free(anchored);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "open", anchored },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => &[_][]const u8{ "xdg-open", anchored },
        else => @compileError("platform not supported"),
    };

    var proc = std.process.Child.init(argv, allocator);
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();
    const term = proc.wait() catch return error.OpenProcessFailed;
    if (term != .Exited or term.Exited != 0) return error.OpenProcessFailed;
}
