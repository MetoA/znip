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

/// A step that's about to run. Pair with a later `ok`/`err` call once it's done.
pub fn step(comptime fmt: []const u8, args: anytype) void {
    if (useEmoji()) {
        std.log.info("⏳ " ++ fmt, args);
    } else {
        std.log.info(fmt, args);
    }
}

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_interval_ns = 80 * std.time.ns_per_ms;
const clear_line = "\r" ++ (" " ** 120) ++ "\r";

/// An animated "in progress" indicator for steps with unpredictable latency
/// (network calls). Only animates on a real terminal - on non-TTY output it
/// simply stays silent until `stop` prints the final result, so redirected
/// output doesn't fill up with carriage-return noise.
pub const Spinner = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    /// Initializes `self` in place and, on a real terminal, spawns the
    /// animation thread. Must be called on a `Spinner` that already has a
    /// stable address (e.g. a local `var`) - the spawned thread holds a
    /// pointer into `self`, which would dangle if `self` were later moved
    /// or returned by value.
    pub fn start(self: *Spinner, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        self.* = Spinner{
            .allocator = allocator,
            .message = try std.fmt.allocPrint(allocator, fmt, args),
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };

        if (useEmoji()) {
            self.thread = std.Thread.spawn(.{}, spin, .{ &self.running, self.message }) catch null;
        }
    }

    fn spin(running: *std.atomic.Value(bool), message: []const u8) void {
        const stderr = std.fs.File.stderr();
        var frame: usize = 0;
        while (running.load(.acquire)) {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "\r{s} {s}", .{ spinner_frames[frame % spinner_frames.len], message }) catch break;
            stderr.writeAll(line) catch break;
            frame += 1;
            std.Thread.sleep(spinner_interval_ns);
        }
    }

    /// Stops the spinner and prints the final outcome via `ok`/`err`.
    pub fn stop(self: *Spinner, succeeded: bool, comptime fmt: []const u8, args: anytype) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            std.fs.File.stderr().writeAll(clear_line) catch {};
        }
        self.allocator.free(self.message);

        if (succeeded) {
            ok(fmt, args);
        } else {
            err(fmt, args);
        }
    }
};
