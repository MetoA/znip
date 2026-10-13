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
        defer allocator.free(content);
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

pub fn readStdin(allocator: std.mem.Allocator) ![:0]u8 {
    const max_bytes = 10 * 1024 * 1024; // 10MB
    const content = try std.fs.File.stdin().readToEndAlloc(allocator, max_bytes);
    defer allocator.free(content);

    if (isBinary(content)) return error.BinaryFileNotSupported;
    if (content.len == 0) return error.EmptyFileNotSupported;

    return allocator.dupeZ(u8, content);
}

// Null bytes indicate binary
fn isBinary(buffer: []const u8) bool {
    const check_size = @min(buffer.len, 4096);
    for (buffer[0..check_size]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

pub fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const stats = try file.stat();
    return try file.readToEndAlloc(allocator, stats.size);
}

/// Appends ".png" to `name` unless it already ends with ".png" (case-insensitive).
pub fn ensurePngExtension(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.ascii.endsWithIgnoreCase(name, ".png")) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}.png", .{name});
}

/// Given a candidate file path, returns a path guaranteed not to already exist,
/// appending " (1)", " (2)", etc. before the extension (Windows-style) as needed.
pub fn uniqueOutputPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.cwd().access(path, .{})) |_| {} else |_| {
        return try allocator.dupe(u8, path);
    }

    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];

    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, attempt, ext });
        if (std.fs.cwd().access(candidate, .{})) |_| {
            allocator.free(candidate);
        } else |_| {
            return candidate;
        }
    }
}
const test_content = "one\ntwo\nthree\nfour\nfive";

/// Writes `data` to `name` inside `tmp` and returns its absolute path (caller frees).
fn writeTmpFile(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = name, .data = data });
    return tmpPath(allocator, tmp, name);
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn expectLines(path: []const u8, start: ?usize, end: ?usize, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const result = try getLinesInRange(allocator, path, start, end);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "isBinary flags a NUL byte" {
    try std.testing.expect(isBinary("ab\x00cd"));
    try std.testing.expect(isBinary("\x00"));
}

test "isBinary accepts text, unicode and empty input" {
    try std.testing.expect(!isBinary(""));
    try std.testing.expect(!isBinary("fn main() void {}\n"));
    try std.testing.expect(!isBinary("héllo wörld ✓\n"));
}

test "isBinary only inspects the first 4096 bytes" {
    var buf = [_]u8{'a'} ** 5000;
    buf[4095] = 0;
    try std.testing.expect(isBinary(&buf));
    buf[4095] = 'a';
    buf[4096] = 0;
    try std.testing.expect(!isBinary(&buf));
}

test "getLinesInRange returns the whole file when no range is given" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, null, null, test_content);
}

test "getLinesInRange keeps a trailing newline when no range is given" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", "a\nb\n");
    defer allocator.free(path);

    try expectLines(path, null, null, "a\nb\n");
}

test "getLinesInRange selects an inclusive 1-based range" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, 2, 4, "two\nthree\nfour");
    try expectLines(path, 1, 1, "one");
    try expectLines(path, 5, 5, "five");
    try expectLines(path, 1, 5, test_content);
}

test "getLinesInRange with only a start runs to the end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, 3, null, "three\nfour\nfive");
    try expectLines(path, 5, null, "five");
}

test "getLinesInRange with only an end starts at the top" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, null, 2, "one\ntwo");
}

test "getLinesInRange clamps an end past the last line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, 4, 100, "four\nfive");
    try expectLines(path, null, 100, test_content);
}

test "getLinesInRange treats a start of zero as the first line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try expectLines(path, 0, 2, "one\ntwo");
}

test "getLinesInRange rejects ranges outside the file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", test_content);
    defer allocator.free(path);

    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 6, null));
    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 99, 100));
    // Reversed: start is after end.
    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 4, 3));
    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 3, 2));
}

test "getLinesInRange counts the empty segment after a trailing newline as a line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", "a\nb\n");
    defer allocator.free(path);

    try expectLines(path, 2, null, "b\n");
    try expectLines(path, 3, null, "");
    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 4, null));
}

test "getLinesInRange handles an empty file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "empty.txt", "");
    defer allocator.free(path);

    try expectLines(path, null, null, "");
    try expectLines(path, 1, null, "");
    try std.testing.expectError(error.InvalidRange, getLinesInRange(allocator, path, 2, null));
}

test "getLinesInRange refuses binary files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "blob.bin", "abc\x00def\nghi");
    defer allocator.free(path);

    try std.testing.expectError(error.BinaryFileNotSupported, getLinesInRange(allocator, path, null, null));
    try std.testing.expectError(error.BinaryFileNotSupported, getLinesInRange(allocator, path, 1, 2));
}

