/// Adapted from https://github.com/dgv/clipboard/blob/main/src/clipboard_unix.zig

const std = @import("std");

const xsel: []const u8 = "xsel";
const xclip: []const u8 = "xclip";
const wlpaste: []const u8 = "wl-paste";
const wlcopy: []const u8 = "wl-copy";

const xsel_read = [_][]const u8{ xsel, "--output", "--clipboard" };
const xclip_read = [_][]const u8{ xclip, "-out", "-selection", "clipboard" };
const wlpaste_read = [_][]const u8{ wlpaste, "--no-newline" };
const xsel_write_image = [_][]const u8{ xsel, "--input", "--clipboard", "--attachment", "image/png" };
const xclip_write_image = [_][]const u8{ xclip, "-in", "-selection", "clipboard", "-t", "image/png" };
const wlcopy_write_image = [_][]const u8{ wlcopy, "--type", "image/png" };

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

fn getCmd(operation: Operation) ![]const []const u8 {
    const pathenv = std.process.getEnvVarOwned(std.heap.page_allocator, "PATH") catch "";
    const wd = std.process.getEnvVarOwned(std.heap.page_allocator, "XDG_SESSION_TYPE") catch "";
    if (std.mem.eql(u8, wd, "wayland")) {
        return if (operation == Operation.read) &wlpaste_read else &wlcopy_write_image;
    }
    var buf: [255]u8 = undefined;
    var program = findProgramByNamePosix(xclip, pathenv, &buf);
    if (program != null) {
        return if (operation == Operation.read) &xclip_read else &xclip_write_image;
    }
    program = findProgramByNamePosix(xsel, pathenv, &buf);
    if (program != null) {
        return if (operation == Operation.read) &xsel_read else &xsel_write_image;
    }
    return error.ClipboardCmdNotFound;
}

pub fn read() ![]u8 {
    const cmd = try getCmd(.read);
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = cmd,
    });
    return result.stdout;
}

pub fn write(png_bytes: []const u8) !void {
    const cmd = try getCmd(.write_image);
    var proc = std.process.Child.init(
        cmd,
        std.heap.page_allocator,
    );
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();
    try proc.stdin.?.writeAll(png_bytes);
    proc.stdin.?.close();
    proc.stdin = null;
    const term = proc.wait() catch unreachable;
    if (term != .Exited or term.Exited != 0) unreachable;
}