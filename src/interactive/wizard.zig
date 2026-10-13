const std = @import("std");
const vaxis = @import("vaxis");
const znip = @import("znip");
const fonts = znip.fonts_module;
const output = znip.output;
const cli = @import("../core/cli.zig");

const Preset = znip.config.Preset;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const Result = struct {
    preset: Preset,
    saved_as: ?[]const u8,
    output_name: ?[]const u8,
    highlight_lines: ?[]usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.preset.theme);
        allocator.free(self.preset.font);
        if (self.preset.name) |name| allocator.free(name);
        if (self.output_name) |name| allocator.free(name);
        if (self.highlight_lines) |lines| allocator.free(lines);
    }
};

const Line = struct {
    text: []const u8,
    style: vaxis.Style = .{},
    owned: bool = false,
};

const known_font_styles = [_][]const u8{ "-BoldItalic", "-Bold", "-Italic", "-Regular" };

/// Strips a trailing style suffix (e.g. "-Bold") so same-family font files
/// can be grouped together in the picker.
fn fontFamilyName(name: []const u8) []const u8 {
    for (known_font_styles) |suffix| {
        if (name.len > suffix.len and std.ascii.eqlIgnoreCase(name[name.len - suffix.len ..], suffix)) {
            return name[0 .. name.len - suffix.len];
        }
    }
    return name;
}

/// Case-insensitive alphabetical ordering for picker labels, so "dracula"
/// doesn't sort after "Tokyo Night" just because of its case.
pub fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

fn familyLessThan(_: void, a: FontFamily, b: FontFamily) bool {
    return nameLessThan({}, a.family_name, b.family_name);
}

const FontNameOrder = struct {
    entries: []const fonts.FontEntry,

    fn lessThan(self: FontNameOrder, a: usize, b: usize) bool {
        return nameLessThan({}, self.entries[a].name, self.entries[b].name);
    }
};

fn fontSourceLabel(source: fonts.FontSource) []const u8 {
    return switch (source) {
        .bundled => "bundled",
        .user => "user",
        .extra => "your-dir",
        .system => "system",
    };
}

