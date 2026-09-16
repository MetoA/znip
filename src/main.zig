const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");
const config = znip.config;
const theme = znip.theme_module;
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
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        if (std.mem.eql(u8, path, "~")) return try allocator.dupe(u8, home);
        return try std.fs.path.join(allocator, &[_][]const u8{ home, path[2..] });
    }
    return try allocator.dupe(u8, path);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    znip.createRootConfigDirectories(allocator) catch |err| {
        output.err("Couldn't set up '~/.znip': {s}", .{@errorName(err)});
        return;
    };

    var cli_config = cli.parse(allocator) catch |err| switch (err) {
        error.InvalidStartEndLines => {
            output.err("The start line must come before the end line.", .{});
            return;
        },
        error.MultipleCodeSourcesNotSupported => {
            output.err("Please provide only one input source: a file path, --from-clipboard, or piped stdin.", .{});
            return;
        },
        error.NoInputProvided => {
            output.err("No input provided. Pass a file path, use --from-clipboard, or pipe code via stdin.", .{});
            return;
        },
        error.InvalidStartLine => {
            output.err("The start line must be 1 or greater.", .{});
            return;
        },
        error.InvalidEndLine => {
            output.err("The end line must be 1 or greater.", .{});
            return;
        },
        else => {
            output.err("Couldn't parse the command line arguments: {s}", .{@errorName(err)});
            return;
        },
    };
    defer cli_config.deinit(allocator);

    if (cli_config.help) {
        try cli.help();
        return;
    }

    if (cli_config.install_lang) |lang| {
        // installLanguage reports success/failure itself via a spinner, except
        // for WasmSupportNotBuilt, which returns before the spinner ever starts.
        znip.installLanguage(allocator, lang) catch |err| {
            if (err == error.WasmSupportNotBuilt) {
                output.err("This build of znip doesn't support installing languages (built without WASM support).", .{});
            }
            return;
        };
        return;
    }

    if (cli_config.output_dir) |raw_dir| {
        const expanded = try expandTilde(allocator, raw_dir);
        defer allocator.free(expanded);

        var dir = std.fs.cwd().openDir(expanded, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                output.err("'{s}' is not a valid, existing directory.", .{expanded});
                return;
            },
            else => {
                output.err("Couldn't open '{s}': {s}", .{ expanded, @errorName(err) });
                return;
            },
        };
        dir.close();

        var output_dir_config = config.Config.load(allocator) catch |err| {
            output.err("Couldn't load your configuration: {s}", .{@errorName(err)});
            return;
        };
        defer output_dir_config.deinit();

        output_dir_config.value.output_directory = expanded;

        config.Config.save(allocator, output_dir_config.value) catch |err| {
            output.err("Couldn't save your configuration: {s}", .{@errorName(err)});
            return;
        };
        output.ok("Default output directory set to '{s}'.", .{expanded});
        return;
    }

    var parsed_config = config.Config.load(allocator) catch |err| {
        output.err("Couldn't load your configuration: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_config.deinit();

    var wizard_result: ?wizard.Result = null;
    defer if (wizard_result) |*r| r.deinit(allocator);

    var parsed_preset: ?std.json.Parsed(config.Preset) = null;
    defer if (parsed_preset) |*p| p.deinit();

    var active_preset: config.Preset = blk: {
        if (cli_config.interactive) {
            wizard_result = wizard.run(allocator) catch |err| switch (err) {
                error.WizardCancelled => {
                    output.ok("Cancelled.", .{});
                    return;
                },
                else => {
                    output.err("The interactive wizard failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            break :blk wizard_result.?.preset;
        }

        const preset_name = cli_config.preset orelse parsed_config.value.active_preset;
        parsed_preset = config.Config.loadPreset(allocator, preset_name) catch |err| {
            output.err("Couldn't load preset '{s}': {s}", .{ preset_name, @errorName(err) });
            return;
        };
        break :blk parsed_preset.?.value;
    };

    // Run-scoped overrides: unlike --preset (which selects a saved,
    // persisted preset), these only apply to this invocation.
    if (cli_config.font) |font| active_preset.font = font;
    if (cli_config.font_size) |font_size| active_preset.font_size = font_size;
    if (cli_config.transparent) active_preset.transparent_background = true;

    const active_theme = theme.getThemeByName(active_preset.theme);

    var code: ?[:0]u8 = null;
    var line_offset: u32 = 1;

    if (cli_config.file_path) |file_path| {
        line_offset = @intCast(cli_config.starting_line orelse 1);
        code = util_files.getLinesInRange(allocator, file_path, cli_config.starting_line, cli_config.ending_line) catch |err| switch (err) {
            error.FileNotFound => {
                output.err("'{s}' doesn't exist.", .{file_path});
                return;
            },
            error.BinaryFileNotSupported => {
                output.err("'{s}' looks like a binary file, which isn't supported.", .{file_path});
                return;
            },
            error.EmptyFileNotSupported => {
                output.err("'{s}' is empty, so there's nothing to render.", .{file_path});
                return;
            },
            error.InvalidRange => {
                output.err("The requested line range isn't valid for '{s}'.", .{file_path});
                return;
            },
            error.FileTooLarge => {
                output.err("'{s}' is too large (max 10MB).", .{file_path});
                return;
            },
            else => {
                output.err("Couldn't read '{s}': {s}", .{ file_path, @errorName(err) });
                return;
            },
        };
    }

    if (cli_config.from_clipboard) {
        code = clipboard.read(allocator) catch |err| {
            if (std.mem.eql(u8, @errorName(err), "ClipboardCmdNotFound")) {
                output.err("No clipboard tool found. Install xclip, xsel, or wl-copy.", .{});
            } else {
                output.err("Couldn't read from the clipboard: {s}", .{@errorName(err)});
            }
            return;
        };
    }

    if (cli_config.from_stdin) {
        code = util_files.readStdin(allocator) catch |err| switch (err) {
            error.BinaryFileNotSupported => {
                output.err("Piped input looks like binary data, which isn't supported.", .{});
                return;
            },
            error.EmptyFileNotSupported => {
                output.err("No input received on stdin.", .{});
                return;
            },
            error.FileTooBig => {
                output.err("Piped input is too large (max 10MB).", .{});
                return;
            },
            else => {
                output.err("Couldn't read from stdin: {s}", .{@errorName(err)});
                return;
            },
        };
    }

    if (code) |c| {
        const trimmed = try util_indent.trimCommonIndent(allocator, c);
        allocator.free(c);
        code = trimmed;
    }

    defer if (code) |c| allocator.free(c);

    if (code == null) {
        output.err("No code provided. Pass a file path, use --from-clipboard, or pipe code via stdin.", .{});
        return;
    }

    const highlight_lines: ?[]const usize = if (wizard_result) |r| r.highlight_lines else cli_config.highlight_lines;

    if (highlight_lines) |lines| {
        const total_lines: u32 = @intCast(std.mem.count(u8, code.?, "\n") + 1);
        const max_line = line_offset + total_lines - 1;
        for (lines) |line| {
            if (line < line_offset or line > max_line) {
                output.err("Highlight line {d} is outside the rendered range ({d}-{d}).", .{ line, line_offset, max_line });
                return;
            }
        }
    }

    const base_name = if (wizard_result) |r| r.output_name else cli_config.output_name;

    const file_name = if (base_name) |name|
        try util_files.ensurePngExtension(allocator, name)
    else
        try std.fmt.allocPrint(allocator, "znip_output_{d}.png", .{ std.time.timestamp() });
    defer allocator.free(file_name);

    const candidate_path = if (parsed_config.value.output_directory) |dir|
        try std.fs.path.join(allocator, &[_][]const u8{ dir, file_name })
    else
        try allocator.dupe(u8, file_name);
    defer allocator.free(candidate_path);

    const output_path = try util_files.uniqueOutputPath(allocator, candidate_path);
    defer allocator.free(output_path);

    if (code) |c| {
        znip.renderImage(c, output_path, cli_config.file_path, active_preset, active_theme, cli_config.lang, cli_config.yes, line_offset, highlight_lines orelse &[_]usize{}) catch |err| switch (err) {
            error.LanguageNotAvailable => {
                output.err("Language '{s}' isn't available (not built in, not cached, and not found in the grammar manifest).", .{cli_config.lang.?});
                return;
            },
            else => {
                output.err("Couldn't render the image: {s}", .{@errorName(err)});
                return;
            },
        };
        output.ok("Saved to '{s}'.", .{output_path});
    }

    if (cli_config.to_clipboard) {
        const content = util_files.readFile(allocator, output_path) catch |err| {
            output.err("Couldn't read the generated image back for the clipboard: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(content);
        output.step("Copying to clipboard...", .{});
        clipboard.write_image(content) catch |err| {
            output.err("Couldn't copy the image to the clipboard: {s}", .{@errorName(err)});
            return;
        };
        output.ok("Copied to clipboard.", .{});
    }

    if (cli_config.open) {
        opener.open(allocator, output_path) catch |err| {
            output.err("Couldn't open '{s}': {s}", .{ output_path, @errorName(err) });
        };
    }
}

test {
    // Zig only discovers `test` blocks in files that actually get analyzed;
    // merely `@import`ing a file (as above) isn't enough - see root.zig's
    // identical use of refAllDecls for tree_sitter/grammar_cache. This is the
    // exe-side counterpart, for wizard.zig's tests, which would otherwise
    // never run.
    std.testing.refAllDecls(wizard);
}
