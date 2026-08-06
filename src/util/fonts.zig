const std = @import("std");
const embedded_fonts = @import("../assets/fonts/fonts.zig");

pub const default_font_name = "JetBrainsMono-Bold";

pub fn listAvailableFontNames(allocator: std.mem.Allocator) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    try names.append(allocator, try allocator.dupe(u8, default_font_name));

    const fonts_dir_path = try userFontsDirPath(allocator);
    defer allocator.free(fonts_dir_path);

    var dir = std.fs.cwd().openDir(fonts_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttf")) continue;

        const name = entry.name[0 .. entry.name.len - ".ttf".len];
        try names.append(allocator, try allocator.dupe(u8, name));
    }

    return names.toOwnedSlice(allocator);
}

pub fn loadFontBytes(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, default_font_name)) {
        return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
    }

    const fonts_dir_path = try userFontsDirPath(allocator);
    defer allocator.free(fonts_dir_path);

    const path = try std.fs.path.join(allocator, &[_][]const u8{ fonts_dir_path, name });
    defer allocator.free(path);

    const path_with_ext = try std.mem.concat(allocator, u8, &[_][]const u8{ path, ".ttf" });
    defer allocator.free(path_with_ext);

    return std.fs.cwd().readFileAlloc(allocator, path_with_ext, 10 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold),
        else => err,
    };
}

pub fn userFontsDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "fonts" });
}
