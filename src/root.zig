const std = @import("std");
const build_options = @import("build_options");
const tree_sitter = @import("core/tree_sitter.zig");
const grammar_cache = @import("core/grammar_cache.zig");
const Preset = @import("core/config.zig").Preset;
const root_config = @import("core/config.zig");
const theme = @import("ui/theme.zig");
const Renderer = @import("ui/renderer.zig").Renderer;

pub const config = @import("core/config.zig");
pub const theme_module = @import("ui/theme.zig");
pub const fonts_module = @import("util/fonts.zig");
pub const output = @import("util/output.zig");

pub fn renderImage(source_code: [:0]const u8, file_name: []const u8, source_hint_path: ?[]const u8, preset: Preset, active_theme: theme.Theme, requested_lang: ?[]const u8, auto_confirm: bool, starting_line: u32, highlight_lines: []const usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const display_file_name: ?[]const u8 = if (preset.show_file_name and source_hint_path != null)
        std.fs.path.basename(source_hint_path.?)
    else
        null;

    var renderer = try Renderer.init(arena_allocator, preset, active_theme, display_file_name);
    defer renderer.deinit();

    var parser = tree_sitter.Parser.init(arena_allocator, source_code, source_hint_path);
    var registry = tree_sitter.LanguageRegistry.init(arena_allocator);
    parser.attachRegistry(&registry);
    if (requested_lang) |lang| parser.setRequestedLanguage(lang);

    // Explicit --lang always drives the candidate; otherwise, only bother
    // checking the manifest for names that already look unrecognized (native
    // extension/fence-tag lookups keep working exactly as before, with zero
    // network activity for the common case).
    //
    // Gated on wasm_enabled: a build without WASM support can never actually
    // load a fetched grammar (LanguageRegistry.resolve() is comptime-compiled
    // to always return null), so prompting/downloading one would just be a
    // pointless network round-trip that silently goes nowhere.
    if (comptime build_options.wasm_enabled) {
        const candidate = requested_lang orelse
            if (source_hint_path) |p| tree_sitter.candidateNameFromPath(p) else null;

        if (candidate) |name| {
            if (tree_sitter.nativeLanguageFromHint(name) == null and try registry.resolve(name) == null) {
                maybeFetchDynamicLanguage(arena_allocator, name, auto_confirm);
            }
        }
    }

    output.step("Parsing source code...", .{});
    var matches = try parser.sourceCodeMatches();
    defer matches.deinit(arena_allocator);
    var tokens = try parser.sourceCodeTokens(matches);
    defer tokens.deinit(arena_allocator);

    output.step("Rendering image...", .{});
    var prepared = try renderer.prepareDrawableChunks(tokens.items, starting_line, highlight_lines);
    defer prepared.chunks.deinit(arena_allocator);
    defer prepared.highlights.deinit(arena_allocator);
    const last_chunk_height: f64 = if (prepared.chunks.items.len > 0) prepared.chunks.getLast().y else 300.0;
    try renderer.initImage(last_chunk_height);
    renderer.fillBackground();
    try renderer.drawCodeWindow(last_chunk_height);
    renderer.drawHighlights(prepared.highlights.items);
    renderer.drawCodeWindowControls();
    renderer.drawFileName();
    try renderer.drawChunks(prepared.chunks.items);

    output.step("Saving image...", .{});
    try renderer.saveImage(file_name);
}

pub fn createRootConfigDirectories(allocator: std.mem.Allocator) !void {
    try root_config.createRootConfigDirectories(allocator);
}

