const std = @import("std");
const vaxis = @import("vaxis");
const znip = @import("znip");
const fonts = znip.fonts_module;

const Preset = znip.config.Preset;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const Result = struct {
    preset: Preset,
    saved_as: ?[]const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.preset.theme);
        allocator.free(self.preset.font);
        if (self.preset.name) |name| allocator.free(name);
    }
};

const Line = struct {
    text: []const u8,
    style: vaxis.Style = .{},
    owned: bool = false,
};

const Wizard = struct {
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(Event),

    fn render(self: *Wizard, lines: []const Line) !void {
        const win = self.vx.window();
        win.clear();
        for (lines, 0..) |line, i| {
            _ = win.print(&.{.{ .text = line.text, .style = line.style }}, .{ .row_offset = @intCast(i) });
        }
        try self.vx.render(self.tty.writer());
    }

    fn nextKey(self: *Wizard) !vaxis.Key {
        while (true) {
            const event = self.loop.nextEvent();
            switch (event) {
                .key_press => |key| return key,
                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
            }
        }
    }

    fn isCancel(key: vaxis.Key) bool {
        return key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{});
    }

    fn selectOne(self: *Wizard, title: []const u8, options: []const []const u8) !usize {
        var idx: usize = 0;
        while (true) {
            var lines = std.ArrayList(Line).empty;
            defer {
                for (lines.items) |line| if (line.owned) self.allocator.free(line.text);
                lines.deinit(self.allocator);
            }

            try lines.append(self.allocator, .{ .text = title, .style = .{ .bold = true } });
            try lines.append(self.allocator, .{ .text = "" });
            for (options, 0..) |option, i| {
                const marker = if (i == idx) "> " else "  ";
                const text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ marker, option });
                try lines.append(self.allocator, .{
                    .text = text,
                    .style = if (i == idx) .{ .reverse = true } else .{},
                    .owned = true,
                });
            }
            try lines.append(self.allocator, .{ .text = "" });
            try lines.append(self.allocator, .{ .text = "up/down to move, enter to select, ctrl+c to cancel", .style = .{ .dim = true } });

            try self.render(lines.items);

            const key = try self.nextKey();
            if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                idx = if (idx == 0) options.len - 1 else idx - 1;
            } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                idx = if (idx + 1 == options.len) 0 else idx + 1;
            } else if (key.matches(vaxis.Key.enter, .{})) {
                return idx;
            } else if (isCancel(key)) {
                return error.WizardCancelled;
            }
        }
    }

    fn confirm(self: *Wizard, title: []const u8, default_yes: bool) !bool {
        const options = [_][]const u8{ "Yes", "No" };
        const idx = try self.selectOne(title, &options);
        _ = default_yes;
        return idx == 0;
    }

    /// Prompts for a line of text, returning an allocator-owned slice.
    fn textInput(self: *Wizard, title: []const u8, initial: ?[]const u8, err_message: ?[]const u8) ![]const u8 {
        var input = vaxis.widgets.TextInput.init(self.allocator, &self.vx.unicode);
        defer input.deinit();
        if (initial) |text| try input.insertSliceAtCursor(text);

        while (true) {
            const win = self.vx.window();
            win.clear();
            _ = win.print(&.{.{ .text = title, .style = .{ .bold = true } }}, .{ .row_offset = 0 });
            if (err_message) |msg| {
                _ = win.print(&.{.{ .text = msg, .style = .{ .fg = .{ .index = 1 } } }}, .{ .row_offset = 1 });
            }
            const input_win = win.child(.{ .x_off = 0, .y_off = 3, .width = win.width, .height = 1 });
            input.draw(input_win);
            try self.vx.render(self.tty.writer());

            const key = try self.nextKey();
            if (key.matches(vaxis.Key.enter, .{})) {
                return try input.toOwnedSlice();
            } else if (isCancel(key)) {
                return error.WizardCancelled;
            }
            try input.update(.{ .key_press = key });
        }
    }

    fn numberInput(self: *Wizard, title: []const u8, default: u32) !u32 {
        var default_buf: [16]u8 = undefined;
        const default_str = try std.fmt.bufPrint(&default_buf, "{d}", .{default});

        var err_message: ?[]const u8 = null;
        while (true) {
            const raw = try self.textInput(title, default_str, err_message);
            defer self.allocator.free(raw);

            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return default;

            if (std.fmt.parseInt(u32, trimmed, 10)) |value| {
                return value;
            } else |_| {
                err_message = "Please enter a whole number.";
            }
        }
    }
};

pub fn run(allocator: std.mem.Allocator) !Result {
    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    defer vx.exitAltScreen(tty.writer()) catch {};
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var wiz = Wizard{ .allocator = allocator, .tty = &tty, .vx = &vx, .loop = &loop };

    var theme_names = std.ArrayList([]const u8).empty;
    defer theme_names.deinit(allocator);
    for (znip.theme_module.builtin_themes) |t| try theme_names.append(allocator, t.name);

    const theme_idx = try wiz.selectOne("Select a theme", theme_names.items);
    const theme_name = try allocator.dupe(u8, theme_names.items[theme_idx]);
    errdefer allocator.free(theme_name);

    const font_names = try fonts.listAvailableFontNames(allocator);
    defer {
        for (font_names) |name| allocator.free(name);
        allocator.free(font_names);
    }
    const font_idx = try wiz.selectOne("Select a font", font_names);
    const font_name = try allocator.dupe(u8, font_names[font_idx]);
    errdefer allocator.free(font_name);

    const font_size = try wiz.numberInput("Font size (px)", 16);
    const window_controls = try wiz.confirm("Show window controls?", true);
    const vertical_padding_px = try wiz.numberInput("Vertical padding (px)", 50);
    const horizontal_padding_px = try wiz.numberInput("Horizontal padding (px)", 50);
    const include_drop_shadow = try wiz.confirm("Include drop shadow?", true);

    const save_options = [_][]const u8{ "Save as a named preset", "Use once for this run" };
    const save_choice = try wiz.selectOne("What would you like to do with this configuration?", &save_options);

    var preset_name: ?[]const u8 = null;
    if (save_choice == 0) {
        const name = try wiz.textInput("Preset name", null, null);
        errdefer allocator.free(name);
        preset_name = name;
    }

    const preset = Preset{
        .name = preset_name,
        .theme = theme_name,
        .font = font_name,
        .font_size = font_size,
        .window_controls = window_controls,
        .vertical_padding_px = vertical_padding_px,
        .horizontal_padding_px = horizontal_padding_px,
        .include_drop_shadow = include_drop_shadow,
    };

    if (preset_name != null) {
        try znip.config.Config.savePreset(allocator, preset);
    }

    return Result{ .preset = preset, .saved_as = preset_name };
}
