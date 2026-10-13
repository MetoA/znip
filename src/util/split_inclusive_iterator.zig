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

fn collect(allocator: std.mem.Allocator, buffer: []const u8, delimiter: []const u8) ![]const []const u8 {
    var it = SplitInclusiveIterator{ .buffer = buffer, .delimiter = delimiter, .index = 0 };
    var parts = std.ArrayList([]const u8).empty;
    errdefer parts.deinit(allocator);
    while (it.next()) |part| try parts.append(allocator, part);
    return parts.toOwnedSlice(allocator);
}

fn expectParts(buffer: []const u8, delimiter: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const parts = try collect(allocator, buffer, delimiter);
    defer allocator.free(parts);
    try std.testing.expectEqual(expected.len, parts.len);
    for (expected, parts) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "SplitInclusiveIterator keeps the delimiter on each piece" {
    try expectParts("a\nb\nc", "\n", &.{ "a\n", "b\n", "c" });
}

test "SplitInclusiveIterator has no trailing empty piece after a final delimiter" {
    try expectParts("a\nb\n", "\n", &.{ "a\n", "b\n" });
}

test "SplitInclusiveIterator yields nothing for an empty buffer" {
    try expectParts("", "\n", &.{});
}

test "SplitInclusiveIterator returns the whole buffer when there is no delimiter" {
    try expectParts("abc", "\n", &.{"abc"});
}

test "SplitInclusiveIterator yields a lone delimiter as its own piece" {
    try expectParts("\n", "\n", &.{"\n"});
}

test "SplitInclusiveIterator yields consecutive delimiters as separate pieces" {
    try expectParts("a\n\n\nb", "\n", &.{ "a\n", "\n", "\n", "b" });
}

test "SplitInclusiveIterator supports multi-character delimiters" {
    try expectParts("a\r\nb\r\nc", "\r\n", &.{ "a\r\n", "b\r\n", "c" });
    // A lone `\r` or `\n` is not the delimiter.
    try expectParts("a\rb\nc", "\r\n", &.{"a\rb\nc"});
}

test "SplitInclusiveIterator keeps returning null once finished" {
    var it = SplitInclusiveIterator{ .buffer = "a\n", .delimiter = "\n", .index = 0 };
    try std.testing.expectEqualStrings("a\n", it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.next() == null);
}

test "SplitInclusiveIterator pieces concatenate back to the input" {
    const allocator = std.testing.allocator;
    const input = "fn main() {\n    return;\n}\n\nend";
    const parts = try collect(allocator, input, "\n");
    defer allocator.free(parts);
    const joined = try std.mem.concat(allocator, u8, parts);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings(input, joined);
}
