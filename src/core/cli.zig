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
    preset: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    install_lang: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    yes: bool = false,

    pub fn deinit(self: *CLIConfig, allocator: std.mem.Allocator) void {
        if (self.file_path) |path| allocator.free(path);
        if (self.preset) |preset| allocator.free(preset);
        if (self.lang) |lang| allocator.free(lang);
        if (self.install_lang) |install_lang| allocator.free(install_lang);
        if (self.output_dir) |output_dir| allocator.free(output_dir);
    }
};

pub const params = clap.parseParamsComptime(
    \\-h, --help              Displays help and exits
    \\-s, --start <usize>     Specifies starting line of the file
    \\-e, --end <usize>       Specifies ending line of the file
    \\    --from-clipboard    Uses the text available in your clipboard
    \\    --to-clipboard      Copies the generated image to your clipboard
    \\-i, --interactive       Initiates an interactive step by step process of selecting various configurations
    \\-p, --preset <str>      Use a specific preset for this run
    \\    --lang <str>        Explicit language override, bypasses automatic detection
    \\    --install-lang <str> Fetches and caches a WASM grammar for the given language, then exits
    \\    --output-dir <str>  Sets the default directory where generated images are saved, then exits
    \\-y, --yes               Skip the download confirmation prompt for on-demand grammars
    \\<str>                   The file path of the code that would be used
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

    // Help early
    if (result.args.help != 0) return CLIConfig{ .help = true };

    // --install-lang early: fetch-only, no file/clipboard input required.
    const raw_install_lang: ?[]const u8 = result.args.@"install-lang";
    if (raw_install_lang) |raw| {
        return CLIConfig{ .install_lang = try allocator.dupe(u8, raw) };
    }

    // --output-dir early: config-only, no file/clipboard input required.
    const raw_output_dir: ?[]const u8 = result.args.@"output-dir";
    if (raw_output_dir) |raw| {
        return CLIConfig{ .output_dir = try allocator.dupe(u8, raw) };
    }

    const raw_path = if (result.positionals.len > 0) result.positionals[0] else null;
    const file_path = if (raw_path) |p| try allocator.dupe(u8, p) else null;
    errdefer if (file_path) |fp| allocator.free(fp);

    const raw_preset: ?[]const u8 = result.args.preset;
    const preset = if (raw_preset) |p| try allocator.dupe(u8, p) else null;
    errdefer if (preset) |pr| allocator.free(pr);

    const raw_lang: ?[]const u8 = result.args.lang;
    const lang = if (raw_lang) |l| try allocator.dupe(u8, l) else null;
    errdefer if (lang) |l| allocator.free(l);

    const from_clipboard = result.args.@"from-clipboard" != 0;
    if (file_path != null and from_clipboard) {
        return error.MultipleCodeSourcesNotSupported;
    }

    if (file_path == null and !from_clipboard) {
        return error.NoInputProvided;
    }

    const start: ?usize = result.args.start;
    const end: ?usize = result.args.end;
    if (start) |s| if (s == 0) return error.InvalidStartLine;
    if (end) |e| if (e == 0) return error.InvalidEndLine;
    if (start) |s| {
        if (end) |e| {
            if (s >= e) return error.InvalidStartEndLines;
        }
    }

    return CLIConfig{
        .help = false,
        .file_path = file_path,
        .starting_line = start,
        .ending_line = end,
        .from_clipboard = from_clipboard,
        .to_clipboard = result.args.@"to-clipboard" != 0,
        .interactive = result.args.interactive != 0,
        .preset = preset,
        .lang = lang,
        .yes = result.args.yes != 0,
    };
}

pub fn help() !void {
    return try clap.helpToFile(.stderr(), clap.Help, &params, .{});
}