// Explicit, one-shot install (--install-lang): fetches the manifest, looks
// up `name`, and fetches+caches its grammar bundle. No prompt - the caller
// already asked explicitly.
// Explicit `anyerror` return: the WasmSupportNotBuilt early-return below
// makes the rest of this function's body unreachable (and its errors
// pruned from the inferred set) when built with -Dwasm=false - an inferred
// `!void` would silently shrink to just {WasmSupportNotBuilt} in that
// config, breaking main.zig's switch on error.LanguageNotInManifest, which
// is only reachable in the wasm-enabled config.
pub fn installLanguage(allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    if (comptime !build_options.wasm_enabled) return error.WasmSupportNotBuilt;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var spinner: output.Spinner = undefined;
    try spinner.start(allocator, "Installing language '{s}'...", .{name});

    var manifest = grammar_cache.fetchManifest(allocator, &client, grammar_cache.default_manifest_url) catch |err| {
        spinner.stop(false, "Couldn't fetch the grammar manifest: {s}", .{@errorName(err)});
        return err;
    };
    defer manifest.deinit();

    const entry = grammar_cache.findEntry(manifest.value, name) orelse {
        spinner.stop(false, "Language '{s}' wasn't found in the grammar manifest.", .{name});
        return error.LanguageNotInManifest;
    };

    grammar_cache.fetchGrammar(allocator, &client, entry) catch |err| {
        spinner.stop(false, "Couldn't download the grammar for '{s}': {s}", .{ name, @errorName(err) });
        return err;
    };

    spinner.stop(true, "Language '{s}' installed.", .{name});
}

// Automatic fetch-on-first-use: checks the manifest for `name` and, if
// listed, prompts (unless auto_confirm) before fetching. Never returns an
// error - a missing manifest, an unlisted language, or a declined prompt are
// all just "nothing to do here", logged at debug level so the common case of
// a plain unrecognized extension stays silent and offline.
fn maybeFetchDynamicLanguage(allocator: std.mem.Allocator, name: []const u8, auto_confirm: bool) void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var manifest = grammar_cache.fetchManifest(allocator, &client, grammar_cache.default_manifest_url) catch |err| {
        std.log.debug("Grammar manifest unavailable, skipping on-demand fetch for '{s}': {s}", .{ name, @errorName(err) });
        return;
    };
    defer manifest.deinit();

    const entry = grammar_cache.findEntry(manifest.value, name) orelse {
        return;
    };

    if (!auto_confirm) {
        // With piped input stdin has already been consumed (or is empty), so
        // the prompt could never be answered: say what to do instead of
        // quietly treating it as "no".
        if (!std.fs.File.stdin().isTty()) {
            output.warn("Language '{s}' isn't built in. Re-run with -y to download its grammar.", .{name});
            return;
        }
        std.debug.print("Language '{s}' isn't built in - download WASM grammar? [y/N] ", .{name});
        if (!promptYesNo()) return;
    }

    var spinner: output.Spinner = undefined;
    spinner.start(allocator, "Downloading grammar for '{s}'...", .{name}) catch return;

    grammar_cache.fetchGrammar(allocator, &client, entry) catch |err| {
        spinner.stop(false, "Couldn't download the grammar for '{s}': {s}", .{ name, @errorName(err) });
        return;
    };
    spinner.stop(true, "Downloaded grammar for '{s}'.", .{name});
}

