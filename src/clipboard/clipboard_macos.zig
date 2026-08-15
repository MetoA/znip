/// Adapted from https://github.com/dgv/clipboard/blob/main/src/clipboard_macos.zig
const std = @import("std");

pub fn read() ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{
            "pbpaste",
        },
    });
    return result.stdout;
}

pub fn write(png_bytes: []const u8) !void {
    const allocator = std.heap.page_allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "zig_clipboard.png";
    var file = try tmp_dir.dir.createFile(file_name, .{
        .read = false,
        .truncate = true,
    });
    defer file.close();

    try file.writeAll(png_bytes);

    const full_path = try tmp_dir.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(full_path);

    const script =
        \\import AppKit
        \\import Foundation
        \\
        \\let filePath = CommandLine.arguments[1]
        \\let imageURL = URL(fileURLWithPath: filePath)
        \\let pngData = try Data(contentsOf: imageURL)
        \\guard let image = NSImage(data: pngData) else {
        \\    fputs("invalid PNG data\n", stderr)
        \\    exit(1)
        \\}
        \\
        \\let pasteboard = NSPasteboard.general
        \\pasteboard.clearContents()
        \\if !pasteboard.writeObjects([image]) {
        \\    fputs("failed to write image to clipboard\n", stderr)
        \\    exit(1)
        \\}
    ;

    var proc = std.process.Child.init(
        &[_][]const u8{
            "swift",
            "-e",
            script,
            full_path,
        },
        allocator,
    );
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();
    const term = proc.wait() catch return error.ClipboardProcessFailed;
    if (term != .Exited or term.Exited != 0) return error.ClipboardProcessFailed;
}
