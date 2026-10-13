const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");
const theme_cli = @import("core/theme_cli.zig");
const config = znip.config;
const util_files = @import("util/files.zig");
const util_indent = @import("util/indent.zig");
const clipboard = @import("clipboard/clipboard.zig");
const opener = @import("util/opener.zig");
const wizard = @import("interactive/wizard.zig");
const output = znip.output;

pub const std_options: std.Options = .{ .logFn = logFn };

/// Mirrors std.log.defaultLog, minus the "info: "/"error: "/etc. level prefix -
/// output.zig's helpers already carry their own emoji marker.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(format ++ "\n", args) catch return;
}

fn expandTilde(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return znip.config.expandTilde(allocator, path);
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // Every failure path in `run` returns 1 rather than calling
    // std.process.exit, so the defers above/below (and the leak check) still run.
    return run(gpa.allocator()) catch |err| {
        output.err("Unexpected error: {s}", .{@errorName(err)});
        return 1;
    };
}

/// Prints a message for a command-line parse failure; returns the exit code.
fn reportParseError(err: anyerror) u8 {
    switch (err) {
        error.InvalidStartEndLines => output.err("The start line must come before the end line.", .{}),
        error.MultipleCodeSourcesNotSupported => output.err("Please provide only one input source: a file path or --from-clipboard.", .{}),
        error.NoInputProvided => output.err("No input provided. Pass a file path, use --from-clipboard, or pipe code via stdin.", .{}),
        error.InvalidStartLine => output.err("The start line must be 1 or greater.", .{}),
        error.InvalidEndLine => output.err("The end line must be 1 or greater.", .{}),
        error.LineNumberTooLarge => output.err("Line numbers can't exceed {d}.", .{cli.max_line_number}),
        error.InvalidFontSize => output.err("The font size must be between 1 and {d}.", .{cli.max_font_size}),
        error.InvalidHighlightSpec => output.err("Couldn't parse --highlight. Use lines and ranges like 5,8-10.", .{}),
        error.HighlightRangeTooLarge => output.err("--highlight covers too many lines (max {d}).", .{cli.max_highlight_lines}),
        else => output.err("Couldn't parse the command line arguments: {s}", .{@errorName(err)}),
    }
    return 1;
}

/// Creates `~/.znip` and its defaults. Returns an exit code only on failure.
fn setUpConfigDirectories(allocator: std.mem.Allocator) ?u8 {
    znip.createRootConfigDirectories(allocator) catch |err| {
        output.err("Couldn't set up '~/.znip': {s}", .{@errorName(err)});
        return 1;
    };
    return null;
}

