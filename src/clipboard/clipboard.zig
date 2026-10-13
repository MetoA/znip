const std = @import("std");
const builtin = @import("builtin");
const unix = @import("clipboard_unix.zig");
const macos = @import("clipboard_macos.zig");

/// Reads text from the system clipboard. Fails with `error.ClipboardEmpty`
/// when it holds no text (rather than rendering a blank image).
pub fn read(allocator: std.mem.Allocator) ![:0]u8 {
    const original = switch (builtin.os.tag) {
        .macos => try macos.read(allocator),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => try unix.read(allocator),
        else => @compileError("platform not supported"),
    };
    defer allocator.free(original);
    if (std.mem.trim(u8, original, " \t\r\n").len == 0) return error.ClipboardEmpty;
    return try allocator.dupeZ(u8, original);
}

/// Puts the PNG file at `png_path` on the system clipboard.
pub fn write_image(allocator: std.mem.Allocator, png_path: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try macos.write(allocator, png_path),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => {
            const png_bytes = try std.fs.cwd().readFileAlloc(allocator, png_path, 256 * 1024 * 1024);
            defer allocator.free(png_bytes);
            try unix.write(allocator, png_bytes);
        },
        else => @compileError("platform not supported"),
    }
}
