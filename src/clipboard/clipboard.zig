const std = @import("std");
const unix = @import("clipboard_unix.zig");

pub fn read(allocator: std.mem.Allocator) ![:0]u8 {
    const original = try unix.read();
    const null_terminated = try allocator.dupeZ(u8, original);
    return null_terminated;
}
