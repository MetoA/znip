const std = @import("std");

pub fn getLinesInRange(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    starting_line: ?usize,
    ending_line: ?usize,
) ![:0]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const max_bytes = 10 * 1024 * 1024; // 10MB
    const stat = try file.stat();
    
    if (stat.size > max_bytes) return error.FileTooLarge;
    const content = try file.readToEndAlloc(allocator, max_bytes);
    errdefer allocator.free(content);
    
    if (isBinary(content)) return error.BinaryFileNotSupported;
    
    if (starting_line == null and ending_line == null) {
        return allocator.dupeZ(u8, content);
    }
    
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    
    var line_iterator = std.mem.splitScalar(u8, content, '\n');
    while (line_iterator.next()) |line| {
        try lines.append(allocator, line);
    }
    
    const total = lines.items.len;
    
    if (total == 0) return error.EmptyFileNotSupported;
    
    const start_index = if (starting_line) |start| (if (start > 0) start - 1 else 0) else 0;
    const end_index = if (ending_line) |end| @min(end, total) else total;
    
    if (start_index >= total or start_index >= end_index) return error.InvalidRange;
    
    const result = try std.mem.joinZ(allocator, "\n", lines.items[start_index..end_index]);
    
    allocator.free(content);
    return result;
}

// Null bytes indicate binary
fn isBinary(buffer: []const u8) bool {
    const check_size = @min(buffer.len, 4096);
    for (buffer[0..check_size]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}