const std = @import("std");
const clap = @import("clap");

pub const CLIConfig = struct {
    help: bool = false,
    file_path: ?[]const u8 = null,
    starting_line: ?usize = null,
    ending_line: ?usize = null,
    highlight_lines: ?[]usize = null,
    interactive: bool = false,
    from_clipboard: bool = false,
    from_stdin: bool = false,
    to_clipboard: bool = false,
    transparent: bool = false,
    open: bool = false,
    preset: ?[]const u8 = null,
    font: ?[]const u8 = null,
    font_size: ?u32 = null,
    lang: ?[]const u8 = null,
    install_lang: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    output_name: ?[]const u8 = null,
    yes: bool = false,

    pub fn deinit(self: *CLIConfig, allocator: std.mem.Allocator) void {
        if (self.file_path) |path| allocator.free(path);
        if (self.preset) |preset| allocator.free(preset);
        if (self.font) |font| allocator.free(font);
        if (self.lang) |lang| allocator.free(lang);
        if (self.install_lang) |install_lang| allocator.free(install_lang);
        if (self.output_dir) |output_dir| allocator.free(output_dir);
        if (self.output_name) |output_name| allocator.free(output_name);
        if (self.highlight_lines) |lines| allocator.free(lines);
    }
};

/// Largest line number accepted for -s/-e/--highlight.
pub const max_line_number: usize = std.math.maxInt(u32);
/// Most lines a single --highlight spec may expand to. Far above what fits in
/// an image (Blend2D caps images at 65535px), but keeps `1-4000000000` from
/// allocating gigabytes.
pub const max_highlight_lines: usize = 100_000;
pub const max_font_size: u32 = 512;

