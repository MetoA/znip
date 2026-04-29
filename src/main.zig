const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");
const config = znip.config;
const theme = znip.theme_module;
const util_files = @import("util/files.zig");
const clipboard = @import("clipboard/clipboard.zig");

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

    var parsed_config = try config.Config.load(allocator);
    defer parsed_config.deinit();

    const preset_name = cli_config.preset orelse parsed_config.value.active_preset;

    var parsed_preset = try config.Config.loadPreset(allocator, preset_name);
    defer parsed_preset.deinit();

    const active_theme = theme.getThemeByName(parsed_preset.value.theme);

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

    defer if (code) |c| allocator.free(c);

    if (code == null) {
        std.log.err("NO CODE PROVIDED", .{});
        return;
    }

    const file_name = try std.fmt.allocPrint(allocator, "znip_output_{d}.png", .{ std.time.timestamp() });
    defer allocator.free(file_name);
    
    if (code) |c| {
        try znip.renderImage(c, file_name, cli_config.file_path, parsed_preset.value, active_theme);
    }

    if (cli_config.to_clipboard) {
            const content = try util_files.readFile(allocator, file_name);
            defer allocator.free(content);
            try clipboard.write_image(content);
    }
}