fn run(allocator: std.mem.Allocator) !u8 {
    const raw_argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_argv);

    if (raw_argv.len >= 2 and std.mem.eql(u8, raw_argv[1], "theme")) {
        if (setUpConfigDirectories(allocator)) |code| return code;
        return try theme_cli.run(allocator, raw_argv[2..]);
    }

    var cli_config = cli.parse(allocator) catch |err| return reportParseError(err);
    defer cli_config.deinit(allocator);

    // Before any filesystem setup, so --help works even without a usable $HOME.
    if (cli_config.help) {
        try cli.help();
        return 0;
    }

    if (setUpConfigDirectories(allocator)) |code| return code;

    if (cli_config.install_lang) |lang| {
        // installLanguage reports success/failure itself via a spinner, except
        // for WasmSupportNotBuilt, which returns before the spinner ever starts.
        znip.installLanguage(allocator, lang) catch |err| {
            if (err == error.WasmSupportNotBuilt) {
                output.err("This build of znip doesn't support installing languages (built without WASM support).", .{});
            }
            return 1;
        };
        return 0;
    }

    if (cli_config.output_dir) |raw_dir| {
        const expanded = try expandTilde(allocator, raw_dir);
        defer allocator.free(expanded);

        // Stored as an absolute path: a relative one would silently resolve
        // against whatever directory a later run happens to start in.
        const resolved = std.fs.cwd().realpathAlloc(allocator, expanded) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                output.err("'{s}' is not a valid, existing directory.", .{expanded});
                return 1;
            },
            else => {
                output.err("Couldn't open '{s}': {s}", .{ expanded, @errorName(err) });
                return 1;
            },
        };
        defer allocator.free(resolved);

        var dir = std.fs.openDirAbsolute(resolved, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                output.err("'{s}' is not a valid, existing directory.", .{expanded});
                return 1;
            },
            else => {
                output.err("Couldn't open '{s}': {s}", .{ expanded, @errorName(err) });
                return 1;
            },
        };
        dir.close();

        var output_dir_config = config.Config.load(allocator) catch |err| {
            output.err("Couldn't load your configuration: {s}", .{@errorName(err)});
            return 1;
        };
        defer output_dir_config.deinit();

        output_dir_config.value.output_directory = resolved;

        config.Config.save(allocator, output_dir_config.value) catch |err| {
            output.err("Couldn't save your configuration: {s}", .{@errorName(err)});
            return 1;
        };
        output.ok("Default output directory set to '{s}'.", .{resolved});
        return 0;
    }

    var parsed_config = config.Config.load(allocator) catch |err| {
        output.err("Couldn't load your configuration: {s}", .{@errorName(err)});
        return 1;
    };
    defer parsed_config.deinit();

    // A hand-edited "~/Pictures" is as valid here as on the command line.
    const configured_output_dir: ?[]const u8 = if (parsed_config.value.output_directory) |dir|
        try expandTilde(allocator, dir)
    else
        null;
    defer if (configured_output_dir) |dir| allocator.free(dir);

    var wizard_result: ?wizard.Result = null;
    defer if (wizard_result) |*r| r.deinit(allocator);

    var parsed_preset: ?std.json.Parsed(config.Preset) = null;
    defer if (parsed_preset) |*p| p.deinit();

    var active_preset: config.Preset = blk: {
        if (cli_config.interactive) {
            wizard_result = wizard.run(allocator) catch |err| switch (err) {
                error.WizardCancelled => {
                    output.ok("Cancelled.", .{});
                    return 0;
                },
                else => {
                    output.err("The interactive wizard failed: {s}", .{@errorName(err)});
                    return 1;
                },
            };
            break :blk wizard_result.?.preset;
        }

        const preset_name = cli_config.preset orelse parsed_config.value.active_preset;
        parsed_preset = config.Config.loadPreset(allocator, preset_name) catch |err| switch (err) {
            error.InvalidPresetName => {
                output.err("'{s}' isn't a valid preset name.", .{preset_name});
                return 1;
            },
            else => {
                output.err("Couldn't load preset '{s}': {s}", .{ preset_name, @errorName(err) });
                return 1;
            },
        };
        // A missing preset quietly falls back to the default one; say so, so a
        // typo in --preset doesn't go unnoticed.
        if (!std.mem.eql(u8, preset_name, "default") and !config.Config.presetFileExists(allocator, preset_name)) {
            output.warn("Preset '{s}' doesn't exist; using the default preset.", .{preset_name});
        }
        break :blk parsed_preset.?.value;
    };

    // Run-scoped overrides: unlike --preset (which selects a saved,
    // persisted preset), these only apply to this invocation.
    if (cli_config.font) |font| active_preset.font = font;
    if (cli_config.font_size) |font_size| active_preset.font_size = font_size;
    if (cli_config.transparent) active_preset.transparent_background = true;

    active_preset.validate() catch |err| switch (err) {
        error.InvalidFontSize => {
            output.err("The font size must be between 1 and {d} (got {d}).", .{ config.Preset.max_font_size, active_preset.font_size });
            return 1;
        },
        else => {
            output.err("Padding can't exceed {d}px (got {d}px vertical, {d}px horizontal).", .{ config.Preset.max_padding_px, active_preset.vertical_padding_px, active_preset.horizontal_padding_px });
            return 1;
        },
    };

    var theme_handle = config.resolveTheme(allocator, active_preset.theme) catch |err| switch (err) {
        error.ThemeNotFound => {
            output.err("Theme '{s}' not found.", .{active_preset.theme});
            return 1;
        },
        else => {
            output.err("Couldn't load theme '{s}': {s}", .{ active_preset.theme, @errorName(err) });
            return 1;
        },
    };
    defer theme_handle.deinit();
    const active_theme = theme_handle.value();

    var code: ?[:0]u8 = null;
    var line_offset: u32 = 1;

    if (cli_config.file_path) |file_path| {
        line_offset = std.math.cast(u32, cli_config.starting_line orelse 1) orelse {
            output.err("Line numbers can't exceed {d}.", .{cli.max_line_number});
            return 1;
        };
        code = util_files.getLinesInRange(allocator, file_path, cli_config.starting_line, cli_config.ending_line) catch |err| switch (err) {
            error.FileNotFound => {
                output.err("'{s}' doesn't exist.", .{file_path});
                return 1;
            },
            error.BinaryFileNotSupported => {
                output.err("'{s}' looks like a binary file, which isn't supported.", .{file_path});
                return 1;
            },
            error.EmptyFileNotSupported => {
                output.err("'{s}' is empty, so there's nothing to render.", .{file_path});
                return 1;
            },
            error.InvalidRange => {
                output.err("The requested line range isn't valid for '{s}'.", .{file_path});
                return 1;
            },
            error.FileTooLarge => {
                output.err("'{s}' is too large (max 10MB).", .{file_path});
                return 1;
            },
            else => {
                output.err("Couldn't read '{s}': {s}", .{ file_path, @errorName(err) });
                return 1;
            },
        };
    } else if (cli_config.starting_line != null or cli_config.ending_line != null) {
        output.warn("-s/--start and -e/--end only apply to files; ignoring them.", .{});
    }

    if (cli_config.from_clipboard) {
        code = clipboard.read(allocator) catch |err| {
            if (std.mem.eql(u8, @errorName(err), "ClipboardCmdNotFound")) {
                output.err("No clipboard tool found. Install xclip, xsel, or wl-clipboard.", .{});
            } else if (err == error.ClipboardEmpty) {
                output.err("The clipboard doesn't contain any text.", .{});
            } else {
                output.err("Couldn't read from the clipboard: {s}", .{@errorName(err)});
            }
            return 1;
        };
    }

    if (cli_config.from_stdin) {
        code = util_files.readStdin(allocator) catch |err| switch (err) {
            error.BinaryFileNotSupported => {
                output.err("Piped input looks like binary data, which isn't supported.", .{});
                return 1;
            },
            error.EmptyFileNotSupported => {
                output.err("No input received on stdin.", .{});
                return 1;
            },
            error.FileTooBig => {
                output.err("Piped input is too large (max 10MB).", .{});
                return 1;
            },
            else => {
                output.err("Couldn't read from stdin: {s}", .{@errorName(err)});
                return 1;
            },
        };
    }

    // Line endings, tabs, BOM and invalid UTF-8 are sorted out once, here, so
    // indent trimming, measuring and drawing all see the same text.
    if (code) |c| {
        const normalized = try util_files.normalizeSource(allocator, c);
        allocator.free(c);
        code = normalized;
    }

    if (code) |c| {
        const trimmed = try util_indent.trimCommonIndent(allocator, c);
        allocator.free(c);
        code = trimmed;
    }

    defer if (code) |c| allocator.free(c);

    if (code == null) {
        output.err("No code provided. Pass a file path, use --from-clipboard, or pipe code via stdin.", .{});
        return 1;
    }

    // Values the wizard left blank fall back to what was given on the
    // command line, rather than discarding it.
    const highlight_lines: ?[]const usize = (if (wizard_result) |r| r.highlight_lines else null) orelse cli_config.highlight_lines;

    if (highlight_lines) |lines| {
        const total_lines: u64 = std.mem.count(u8, code.?, "\n") + 1;
        const max_line: u64 = @as(u64, line_offset) + total_lines - 1;
        for (lines) |line| {
            if (line < line_offset or line > max_line) {
                output.err("Highlight line {d} is outside the rendered range ({d}-{d}).", .{ line, line_offset, max_line });
                return 1;
            }
        }
    }

    const base_name = (if (wizard_result) |r| r.output_name else null) orelse cli_config.output_name;

    const file_name = if (base_name) |name|
        try util_files.ensurePngExtension(allocator, name)
    else
        try std.fmt.allocPrint(allocator, "znip_output_{d}.png", .{std.time.timestamp()});
    defer allocator.free(file_name);

    const candidate_path = if (configured_output_dir) |dir|
        try std.fs.path.join(allocator, &[_][]const u8{ dir, file_name })
    else
        try allocator.dupe(u8, file_name);
    defer allocator.free(candidate_path);

    const output_path = try util_files.uniqueOutputPath(allocator, candidate_path);
    defer allocator.free(output_path);

    // `--name shots/a.png` should work even if `shots` doesn't exist yet.
    if (std.fs.path.dirname(output_path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| {
            output.err("Couldn't create '{s}': {s}", .{ parent, @errorName(err) });
            return 1;
        };
    }

    if (code) |c| {
        znip.renderImage(c, output_path, cli_config.file_path, active_preset, active_theme, cli_config.lang, cli_config.yes, line_offset, highlight_lines orelse &[_]usize{}) catch |err| switch (err) {
            error.LanguageNotAvailable => {
                output.err("Language '{s}' isn't available (not built in, not cached, and not found in the grammar manifest).", .{cli_config.lang orelse "?"});
                return 1;
            },
            error.ImageTooLarge => {
                output.err("The image would be too large (Blend2D allows at most 65535px per side). Try fewer lines (-s/-e), a smaller --font-size, or less padding.", .{});
                return 1;
            },
            else => {
                output.err("Couldn't render the image: {s}", .{@errorName(err)});
                return 1;
            },
        };
        output.ok("Saved to '{s}'.", .{output_path});
    }

    if (cli_config.to_clipboard) {
        output.step("Copying to clipboard...", .{});
        clipboard.write_image(allocator, output_path) catch |err| {
            output.err("Couldn't copy the image to the clipboard: {s}", .{@errorName(err)});
            return 1;
        };
        output.ok("Copied to clipboard.", .{});
    }

    if (cli_config.open) {
        opener.open(allocator, output_path) catch |err| {
            // The image itself was saved, so this isn't a failed run.
            output.warn("Couldn't open '{s}': {s}", .{ output_path, @errorName(err) });
        };
    }

    return 0;
}

