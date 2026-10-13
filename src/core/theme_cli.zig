const std = @import("std");
const znip = @import("znip");
const config = znip.config;
const theme = znip.theme_module;
const output = znip.output;
const wizard = @import("../interactive/wizard.zig");

const usage =
    \\Usage: znip theme <command> [args]
    \\
    \\Commands:
    \\  list                          List available themes
    \\  show <name>                   Show a theme's colors
    \\  use <name>                    Set the active preset's theme
    \\  create <name> [--from <name>] [--force]
    \\                                Scaffold a new theme file for editing
    \\
;

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const verb = args[0];
    if (std.mem.eql(u8, verb, "list")) {
        try runList(allocator);
    } else if (std.mem.eql(u8, verb, "show")) {
        try runShow(allocator, args[1..]);
    } else if (std.mem.eql(u8, verb, "use")) {
        try runUse(allocator, args[1..]);
    } else if (std.mem.eql(u8, verb, "create")) {
        try runCreate(allocator, args[1..]);
    } else if (std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        output.err("Unknown 'theme' command '{s}'.", .{verb});
        std.debug.print("{s}", .{usage});
    }
}

fn activeThemeName(allocator: std.mem.Allocator) !?[]const u8 {
    var cfg = config.Config.load(allocator) catch return null;
    defer cfg.deinit();

    var preset = config.Config.loadPreset(allocator, cfg.value.active_preset) catch return null;
    defer preset.deinit();

    return try allocator.dupe(u8, preset.value.theme);
}

const ThemeEntry = struct {
    name: []const u8,
    source: enum { user, builtin },
};

/// Merged, shadow-aware theme list: every user theme first, then every
/// builtin not shadowed by a same-named user theme. Caller frees with
/// `freeThemeEntries`.
fn collectThemeEntries(allocator: std.mem.Allocator) ![]ThemeEntry {
    var entries = std.ArrayList(ThemeEntry).empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    const user_names = try config.listUserThemeNames(allocator);
    defer allocator.free(user_names);

    for (user_names) |name| {
        try entries.append(allocator, .{ .name = name, .source = .user });
    }

    for (theme.builtin_themes) |t| {
        var shadowed = false;
        for (user_names) |name| {
            if (std.mem.eql(u8, name, t.name)) {
                shadowed = true;
                break;
            }
        }
        if (shadowed) continue;

        try entries.append(allocator, .{ .name = try allocator.dupe(u8, t.name), .source = .builtin });
    }

    return entries.toOwnedSlice(allocator);
}

fn freeThemeEntries(allocator: std.mem.Allocator, entries: []const ThemeEntry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

fn sourceLabel(source: anytype) []const u8 {
    return switch (source) {
        .user => "user",
        .builtin => "builtin",
    };
}

/// Opens the interactive up/down picker over every available theme, or
/// prints a message and returns null if the user cancels (ctrl+c/esc) or an
/// error already got reported. Returned name is allocator-owned.
fn pickThemeName(allocator: std.mem.Allocator, title: []const u8) !?[]const u8 {
    const active_name = activeThemeName(allocator) catch null;
    defer if (active_name) |n| allocator.free(n);

    const entries = collectThemeEntries(allocator) catch |err| {
        output.err("Couldn't list themes: {s}", .{@errorName(err)});
        return null;
    };
    defer freeThemeEntries(allocator, entries);

    if (entries.len == 0) {
        output.err("No themes available.", .{});
        return null;
    }

    var labels = std.ArrayList([]const u8).empty;
    defer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
    }
    for (entries) |e| {
        const active_suffix: []const u8 = if (active_name != null and std.mem.eql(u8, active_name.?, e.name)) " (active)" else "";
        try labels.append(allocator, try std.fmt.allocPrint(allocator, "[{s}] {s}{s}", .{ sourceLabel(e.source), e.name, active_suffix }));
    }

    const idx = wizard.selectFromList(allocator, title, labels.items) catch |err| switch (err) {
        error.WizardCancelled => {
            output.ok("Cancelled.", .{});
            return null;
        },
        else => {
            output.err("The interactive picker failed: {s}", .{@errorName(err)});
            return null;
        },
    };

    return try allocator.dupe(u8, entries[idx].name);
}

fn runList(allocator: std.mem.Allocator) !void {
    const active_name = activeThemeName(allocator) catch null;
    defer if (active_name) |n| allocator.free(n);

    const entries = collectThemeEntries(allocator) catch |err| {
        output.err("Couldn't list themes: {s}", .{@errorName(err)});
        return;
    };
    defer freeThemeEntries(allocator, entries);

    const stdout = std.fs.File.stdout();
    for (entries) |e| {
        const active_suffix: []const u8 = if (active_name != null and std.mem.eql(u8, active_name.?, e.name)) " (active)" else "";
        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "[{s}] {s}{s}\n", .{ sourceLabel(e.source), e.name, active_suffix });
        try stdout.writeAll(line);
    }
}

