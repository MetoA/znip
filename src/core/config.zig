const std = @import("std");
const theme = @import("../ui/theme.zig");

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
    transparent_background: bool = false,
};

pub const Config = struct {
    active_preset: []const u8,
    output_directory: ?[]const u8 = null,
    font_directories: ?[]const []const u8 = null,

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

pub fn userThemesDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "themes" });
}

pub fn userThemePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const dir = try userThemesDirPath(allocator);
    defer allocator.free(dir);

    const base = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
    defer allocator.free(base);

    return try std.mem.concat(allocator, u8, &[_][]const u8{ base, ".json" });
}

fn readUserThemeFile(allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(theme.Theme) {
    const path = try userThemePath(allocator, name);
    defer allocator.free(path);

    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);

    return try std.json.parseFromSlice(theme.Theme, allocator, data, .{ .allocate = .alloc_always });
}

/// Writes `t` to `~/.znip/themes/<name>.json`. Refuses to overwrite an
/// existing file unless `force` is true. Returns the allocated absolute
/// path on success (caller frees).
pub fn saveUserTheme(allocator: std.mem.Allocator, name: []const u8, t: theme.Theme, force: bool) ![]const u8 {
    const path = try userThemePath(allocator, name);
    errdefer allocator.free(path);

    const json_data = try std.json.Stringify.valueAlloc(allocator, t, .{ .whitespace = .indent_2 });
    defer allocator.free(json_data);

    const file = std.fs.createFileAbsolute(path, .{ .exclusive = !force }) catch |err| {
        if (err == error.PathAlreadyExists) return error.ThemeAlreadyExists;
        return err;
    };
    defer file.close();

    try file.writeAll(json_data);

    return path;
}

/// Filename stems (without `.json`) of every theme file in
/// `~/.znip/themes`. Returns an empty slice if the directory doesn't exist.
/// Caller frees each name and the slice.
pub fn listUserThemeNames(allocator: std.mem.Allocator) ![]const []const u8 {
    const dir_path = try userThemesDirPath(allocator);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &[_][]const u8{},
        else => return err,
    };
    defer dir.close();

    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]));
    }

    return names.toOwnedSlice(allocator);
}

/// Resolves `name` to a theme, checking `~/.znip/themes/<name>.json` first
/// (so a user file can shadow a builtin of the same name), then builtins.
/// Returns error.ThemeNotFound if neither matches.
pub fn resolveTheme(allocator: std.mem.Allocator, name: []const u8) !theme.ThemeHandle {
    if (readUserThemeFile(allocator, name)) |parsed| {
        return .{ .owned = parsed };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (theme.findBuiltin(name)) |t| return .{ .static = t };
    return error.ThemeNotFound;
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
\\  "font": "JetBrainsMono-Bold",
\\  "font_size": 16,
\\  "window_controls": true,
\\  "show_file_name": true,
\\  "vertical_padding_px": 50,
\\  "horizontal_padding_px": 50,
\\  "include_drop_shadow": true,
\\  "transparent_background": false
\\}
\\
;