const FontFamily = struct {
    family_name: []const u8,
    source: fonts.FontSource,
    members: std.ArrayList(usize),
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

    /// Fixed rows reserved by `selectOne` around the scrollable option list:
    /// title, blank, top scroll-indicator, bottom scroll-indicator, blank,
    /// footer.
    const select_one_chrome_rows = 6;

    const ScrollWindow = struct {
        scroll_offset: usize,
        visible_count: usize,
    };

    /// Pure scroll-viewport math for `selectOne`, factored out so it can be
    /// unit tested without a live terminal: keeps `idx` within
    /// `[scroll_offset, scroll_offset + visible_count)`, scrolling by the
    /// minimum amount needed, and clamps to the list's actual bounds.
    fn computeScrollWindow(idx: usize, options_len: usize, available_rows: u16, scroll_offset_in: usize) ScrollWindow {
        const visible_count = @max(available_rows -| select_one_chrome_rows, 1);
        var scroll_offset = scroll_offset_in;
        if (idx < scroll_offset) scroll_offset = idx;
        if (idx >= scroll_offset + visible_count) scroll_offset = idx - visible_count + 1;
        scroll_offset = @min(scroll_offset, options_len -| visible_count);
        return .{ .scroll_offset = scroll_offset, .visible_count = visible_count };
    }

    fn selectOne(self: *Wizard, title: []const u8, options: []const []const u8) !usize {
        return self.selectOneFrom(title, options, 0);
    }

    /// Like `selectOne`, with the cursor starting on `initial_idx`.
    fn selectOneFrom(self: *Wizard, title: []const u8, options: []const []const u8, initial_idx: usize) !usize {
        var idx: usize = @min(initial_idx, options.len -| 1);
        var scroll_offset: usize = 0;
        while (true) {
            const window = computeScrollWindow(idx, options.len, self.vx.window().height, scroll_offset);
            scroll_offset = window.scroll_offset;
            const visible_count = window.visible_count;

            const window_end = @min(scroll_offset + visible_count, options.len);

            var lines = std.ArrayList(Line).empty;
            defer {
                for (lines.items) |line| if (line.owned) self.allocator.free(line.text);
                lines.deinit(self.allocator);
            }

            try lines.append(self.allocator, .{ .text = title, .style = .{ .bold = true } });
            try lines.append(self.allocator, .{ .text = "" });

            if (scroll_offset > 0) {
                try lines.append(self.allocator, .{
                    .text = try std.fmt.allocPrint(self.allocator, "↑ {d} more above", .{scroll_offset}),
                    .style = .{ .dim = true },
                    .owned = true,
                });
            } else {
                try lines.append(self.allocator, .{ .text = "" });
            }

            for (options[scroll_offset..window_end], scroll_offset..) |option, i| {
                const marker = if (i == idx) "> " else "  ";
                const text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ marker, option });
                try lines.append(self.allocator, .{
                    .text = text,
                    .style = if (i == idx) .{ .reverse = true } else .{},
                    .owned = true,
                });
            }

            const remaining_below = options.len - window_end;
            if (remaining_below > 0) {
                try lines.append(self.allocator, .{
                    .text = try std.fmt.allocPrint(self.allocator, "↓ {d} more below", .{remaining_below}),
                    .style = .{ .dim = true },
                    .owned = true,
                });
            } else {
                try lines.append(self.allocator, .{ .text = "" });
            }

            try lines.append(self.allocator, .{ .text = "" });
            try lines.append(self.allocator, .{ .text = "up/down to move, pgup/pgdn to jump, enter to select, ctrl+c to cancel", .style = .{ .dim = true } });

            try self.render(lines.items);

            const key = try self.nextKey();
            if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                idx = if (idx == 0) options.len - 1 else idx - 1;
            } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                idx = if (idx + 1 == options.len) 0 else idx + 1;
            } else if (key.matches(vaxis.Key.page_up, .{})) {
                idx = idx -| visible_count;
            } else if (key.matches(vaxis.Key.page_down, .{})) {
                idx = @min(idx + visible_count, options.len - 1);
            } else if (key.matches(vaxis.Key.enter, .{})) {
                return idx;
            } else if (isCancel(key)) {
                return error.WizardCancelled;
            }
        }
    }

    fn confirm(self: *Wizard, title: []const u8, default_yes: bool) !bool {
        const options = [_][]const u8{ "Yes", "No" };
        // The cursor starts on the default, so just pressing enter takes it.
        const idx = try self.selectOneFrom(title, &options, if (default_yes) 0 else 1);
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

    fn numberInput(self: *Wizard, title: []const u8, default: u32, min: u32, max: u32) !u32 {
        var default_buf: [16]u8 = undefined;
        const default_str = try std.fmt.bufPrint(&default_buf, "{d}", .{default});

        var message_buf: [64]u8 = undefined;
        var err_message: ?[]const u8 = null;
        while (true) {
            const raw = try self.textInput(title, default_str, err_message);
            defer self.allocator.free(raw);

            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return default;

            if (std.fmt.parseInt(u32, trimmed, 10)) |value| {
                if (value >= min and value <= max) return value;
                err_message = std.fmt.bufPrint(&message_buf, "Please enter a number from {d} to {d}.", .{ min, max }) catch "Number out of range.";
            } else |_| {
                err_message = "Please enter a whole number.";
            }
        }
    }

    /// Prompts for a highlight spec like "5,8-10"; blank input means no highlights.
    fn highlightInput(self: *Wizard) !?[]usize {
        var err_message: ?[]const u8 = null;
        while (true) {
            const raw = try self.textInput("Highlight line(s) (optional, e.g. 5,8-10)", null, err_message);
            defer self.allocator.free(raw);

            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return null;

            if (cli.parseHighlightSpec(self.allocator, trimmed)) |lines| {
                return lines;
            } else |_| {
                err_message = "Invalid format. Use e.g. 5,8-10.";
            }
        }
    }
};

