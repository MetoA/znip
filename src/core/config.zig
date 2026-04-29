const std = @import("std");

pub const Preset = struct {
    name: ?[]const u8,
    theme: []const u8,
    font: []const u8,
    font_size: u32,
    window_controls: bool,
    vertical_padding_px: u32,
    horizontal_padding_px: u32,
    include_drop_shadow: bool,
};

pub const Config = struct {
    active_preset: []const u8,

    pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        const path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "config.json" });
        defer allocator.free(path);

        const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                return try std.json.parseFromSlice(Config, allocator, config_default, .{ .allocate = .alloc_always});
            },
            else => return err,
        };
        defer allocator.free(data);

        return try std.json.parseFromSlice(Config, allocator, data, .{ .allocate = .alloc_always});
    }

    pub fn loadPreset(allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(Preset) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        const path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "presets", name });
        defer allocator.free(path);

        const path_with_ext = try std.mem.concat(allocator, u8, &[_][]const u8{ path, ".json" });
        defer allocator.free(path_with_ext);

        const data = try std.fs.cwd().readFileAlloc(allocator, path_with_ext, 1024 * 1024);
        defer allocator.free(data);

        return try std.json.parseFromSlice(Preset, allocator, data, .{ .allocate = .alloc_always});
    }
};

pub fn createRootConfigDirectories(allocator: std.mem.Allocator) !void {
    try createRootDirectory(allocator, ".znip");
    try createRootDirectory(allocator, ".znip/presets");
    try createRootDirectory(allocator, ".znip/themes");
    try createRootFile(allocator, ".znip/config.json", config_default);
    try createRootFile(allocator, ".znip/presets/default.json", preset_default);
}

fn createRootDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const full_path = try std.fs.path.join(allocator, &[_][]const u8 { home, path });
    defer allocator.free(full_path);

    std.fs.makeDirAbsolute(full_path) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.log.debug("PathAlreadyExists", .{});
            return;
        }
        return err;
    };
}

fn createRootFile(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const full_path = try std.fs.path.join(allocator, &[_][]const u8 { home, path });
    defer allocator.free(full_path);

    const file = std.fs.createFileAbsolute(full_path, .{
        .read = true,
        .exclusive = true,
    }) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.log.debug("PathAlreadyExists", .{});
            return;
        }
        return err;
    };
    defer file.close();

    try file.writeAll(contents);
}

const config_default =
\\{"active_preset": "default"}
\\
;

const preset_default =
\\{
\\  "name": "default",
\\  "theme": "One Darker",
\\  "font": "JetBrainsMono-Bold.ttf",
\\  "font_size": 16,
\\  "window_controls": true,
\\  "vertical_padding_px": 50,
\\  "horizontal_padding_px": 50,
\\  "include_drop_shadow": true
\\}
\\
;
