const std = @import("std");
const builtin = @import("builtin");

pub fn open(allocator: std.mem.Allocator, path: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "open", path },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => &[_][]const u8{ "xdg-open", path },
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
