const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");
const config = znip.config;
const theme = znip.theme_module;
const util_files = @import("util/files.zig");
const util_indent = @import("util/indent.zig");
const clipboard = @import("clipboard/clipboard.zig");
const wizard = @import("interactive/wizard.zig");

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
    
    try znip.createRootConfigDirectories(allocator);

    var cli_config = cli.parse(allocator) catch |err| switch (err) {
        error.InvalidStartEndLines => {
            std.log.err("Invalid Start and end lines", .{});
            return;
        },
        error.MultipleCodeSourcesNotSupported => {
            std.log.err("Multiple code sources not supported", .{});
            return;
        },
        else => {
            std.log.err("Error {}", .{err});
            return;
        },
    };
    defer cli_config.deinit(allocator);

    if (cli_config.help) {
        try cli.help();
        return;
    }

    if (cli_config.install_lang) |lang| {
        znip.installLanguage(allocator, lang) catch |err| switch (err) {
            error.LanguageNotInManifest => {
                std.log.err("Language '{s}' was not found in the grammar manifest", .{lang});
                return;
            },
            else => {
                std.log.err("Failed to install language '{s}': {s}", .{ lang, @errorName(err) });
                return;
            },
        };
        std.log.info("Language '{s}' installed", .{lang});
        return;
    }

    if (cli_config.output_dir) |raw_dir| {
        const expanded = try expandTilde(allocator, raw_dir);
        defer allocator.free(expanded);

        var dir = std.fs.cwd().openDir(expanded, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                std.log.err("'{s}' is not a valid, existing directory", .{expanded});
                return;
            },
            else => return err,
        };
        dir.close();

        var output_dir_config = try config.Config.load(allocator);
        defer output_dir_config.deinit();

        output_dir_config.value.output_directory = expanded;

        try config.Config.save(allocator, output_dir_config.value);
        std.log.info("Default output directory set to '{s}'", .{expanded});
        return;
    }

    var parsed_config = try config.Config.load(allocator);
    defer parsed_config.deinit();

    var wizard_result: ?wizard.Result = null;
    defer if (wizard_result) |*r| r.deinit(allocator);

    var parsed_preset: ?std.json.Parsed(config.Preset) = null;
    defer if (parsed_preset) |*p| p.deinit();

    const active_preset: config.Preset = blk: {
        if (cli_config.interactive) {
            wizard_result = try wizard.run(allocator);
            break :blk wizard_result.?.preset;
        }

        const preset_name = cli_config.preset orelse parsed_config.value.active_preset;
        parsed_preset = try config.Config.loadPreset(allocator, preset_name);
        break :blk parsed_preset.?.value;
    };

    const active_theme = theme.getThemeByName(active_preset.theme);

    var code: ?[:0]u8 = null;

    if (cli_config.file_path) |file_path| {
        code = util_files.getLinesInRange(allocator, file_path, cli_config.starting_line, cli_config.ending_line) catch |err| switch (err) {
            error.BinaryFileNotSupported => {
                std.log.err("BINARY FILE NOT SUPPORTED", .{});
                return;
            },
            error.EmptyFileNotSupported => {
                std.log.err("EMPTY FILE NOT SUPPORTED", .{});
                return;
            },
            error.InvalidRange => {
                std.log.err("INVALID RANGE", .{});
                return;
            },
            else => {
                std.log.err("OTHER ERROR", .{});
                return err;
            },
        };
    }

    if (cli_config.from_clipboard) {
        code = clipboard.read(allocator) catch {
            std.log.err("CLIPBOARD READ ERR", .{});
            return;
        };
    }

    if (code) |c| {
        const trimmed = try util_indent.trimCommonIndent(allocator, c);
        allocator.free(c);
        code = trimmed;
    }

    defer if (code) |c| allocator.free(c);

    if (code == null) {
        std.log.err("NO CODE PROVIDED", .{});
        return;
    }

    const file_name = try std.fmt.allocPrint(allocator, "znip_output_{d}.png", .{ std.time.timestamp() });
    defer allocator.free(file_name);

    const output_path = if (parsed_config.value.output_directory) |dir|
        try std.fs.path.join(allocator, &[_][]const u8{ dir, file_name })
    else
        try allocator.dupe(u8, file_name);
    defer allocator.free(output_path);

    if (code) |c| {
        znip.renderImage(c, output_path, cli_config.file_path, active_preset, active_theme, cli_config.lang, cli_config.yes) catch |err| switch (err) {
            error.LanguageNotAvailable => {
                std.log.err("Language '{s}' is not available (not built in, not cached, and not found in the grammar manifest)", .{cli_config.lang.?});
                return;
            },
            else => return err,
        };
    }

    if (cli_config.to_clipboard) {
            const content = try util_files.readFile(allocator, output_path);
            defer allocator.free(content);
            try clipboard.write_image(content);
    }
}