fn resolveOrReport(allocator: std.mem.Allocator, name: []const u8) !?theme.ThemeHandle {
    return config.resolveTheme(allocator, name) catch |err| switch (err) {
        error.ThemeNotFound => {
            output.err("Theme '{s}' not found.", .{name});
            return null;
        },
        else => {
            output.err("Couldn't load theme '{s}': {s}", .{ name, @errorName(err) });
            return null;
        },
    };
}

fn stdoutIsTty() bool {
    return std.fs.File.stdout().isTty();
}

fn printColorField(stdout: std.fs.File, name: []const u8, argb: u32, swatches: bool) !void {
    const r: u8 = @truncate((argb >> 16) & 0xFF);
    const g: u8 = @truncate((argb >> 8) & 0xFF);
    const b: u8 = @truncate(argb & 0xFF);

    var hex_buf: [10]u8 = undefined;
    const hex = theme.colorToHex(&hex_buf, argb);

    var buf: [256]u8 = undefined;
    const line = if (swatches)
        try std.fmt.bufPrint(&buf, "  \x1b[48;2;{d};{d};{d}m  \x1b[0m {s}  {s}\n", .{ r, g, b, hex, name })
    else
        try std.fmt.bufPrint(&buf, "  {s}  {s}\n", .{ hex, name });
    try stdout.writeAll(line);
}

fn runShow(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var owned_name: ?[]const u8 = null;
    defer if (owned_name) |n| allocator.free(n);

    const name: []const u8 = if (args.len > 0) args[0] else blk: {
        if (!std.fs.File.stdin().isTty()) {
            output.err("Usage: znip theme show <name>", .{});
            return;
        }
        owned_name = (try pickThemeName(allocator, "Select a theme to show")) orelse return;
        break :blk owned_name.?;
    };

    var handle = (try resolveOrReport(allocator, name)) orelse return;
    defer handle.deinit();

    const stdout = std.fs.File.stdout();
    const swatches = stdoutIsTty();
    const t = handle.value();

    var name_buf: [512]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&name_buf, "name: {s}\n", .{t.name}));

    switch (handle) {
        .static => try stdout.writeAll("source: builtin\n"),
        .owned => {
            const path = config.userThemePath(allocator, name) catch null;
            defer if (path) |p| allocator.free(p);
            if (path) |p| {
                var buf: [1024]u8 = undefined;
                try stdout.writeAll(try std.fmt.bufPrint(&buf, "source: user ({s})\n", .{p}));
            } else {
                try stdout.writeAll("source: user\n");
            }
        },
    }

    try stdout.writeAll("ui:\n");
    inline for (std.meta.fields(@TypeOf(t.ui))) |field| {
        const value = @field(t.ui, field.name);
        switch (@typeInfo(field.type)) {
            .optional => if (value) |v| try printColorField(stdout, field.name, v, swatches),
            else => try printColorField(stdout, field.name, value, swatches),
        }
    }

    try stdout.writeAll("syntax:\n");
    inline for (std.meta.fields(@TypeOf(t.syntax))) |field| {
        const value = @field(t.syntax, field.name);
        switch (@typeInfo(field.type)) {
            .optional => if (value) |v| try printColorField(stdout, field.name, v, swatches),
            else => try printColorField(stdout, field.name, value, swatches),
        }
    }
}

fn runUse(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var owned_name: ?[]const u8 = null;
    defer if (owned_name) |n| allocator.free(n);

    const name: []const u8 = if (args.len > 0) args[0] else blk: {
        if (!std.fs.File.stdin().isTty()) {
            output.err("Usage: znip theme use <name>", .{});
            return;
        }
        owned_name = (try pickThemeName(allocator, "Select a theme to use")) orelse return;
        break :blk owned_name.?;
    };

    var handle = (try resolveOrReport(allocator, name)) orelse return;
    handle.deinit();

    var cfg = config.Config.load(allocator) catch |err| {
        output.err("Couldn't load your configuration: {s}", .{@errorName(err)});
        return;
    };
    defer cfg.deinit();

    var preset = config.Config.loadPreset(allocator, cfg.value.active_preset) catch |err| {
        output.err("Couldn't load preset '{s}': {s}", .{ cfg.value.active_preset, @errorName(err) });
        return;
    };
    defer preset.deinit();

    preset.value.theme = name;

    config.Config.savePreset(allocator, preset.value) catch |err| {
        output.err("Couldn't save preset '{s}': {s}", .{ preset.value.name orelse "?", @errorName(err) });
        return;
    };

    output.ok("'{s}' now uses the '{s}' theme.", .{ preset.value.name orelse "?", name });
}

