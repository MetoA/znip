const std = @import("std");
const theme = @import("../ui/theme.zig");

/// Test seam: when set, replaces `$HOME` for everything stored under `~/.znip`
/// (config, presets, themes, fonts, grammars). Always null in production.
pub var home_dir_override: ?[]const u8 = null;

/// The user's home directory; caller frees. Must be an absolute path: an
/// empty or relative `$HOME` would make everything under `~/.znip` resolve
/// against the working directory (and trips asserts in std's absolute-path
/// helpers).
pub fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    if (home_dir_override) |home| return allocator.dupe(u8, home);
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    errdefer allocator.free(home);
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return home;
}

/// Expands a leading `~` / `~/` to the home directory; any other path is
/// returned unchanged (as a copy). Caller frees.
pub fn expandTilde(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = try homeDir(allocator);
        defer allocator.free(home);

        if (path.len == 1) return try allocator.dupe(u8, home);
        return try std.fs.path.join(allocator, &[_][]const u8{ home, path[2..] });
    }
    return try allocator.dupe(u8, path);
}

/// Preset and theme names become file names under `~/.znip`, so they must not
/// be able to point anywhere else.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

const json_parse_options: std.json.ParseOptions = .{
    .allocate = .alloc_always,
    // Files are hand-edited and may come from a newer znip: tolerate keys we
    // don't know about instead of refusing to run.
    .ignore_unknown_fields = true,
};

/// Writes `data` to `path` through a uniquely named sibling file and a rename,
/// so a crash or full disk can't leave a truncated file behind.
fn writeFileReplacing(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, std.crypto.random.int(u64) });
    defer allocator.free(tmp_path);

    const cwd = std.fs.cwd();
    {
        const file = try cwd.createFile(tmp_path, .{ .exclusive = true });
        errdefer cwd.deleteFile(tmp_path) catch {};
        defer file.close();
        try file.writeAll(data);
    }
    errdefer cwd.deleteFile(tmp_path) catch {};
    try cwd.rename(tmp_path, path);
}

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

    pub const max_font_size = 512;
    pub const max_padding_px = 10_000;

    /// Rejects values that can't produce a sensible image (and would
    /// overflow the renderer's size arithmetic).
    pub fn validate(self: Preset) !void {
        if (self.font_size == 0 or self.font_size > max_font_size) return error.InvalidFontSize;
        if (self.vertical_padding_px > max_padding_px or self.horizontal_padding_px > max_padding_px) return error.InvalidPadding;
    }
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
                return try std.json.parseFromSlice(Config, allocator, config_default, json_parse_options);
            },
            else => return err,
        };
        defer allocator.free(data);

        return std.json.parseFromSlice(Config, allocator, data, json_parse_options) catch |err| {
            std.log.warn("Couldn't parse '{s}'", .{path});
            return err;
        };
    }

    pub fn save(allocator: std.mem.Allocator, cfg: Config) !void {
        const path = try configPath(allocator);
        defer allocator.free(path);

        const json_data = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_2 });
        defer allocator.free(json_data);

        try writeFileReplacing(allocator, path, json_data);
    }

    /// Whether `~/.znip/presets/<name>.json` exists (a missing preset falls
    /// back to the default one in `loadPreset`, which callers may want to
    /// mention).
    pub fn presetFileExists(allocator: std.mem.Allocator, name: []const u8) bool {
        const path = presetPath(allocator, name) catch return false;
        defer allocator.free(path);
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    pub fn loadPreset(allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(Preset) {
        if (!isValidName(name)) return error.InvalidPresetName;
        return readPresetFile(allocator, name) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.eql(u8, name, "default")) {
                    return try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options);
                }
                return readPresetFile(allocator, "default") catch |err2| switch (err2) {
                    error.FileNotFound => try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options),
                    else => err2,
                };
            },
            else => err,
        };
    }

    pub fn savePreset(allocator: std.mem.Allocator, preset: Preset) !void {
        const name = preset.name orelse return error.PresetNameRequired;
        try savePresetAs(allocator, name, preset);
    }

    /// Saves `preset` as `~/.znip/presets/<file_stem>.json`. Unlike
    /// `savePreset` this doesn't trust the preset's own `name` field to match
    /// the file it was loaded from.
    pub fn savePresetAs(allocator: std.mem.Allocator, file_stem: []const u8, preset: Preset) !void {
        if (!isValidName(file_stem)) return error.InvalidPresetName;

        const path_with_ext = try presetPath(allocator, file_stem);
        defer allocator.free(path_with_ext);

        const json_data = try std.json.Stringify.valueAlloc(allocator, preset, .{ .whitespace = .indent_2 });
        defer allocator.free(json_data);

        try writeFileReplacing(allocator, path_with_ext, json_data);
    }
};

fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "config.json" });
}

fn presetPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const home = try homeDir(allocator);
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

    return std.json.parseFromSlice(Preset, allocator, data, json_parse_options) catch |err| {
        std.log.warn("Couldn't parse '{s}'", .{path_with_ext});
        return err;
    };
}

pub fn userThemesDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "themes" });
}

pub fn userThemePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!isValidName(name)) return error.InvalidThemeName;
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

    return std.json.parseFromSlice(theme.Theme, allocator, data, json_parse_options) catch |err| {
        std.log.warn("Couldn't parse '{s}'", .{path});
        return err;
    };
}

/// Writes `t` to `~/.znip/themes/<name>.json`. Refuses to overwrite an
/// existing file unless `force` is true. Returns the allocated absolute
/// path on success (caller frees).
pub fn saveUserTheme(allocator: std.mem.Allocator, name: []const u8, t: theme.Theme, force: bool) ![]const u8 {
    const path = try userThemePath(allocator, name);
    errdefer allocator.free(path);

    const json_data = try std.json.Stringify.valueAlloc(allocator, t, .{ .whitespace = .indent_2 });
    defer allocator.free(json_data);

    if (!force) {
        // Exclusive create keeps "refuse to overwrite" race-free.
        const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) return error.ThemeAlreadyExists;
            return err;
        };
        defer file.close();
        errdefer std.fs.deleteFileAbsolute(path) catch {};
        try file.writeAll(json_data);
    } else {
        try writeFileReplacing(allocator, path, json_data);
    }

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
        // Symlinks count: dotfile managers install themes that way.
        if (entry.kind != .file and entry.kind != .sym_link and entry.kind != .unknown) continue;
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
        // A name that can't be a file name can still match a builtin.
        error.FileNotFound, error.InvalidThemeName => {},
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
    const home = try homeDir(allocator);
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
    const home = try homeDir(allocator);
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

    // Don't leave an empty file behind: later runs would see it as existing
    // (and never repair it) and then fail to parse it.
    errdefer std.fs.deleteFileAbsolute(full_path) catch {};
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

/// Points `$HOME` at a fresh temporary directory for the duration of a test.
const TmpHome = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(allocator: std.mem.Allocator) !TmpHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        home_dir_override = path;
        return .{ .tmp = tmp, .path = path };
    }

    /// Like `init`, plus the standard `~/.znip` tree.
    fn initWithConfigDirs(allocator: std.mem.Allocator) !TmpHome {
        const home = try init(allocator);
        errdefer home.deinit(allocator);
        try createRootConfigDirectories(allocator);
        return home;
    }

    fn deinit(self: *const TmpHome, allocator: std.mem.Allocator) void {
        home_dir_override = null;
        allocator.free(self.path);
        var tmp = self.tmp;
        tmp.cleanup();
    }
};

fn expectContainsName(names: []const []const u8, wanted: []const u8) !void {
    for (names) |n| if (std.mem.eql(u8, n, wanted)) return;
    return error.TestUnexpectedResult;
}

fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

test "homeDir returns the override when set" {
    const allocator = std.testing.allocator;
    home_dir_override = "/somewhere/else";
    defer home_dir_override = null;

    const home = try homeDir(allocator);
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/somewhere/else", home);
}

test "homeDir falls back to the HOME environment variable" {
    const allocator = std.testing.allocator;
    home_dir_override = null;

    const expected = std.process.getEnvVarOwned(allocator, "HOME") catch return error.SkipZigTest;
    defer allocator.free(expected);
    const home = try homeDir(allocator);
    defer allocator.free(home);
    try std.testing.expectEqualStrings(expected, home);
}

test "config paths live under ~/.znip" {
    const allocator = std.testing.allocator;
    home_dir_override = "/home/u";
    defer home_dir_override = null;

    const config_file = try configPath(allocator);
    defer allocator.free(config_file);
    try std.testing.expectEqualStrings("/home/u/.znip/config.json", config_file);

    const preset_file = try presetPath(allocator, "work");
    defer allocator.free(preset_file);
    try std.testing.expectEqualStrings("/home/u/.znip/presets/work.json", preset_file);

    const themes_dir = try userThemesDirPath(allocator);
    defer allocator.free(themes_dir);
    try std.testing.expectEqualStrings("/home/u/.znip/themes", themes_dir);

    const theme_file = try userThemePath(allocator, "My Theme");
    defer allocator.free(theme_file);
    try std.testing.expectEqualStrings("/home/u/.znip/themes/My Theme.json", theme_file);
}

