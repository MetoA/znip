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

pub fn renderImage(source_code: [:0]const u8, file_name: []const u8, source_hint_path: ?[]const u8, preset: Preset, active_theme: theme.Theme, requested_lang: ?[]const u8, auto_confirm: bool) !void {
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
    var chunks = try renderer.prepareDrawableChunks(tokens.items);
    defer chunks.deinit(arena_allocator);
    const last_chunk_height: f64 = if (chunks.items.len > 0) chunks.getLast().y else 300.0;
    renderer.initImage(last_chunk_height);
    renderer.fillBackground();
    try renderer.drawCodeWindow(last_chunk_height);
    renderer.drawCodeWindowControls();
    renderer.drawFileName();
    try renderer.drawChunks(chunks.items);

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

test {
    std.testing.refAllDecls(tree_sitter);
    std.testing.refAllDecls(grammar_cache);
}

