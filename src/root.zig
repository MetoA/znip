const std = @import("std");
const tree_sitter = @import("core/tree_sitter.zig");
const Config = @import("core/config.zig").Config;
const Renderer = @import("ui/renderer.zig").Renderer;

pub fn renderImage(source_code: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config = try Config.init();

    var renderer = try Renderer.init(allocator, config);
    defer renderer.deinit();

    var parser = tree_sitter.Parser.init(allocator, source_code);

    var matches = try parser.sourceCodeMatches();
    defer matches.deinit(allocator);
    defer for (matches.items) |match| {
        allocator.free(match.capture_name);
    };
    var tokens = try parser.sourceCodeTokens(matches);
    defer tokens.deinit(allocator);
    defer for (tokens.items) |token| {
        allocator.free(token.capture_name);
        allocator.free(token.text);
    };
    var chunks = try renderer.prepareDrawableChunks(tokens.items);
    defer chunks.deinit(allocator);
    defer for (chunks.items) |chunk| {
        allocator.free(chunk.text);
    };
    const last_chunk_height: f64 = if (chunks.items.len > 0) chunks.getLast().y else 300.0;
    renderer.initImage(last_chunk_height);
    renderer.fillBackground();
    try renderer.drawCodeWindow(last_chunk_height);
    renderer.drawCodeWindowControls();
    renderer.drawChunks(chunks.items);
    renderer.saveImage();
}
