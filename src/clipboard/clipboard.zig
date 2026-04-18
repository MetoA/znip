const std = @import("std");
const builtin = @import("builtin");
const unix = @import("clipboard_unix.zig");
const macos = @import("clipboard_macos.zig");

pub fn read(allocator: std.mem.Allocator) ![:0]u8 {
    const original = switch (builtin.os.tag) {
        .macos => try macos.read(),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => try unix.read(),
        else => @compileError("platform not supported"),
    }; 
    const null_terminated = try allocator.dupeZ(u8, original);
    return null_terminated;
}

pub fn write_image(image_bytes: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try macos.write(image_bytes),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => try unix.write(image_bytes),
        else => @compileError("platform not supported"),
    }
}
