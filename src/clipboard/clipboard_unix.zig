/// Adapted from https://github.com/dgv/clipboard/blob/main/src/clipboard_unix.zig

const std = @import("std");

const xsel: []const u8 = "xsel";
const xclip: []const u8 = "xclip";
const wlpaste: []const u8 = "wl-paste";
const wlcopy: []const u8 = "wl-copy";

const xsel_read = [_][]const u8{ xsel, "--output", "--clipboard" };
const xclip_read = [_][]const u8{ xclip, "-out", "-selection", "clipboard" };
const wlpaste_read = [_][]const u8{ wlpaste, "--no-newline" };
// xsel only handles text selections, so it can't be used to copy an image.
const xclip_write_image = [_][]const u8{ xclip, "-in", "-selection", "clipboard", "-t", "image/png" };
const wlcopy_write_image = [_][]const u8{ wlcopy, "--type", "image/png" };

/// Same limit as for files and stdin.
const max_clipboard_bytes = 10 * 1024 * 1024;

const Operation = enum {
    read,
    write_image,
};

fn canExecutePosix(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn findProgramByNamePosix(name: []const u8, path: ?[]const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const path_env = path orelse return null;
    var fib = std.heap.FixedBufferAllocator.init(buf);

    var it = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter_posix);
    while (it.next()) |path_dir| {
        defer fib.reset();
        const full_path = std.fs.path.join(fib.allocator(), &.{ path_dir, name }) catch continue;
        if (canExecutePosix(full_path)) return full_path;
    }

    return null;
}

fn isInstalled(name: []const u8, path_env: ?[]const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return findProgramByNamePosix(name, path_env, &buf) != null;
}

/// Picks the clipboard tool: the Wayland ones when running under Wayland
/// (`WAYLAND_DISPLAY` is the reliable signal; `XDG_SESSION_TYPE` is `tty`
/// when a compositor was started from a console), otherwise xclip, otherwise
/// xsel for reading. Only tools that are actually installed are chosen.
fn getCmd(operation: Operation) ![]const []const u8 {
    const path_env: ?[]const u8 = std.posix.getenv("PATH");
    const session_type: []const u8 = std.posix.getenv("XDG_SESSION_TYPE") orelse "";
    const wayland = std.posix.getenv("WAYLAND_DISPLAY") != null or std.mem.eql(u8, session_type, "wayland");

    if (wayland) {
        switch (operation) {
            .read => if (isInstalled(wlpaste, path_env)) return &wlpaste_read,
            .write_image => if (isInstalled(wlcopy, path_env)) return &wlcopy_write_image,
        }
    }

    if (isInstalled(xclip, path_env)) {
        return if (operation == .read) &xclip_read else &xclip_write_image;
    }
    if (operation == .read and isInstalled(xsel, path_env)) return &xsel_read;

    return error.ClipboardCmdNotFound;
}

/// Runs `argv` and returns its stdout (caller frees). A non-zero exit - e.g.
/// `xclip`/`wl-paste` when the clipboard holds no text - is an error rather
/// than an empty string.
pub fn runReadCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = max_clipboard_bytes,
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (result.term != .Exited or result.term.Exited != 0) return error.ClipboardEmpty;
    return result.stdout;
}

pub fn read(allocator: std.mem.Allocator) ![]u8 {
    const cmd = try getCmd(.read);
    return runReadCommand(allocator, cmd);
}

pub fn write(allocator: std.mem.Allocator, png_bytes: []const u8) !void {
    const cmd = try getCmd(.write_image);
    var proc = std.process.Child.init(cmd, allocator);
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();

    // The child may exit early (no DISPLAY, bad option): that shows up as a
    // broken pipe here. Either way the pipe is closed and the child reaped.
    const write_result = proc.stdin.?.writeAll(png_bytes);
    proc.stdin.?.close();
    proc.stdin = null;
    const term = proc.wait() catch return error.ClipboardProcessFailed;
    write_result catch return error.ClipboardProcessFailed;
    if (term != .Exited or term.Exited != 0) return error.ClipboardProcessFailed;
}