fn promptYesNo() bool {
    var buf: [16]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const n = stdin.read(&buf) catch return false;
    if (n == 0) return false;
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

fn e2ePreset() Preset {
    return .{
        .name = "e2e",
        .theme = "One Darker",
        .font = "JetBrainsMono-Bold",
        .font_size = 16,
        .window_controls = true,
        .show_file_name = true,
        .vertical_padding_px = 30,
        .horizontal_padding_px = 30,
        .include_drop_shadow = true,
        .transparent_background = false,
    };
}

const PngInfo = struct { width: u32, height: u32 };

/// Reads the dimensions from a PNG's IHDR chunk, checking the signature.
fn readPngInfo(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !PngInfo {
    const bytes = try dir.readFileAlloc(allocator, name, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 33);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

/// Renders `source` into a fresh temp dir and returns the PNG's dimensions.
fn renderToPng(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    hint: ?[]const u8,
    preset: Preset,
    lang: ?[]const u8,
    starting_line: u32,
    highlights: []const usize,
) !PngInfo {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "out.png" });
    defer allocator.free(path);

    try renderImage(source, path, hint, preset, theme.OneDarker, lang, true, starting_line, highlights);
    return readPngInfo(allocator, tmp.dir, "out.png");
}

test "renderImage writes a PNG for a source file" {
    const info = try renderToPng(std.testing.allocator, "const x: u32 = 5;\n", "main.zig", e2ePreset(), null, 1, &.{});
    // Window holds the code and the header, plus padding on both sides.
    try std.testing.expect(info.width >= 120 + 60);
    try std.testing.expect(info.height > 60);
}

test "renderImage works for an explicit language and for piped input without a path" {
    const rust = try renderToPng(std.testing.allocator, "fn main() {\n    println!(\"hi\");\n}\n", null, e2ePreset(), "rust", 1, &.{});
    try std.testing.expect(rust.width > 0 and rust.height > 0);

    const detected = try renderToPng(std.testing.allocator, "def add(a, b):\n    return a + b\n", null, e2ePreset(), null, 1, &.{});
    try std.testing.expect(detected.width > 0 and detected.height > 0);
}

test "renderImage renders every native language" {
    const samples = [_]struct { []const u8, [:0]const u8 }{
        .{ "zig", "const a = 1;\n" },
        .{ "rust", "fn f() {}\n" },
        .{ "python", "x = 1\n" },
        .{ "javascript", "let x = 1;\n" },
        .{ "typescript", "let x: number = 1;\n" },
        .{ "c", "int main(void) { return 0; }\n" },
        .{ "cpp", "int main() { return 0; }\n" },
        .{ "go", "package main\n" },
        .{ "html", "<p>hi</p>\n" },
        .{ "css", "a { color: red; }\n" },
        .{ "java", "class A {}\n" },
        .{ "ruby", "puts 1\n" },
        .{ "json", "{\"a\": 1}\n" },
        .{ "php", "<?php echo 1;\n" },
        .{ "markdown", "# Title\n" },
        .{ "sql", "SELECT 1;\n" },
    };
    for (samples) |sample| {
        const info = try renderToPng(std.testing.allocator, sample[1], null, e2ePreset(), sample[0], 1, &.{});
        try std.testing.expect(info.width > 0 and info.height > 0);
    }
}

test "renderImage output grows taller with more lines" {
    const one = try renderToPng(std.testing.allocator, "a = 1\n", "a.py", e2ePreset(), null, 1, &.{});
    const ten = try renderToPng(std.testing.allocator, "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\ng = 7\nh = 8\ni = 9\nj = 10\n", "a.py", e2ePreset(), null, 1, &.{});
    try std.testing.expectEqual(one.width, ten.width);
    try std.testing.expect(ten.height > one.height + 8 * 15);
}

test "renderImage caps very long lines at the same width and allows 120 columns" {
    const long_a = "x = \"" ++ "a" ** 1500 ++ "\"\n";
    const long_b = "x = \"" ++ "b" ** 3000 ++ "\"\n";
    const exact_fit = "x = \"" ++ "a" ** 114 ++ "\"\n"; // 120 columns
    const capped_a = try renderToPng(std.testing.allocator, long_a, "a.py", e2ePreset(), null, 1, &.{});
    const capped_b = try renderToPng(std.testing.allocator, long_b, "a.py", e2ePreset(), null, 1, &.{});
    const exact = try renderToPng(std.testing.allocator, exact_fit, "a.py", e2ePreset(), null, 1, &.{});
    try std.testing.expectEqual(capped_a.width, capped_b.width);
    // Wider than the old 900px window, and a 120 column line needs no wrapping, so no extra rows.
    try std.testing.expect(capped_a.width > 900 + 2 * 30);
    try std.testing.expectEqual(capped_a.width, exact.width);
    try std.testing.expectEqual(exact.height, (try renderToPng(std.testing.allocator, "x = 1\n", "a.py", e2ePreset(), null, 1, &.{})).height);
}

test "renderImage sizes short code to its content instead of a fixed minimum" {
    const tiny = try renderToPng(std.testing.allocator, "x\n", "a.py", e2ePreset(), null, 1, &.{});
    const short = try renderToPng(std.testing.allocator, "x = 1\n", "a.py", e2ePreset(), null, 1, &.{});
    const longer = try renderToPng(std.testing.allocator, "x = 1 + 2 + 3 + 4\n", "a.py", e2ePreset(), null, 1, &.{});
    try std.testing.expect(tiny.width < 320 + 2 * 30);
    try std.testing.expect(short.width <= longer.width);
    try std.testing.expect(longer.width > tiny.width);
}

test "renderImage widens the window for a long file name" {
    const plain = try renderToPng(std.testing.allocator, "x\n", "a.py", e2ePreset(), null, 1, &.{});
    const named = try renderToPng(std.testing.allocator, "x\n", "a_very_long_file_name_for_a_tiny_snippet.py", e2ePreset(), null, 1, &.{});
    try std.testing.expect(named.width > plain.width);
}

test "renderImage respects the padding in the preset" {
    var wide = e2ePreset();
    wide.horizontal_padding_px = 100;
    wide.vertical_padding_px = 100;
    const base = try renderToPng(std.testing.allocator, "x = 1\n", "a.py", e2ePreset(), null, 1, &.{});
    const padded = try renderToPng(std.testing.allocator, "x = 1\n", "a.py", wide, null, 1, &.{});
    try std.testing.expectEqual(base.width + 140, padded.width);
    try std.testing.expect(padded.height > base.height);
}

test "renderImage accepts highlights, a line offset and a transparent canvas" {
    var preset = e2ePreset();
    preset.transparent_background = true;
    preset.show_file_name = false;
    preset.window_controls = false;
    const info = try renderToPng(std.testing.allocator, "a = 1\nb = 2\nc = 3\n", "a.py", preset, null, 40, &.{ 41, 42 });
    try std.testing.expect(info.width > 0 and info.height > 0);
}

test "renderImage is deterministic for identical input" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    const source: [:0]const u8 = "fn main() {\n    let x = 1;\n}\n";
    for ([_][]const u8{ "one.png", "two.png" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        try renderImage(source, path, "main.rs", e2ePreset(), theme.OneDarker, null, true, 1, &.{2});
    }

    const one = try tmp.dir.readFileAlloc(allocator, "one.png", 32 * 1024 * 1024);
    defer allocator.free(one);
    const two = try tmp.dir.readFileAlloc(allocator, "two.png", 32 * 1024 * 1024);
    defer allocator.free(two);
    try std.testing.expectEqualSlices(u8, one, two);
}

test "renderImage output differs between themes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    const themes = [_]theme.Theme{ theme.OneDarker, theme.PaperWhite };
    const names = [_][]const u8{ "dark.png", "light.png" };
    for (themes, names) |t, name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        try renderImage("x = 1\n", path, "a.py", e2ePreset(), t, null, true, 1, &.{});
    }

    const dark = try tmp.dir.readFileAlloc(allocator, "dark.png", 32 * 1024 * 1024);
    defer allocator.free(dark);
    const light = try tmp.dir.readFileAlloc(allocator, "light.png", 32 * 1024 * 1024);
    defer allocator.free(light);
    try std.testing.expect(!std.mem.eql(u8, dark, light));
}

test "renderImage fails cleanly when the output path is not writable" {
    try std.testing.expectError(
        error.ImageWriteFailed,
        renderImage("x = 1\n", "/definitely/not/a/dir/out.png", "a.py", e2ePreset(), theme.OneDarker, null, true, 1, &.{}),
    );
}

test "renderImage handles empty and whitespace-only input" {
    const empty = try renderToPng(std.testing.allocator, "", null, e2ePreset(), null, 1, &.{});
    try std.testing.expect(empty.width > 0 and empty.height > 0);
    const blank = try renderToPng(std.testing.allocator, "   \n\n  \n", null, e2ePreset(), null, 1, &.{});
    try std.testing.expect(blank.height > empty.height);
}

test {
    std.testing.refAllDecls(tree_sitter);
    std.testing.refAllDecls(@import("core/mini_regex.zig"));
    std.testing.refAllDecls(grammar_cache);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(theme_module);
    std.testing.refAllDecls(fonts_module);
    std.testing.refAllDecls(@import("ui/renderer.zig"));
    std.testing.refAllDecls(@import("util/split_inclusive_iterator.zig"));
}

