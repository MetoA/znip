const std = @import("std");

pub const Preset = struct {
    name: ?[]const u8,
    theme: []const u8,
    font: []const u8,
    font_size: u32,
    window_controls: bool,
    show_file_name: bool = true,
    vertical_padding_px: u32,
    horizontal_padding_px: u32,
    include_drop_shadow: bool,
};

pub const Config = struct {
    active_preset: []const u8,
    output_directory: ?[]const u8 = null,

    pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
        const path = try configPath(allocator);
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

    pub fn save(allocator: std.mem.Allocator, cfg: Config) !void {
        const path = try configPath(allocator);
        defer allocator.free(path);

        const json_data = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_2 });
        defer allocator.free(json_data);

        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_data });
    }

    pub fn loadPreset(allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(Preset) {
        return readPresetFile(allocator, name) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.eql(u8, name, "default")) {
                    return try std.json.parseFromSlice(Preset, allocator, preset_default, .{ .allocate = .alloc_always });
                }
                return readPresetFile(allocator, "default") catch |err2| switch (err2) {
                    error.FileNotFound => try std.json.parseFromSlice(Preset, allocator, preset_default, .{ .allocate = .alloc_always }),
                    else => err2,
                };
            },
            else => err,
        };
    }

    pub fn savePreset(allocator: std.mem.Allocator, preset: Preset) !void {
        const name = preset.name orelse return error.PresetNameRequired;

        const path_with_ext = try presetPath(allocator, name);
        defer allocator.free(path_with_ext);

        const json_data = try std.json.Stringify.valueAlloc(allocator, preset, .{ .whitespace = .indent_2 });
        defer allocator.free(json_data);

        try std.fs.cwd().writeFile(.{ .sub_path = path_with_ext, .data = json_data });
    }
};

fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "config.json" });
}

fn presetPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "presets", name });
    defer allocator.free(path);

    return try std.mem.concat(allocator, u8, &[_][]const u8{ path, ".json" });
}

fn readPresetFile(allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(Preset) {
    const path_with_ext = try presetPath(allocator, name);
    defer allocator.free(path_with_ext);

    const data = try std.fs.cwd().readFileAlloc(allocator, path_with_ext, 1024 * 1024);
    defer allocator.free(data);

    return try std.json.parseFromSlice(Preset, allocator, data, .{ .allocate = .alloc_always });
}

pub fn createRootConfigDirectories(allocator: std.mem.Allocator) !void {
    try createRootDirectory(allocator, ".znip");
    try createRootDirectory(allocator, ".znip/presets");
    try createRootDirectory(allocator, ".znip/themes");
    try createRootDirectory(allocator, ".znip/fonts");
    try createRootDirectory(allocator, ".znip/grammars");
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
\\  "show_file_name": true,
\\  "vertical_padding_px": 50,
\\  "horizontal_padding_px": 50,
\\  "include_drop_shadow": true
\\}
\\
;
