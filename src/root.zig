const std = @import("std");
const tree_sitter = @import("core/tree_sitter.zig");
const Config = @import("core/config.zig").Config;
const Renderer = @import("ui/renderer.zig").Renderer;

pub fn renderImage(allocator: std.mem.Allocator, source_code: [:0]const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    const config = try Config.init();

    var renderer = try Renderer.init(arena_allocator, config);
    defer renderer.deinit();

    var parser = tree_sitter.Parser.init(arena_allocator, source_code);

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
    renderer.drawChunks(chunks.items);
    const generated_path = try renderer.saveImage();
    const final_path = try allocator.dupe(u8, generated_path);
    return final_path;
}
