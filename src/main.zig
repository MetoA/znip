const std = @import("std");
const znip = @import("znip");
const cli = @import("core/cli.zig");
const util_files = @import("util/files.zig");
const clipboard = @import("clipboard/clipboard.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    std.log.debug("----- CLI CONFIG ----", .{});
    std.log.debug("Help {}", .{cli_config.help});
    std.log.debug("File Name {s}", .{cli_config.file_path orelse "none"});
    std.log.debug("Start {d}", .{cli_config.starting_line orelse 1});
    std.log.debug("End {d}", .{cli_config.ending_line orelse 9999});
    std.log.debug("From Clipboard {}", .{cli_config.from_clipboard});
    std.log.debug("To Clipboard {}", .{cli_config.to_clipboard});
    std.log.debug("Interactive {}", .{cli_config.interactive});

    if (cli_config.help) {
        try cli.help();
        return;
    }

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

    if (code) |c| {
        try znip.renderImage(c);
    }
}