pub const params = clap.parseParamsComptime(
    \\-h, --help              Displays help and exits
    \\-s, --start <usize>     Specifies starting line of the file
    \\-e, --end <usize>       Specifies ending line of the file
    \\    --highlight <str>   Highlight specific line(s), e.g. 5,8-10
    \\    --from-clipboard    Uses the text available in your clipboard
    \\    --to-clipboard      Copies the generated image to your clipboard
    \\    --transparent       Make the outer canvas transparent (the code window itself stays opaque)
    \\-o, --open              Opens the generated image in your default viewer
    \\-i, --interactive       Initiates an interactive step by step process of selecting various configurations
    \\-p, --preset <str>      Use a specific preset for this run
    \\    --font <str>        Override the font for this run (bypasses the preset's font)
    \\    --font-size <u32>   Override the font size in px for this run (bypasses the preset's font size)
    \\-n, --name <str>        Sets the name of the saved output file (.png is appended if missing)
    \\    --lang <str>        Explicit language override, bypasses automatic detection
    \\    --install-lang <str> Fetches and caches a WASM grammar for the given language, then exits
    \\    --output-dir <str>  Sets the default directory where generated images are saved, then exits
    \\-y, --yes               Skip the download confirmation prompt for on-demand grammars
    \\<str>                   The file path of the code that would be used
);

/// Parses the process's real command line. stdin is the input source only when
/// it isn't a TTY (i.e. something is piped in) and no file path or
/// --from-clipboard was given: an explicit source always wins, so `znip f.zig`
/// still works from cron, CI, git hooks and `ssh host znip f.zig`, where stdin
/// is never a terminal.
pub fn parse(allocator: std.mem.Allocator) !CLIConfig {
    var diagnostic = clap.Diagnostic{};
    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // executable name

    return parseFrom(allocator, &iter, !std.fs.File.stdin().isTty(), &diagnostic);
}

/// The testable core of `parse`: `iter` yields the arguments after the
/// executable name, and `stdin_piped` says whether stdin carries code.
/// Clap errors are reported to stderr through `diagnostic` when one is given.
pub fn parseFrom(
    allocator: std.mem.Allocator,
    iter: anytype,
    stdin_piped: bool,
    diagnostic: ?*clap.Diagnostic,
) !CLIConfig {
    var result = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .allocator = allocator,
        .diagnostic = diagnostic,
    }) catch |err| {
        if (diagnostic) |d| d.reportToFile(.stderr(), err) catch {};
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

    const raw_font: ?[]const u8 = result.args.font;
    const font = if (raw_font) |f| try allocator.dupe(u8, f) else null;
    errdefer if (font) |f| allocator.free(f);

    const raw_lang: ?[]const u8 = result.args.lang;
    const lang = if (raw_lang) |l| try allocator.dupe(u8, l) else null;
    errdefer if (lang) |l| allocator.free(l);

    const raw_name: ?[]const u8 = result.args.name;
    const output_name = if (raw_name) |n| try allocator.dupe(u8, n) else null;
    errdefer if (output_name) |n| allocator.free(n);

    const from_clipboard = result.args.@"from-clipboard" != 0;
    const from_stdin = stdin_piped and file_path == null and !from_clipboard;

    const source_count: u8 = @as(u8, @intFromBool(file_path != null)) +
        @as(u8, @intFromBool(from_clipboard)) +
        @as(u8, @intFromBool(from_stdin));

    if (source_count > 1) return error.MultipleCodeSourcesNotSupported;
    if (source_count == 0) return error.NoInputProvided;

    const start: ?usize = result.args.start;
    const end: ?usize = result.args.end;
    if (start) |s| if (s == 0) return error.InvalidStartLine;
    if (end) |e| if (e == 0) return error.InvalidEndLine;
    // Line numbers are carried around as u32 later on.
    if (start) |s| if (s > max_line_number) return error.LineNumberTooLarge;
    if (end) |e| if (e > max_line_number) return error.LineNumberTooLarge;

    const font_size: ?u32 = result.args.@"font-size";
    if (font_size) |size| if (size == 0 or size > max_font_size) return error.InvalidFontSize;
    if (start) |s| {
        if (end) |e| {
            if (s >= e) return error.InvalidStartEndLines;
        }
    }

    const raw_highlight: ?[]const u8 = result.args.highlight;
    const highlight_lines = if (raw_highlight) |h| try parseHighlightSpec(allocator, h) else null;
    errdefer if (highlight_lines) |lines| allocator.free(lines);

    return CLIConfig{
        .help = false,
        .file_path = file_path,
        .starting_line = start,
        .ending_line = end,
        .highlight_lines = highlight_lines,
        .from_clipboard = from_clipboard,
        .from_stdin = from_stdin,
        .to_clipboard = result.args.@"to-clipboard" != 0,
        .transparent = result.args.transparent != 0,
        .open = result.args.open != 0,
        .interactive = result.args.interactive != 0,
        .preset = preset,
        .font = font,
        .font_size = font_size,
        .lang = lang,
        .output_name = output_name,
        .yes = result.args.yes != 0,
    };
}

/// Parses a comma-separated highlight spec like "5,8-10" into a sorted,
/// deduplicated list of 1-based line numbers.
pub fn parseHighlightSpec(allocator: std.mem.Allocator, spec: []const u8) ![]usize {
    var lines = std.ArrayList(usize).empty;
    errdefer lines.deinit(allocator);

    var segment_iterator = std.mem.splitScalar(u8, spec, ',');
    while (segment_iterator.next()) |raw_segment| {
        const segment = std.mem.trim(u8, raw_segment, " \t");
        if (segment.len == 0) return error.InvalidHighlightSpec;

        if (std.mem.indexOfScalar(u8, segment, '-')) |dash_index| {
            const start_str = segment[0..dash_index];
            const end_str = segment[dash_index + 1 ..];
            const range_start = std.fmt.parseUnsigned(usize, start_str, 10) catch return error.InvalidHighlightSpec;
            const range_end = std.fmt.parseUnsigned(usize, end_str, 10) catch return error.InvalidHighlightSpec;
            if (range_start == 0 or range_end == 0 or range_end < range_start) return error.InvalidHighlightSpec;
            if (range_end > max_line_number) return error.LineNumberTooLarge;
            if (range_end - range_start >= max_highlight_lines - @min(lines.items.len, max_highlight_lines)) return error.HighlightRangeTooLarge;

            var line = range_start;
            while (line <= range_end) : (line += 1) {
                try lines.append(allocator, line);
            }
        } else {
            const line = std.fmt.parseUnsigned(usize, segment, 10) catch return error.InvalidHighlightSpec;
            if (line == 0) return error.InvalidHighlightSpec;
            if (line > max_line_number) return error.LineNumberTooLarge;
            if (lines.items.len >= max_highlight_lines) return error.HighlightRangeTooLarge;
            try lines.append(allocator, line);
        }
    }

    std.mem.sort(usize, lines.items, {}, std.sort.asc(usize));

    var deduped = std.ArrayList(usize).empty;
    errdefer deduped.deinit(allocator);
    for (lines.items) |line| {
        if (deduped.items.len == 0 or deduped.items[deduped.items.len - 1] != line) {
            try deduped.append(allocator, line);
        }
    }
    lines.deinit(allocator);

    return deduped.toOwnedSlice(allocator);
}

pub fn help() !void {
    return try clap.helpToFile(.stdout(), clap.Help, &params, .{});
}

fn parseArgsForTest(allocator: std.mem.Allocator, args: []const []const u8, stdin_piped: bool) !CLIConfig {
    var iter = clap.args.SliceIterator{ .args = args };
    return parseFrom(allocator, &iter, stdin_piped, null);
}

test "parseHighlightSpec parses a single line" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "7");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{7}, lines);
}