test "config_default parses with no optional settings" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_default, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("default", parsed.value.active_preset);
    try std.testing.expect(parsed.value.output_directory == null);
    try std.testing.expect(parsed.value.font_directories == null);
}

test "preset_default parses to the documented defaults" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options);
    defer parsed.deinit();
    const p = parsed.value;

    try std.testing.expectEqualStrings("default", p.name.?);
    try std.testing.expectEqualStrings("One Darker", p.theme);
    try std.testing.expectEqualStrings("JetBrainsMono-Bold", p.font);
    try std.testing.expectEqual(@as(u32, 16), p.font_size);
    try std.testing.expect(p.window_controls);
    try std.testing.expect(p.show_file_name);
    try std.testing.expectEqual(@as(u32, 50), p.vertical_padding_px);
    try std.testing.expectEqual(@as(u32, 50), p.horizontal_padding_px);
    try std.testing.expect(p.include_drop_shadow);
    try std.testing.expect(!p.transparent_background);
}

test "the default preset names a builtin theme" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options);
    defer parsed.deinit();
    try std.testing.expect(theme.findBuiltin(parsed.value.theme) != null);
}

test "Preset applies defaults for show_file_name and transparent_background" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name":"p","theme":"One Darker","font":"F","font_size":12,"window_controls":false,
        \\"vertical_padding_px":1,"horizontal_padding_px":2,"include_drop_shadow":false}
    ;
    const parsed = try std.json.parseFromSlice(Preset, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.show_file_name);
    try std.testing.expect(!parsed.value.transparent_background);
    try std.testing.expect(!parsed.value.window_controls);
}

test "Preset rejects a missing required field" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(
        Preset,
        allocator,
        \\{"name":"p","theme":"One Darker"}
        ,
        .{ .allocate = .alloc_always },
    ));
}

test "Config.load returns the defaults when there is no config file" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const parsed = try Config.load(allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("default", parsed.value.active_preset);
    try std.testing.expect(parsed.value.output_directory == null);
}

test "Config.save and Config.load round trip" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    const dirs = [_][]const u8{ "/fonts/a", "/fonts/b" };
    try Config.save(allocator, .{
        .active_preset = "work",
        .output_directory = "/tmp/images",
        .font_directories = &dirs,
    });

    const parsed = try Config.load(allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("work", parsed.value.active_preset);
    try std.testing.expectEqualStrings("/tmp/images", parsed.value.output_directory.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.font_directories.?.len);
    try std.testing.expectEqualStrings("/fonts/b", parsed.value.font_directories.?[1]);
}

test "Config.save fails when ~/.znip does not exist" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    try std.testing.expectError(error.FileNotFound, Config.save(allocator, .{ .active_preset = "x" }));
}

test "Config.load reports a corrupt config file" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/config.json", .data = "{not json" });
    try std.testing.expectError(error.SyntaxError, Config.load(allocator));
}

test "Config.loadPreset falls back to the builtin default when nothing is saved" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const named = try Config.loadPreset(allocator, "does-not-exist");
    defer named.deinit();
    try std.testing.expectEqualStrings("One Darker", named.value.theme);

    const default = try Config.loadPreset(allocator, "default");
    defer default.deinit();
    try std.testing.expectEqualStrings("default", default.value.name.?);
}

test "Config.savePreset requires a name" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    const preset = Preset{
        .name = null,
        .theme = "One Darker",
        .font = "F",
        .font_size = 12,
        .window_controls = true,
        .vertical_padding_px = 1,
        .horizontal_padding_px = 1,
        .include_drop_shadow = false,
    };
    try std.testing.expectError(error.PresetNameRequired, Config.savePreset(allocator, preset));
}

test "Config.savePreset and loadPreset round trip every field" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try Config.savePreset(allocator, .{
        .name = "work",
        .theme = "Paper White",
        .font = "Inter-Bold",
        .font_size = 22,
        .window_controls = false,
        .show_file_name = false,
        .vertical_padding_px = 11,
        .horizontal_padding_px = 33,
        .include_drop_shadow = false,
        .transparent_background = true,
    });

    const parsed = try Config.loadPreset(allocator, "work");
    defer parsed.deinit();
    const p = parsed.value;
    try std.testing.expectEqualStrings("work", p.name.?);
    try std.testing.expectEqualStrings("Paper White", p.theme);
    try std.testing.expectEqualStrings("Inter-Bold", p.font);
    try std.testing.expectEqual(@as(u32, 22), p.font_size);
    try std.testing.expect(!p.window_controls);
    try std.testing.expect(!p.show_file_name);
    try std.testing.expectEqual(@as(u32, 11), p.vertical_padding_px);
    try std.testing.expectEqual(@as(u32, 33), p.horizontal_padding_px);
    try std.testing.expect(!p.include_drop_shadow);
    try std.testing.expect(p.transparent_background);
}