/// Opens a standalone terminal session and runs a single `selectOne` picker,
/// returning the chosen index. Mirrors `run()`'s session setup/teardown
/// exactly (same locals, same defer order) rather than factoring it into a
/// shared helper - `vaxis.Tty.init(&tty_buf)` and the later `&tty`/`&vx`
/// references need `tty_buf`/`tty`/`vx` to keep a stable address for the
/// whole session, which a helper returning them by value would break.
pub fn selectFromList(allocator: std.mem.Allocator, title: []const u8, options: []const []const u8) !usize {
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
    return try wiz.selectOne(title, options);
}

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
    std.mem.sort([]const u8, theme_names.items, {}, nameLessThan);

    const theme_idx = try wiz.selectOne("Select a theme", theme_names.items);
    const theme_name = try allocator.dupe(u8, theme_names.items[theme_idx]);
    errdefer allocator.free(theme_name);

    const font_entries = try fonts.listAvailableFonts(allocator);
    defer fonts.freeFontEntries(allocator, font_entries);

    var families = std.ArrayList(FontFamily).empty;
    defer {
        for (families.items) |*fam| fam.members.deinit(allocator);
        families.deinit(allocator);
    }
    for (font_entries, 0..) |entry, i| {
        const family_name = fontFamilyName(entry.name);
        var found = false;
        for (families.items) |*fam| {
            if (std.mem.eql(u8, fam.family_name, family_name)) {
                try fam.members.append(allocator, i);
                found = true;
                break;
            }
        }
        if (!found) {
            var members = std.ArrayList(usize).empty;
            try members.append(allocator, i);
            try families.append(allocator, .{ .family_name = family_name, .source = entry.source, .members = members });
        }
    }

    // Members index into `font_entries`, so sorting families and their styles
    // doesn't invalidate anything.
    std.mem.sort(FontFamily, families.items, {}, familyLessThan);
    for (families.items) |*fam| {
        std.mem.sort(usize, fam.members.items, FontNameOrder{ .entries = font_entries }, FontNameOrder.lessThan);
    }

    var family_labels = std.ArrayList([]const u8).empty;
    defer {
        for (family_labels.items) |label| allocator.free(label);
        family_labels.deinit(allocator);
    }
    for (families.items) |fam| {
        try family_labels.append(allocator, try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ fontSourceLabel(fam.source), fam.family_name }));
    }

    const family_idx = try wiz.selectOne("Select a font", family_labels.items);
    const family = families.items[family_idx];

    const font_name = blk: {
        if (family.members.items.len == 1) {
            break :blk try allocator.dupe(u8, font_entries[family.members.items[0]].name);
        }

        var style_labels = std.ArrayList([]const u8).empty;
        defer {
            for (style_labels.items) |label| allocator.free(label);
            style_labels.deinit(allocator);
        }
        for (family.members.items) |idx| {
            try style_labels.append(allocator, try allocator.dupe(u8, font_entries[idx].name));
        }

        const style_idx = try wiz.selectOne("Select a style", style_labels.items);
        break :blk try allocator.dupe(u8, font_entries[family.members.items[style_idx]].name);
    };
    errdefer allocator.free(font_name);

    const font_size = try wiz.numberInput("Font size (px)", 16, 1, Preset.max_font_size);
    const window_controls = try wiz.confirm("Show window controls?", true);
    const show_file_name = try wiz.confirm("Show file name (when reading from a file)?", true);
    const vertical_padding_px = try wiz.numberInput("Vertical padding (px)", 50, 0, Preset.max_padding_px);
    const horizontal_padding_px = try wiz.numberInput("Horizontal padding (px)", 50, 0, Preset.max_padding_px);
    const include_drop_shadow = try wiz.confirm("Include drop shadow?", true);
    const transparent_background = try wiz.confirm("Transparent background (canvas only, window stays opaque)?", false);

    const raw_output_name = try wiz.textInput("File name (optional, press enter for default)", null, null);
    const output_name: ?[]const u8 = blk: {
        const trimmed = std.mem.trim(u8, raw_output_name, " \t");
        if (trimmed.len == 0) {
            allocator.free(raw_output_name);
            break :blk null;
        }
        if (trimmed.len == raw_output_name.len) break :blk raw_output_name;
        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(raw_output_name);
        break :blk owned;
    };
    errdefer if (output_name) |name| allocator.free(name);

    const highlight_lines = try wiz.highlightInput();
    errdefer if (highlight_lines) |lines| allocator.free(lines);

    const save_options = [_][]const u8{ "Save as a named preset", "Use once for this run" };
    const save_choice = try wiz.selectOne("What would you like to do with this configuration?", &save_options);

    var preset_name: ?[]const u8 = null;
    // Declared before the prompt so an error from anything below (including
    // saving) frees the name too.
    errdefer if (preset_name) |name| allocator.free(name);
    if (save_choice == 0) {
        var name_error: ?[]const u8 = null;
        while (true) {
            const raw = try wiz.textInput("Preset name", null, name_error);
            defer allocator.free(raw);

            // The name becomes a file name under ~/.znip/presets.
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!znip.config.isValidName(trimmed)) {
                name_error = "Please enter a name without slashes (e.g. work).";
                continue;
            }
            preset_name = try allocator.dupe(u8, trimmed);
            break;
        }
    }

    const preset = Preset{
        .name = preset_name,
        .theme = theme_name,
        .font = font_name,
        .font_size = font_size,
        .window_controls = window_controls,
        .show_file_name = show_file_name,
        .vertical_padding_px = vertical_padding_px,
        .horizontal_padding_px = horizontal_padding_px,
        .include_drop_shadow = include_drop_shadow,
        .transparent_background = transparent_background,
    };

    if (preset_name) |name| {
        znip.config.Config.savePreset(allocator, preset) catch |err| {
            output.err("Couldn't save preset '{s}': {s}", .{ name, @errorName(err) });
            return err;
        };
    }

    return Result{ .preset = preset, .saved_as = preset_name, .output_name = output_name, .highlight_lines = highlight_lines };
}