test "parseHighlightSpec expands a range inclusively" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "3-6");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 5, 6 }, lines);
}

test "parseHighlightSpec accepts a single-line range" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "4-4");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{4}, lines);
}

test "parseHighlightSpec mixes lines and ranges" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "5,8-10");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 5, 8, 9, 10 }, lines);
}

test "parseHighlightSpec sorts out-of-order segments" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "9,2,5-6");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 2, 5, 6, 9 }, lines);
}

test "parseHighlightSpec deduplicates repeated and overlapping lines" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, "1-3,2-4,3,3");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, lines);
}

test "parseHighlightSpec trims spaces and tabs around segments" {
    const allocator = std.testing.allocator;
    const lines = try parseHighlightSpec(allocator, " 2 ,\t4-5 ");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 5 }, lines);
}

test "parseHighlightSpec rejects malformed specs" {
    const allocator = std.testing.allocator;
    const bad = [_][]const u8{
        "", // empty
        ",", // only separators
        "5,", // trailing comma
        ",5", // leading comma
        "5,,6", // empty middle segment
        "0", // lines are 1-based
        "0-3", // range starts at zero
        "3-0", // range ends at zero
        "9-5", // reversed range
        "1-", // open-ended range
        "-3", // open-started range
        "a", // not a number
        "1-b", // range end not a number
        "1.5", // not an integer
        "-1", // negative
        "1-2-3", // too many dashes
        "1 2", // inner whitespace
    };
    for (bad) |spec| {
        try std.testing.expectError(error.InvalidHighlightSpec, parseHighlightSpec(allocator, spec));
    }
}

test "CLIConfig.deinit frees every owned field" {
    const allocator = std.testing.allocator;
    var config = CLIConfig{
        .file_path = try allocator.dupe(u8, "a.zig"),
        .preset = try allocator.dupe(u8, "p"),
        .font = try allocator.dupe(u8, "f"),
        .lang = try allocator.dupe(u8, "zig"),
        .install_lang = try allocator.dupe(u8, "rust"),
        .output_dir = try allocator.dupe(u8, "/tmp"),
        .output_name = try allocator.dupe(u8, "out"),
        .highlight_lines = try allocator.dupe(usize, &.{ 1, 2 }),
    };
    config.deinit(allocator);
}

test "CLIConfig.deinit tolerates an empty config" {
    var config = CLIConfig{};
    config.deinit(std.testing.allocator);
}

test "parseFrom reads a lone file path with defaults" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{"main.zig"}, false);
    defer config.deinit(allocator);

    try std.testing.expect(!config.help);
    try std.testing.expectEqualStrings("main.zig", config.file_path.?);
    try std.testing.expect(!config.from_clipboard);
    try std.testing.expect(!config.from_stdin);
    try std.testing.expect(!config.to_clipboard);
    try std.testing.expect(!config.transparent);
    try std.testing.expect(!config.open);
    try std.testing.expect(!config.interactive);
    try std.testing.expect(!config.yes);
    try std.testing.expectEqual(@as(?usize, null), config.starting_line);
    try std.testing.expectEqual(@as(?usize, null), config.ending_line);
    try std.testing.expect(config.highlight_lines == null);
    try std.testing.expect(config.preset == null);
    try std.testing.expect(config.font == null);
    try std.testing.expectEqual(@as(?u32, null), config.font_size);
    try std.testing.expect(config.lang == null);
    try std.testing.expect(config.output_name == null);
}

