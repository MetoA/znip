//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const SplitInclusiveIterator = struct {
    buffer: []const u8,
    delimiter: []const u8,
    index: ?usize,

    pub fn next(self: *SplitInclusiveIterator) ?[]const u8 {
        const start = self.index orelse return null;

        if (std.mem.indexOfPos(u8, self.buffer, start, self.delimiter)) |delim_idx| {
            const end = delim_idx + self.delimiter.len;
            self.index = end;
            return self.buffer[start..end];
        } else {
            // Returns the remainder of the string
            const remainder = self.buffer[start..];
            self.index = null; // Marks as finished
            return if (remainder.len > 0) remainder else null;
        }
    }
};