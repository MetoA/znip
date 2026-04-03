const std = @import("std");
const clap = @import("clap");

pub const CLIConfig = struct {
    help: bool = false,
    file_path: ?[]const u8 = null,
    starting_line: ?usize = null,
    ending_line: ?usize = null,
    interactive: bool = false,
    from_clipboard: bool = false,
    to_clipboard: bool = false,

    pub fn deinit(self: *CLIConfig, allocator: std.mem.Allocator) void {
        if (self.file_path) |path| allocator.free(path);
    }
};

pub const params = clap.parseParamsComptime(
    \\-h, --help           Displays help and exits
    \\-s, --start <usize>  Specifies starting line of the file
    \\-e, --end <usize>    Specifies ending line of the file
    \\    --from-clipboard Uses the text available in your clipboard
    \\    --to-clipboard   Copies the generated image to your clipboard
    \\-i, --interactive    Initiates an interactive step by step process of selecting various configurations
    \\<str>
);

pub fn parse(allocator: std.mem.Allocator) !CLIConfig {
    var diagnostic = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        diagnostic.reportToFile(.stderr(), err) catch {};
        return err;
    };
    defer result.deinit();

    const raw_path = if (result.positionals.len > 0) result.positionals[0] else null;
    const file_path = if (raw_path) |p| try allocator.dupe(u8, p) else null;

    return CLIConfig{
        .help = result.args.help != 0,
        .file_path = file_path,
        .starting_line = result.args.start,
        .ending_line = result.args.end,
        .from_clipboard = result.args.@"from-clipboard" != 0,
        .to_clipboard = result.args.@"to-clipboard" != 0,
        .interactive = result.args.interactive != 0,
    };
}
