const std = @import("std");

fn isWhitespaceOnly(line: []const u8) bool {
    // A stray '\r' (CRLF input) must not make a blank line look like code,
    // which would collapse the common margin to nothing.
    for (line) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != 0x0b and byte != 0x0c) return false;
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

test "trimCommonIndent: tab indentation is removed" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "\tif (x) {\n\t\ty();\n\t}";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("if (x) {\n\ty();\n}", result);
}

test "trimCommonIndent: only the shared prefix is removed" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "      a\n    b\n        c";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("  a\nb\n    c", result);
}

test "trimCommonIndent: whitespace-only lines are emptied" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "  a\n \n  b";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\n\nb", result);
}

test "trimCommonIndent: empty input stays empty" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "trimCommonIndent: all-blank input is returned unchanged" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "   \n\t\n";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "trimCommonIndent: trailing newline is preserved" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "  a\n  b\n";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\nb\n", result);
}

test "trimCommonIndent: result is NUL-terminated" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "  x";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0), result[result.len]);
}

test "trimCommonIndent: blank CRLF lines don't defeat the margin" {
    const allocator = std.testing.allocator;
    const input: [:0]const u8 = "    a\r\n\r\n  \r\n    b\r";
    const result = try trimCommonIndent(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\r\n\r\n\r\nb\r", result);
}
