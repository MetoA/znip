const std = @import("std");
const theme = @import("../ui/theme.zig");

const Preset = struct {
    name: ?[]const u8,
    theme: []const u8,
    font: []const u8,
    font_size: u32,
    window_controls: bool,
    vertical_padding_px: u32,
    horizontal_padding_px: u32,
    include_drop_shadow: bool,
};

const ConfigNew = struct {
    inline_preset: Preset,
};

const CodeWindowPaddingSize = enum(u32) {
    sm = 25,
    md = 50,
    lg = 75,
    xl = 100,
};

const BoxShadowOptions = struct {
    enabled: bool = true,
    offset_x: f64 = 0.0,
    offset_y: f64 = 5.0,
    blur: f64 = 20.0,
    color: u32 = 0x10000000,
};

const CodeWindowOptions = struct {
    padding: CodeWindowPaddingSize = CodeWindowPaddingSize.md,
    max_width: f64 = 700.0,
    radius: f64 = 12.0,
    box_shadow: BoxShadowOptions = .{},

    pub fn x(self: *CodeWindowOptions) f32 {
        return @as(f32, @floatFromInt(@intFromEnum(self.padding)));
    }

    pub fn y(self: *CodeWindowOptions) f32 {
        return @as(f32, @floatFromInt(@intFromEnum(self.padding)));
    }

    pub fn lineNumberX(self: *CodeWindowOptions) f64 {
        return self.x() + 5.0;
    }

    pub fn windowControlsX(self: *CodeWindowOptions) f64 {
        return self.x() + 25.0;
    }

    pub fn windowControlsY(self: *CodeWindowOptions) f64 {
        return self.y() + 25.0;
    }

    pub fn codeStartX(self: *CodeWindowOptions) f32 {
        return self.x() + 50.0;
    }

    pub fn codeStartY(self: *CodeWindowOptions) f32 {
        return self.y() + 50.0;
    }

    pub fn heightFromLastY(self: *CodeWindowOptions, last_y: f64) f64 {
        const padding_bottom = 25.0;
        return last_y + padding_bottom - self.y();
    }
};

pub const Config = struct {
    font_size: f32 = 16.0,
    code_window_options: CodeWindowOptions = .{},
    active_theme: theme.Theme = theme.PaperWhite,

    pub fn init() !Config {
        // TODO load from file? and have default
        return .{};
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
    std.log.debug("FULL PATH DIRECTORY {s}", .{full_path});

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
    std.log.debug("FULL PATH FILE {s}", .{full_path});

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
\\{
\\  "inline_preset": {
\\      "theme": "One Darker",
\\      "font": "JetBrainsMono-Bold.ttf",
\\      "font_size": 16,
\\      "window_controls": true,
\\      "vertical_padding_px": 50,
\\      "horizontal_padding_px": 50,
\\      "include_drop_shadow": true
\\  }
\\}
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