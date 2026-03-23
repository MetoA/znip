const std = @import("std");
const tree_sitter = @import("tree-sitter.zig");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

const font_bytes = @embedFile("fonts/JetBrainsMono-Bold.ttf");

pub fn generateImage(tokens: []const tree_sitter.Token) !void {
    var img: c.BLImageCore = undefined;
    _ = c.bl_image_init_as(&img, 800, 400, c.BL_FORMAT_PRGB32);
    defer _ = c.bl_image_reset(&img);

    var ctx: c.BLContextCore = undefined;
    _ = c.bl_context_init_as(&ctx, &img, null);
    defer _ = c.bl_context_reset(&ctx);

    fillBackground(&ctx, 0xFF37A3FF);
    drawCodeWindow(&ctx, 0xFF44475A);
    drawTokens(&ctx, tokens) catch |err| {
        std.log.err("Failed to draw tokens: {}", .{err});
        return err;
    };
    
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

fn drawCodeWindow(ctx: *c.BLContextCore, color: u32) void {
    const rect = c.BLRoundRect{ .x = 50, .y = 50, .w = 700, .h = 300, .rx = 12, .ry = 12 };
    _ = c.bl_context_set_fill_style_rgba32(ctx, color);
    _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);

    drawCodeWindowControls(ctx);
}

fn drawCodeWindowControls(ctx: *c.BLContextCore) void {
    const colors = [_]u32{ 0xFFFF5F56, 0xFFFFBD2E, 0xFF27C93F };
    for (colors, 0..) |color, index| {
        const circle = c.BLCircle{ .cx = @as(f64, @floatFromInt(75 + (index * 20))), .cy = @as(f64, @floatFromInt(75)), .r = @as(f64, @floatFromInt(6)) };
        _ = c.bl_context_set_fill_style_rgba32(ctx, color);
        _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
    }
}

fn drawTokens(ctx: *c.BLContextCore, tokens: []const tree_sitter.Token) !void {
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
    _ = c.bl_font_init(&font);
    _ = c.bl_font_create_from_face(&font, &face, 20.0); // TODO font size
    defer _ = c.bl_font_reset(&font);

    var metrics: c.BLFontMetrics = undefined;
    _ = c.bl_font_get_metrics(&font, &metrics);
    const ascent = metrics.unnamed_0.unnamed_0.ascent;
    const descent = metrics.unnamed_0.unnamed_0.descent;
    const line_height = ascent + descent + metrics.line_gap;

    const margin_x: f64 = 80.0;
    const margin_y: f64 = 60.0;
    var pen_x = margin_x;
    var pen_y = margin_y + ascent;
    var line_num: usize = 1;

    // First line number
    drawLineNumber(ctx, &font, 10.0, pen_y, line_num);

    var gb: c.BLGlyphBufferCore = undefined;
    _ = c.bl_glyph_buffer_init(&gb);
    defer _ = c.bl_glyph_buffer_reset(&gb);

    for (tokens) |token| {
        var it = std.mem.splitScalar(u8, token.text, '\n');
        var first_part = true;

        while (it.next()) |chunk| {
            if (!first_part) {
                line_num += 1;
                pen_x = margin_x;
                pen_y += line_height;
                drawLineNumber(ctx, &font, 10.0, pen_y, line_num);
            }
            first_part = false;

            if (chunk.len > 0) {
                std.log.debug("chunk={s}", .{chunk});
                _ = c.bl_glyph_buffer_set_text(&gb, chunk.ptr, chunk.len, c.BL_TEXT_ENCODING_UTF8);
                _ = c.bl_font_shape(&font, &gb);

                _ = c.bl_context_set_fill_style_rgba32(ctx, token.color);

                const pt = c.BLPoint{ .x = pen_x, .y = pen_y };
                _ = c.bl_context_fill_glyph_run_d(ctx, &pt, &font, c.bl_glyph_buffer_get_glyph_run(&gb));

                var text_metrics: c.BLTextMetrics = undefined;
                _ = c.bl_font_get_text_metrics(&font, &gb, &text_metrics);
                pen_x += text_metrics.advance.x;
            }
        }
    }
}



fn drawLineNumber(ctx: *c.BLContextCore, font: *c.BLFontCore, x: f64, y: f64, num: usize) void {
    var buf: [8]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d: >3}", .{num}) catch "   ";
    _ = c.bl_context_set_fill_style_rgba32(ctx, 0xFF6272A4); // TODO color
    const pt = c.BLPoint{ .x = x, .y = y };
    _ = c.bl_context_fill_utf8_text_d(ctx, &pt, font, str.ptr, str.len);
}
