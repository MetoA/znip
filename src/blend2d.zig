const std = @import("std");
const tree_sitter = @import("tree-sitter.zig");
const root = @import("root.zig");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

const font_bytes = @embedFile("assets/fonts/JetBrainsMono-Bold.ttf");

const CodeWindowOptions = struct {
    x: f64,
    y: f64,
    margin_x: f64,
    margin_y: f64,
    width: f64,
    height: f64,
    radius: f64,
    background_color: u32,
    
    
    pub fn heightFromLastY(self: *CodeWindowOptions, last_y: f64) f64 {
        const padding_bottom = 25.0;
        return last_y + padding_bottom - self.margin_y;
    }
};

pub fn generateImage(tokens: []const tree_sitter.Token) !void {
    const drawableChunks = prepareDrawableChunks(tokens) catch |err| {
        std.log.err("Failed to prepare chunks: {}", .{err});
        return err;
    };
    for (drawableChunks.items) |chunk| {
        std.log.debug("Chunk: x={d}, y={d}, text={s}", .{ chunk.x, chunk.y, chunk.text });
    }

    const last_chunk_height: f64 = if (drawableChunks.items.len > 0) drawableChunks.getLast().y else 300.0;
    var code_window_options = codeWindowOptions();

    const image_height = @as(i32, @intFromFloat(code_window_options.heightFromLastY(last_chunk_height) + 2 * code_window_options.margin_y));
    const image_width = @as(i32, @intFromFloat(code_window_options.width + 2 * code_window_options.margin_x));

    var img: c.BLImageCore = undefined;
    _ = c.bl_image_init_as(&img, image_width, image_height, c.BL_FORMAT_PRGB32);
    defer _ = c.bl_image_reset(&img);

    var ctx: c.BLContextCore = undefined;
    _ = c.bl_context_init_as(&ctx, &img, null);
    defer _ = c.bl_context_reset(&ctx);

    fillBackground(&ctx, 0xFF37A3FF);
    drawCodeWindow(&ctx, code_window_options);

    try drawDrawableChunks(&ctx, drawableChunks.items);

    var codec: c.BLImageCodecCore = undefined;
    _ = c.bl_image_codec_init(&codec);
    _ = c.bl_image_codec_find_by_name(&codec, "PNG", @intCast("PNG".len), null);
    _ = c.bl_image_write_to_file(&img, "output.png", &codec);
    defer _ = c.bl_image_codec_reset(&codec);

    std.log.debug("Image generated", .{});
}

fn fillBackground(ctx: *c.BLContextCore, color: u32) void {
    _ = c.bl_context_set_fill_style_rgba32(ctx, color);
    _ = c.bl_context_fill_all(ctx);
}

fn drawCodeWindow(ctx: *c.BLContextCore, options: CodeWindowOptions) void {
    const rect = c.BLRoundRect{ .x = options.x, .y = options.y, .w = options.width, .h = options.height, .rx = options.radius, .ry = options.radius };
    _ = c.bl_context_set_fill_style_rgba32(ctx, options.background_color);
    _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);

    drawCodeWindowControls(ctx);
}

fn drawCodeWindowControls(ctx: *c.BLContextCore) void {
    const colors = [_]u32{ 0xFFFF5F56, 0xFFFFBD2E, 0xFF27C93F };
    for (colors, 0..) |color, index| {
        const center_x = @as(f64, @floatFromInt(75 + (index * 20)));
        const center_y = @as(f64, @floatFromInt(75));
        const radius = @as(f64, @floatFromInt(6));
        const circle = c.BLCircle{ .cx = center_x, .cy = center_y, .r = radius };
        _ = c.bl_context_set_fill_style_rgba32(ctx, color);
        _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
    }
}