test "parseFrom reads every option" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{
        "-s",           "2",
        "-e",           "10",
        "--highlight",  "3,5-6",
        "--transparent",
        "--to-clipboard",
        "-o",
        "-i",
        "-p",           "mypreset",
        "--font",       "Inter",
        "--font-size",  "20",
        "-n",           "out",
        "--lang",       "rust",
        "-y",
        "main.rs",
    }, false);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("main.rs", config.file_path.?);
    try std.testing.expectEqual(@as(?usize, 2), config.starting_line);
    try std.testing.expectEqual(@as(?usize, 10), config.ending_line);
    try std.testing.expectEqualSlices(usize, &.{ 3, 5, 6 }, config.highlight_lines.?);
    try std.testing.expect(config.transparent);
    try std.testing.expect(config.to_clipboard);
    try std.testing.expect(config.open);
    try std.testing.expect(config.interactive);
    try std.testing.expectEqualStrings("mypreset", config.preset.?);
    try std.testing.expectEqualStrings("Inter", config.font.?);
    try std.testing.expectEqual(@as(?u32, 20), config.font_size);
    try std.testing.expectEqualStrings("out", config.output_name.?);
    try std.testing.expectEqualStrings("rust", config.lang.?);
    try std.testing.expect(config.yes);
}

test "parseFrom accepts long forms of the short flags" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{
        "--start", "1", "--end", "4", "--preset", "p", "--name", "n", "--open", "--interactive", "--yes", "f.c",
    }, false);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(?usize, 1), config.starting_line);
    try std.testing.expectEqual(@as(?usize, 4), config.ending_line);
    try std.testing.expectEqualStrings("p", config.preset.?);
    try std.testing.expectEqualStrings("n", config.output_name.?);
    try std.testing.expect(config.open and config.interactive and config.yes);
}

test "parseFrom --help returns early without needing input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{"-h"}, false);
    defer config.deinit(allocator);
    try std.testing.expect(config.help);
    try std.testing.expect(config.file_path == null);

    var long = try parseArgsForTest(allocator, &.{"--help"}, false);
    defer long.deinit(allocator);
    try std.testing.expect(long.help);
}

test "parseFrom --help wins over otherwise-invalid input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{ "--help", "-s", "0", "a.zig" }, true);
    defer config.deinit(allocator);
    try std.testing.expect(config.help);
    try std.testing.expect(config.file_path == null);
}

test "parseFrom --install-lang returns early without needing input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{ "--install-lang", "ruby" }, false);
    defer config.deinit(allocator);
    try std.testing.expectEqualStrings("ruby", config.install_lang.?);
    try std.testing.expect(config.file_path == null);
}

test "parseFrom --output-dir returns early without needing input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{ "--output-dir", "/tmp/images" }, false);
    defer config.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp/images", config.output_dir.?);
    try std.testing.expect(config.file_path == null);
}

test "parseFrom --install-lang takes precedence over --output-dir" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{ "--output-dir", "/tmp", "--install-lang", "go" }, false);
    defer config.deinit(allocator);
    try std.testing.expectEqualStrings("go", config.install_lang.?);
    try std.testing.expect(config.output_dir == null);
}

test "parseFrom accepts clipboard as the sole input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{"--from-clipboard"}, false);
    defer config.deinit(allocator);
    try std.testing.expect(config.from_clipboard);
    try std.testing.expect(!config.from_stdin);
    try std.testing.expect(config.file_path == null);
}

test "parseFrom accepts piped stdin as the sole input" {
    const allocator = std.testing.allocator;
    var config = try parseArgsForTest(allocator, &.{"--lang=python"}, true);
    defer config.deinit(allocator);
    try std.testing.expect(config.from_stdin);
    try std.testing.expect(!config.from_clipboard);
    try std.testing.expectEqualStrings("python", config.lang.?);
}

test "parseFrom requires an input source" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NoInputProvided, parseArgsForTest(allocator, &.{}, false));
    try std.testing.expectError(error.NoInputProvided, parseArgsForTest(allocator, &.{ "-s", "1", "--transparent" }, false));
}

test "parseFrom rejects more than one explicit input source" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MultipleCodeSourcesNotSupported, parseArgsForTest(allocator, &.{ "a.zig", "--from-clipboard" }, false));
    try std.testing.expectError(error.MultipleCodeSourcesNotSupported, parseArgsForTest(allocator, &.{ "a.zig", "--from-clipboard" }, true));
}

test "parseFrom lets an explicit file or clipboard win over non-TTY stdin" {
    const allocator = std.testing.allocator;

    // cron / CI / ssh: stdin isn't a terminal but a file was named.
    var file = try parseArgsForTest(allocator, &.{"a.zig"}, true);
    defer file.deinit(allocator);
    try std.testing.expect(!file.from_stdin);
    try std.testing.expectEqualStrings("a.zig", file.file_path.?);

    var clip = try parseArgsForTest(allocator, &.{"--from-clipboard"}, true);
    defer clip.deinit(allocator);
    try std.testing.expect(!clip.from_stdin);
    try std.testing.expect(clip.from_clipboard);
}