test "computeScrollWindow keeps the whole list visible when it already fits" {
    const window = Wizard.computeScrollWindow(2, 3, 20, 0);
    try std.testing.expectEqual(@as(usize, 0), window.scroll_offset);
    try std.testing.expect(window.visible_count >= 3);
}

test "computeScrollWindow scrolls down by the minimum amount to keep idx visible" {
    // available_rows=10 -> visible_count = 10 - 6 = 4
    const window = Wizard.computeScrollWindow(5, 100, 10, 0);
    try std.testing.expectEqual(@as(usize, 4), window.visible_count);
    try std.testing.expectEqual(@as(usize, 2), window.scroll_offset);
    try std.testing.expect(5 >= window.scroll_offset and 5 < window.scroll_offset + window.visible_count);
}

test "computeScrollWindow scrolls up when idx moves above the current window" {
    const window = Wizard.computeScrollWindow(1, 100, 10, 2);
    try std.testing.expectEqual(@as(usize, 1), window.scroll_offset);
}

test "computeScrollWindow clamps to the last page at the end of the list" {
    // available_rows=10 -> visible_count=4; last valid idx is 99.
    const window = Wizard.computeScrollWindow(99, 100, 10, 50);
    try std.testing.expectEqual(@as(usize, 96), window.scroll_offset);
    try std.testing.expect(99 >= window.scroll_offset and 99 < window.scroll_offset + window.visible_count);
}

test "computeScrollWindow never returns a zero-sized viewport on a tiny terminal" {
    const window = Wizard.computeScrollWindow(0, 100, 3, 0);
    try std.testing.expectEqual(@as(usize, 1), window.visible_count);
}

test "fontFamilyName strips known style suffixes" {
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter-Bold"));
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter-Italic"));
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter-Regular"));
    try std.testing.expectEqualStrings("JetBrainsMono", fontFamilyName("JetBrainsMono-Bold"));
}

test "fontFamilyName strips BoldItalic as a whole, not just Italic" {
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter-BoldItalic"));
}

test "fontFamilyName ignores case in the suffix and keeps the family's case" {
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter-bold"));
    try std.testing.expectEqualStrings("InTeR", fontFamilyName("InTeR-ITALIC"));
}

test "fontFamilyName leaves names without a known suffix alone" {
    try std.testing.expectEqualStrings("Inter", fontFamilyName("Inter"));
    try std.testing.expectEqualStrings("Inter-Light", fontFamilyName("Inter-Light"));
    try std.testing.expectEqualStrings("Bold", fontFamilyName("Bold"));
    try std.testing.expectEqualStrings("", fontFamilyName(""));
}

test "fontFamilyName never reduces a name to nothing" {
    try std.testing.expectEqualStrings("-Bold", fontFamilyName("-Bold"));
    try std.testing.expectEqualStrings("-Italic", fontFamilyName("-Italic"));
}

test "fontFamilyName strips only the last style suffix" {
    try std.testing.expectEqualStrings("Inter-Bold", fontFamilyName("Inter-Bold-Italic"));
}

test "fontSourceLabel names every source" {
    try std.testing.expectEqualStrings("bundled", fontSourceLabel(.bundled));
    try std.testing.expectEqualStrings("user", fontSourceLabel(.user));
    try std.testing.expectEqualStrings("your-dir", fontSourceLabel(.extra));
    try std.testing.expectEqualStrings("system", fontSourceLabel(.system));
}
