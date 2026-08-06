const std = @import("std");

fn isWhitespaceOnly(line: []const u8) bool {
    for (line) |byte| {
        if (byte != ' ' and byte != '\t') return false;
    }
    return true;
}

fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const max = @min(a.len, b.len);
    var i: usize = 0;
    while (i < max and a[i] == b[i]) : (i += 1) {}
    return i;
}

pub fn trimCommonIndent(allocator: std.mem.Allocator, code: [:0]const u8) ![:0]u8 {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var line_iterator = std.mem.splitScalar(u8, code, '\n');
    while (line_iterator.next()) |line| {
        try lines.append(allocator, line);
    }

    var margin: ?[]const u8 = null;
    for (lines.items) |line| {
        if (isWhitespaceOnly(line)) continue;
        const indent = leadingWhitespace(line);
        if (margin) |m| {
            margin = m[0..commonPrefixLen(m, indent)];
        } else {
            margin = indent;
        }
    }

    if (margin == null or margin.?.len == 0) {
        return allocator.dupeZ(u8, code);
    }
    const m = margin.?;

    var trimmed_lines = std.ArrayList([]const u8).empty;
    defer trimmed_lines.deinit(allocator);

    for (lines.items) |line| {
        if (std.mem.startsWith(u8, line, m)) {
            try trimmed_lines.append(allocator, line[m.len..]);
        } else {
            try trimmed_lines.append(allocator, line[leadingWhitespace(line).len..]);
        }
    }

    return std.mem.joinZ(allocator, "\n", trimmed_lines.items);
}

test "trimCommonIndent: uniform indent is removed" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "    fn foo() void {\n        bar();\n    }";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fn foo() void {\n    bar();\n}", result);
}

test "trimCommonIndent: no common indent is a no-op" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "fn foo() void {\n    bar();\n}";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "trimCommonIndent: blank lines are ignored when computing margin" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "    fn foo() void {\n\n        bar();\n    }";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fn foo() void {\n\n    bar();\n}", result);
}

test "trimCommonIndent: mixed tabs and spaces is a no-op" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "\tfn foo() void {\n    bar();\n\t}";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "trimCommonIndent: single line input" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "    const x = 1;";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("const x = 1;", result);
}