test "Config.loadPreset for a missing name falls back to the user's own default preset" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try Config.savePreset(allocator, .{
        .name = "default",
        .theme = "Solarized Light",
        .font = "F",
        .font_size = 9,
        .window_controls = true,
        .vertical_padding_px = 1,
        .horizontal_padding_px = 1,
        .include_drop_shadow = true,
    });

    const parsed = try Config.loadPreset(allocator, "missing");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Solarized Light", parsed.value.theme);
    try std.testing.expectEqual(@as(u32, 9), parsed.value.font_size);
}

test "Config.loadPreset reports a corrupt preset instead of falling back" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/presets/broken.json", .data = "][" });
    try std.testing.expectError(error.SyntaxError, Config.loadPreset(allocator, "broken"));
}

test "createRootConfigDirectories builds the ~/.znip tree with default files" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    try createRootConfigDirectories(allocator);

    for ([_][]const u8{ ".znip", ".znip/presets", ".znip/themes", ".znip/fonts", ".znip/grammars" }) |dir| {
        var d = try home.tmp.dir.openDir(dir, .{});
        d.close();
    }

    const config_json = try home.tmp.dir.readFileAlloc(allocator, ".znip/config.json", 4096);
    defer allocator.free(config_json);
    try std.testing.expectEqualStrings(config_default, config_json);

    const preset_json = try home.tmp.dir.readFileAlloc(allocator, ".znip/presets/default.json", 4096);
    defer allocator.free(preset_json);
    try std.testing.expectEqualStrings(preset_default, preset_json);
}

test "createRootConfigDirectories is idempotent and keeps user edits" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/config.json", .data = "{\"active_preset\":\"mine\"}" });
    try createRootConfigDirectories(allocator);

    const parsed = try Config.load(allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("mine", parsed.value.active_preset);
}

test "saveUserTheme writes a theme that resolves back" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    var custom = theme.OneDarker;
    custom.name = "Custom";
    custom.ui.background = 0xFF123456;

    const path = try saveUserTheme(allocator, "Custom", custom, false);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".znip/themes/Custom.json"));

    var handle = try resolveTheme(allocator, "Custom");
    defer handle.deinit();
    try std.testing.expectEqualStrings("Custom", handle.value().name);
    try std.testing.expectEqual(@as(u32, 0xFF123456), handle.value().ui.background);
}

test "saveUserTheme refuses to overwrite unless forced" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    const first = try saveUserTheme(allocator, "Dup", theme.OneDarker, false);
    allocator.free(first);
    try std.testing.expectError(error.ThemeAlreadyExists, saveUserTheme(allocator, "Dup", theme.PaperWhite, false));

    var forced = theme.PaperWhite;
    forced.name = "Dup";
    const second = try saveUserTheme(allocator, "Dup", forced, true);
    allocator.free(second);

    var handle = try resolveTheme(allocator, "Dup");
    defer handle.deinit();
    try std.testing.expectEqual(theme.PaperWhite.ui.background, handle.value().ui.background);
}

test "saveUserTheme fails when the themes directory is missing" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    try std.testing.expectError(error.FileNotFound, saveUserTheme(allocator, "X", theme.OneDarker, false));
}

test "listUserThemeNames is empty when the themes directory does not exist" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const names = try listUserThemeNames(allocator);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "listUserThemeNames returns the stems of .json files only" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/alpha.json", .data = "{}" });
    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/Two Words.json", .data = "{}" });
    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/notes.txt", .data = "" });
    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/backup.json.bak", .data = "" });
    try home.tmp.dir.makePath(".znip/themes/folder.json");

    const names = try listUserThemeNames(allocator);
    defer freeNames(allocator, names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try expectContainsName(names, "alpha");
    try expectContainsName(names, "Two Words");
}

test "resolveTheme returns builtins without allocating" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    for (theme.builtin_themes) |t| {
        var handle = try resolveTheme(allocator, t.name);
        defer handle.deinit();
        try std.testing.expect(handle == .static);
        try std.testing.expectEqualStrings(t.name, handle.value().name);
    }
}

