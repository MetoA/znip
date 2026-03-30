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

    const matches = try parser.sourceCodeMatches();
    std.log.debug("matches: {d}", .{matches.items.len});
    const tokens = try parser.sourceCodeTokens(matches);
    std.log.debug("tokens: {d}", .{tokens.items.len});
    const chunks = try renderer.prepareDrawableChunks(tokens.items);
    std.log.debug("chunks: {d}", .{chunks.items.len});
    const last_chunk_height: f64 = if (chunks.items.len > 0) chunks.getLast().y else 300.0;
    // for (chunks.items) |value| {
    // std.log.debug("CHUNK Y: {d}", .{value.y});
    // }
    renderer.initImage(last_chunk_height);
    std.log.debug("inited img", .{});
    renderer.fillBackground();
    std.log.debug("filled bg", .{});
    try renderer.drawCodeWindow(last_chunk_height);
    std.log.debug("drawn code window", .{});
    renderer.drawCodeWindowControls();
    std.log.debug("drawn code window controls", .{});
    renderer.drawChunks(chunks.items);
    std.log.debug("drawn chunks", .{});
    renderer.saveImage();
    std.log.debug("Saved image", .{});
}