fn prepareDrawableChunks(tokens: []const tree_sitter.Token) !std.ArrayList(DrawableChunk) {
    var allocator = std.heap.page_allocator;
    var starting_whitespace: []const u8 = "";
    defer allocator.free(starting_whitespace);
    var drawableChunks = std.ArrayList(DrawableChunk).empty;

    var face: c.BLFontFaceCore = undefined;
    _ = c.bl_font_face_init(&face);
    defer _ = c.bl_font_face_reset(&face);

    var font_data: c.BLFontDataCore = undefined;
    _ = c.bl_font_data_init(&font_data);
    defer _ = c.bl_font_data_reset(&font_data);

    if (c.bl_font_data_create_from_data(&font_data, font_bytes.ptr, font_bytes.len, null, null) != c.BL_SUCCESS) {
        return error.FontDataCreationFailed;
    }

    if (c.bl_font_face_create_from_data(&face, &font_data, 0) != c.BL_SUCCESS) {
        return error.FontFaceCreationFailed;
    }

    // TODO try without glyphs? just text?
    var gb: c.BLGlyphBufferCore = undefined;
    _ = c.bl_glyph_buffer_init(&gb);
    defer _ = c.bl_glyph_buffer_reset(&gb);

    var font: c.BLFontCore = undefined;
    const font_size = 16.0; // TODO from file
    _ = c.bl_font_init(&font);
    _ = c.bl_font_create_from_face(&font, &face, font_size);
    defer _ = c.bl_font_reset(&font);

    var metrics: c.BLFontMetrics = undefined;
    _ = c.bl_font_get_metrics(&font, &metrics);

    const ascent = metrics.unnamed_0.unnamed_0.ascent;
    const descent = metrics.unnamed_0.unnamed_0.descent;
    const line_height = ascent + descent + metrics.line_gap;
    const char_width = ascent * 0.6;
    const indentation_padding: f64 = char_width * 4;
    const margin_x: f64 = 100.0;
    const margin_y: f64 = 100.0;
    const max_width: f64 = 700.0; // TODO based on longest line width?

    var pen_x = margin_x;
    var pen_y = margin_y + ascent;
    var line_num: usize = 1;

    try drawableChunks.append(allocator, lineNumberDrawableChunk(allocator, 55.0, pen_y, line_num));

    for (tokens) |token| {
        var it = std.mem.splitScalar(u8, token.text, '\n');
        var first_part = true;

        while (it.next()) |chunk| {
            // Mostly helps with new lines
            if (!first_part) {
                starting_whitespace = chunk;
                line_num += 1;
                pen_x = margin_x;
                pen_y += line_height;
                try drawableChunks.append(allocator, lineNumberDrawableChunk(allocator, 55.0, pen_y, line_num));
            }
            first_part = false;

            if (chunk.len > 0) {
                var words = root.SplitInclusiveIterator{ .buffer = chunk, .delimiter = " ", .index = 0 };
                while (words.next()) |word| {
                    var word_metrics: c.BLTextMetrics = undefined;
                    prepareRenderOfChunkAndIndentation(&gb, &font, &word_metrics, word);

                    // Rendering the next word would exceed the bounds of the code box, so we drop it to a new line
                    if (pen_x + word_metrics.advance.x + char_width > max_width) {
                        // Starts a new line, and places the pen at the beginning of the row
                        pen_y += line_height;
                        pen_x = margin_x;

                        // Renders the original line's whitespace, and adds a fixed offset for the next text
                        prepareRenderOfChunkAndIndentation(&gb, &font, &word_metrics, starting_whitespace);
                        try drawableChunks.append(allocator, .{
                            .x = pen_x,
                            .y = pen_y,
                            .color = token.color,
                            .text = starting_whitespace,
                        });
                        pen_x += word_metrics.advance.x + indentation_padding;
                    }

                    // Renders the text and advances the pen_x position
                    prepareRenderOfChunkAndIndentation(&gb, &font, &word_metrics, word);
                    try drawableChunks.append(allocator, .{
                        .x = pen_x,
                        .y = pen_y,
                        .color = token.color,
                        .text = word,
                    });

                    pen_x += word_metrics.advance.x;
                }
            }
        }
    }

    return drawableChunks;
}

fn drawDrawableChunks(ctx: *c.BLContextCore, chunks: []DrawableChunk) !void {
    var face: c.BLFontFaceCore = undefined;
    _ = c.bl_font_face_init(&face);
    defer _ = c.bl_font_face_reset(&face);

    var font_data: c.BLFontDataCore = undefined;
    _ = c.bl_font_data_init(&font_data);
    defer _ = c.bl_font_data_reset(&font_data);

    if (c.bl_font_data_create_from_data(&font_data, font_bytes.ptr, font_bytes.len, null, null) != c.BL_SUCCESS) {
        return error.FontDataCreationFailed;
    }

    if (c.bl_font_face_create_from_data(&face, &font_data, 0) != c.BL_SUCCESS) {
        return error.FontFaceCreationFailed;
    }

    var font: c.BLFontCore = undefined;
    const font_size = 16.0; // TODO from file
    _ = c.bl_font_init(&font);
    _ = c.bl_font_create_from_face(&font, &face, font_size); // TODO font size
    defer _ = c.bl_font_reset(&font);

    for (chunks) |chunk| {
        const pt = c.BLPoint{ .x = chunk.x, .y = chunk.y };
        _ = c.bl_context_set_fill_style_rgba32(ctx, chunk.color); // TODO color
        _ = c.bl_context_fill_utf8_text_d(ctx, &pt, &font, chunk.text.ptr, chunk.text.len);
    }
}

fn prepareRenderOfChunkAndIndentation(gb: *c.BLGlyphBufferCore, font: *c.BLFontCore, word_metrics: *c.BLTextMetrics, word: []const u8) void {
    _ = c.bl_glyph_buffer_set_text(gb, word.ptr, word.len, c.BL_TEXT_ENCODING_UTF8);
    _ = c.bl_font_shape(font, gb);
    _ = c.bl_font_get_text_metrics(font, gb, word_metrics);
}

fn lineNumberDrawableChunk(allocator: std.mem.Allocator, x: f64, y: f64, num: usize) DrawableChunk {
    return .{
        .x = x,
        .y = y,
        .color = 0xFF6272A4,
        .text = std.fmt.allocPrint(allocator, "{d: >3}", .{num}) catch "   ",
    };
}

fn codeWindowOptions() CodeWindowOptions {
    const margin_x = 50.0;
    const margin_y = 50.0;
    const height = 400;
    const width = 700.0;
    const radius = 12.0;
    
    return .{
        .x = margin_x,
        .y = margin_y,
        .margin_x = margin_x,
        .margin_y = margin_y,
        .width = width,
        .height = height,
        .radius = radius,
        .background_color = 0xFF44475A,
    };
}

const DrawableChunk = struct {
    x: f64,
    y: f64,
    color: u32, // Hex, e.g. 0xFF6272A4
    text: []const u8,
};
