const Theme = @import("../ui/theme.zig").Theme;
const themes = @import("../ui/themes.zig");

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
    active_theme: Theme = themes.PaperWhite,

    pub fn init() !Config {
        // TODO load from file?
        return .{};
    }
};