test "parseFrom rejects out-of-range numbers instead of panicking later" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.LineNumberTooLarge, parseArgsForTest(allocator, &.{ "-s", "5000000000", "a.zig" }, false));
    try std.testing.expectError(error.LineNumberTooLarge, parseArgsForTest(allocator, &.{ "-e", "5000000000", "a.zig" }, false));
    try std.testing.expectError(error.InvalidFontSize, parseArgsForTest(allocator, &.{ "--font-size", "0", "a.zig" }, false));
    try std.testing.expectError(error.InvalidFontSize, parseArgsForTest(allocator, &.{ "--font-size", "4000000000", "a.zig" }, false));
    var ok = try parseArgsForTest(allocator, &.{ "--font-size", "512", "a.zig" }, false);
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 512), ok.font_size);
}

test "parseHighlightSpec caps huge ranges and line numbers" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.HighlightRangeTooLarge, parseHighlightSpec(allocator, "1-99999999"));
    try std.testing.expectError(error.LineNumberTooLarge, parseHighlightSpec(allocator, "1-18446744073709551615"));
    try std.testing.expectError(error.LineNumberTooLarge, parseHighlightSpec(allocator, "99999999999"));
    try std.testing.expectError(error.HighlightRangeTooLarge, parseHighlightSpec(allocator, "1-60000,70000-130000"));
    const ok = try parseHighlightSpec(allocator, "1-99999");
    defer allocator.free(ok);
    try std.testing.expectEqual(@as(usize, 99999), ok.len);
}

test "parseFrom rejects a zero start or end line" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidStartLine, parseArgsForTest(allocator, &.{ "-s", "0", "a.zig" }, false));
    try std.testing.expectError(error.InvalidEndLine, parseArgsForTest(allocator, &.{ "-e", "0", "a.zig" }, false));
    try std.testing.expectError(error.InvalidStartLine, parseArgsForTest(allocator, &.{ "-s", "0", "-e", "5", "a.zig" }, false));
}

test "parseFrom requires start to be strictly before end" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidStartEndLines, parseArgsForTest(allocator, &.{ "-s", "5", "-e", "5", "a.zig" }, false));
    try std.testing.expectError(error.InvalidStartEndLines, parseArgsForTest(allocator, &.{ "-s", "6", "-e", "5", "a.zig" }, false));

    var ok = try parseArgsForTest(allocator, &.{ "-s", "4", "-e", "5", "a.zig" }, false);
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 4), ok.starting_line);
    try std.testing.expectEqual(@as(?usize, 5), ok.ending_line);
}

test "parseFrom accepts a start or end line on its own" {
    const allocator = std.testing.allocator;
    var only_start = try parseArgsForTest(allocator, &.{ "-s", "9", "a.zig" }, false);
    defer only_start.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 9), only_start.starting_line);
    try std.testing.expectEqual(@as(?usize, null), only_start.ending_line);

    var only_end = try parseArgsForTest(allocator, &.{ "-e", "9", "a.zig" }, false);
    defer only_end.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, null), only_end.starting_line);
    try std.testing.expectEqual(@as(?usize, 9), only_end.ending_line);
}

test "parseFrom propagates an invalid highlight spec without leaking" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidHighlightSpec, parseArgsForTest(allocator, &.{ "--highlight", "9-5", "-p", "x", "--font", "y", "--lang", "z", "-n", "w", "a.zig" }, false));
}

test "parseFrom does not leak when validation fails after allocating" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidStartLine, parseArgsForTest(allocator, &.{ "-s", "0", "-p", "x", "--font", "y", "--lang", "z", "-n", "w", "a.zig" }, false));
}

test "parseFrom surfaces clap errors for bad arguments" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseArgsForTest(allocator, &.{ "--no-such-flag", "a.zig" }, false));
    try std.testing.expectError(error.MissingValue, parseArgsForTest(allocator, &.{ "a.zig", "-s" }, false));
    try std.testing.expectError(error.InvalidCharacter, parseArgsForTest(allocator, &.{ "-s", "abc", "a.zig" }, false));
    try std.testing.expectError(error.InvalidCharacter, parseArgsForTest(allocator, &.{ "-s", "-3", "a.zig" }, false));
}