fn runCreate(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len == 0) {
        output.err("Usage: znip theme create <name> [--from <name>] [--force]", .{});
        return;
    }
    const name = args[0];

    var from_name: []const u8 = "One Darker";
    var force = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i >= args.len) {
                output.err("--from requires a theme name.", .{});
                return;
            }
            from_name = args[i];
        } else {
            output.err("Unknown option '{s}'.", .{arg});
            return;
        }
    }

    var handle = (try resolveOrReport(allocator, from_name)) orelse return;
    defer handle.deinit();

    var seeded = handle.value();
    seeded.name = name;

    const path = config.saveUserTheme(allocator, name, seeded, force) catch |err| switch (err) {
        error.ThemeAlreadyExists => {
            output.err("Theme '{s}' already exists. Use --force to overwrite.", .{name});
            return;
        },
        else => {
            output.err("Couldn't create theme '{s}': {s}", .{ name, @errorName(err) });
            return;
        },
    };
    defer allocator.free(path);

    output.ok("Created theme '{s}' at '{s}'.", .{ name, path });
}

/// Points `$HOME` at a fresh temporary directory with the standard `~/.znip` tree.
const TmpHome = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(allocator: std.mem.Allocator) !TmpHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        config.home_dir_override = path;
        errdefer config.home_dir_override = null;
        try config.createRootConfigDirectories(allocator);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TmpHome, allocator: std.mem.Allocator) void {
        config.home_dir_override = null;
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn countSource(entries: []const ThemeEntry, name: []const u8, source: @TypeOf(@as(ThemeEntry, undefined).source)) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.source == source and std.mem.eql(u8, e.name, name)) n += 1;
    }
    return n;
}

test "sourceLabel names each source" {
    const entry_user = ThemeEntry{ .name = "x", .source = .user };
    const entry_builtin = ThemeEntry{ .name = "x", .source = .builtin };
    try std.testing.expectEqualStrings("user", sourceLabel(entry_user.source));
    try std.testing.expectEqualStrings("builtin", sourceLabel(entry_builtin.source));
}

test "collectThemeEntries lists every builtin when there are no user themes" {
    const allocator = std.testing.allocator;
    var home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const entries = try collectThemeEntries(allocator);
    defer freeThemeEntries(allocator, entries);

    try std.testing.expectEqual(theme.builtin_themes.len, entries.len);
    for (theme.builtin_themes, entries) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        try std.testing.expect(got.source == .builtin);
    }
}

test "collectThemeEntries puts user themes ahead of builtins" {
    const allocator = std.testing.allocator;
    var home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const saved = try config.saveUserTheme(allocator, "Mine", theme.OneDarker, false);
    allocator.free(saved);

    const entries = try collectThemeEntries(allocator);
    defer freeThemeEntries(allocator, entries);

    try std.testing.expectEqual(theme.builtin_themes.len + 1, entries.len);
    try std.testing.expectEqualStrings("Mine", entries[0].name);
    try std.testing.expect(entries[0].source == .user);
    for (entries[1..]) |e| try std.testing.expect(e.source == .builtin);
}

test "collectThemeEntries hides a builtin shadowed by a same-named user theme" {
    const allocator = std.testing.allocator;
    var home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const saved = try config.saveUserTheme(allocator, "One Darker", theme.OneDarker, false);
    allocator.free(saved);

    const entries = try collectThemeEntries(allocator);
    defer freeThemeEntries(allocator, entries);

    try std.testing.expectEqual(theme.builtin_themes.len, entries.len);
    try std.testing.expectEqual(@as(usize, 1), countSource(entries, "One Darker", .user));
    try std.testing.expectEqual(@as(usize, 0), countSource(entries, "One Darker", .builtin));
    // The other builtins are untouched.
    try std.testing.expectEqual(@as(usize, 1), countSource(entries, "Paper White", .builtin));
}

test "activeThemeName follows the active preset" {
    const allocator = std.testing.allocator;
    var home = try TmpHome.init(allocator);
    defer home.deinit(allocator);

    const initial = (try activeThemeName(allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("One Darker", initial);

    try config.Config.savePreset(allocator, .{
        .name = "default",
        .theme = "Paper White",
        .font = "F",
        .font_size = 10,
        .window_controls = true,
        .vertical_padding_px = 1,
        .horizontal_padding_px = 1,
        .include_drop_shadow = true,
    });
    const updated = (try activeThemeName(allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("Paper White", updated);
}
