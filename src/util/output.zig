const std = @import("std");

/// Whether stderr looks like a real terminal. Cached because it's checked on
/// every message and the underlying isatty() syscall never changes mid-run.
var is_tty: ?bool = null;

fn useEmoji() bool {
    if (is_tty) |v| return v;
    const v = std.fs.File.stderr().isTty();
    is_tty = v;
    return v;
}

/// A user-facing failure. Prefixed with an emoji on a real terminal.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (useEmoji()) {
        std.log.err("❌ " ++ fmt, args);
    } else {
        std.log.err(fmt, args);
    }
}

/// A non-fatal heads-up. Prefixed with an emoji on a real terminal.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (useEmoji()) {
        std.log.warn("⚠️  " ++ fmt, args);
    } else {
        std.log.warn(fmt, args);
    }
}

/// A successful outcome worth confirming to the user.
pub fn ok(comptime fmt: []const u8, args: anytype) void {
    if (useEmoji()) {
        std.log.info("✅ " ++ fmt, args);
    } else {
        std.log.info(fmt, args);
    }
}
