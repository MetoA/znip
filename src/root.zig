const std = @import("std");
const tree_sitter = @import("core/tree_sitter.zig");
const Preset = @import("core/config.zig").Preset;
const root_config = @import("core/config.zig");
const theme = @import("ui/theme.zig");
const Renderer = @import("ui/renderer.zig").Renderer;

pub const config = @import("core/config.zig");
pub const theme_module = @import("ui/theme.zig");
pub const fonts_module = @import("util/fonts.zig");

pub fn renderImage(source_code: [:0]const u8, file_name: []const u8, source_hint_path: ?[]const u8, preset: Preset, active_theme: theme.Theme) !void {
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

    var matches = try parser.sourceCodeMatches();
    defer matches.deinit(arena_allocator);
    var tokens = try parser.sourceCodeTokens(matches);
    defer tokens.deinit(arena_allocator);
    var chunks = try renderer.prepareDrawableChunks(tokens.items);
    defer chunks.deinit(arena_allocator);
    const last_chunk_height: f64 = if (chunks.items.len > 0) chunks.getLast().y else 300.0;
    renderer.initImage(last_chunk_height);
    renderer.fillBackground();
    try renderer.drawCodeWindow(last_chunk_height);
    renderer.drawCodeWindowControls();
    renderer.drawFileName();
    try renderer.drawChunks(chunks.items);
    renderer.saveImage(file_name);
}

pub fn createRootConfigDirectories(allocator: std.mem.Allocator) !void {
    try root_config.createRootConfigDirectories(allocator);
}

test {
    std.testing.refAllDecls(tree_sitter);
}