test "resolveTheme lets a user file shadow a builtin of the same name" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    var tweaked = theme.OneDarker;
    tweaked.ui.background = 0xFF010203;
    const path = try saveUserTheme(allocator, "One Darker", tweaked, false);
    allocator.free(path);

    var handle = try resolveTheme(allocator, "One Darker");
    defer handle.deinit();
    try std.testing.expect(handle == .owned);
    try std.testing.expectEqual(@as(u32, 0xFF010203), handle.value().ui.background);
}

test "resolveTheme reports an unknown theme" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try std.testing.expectError(error.ThemeNotFound, resolveTheme(allocator, "Nope"));
    try std.testing.expectError(error.ThemeNotFound, resolveTheme(allocator, ""));
}

test "resolveTheme surfaces a malformed user theme instead of hiding it" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/Bad.json", .data = "{\"name\": " });
    try std.testing.expectError(error.UnexpectedEndOfInput, resolveTheme(allocator, "Bad"));

    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/themes/Incomplete.json", .data = "{\"name\":\"x\",\"ui\":{},\"syntax\":{}}" });
    try std.testing.expectError(error.MissingField, resolveTheme(allocator, "Incomplete"));
}

test "isValidName rejects names that could leave ~/.znip" {
    try std.testing.expect(isValidName("work"));
    try std.testing.expect(isValidName("One Darker"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("."));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("../x"));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a\\b"));
}

test "Config.loadPreset and savePresetAs reject path-like names" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPresetName, Config.loadPreset(allocator, "../../x"));
    try std.testing.expectError(error.InvalidPresetName, Config.loadPreset(allocator, ""));
    const preset = (try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options));
    defer preset.deinit();
    try std.testing.expectError(error.InvalidPresetName, Config.savePresetAs(allocator, "a/b", preset.value));
}

test "config, preset and theme files tolerate unknown keys" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{
        .sub_path = ".znip/config.json",
        .data = "{\"$schema\": \"x\", \"active_preset\": \"default\", \"future\": [1, 2]}",
    });
    const cfg = try Config.load(allocator);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("default", cfg.value.active_preset);

    var extra = std.ArrayList(u8).empty;
    defer extra.deinit(allocator);
    try extra.appendSlice(allocator, "{\"comment\": \"hi\", ");
    try extra.appendSlice(allocator, preset_default[1..]);
    try home.tmp.dir.writeFile(.{ .sub_path = ".znip/presets/extra.json", .data = extra.items });
    const preset = try Config.loadPreset(allocator, "extra");
    defer preset.deinit();
    try std.testing.expectEqual(@as(u32, 16), preset.value.font_size);
}

test "savePresetAs writes the file it is told to, regardless of the preset's name" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    var parsed = try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options);
    defer parsed.deinit();
    parsed.value.font_size = 20;

    try Config.savePresetAs(allocator, "work", parsed.value);
    const work = try Config.loadPreset(allocator, "work");
    defer work.deinit();
    try std.testing.expectEqual(@as(u32, 20), work.value.font_size);
    // default.json is untouched.
    const default = try Config.loadPreset(allocator, "default");
    defer default.deinit();
    try std.testing.expectEqual(@as(u32, 16), default.value.font_size);
    // and no temp files are left in the presets directory
    var dir = try home.tmp.dir.openDir(".znip/presets", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| try std.testing.expect(std.mem.endsWith(u8, entry.name, ".json"));
}

test "Preset.validate bounds font size and padding" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Preset, allocator, preset_default, json_parse_options);
    defer parsed.deinit();
    var p = parsed.value;
    try p.validate();
    p.font_size = 0;
    try std.testing.expectError(error.InvalidFontSize, p.validate());
    p.font_size = Preset.max_font_size + 1;
    try std.testing.expectError(error.InvalidFontSize, p.validate());
    p.font_size = 16;
    p.horizontal_padding_px = Preset.max_padding_px + 1;
    try std.testing.expectError(error.InvalidPadding, p.validate());
}

test "listUserThemeNames includes symlinked theme files" {
    const allocator = std.testing.allocator;
    const home = try TmpHome.initWithConfigDirs(allocator);
    defer home.deinit(allocator);

    try home.tmp.dir.writeFile(.{ .sub_path = "real.json", .data = "{}" });
    const target = try std.fs.path.join(allocator, &.{ home.path, "real.json" });
    defer allocator.free(target);
    try home.tmp.dir.symLink(target, ".znip/themes/linked.json", .{});

    const names = try listUserThemeNames(allocator);
    defer freeNames(allocator, names);
    try expectContainsName(names, "linked");
}