test "getLinesInRange refuses files over 10MB without reading them" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "big.txt", "x");
    defer allocator.free(path);

    var file = try tmp.dir.openFile("big.txt", .{ .mode = .write_only });
    defer file.close();
    try file.setEndPos(10 * 1024 * 1024 + 1);

    try std.testing.expectError(error.FileTooLarge, getLinesInRange(allocator, path, null, null));
}

test "getLinesInRange accepts a file of exactly 10MB" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "limit.txt", "x");
    defer allocator.free(path);

    var file = try tmp.dir.openFile("limit.txt", .{ .mode = .write_only });
    defer file.close();
    // Sparse file: reads back as NUL bytes, which is binary, but it must get
    // past the size check to be classified as such.
    try file.setEndPos(10 * 1024 * 1024);

    try std.testing.expectError(error.BinaryFileNotSupported, getLinesInRange(allocator, path, null, null));
}

test "getLinesInRange reports a missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp, "missing.txt");
    defer allocator.free(path);

    try std.testing.expectError(error.FileNotFound, getLinesInRange(allocator, path, null, null));
}

test "getLinesInRange preserves non-ASCII text and CRLF line endings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "a.txt", "héllo\r\nwörld ✓\r\nend");
    defer allocator.free(path);

    try expectLines(path, 2, 2, "wörld ✓\r");
}

test "readFile returns the file's exact bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTmpFile(allocator, &tmp, "r.bin", "abc\x00\xff\n");
    defer allocator.free(path);

    const data = try readFile(allocator, path);
    defer allocator.free(data);
    try std.testing.expectEqualSlices(u8, "abc\x00\xff\n", data);
}

test "readFile reports a missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp, "nope");
    defer allocator.free(path);

    try std.testing.expectError(error.FileNotFound, readFile(allocator, path));
}

test "ensurePngExtension appends .png when missing" {
    const allocator = std.testing.allocator;
    const result = try ensurePngExtension(allocator, "shot");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shot.png", result);
}

test "ensurePngExtension keeps an existing .png in any case" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "shot.png", "shot.PNG", "shot.PnG" }) |name| {
        const result = try ensurePngExtension(allocator, name);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(name, result);
    }
}

test "ensurePngExtension appends to other extensions and edge cases" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "shot.jpg", "shot.jpg.png" },
        .{ "shot.png.bak", "shot.png.bak.png" },
        .{ "my shot", "my shot.png" },
        .{ "png", "png.png" },
        .{ ".png", ".png" },
        .{ "", ".png" },
    };
    for (cases) |case| {
        const result = try ensurePngExtension(allocator, case[0]);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
}

test "uniqueOutputPath returns the path unchanged when it is free" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp, "out.png");
    defer allocator.free(path);

    const result = try uniqueOutputPath(allocator, path);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(path, result);
}

test "uniqueOutputPath numbers colliding paths before the extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out.png", .data = "" });
    const path = try tmpPath(allocator, &tmp, "out.png");
    defer allocator.free(path);

    const first = try uniqueOutputPath(allocator, path);
    defer allocator.free(first);
    const expected_first = try tmpPath(allocator, &tmp, "out (1).png");
    defer allocator.free(expected_first);
    try std.testing.expectEqualStrings(expected_first, first);

    try tmp.dir.writeFile(.{ .sub_path = "out (1).png", .data = "" });
    const second = try uniqueOutputPath(allocator, path);
    defer allocator.free(second);
    const expected_second = try tmpPath(allocator, &tmp, "out (2).png");
    defer allocator.free(expected_second);
    try std.testing.expectEqualStrings(expected_second, second);
}

test "uniqueOutputPath fills the first gap in the numbering" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out.png", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "out (2).png", .data = "" });
    const path = try tmpPath(allocator, &tmp, "out.png");
    defer allocator.free(path);

    const result = try uniqueOutputPath(allocator, path);
    defer allocator.free(result);
    const expected = try tmpPath(allocator, &tmp, "out (1).png");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "uniqueOutputPath appends the number when there is no extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out", .data = "" });
    const path = try tmpPath(allocator, &tmp, "out");
    defer allocator.free(path);

    const result = try uniqueOutputPath(allocator, path);
    defer allocator.free(result);
    const expected = try tmpPath(allocator, &tmp, "out (1)");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "uniqueOutputPath only splits the extension off the file name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dir.d");
    try tmp.dir.writeFile(.{ .sub_path = "dir.d/out", .data = "" });
    const path = try tmpPath(allocator, &tmp, "dir.d/out");
    defer allocator.free(path);

    const result = try uniqueOutputPath(allocator, path);
    defer allocator.free(result);
    const expected = try tmpPath(allocator, &tmp, "dir.d/out (1)");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}