test {
    // Zig only discovers `test` blocks in files that actually get analyzed;
    // merely `@import`ing a file (as above) isn't enough - see root.zig's
    // identical use of refAllDecls for tree_sitter/grammar_cache. This is the
    // exe-side counterpart, for wizard.zig's tests, which would otherwise
    // never run.
    std.testing.refAllDecls(wizard);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(theme_cli);
    std.testing.refAllDecls(util_files);
    std.testing.refAllDecls(util_indent);
}

test "expandTilde expands a bare tilde to the home directory" {
    const allocator = std.testing.allocator;
    znip.config.home_dir_override = "/home/u";
    defer znip.config.home_dir_override = null;

    const result = try expandTilde(allocator, "~");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/u", result);
}

test "expandTilde expands a leading ~/ and keeps the rest of the path" {
    const allocator = std.testing.allocator;
    znip.config.home_dir_override = "/home/u";
    defer znip.config.home_dir_override = null;

    const result = try expandTilde(allocator, "~/images/out");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/u/images/out", result);
}

test "expandTilde leaves every other path untouched" {
    const allocator = std.testing.allocator;
    znip.config.home_dir_override = "/home/u";
    defer znip.config.home_dir_override = null;

    const paths = [_][]const u8{ "/abs/path", "relative/dir", "./here", "", "~user/x", "a/~/b", "dir~", "~~" };
    for (paths) |path| {
        const result = try expandTilde(allocator, path);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(path, result);
    }
}

test "expandTilde with a trailing slash resolves to the home directory" {
    const allocator = std.testing.allocator;
    znip.config.home_dir_override = "/home/u";
    defer znip.config.home_dir_override = null;

    const result = try expandTilde(allocator, "~/");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/u", result);
}

