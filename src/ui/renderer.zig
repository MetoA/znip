const std = @import("std");
const tree_sitter = @import("../core/tree_sitter.zig");
const SplitInclusiveIterator = @import("../util/split_inclusive_iterator.zig").SplitInclusiveIterator;
const fonts = @import("../assets/fonts/fonts.zig");
const Theme = @import("theme.zig").Theme;
const themes = @import("themes.zig");
const Config = @import("../core/config.zig").Config;
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

pub const Renderer = struct {
    image: c.BLImageCore = undefined,
    context: c.BLContextCore = undefined,
    face: c.BLFontFaceCore = undefined,
    font: c.BLFontCore = undefined,
    font_data: c.BLFontDataCore = undefined,
    glyph_buffer: c.BLGlyphBufferCore = undefined,
    config: Config = undefined,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;
        self.config = config;

        _ = c.bl_font_face_init(&self.face);
        errdefer _ = c.bl_font_face_reset(&self.face);

        _ = c.bl_font_data_init(&self.font_data);
        errdefer _ = c.bl_font_data_reset(&self.font_data);

        _ = c.bl_glyph_buffer_init(&self.glyph_buffer);
        errdefer _ = c.bl_glyph_buffer_reset(&self.glyph_buffer);

        if (c.bl_font_data_create_from_data(&self.font_data, fonts.font_jet_brains_mono_bold.ptr, fonts.font_jet_brains_mono_bold.len, null, null) != c.BL_SUCCESS) {
            return error.FontDataCreationFailed;
        }

        if (c.bl_font_face_create_from_data(&self.face, &self.font_data, 0) != c.BL_SUCCESS) {
            return error.FontFaceCreationFailed;
        }

        _ = c.bl_font_init(&self.font);
        _ = c.bl_font_create_from_face(&self.font, &self.face, self.config.font_size);
        errdefer _ = c.bl_font_reset(&self.font);

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.bl_font_face_reset(&self.face);
        _ = c.bl_font_data_reset(&self.font_data);
        _ = c.bl_glyph_buffer_reset(&self.glyph_buffer);
        _ = c.bl_image_reset(&self.image);
        _ = c.bl_context_reset(&self.context);
    }

    fn fontMetrics(self: *Renderer) FontMetrics {
        var font_metrics: c.BLFontMetrics = undefined;
        _ = c.bl_font_get_metrics(&self.font, &font_metrics);

        const ascent = font_metrics.unnamed_0.unnamed_0.ascent;
        const descent = font_metrics.unnamed_0.unnamed_0.descent;
        const char_width = ascent * 0.6;

        return .{
            .ascent = ascent,
            .descent = descent,
            .line_height = ascent + descent + font_metrics.line_gap,
            .char_width = char_width,
            .margin_x = self.config.code_window_options.codeStartX(),
            .margin_y = self.config.code_window_options.codeStartY(),
        };
    }

    pub fn prepareDrawableChunks(self: *Renderer, tokens: []const tree_sitter.Token) !std.ArrayList(DrawableChunk) {
        const font_metrics = self.fontMetrics();
        var drawableChunks = std.ArrayList(DrawableChunk).empty;
        errdefer {
            for (drawableChunks.items) |d| {
                self.allocator.free(d.text);
            }
            drawableChunks.deinit(self.allocator);
        }
        var pen = Pen.init(self.config.code_window_options.lineNumberX(), font_metrics.margin_x, font_metrics.margin_y + font_metrics.ascent, font_metrics.line_height);

        try drawableChunks.append(self.allocator, .{
            .x = pen.x,
            .y = pen.y,
            .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.default_text).color,
            .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
        });
        pen.positionAtTextStart();
        var starting_whitespace: ?[]const u8 = null;
        defer if (starting_whitespace) |ws| self.allocator.free(ws);

        for (tokens) |token| {
            var iterator = std.mem.splitScalar(u8, token.text, '\n');
            var first_part = true;
            while (iterator.next()) |chunk| {
                // Mostly helps with new lines
                if (!first_part) {
                    if (starting_whitespace) |ws| {
                        self.allocator.free(ws);
                        starting_whitespace = null;
                    }
                    starting_whitespace = try self.allocator.dupe(u8, chunk);
                    pen.nextLine();
                    pen.positionAtNumStart();
                    try drawableChunks.append(self.allocator, .{
                        .x = pen.x,
                        .y = pen.y,
                        .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.default_text).color,
                        .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
                    });
                    pen.positionAtTextStart();
                }

                first_part = false;

                if (chunk.len > 0) {
                    var wordsIterator = SplitInclusiveIterator{ .buffer = chunk, .delimiter = " ", .index = 0 };
                    while (wordsIterator.next()) |word| {
                        var text_metrics: c.BLTextMetrics = undefined;
                        self.calculateTextMetrics(&text_metrics, word);

                        // max screen width, TODO
                        if (pen.x + text_metrics.advance.x + font_metrics.char_width > 720.0) {
                            try drawableChunks.append(self.allocator, .{
                                .type = ChunkType.wrap_indicator,
                                .x = pen.x + 5.0,
                                .y = pen.y,
                                .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.default_text).color,
                            });
                            pen.nextLineIndentation();
                            pen.positionAtTextStart();

                            if (starting_whitespace) |sw| {
                                self.calculateTextMetrics(&text_metrics, sw);
                                try drawableChunks.append(self.allocator, .{
                                    .x = pen.x,
                                    .y = pen.y,
                                    .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.categorizeCapture(token.capture_name)).color,
                                    .text = try self.allocator.dupe(u8, sw),
                                });
                            }
                            try drawableChunks.append(self.allocator, .{
                                .type = ChunkType.line_continuation,
                                .x = pen.x,
                                .y = pen.y,
                                .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.default_text).color,
                            });
                            pen.advanceX(text_metrics.advance.x);
                        }

                        self.calculateTextMetrics(&text_metrics, word);
                        try drawableChunks.append(self.allocator, .{
                            .x = pen.x,
                            .y = pen.y,
                            .color = self.config.active_theme.getStyle(tree_sitter.TokenCategory.categorizeCapture(token.capture_name)).color,
                            .text = try self.allocator.dupe(u8, word),
                        });
                        pen.advanceX(text_metrics.advance.x);
                    }
                }
            }
        }

        return drawableChunks;
    }

    pub fn drawChunks(self: *Renderer, chunks: []DrawableChunk) void {
        for (chunks) |chunk| {
            switch (chunk.type) {
                .text => {
                    _ = c.bl_context_set_fill_style_rgba32(&self.context, chunk.color);
                    _ = c.bl_context_fill_utf8_text_d(&self.context, &c.BLPoint{ .x = chunk.x, .y = chunk.y }, &self.font, chunk.text.ptr, chunk.text.len);
                },
                .wrap_indicator => {
                    try self.drawWrapStartArrow(chunk.x, chunk.y, chunk.color);
                },
                .line_continuation => {
                    try self.drawLineContinuationArrow(chunk.x, chunk.y, chunk.color);
                },
            }
        }
    }

    fn calculateTextMetrics(self: *Renderer, text_metrics: *c.BLTextMetrics, text: []const u8) void {
        _ = c.bl_glyph_buffer_set_text(&self.glyph_buffer, text.ptr, text.len, c.BL_TEXT_ENCODING_UTF8);
        _ = c.bl_font_shape(&self.font, &self.glyph_buffer);
        _ = c.bl_font_get_text_metrics(&self.font, &self.glyph_buffer, text_metrics);
    }

    pub fn initImage(self: *Renderer, last_line_y: f64) void {
        const width = @as(i32, @intFromFloat(self.config.code_window_options.max_width + 2 * self.config.code_window_options.x()));
        const height = @as(i32, @intFromFloat(self.config.code_window_options.heightFromLastY(last_line_y) + 2 * self.config.code_window_options.y()));
        _ = c.bl_image_init_as(&self.image, width, height, c.BL_FORMAT_PRGB32);
        _ = c.bl_context_init_as(&self.context, &self.image, null);
    }

    pub fn fillBackground(self: *Renderer) void {
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.config.active_theme.ui.background);
        _ = c.bl_context_fill_all(&self.context);
    }

    pub fn drawCodeWindow(self: *Renderer, last_line_y: f64) !void {
        const rect = c.BLRoundRect{
            .x = self.config.code_window_options.x(),
            .y = self.config.code_window_options.y(),
            .w = self.config.code_window_options.max_width,
            .h = self.config.code_window_options.heightFromLastY(last_line_y),
            .rx = self.config.code_window_options.radius,
            .ry = self.config.code_window_options.radius,
        };

        if (self.config.code_window_options.box_shadow.enabled) {
            try self.drawBoxShadow(rect);
        }
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.config.active_theme.ui.code_window_background);
        _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);
    }

    // Fake blur by rendering multiple gray rectangles with decreasing alpha values as they spread out
    fn drawBoxShadow(self: *Renderer, code_rect: c.BLRoundRect) !void {
        const box_shadow = self.config.code_window_options.box_shadow;
        const passes: usize = 12;

        var pass: usize = 0;
        while (pass < passes) : (pass += 1) {
            const spread_range = @as(f64, @floatFromInt(passes - pass)) / @as(f64, @floatFromInt(passes));
            const spread = box_shadow.blur * spread_range;

            // Alpha fades out toward the outer passes
            const base_alpha: f64 = @as(f64, @floatFromInt((box_shadow.color >> 24) & 0xFF));
            const alpha = @as(u32, @intFromFloat(base_alpha * (1.0 - spread_range) * (2.0 / @as(f64, @floatFromInt(passes)))));
            const color = (alpha << 24) | (box_shadow.color & 0x00FFFFFF);

            _ = c.bl_context_set_fill_style_rgba32(&self.context, color);

            var rect = c.BLRoundRect{
                .x = code_rect.x + box_shadow.offset_x - spread,
                .y = code_rect.y + box_shadow.offset_y - spread,
                .w = code_rect.w + spread * 2.0,
                .h = code_rect.h + spread * 2.0,
                .rx = code_rect.rx,
                .ry = code_rect.ry,
            };

            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);
        }
    }

    pub fn drawCodeWindowControls(self: *Renderer) void {
        const colors = [_]u32{ 0xFFFF5F56, 0xFFFFBD2E, 0xFF27C93F };
        for (colors, 0..) |color, index| {
            const center_x = self.config.code_window_options.windowControlsX() + @as(f64, @floatFromInt(index * 20));
            const center_y = self.config.code_window_options.windowControlsY();
            const radius = @as(f64, @floatFromInt(6));
            const circle = c.BLCircle{ .cx = center_x, .cy = center_y, .r = radius };
            _ = c.bl_context_set_fill_style_rgba32(&self.context, color);
            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
        }
    }

    // Curved arrow, drawn at the end of the line, indicating wrapping will appear
    fn drawWrapStartArrow(self: *Renderer, x: f64, y: f64, color: u32) !void {
        const origin = c.BLPoint{ .x = 0, .y = 0 };
        const size: f64 = 8.0;
        const offset_y: f64 = 2.0;

        var path: c.BLPathCore = undefined;
        _ = c.bl_path_init(&path);
        defer _ = c.bl_path_reset(&path);

        _ = c.bl_path_move_to(&path, x + size, y - (size * 1.2) - offset_y);
        _ = c.bl_path_line_to(&path, x + size, y - offset_y);
        _ = c.bl_path_line_to(&path, x, y - offset_y);
        _ = c.bl_path_line_to(&path, x + (size * 0.3), y - (size * 0.3) - offset_y);
        _ = c.bl_path_move_to(&path, x, y - offset_y);
        _ = c.bl_path_line_to(&path, x + (size * 0.3), y + (size * 0.3) - offset_y);

        _ = c.bl_context_set_stroke_width(&self.context, 1.0);
        _ = c.bl_context_set_stroke_caps(&self.context, c.BL_STROKE_CAP_ROUND);
        _ = c.bl_context_set_stroke_alpha(&self.context, 0.5);
        _ = c.bl_context_set_stroke_style_rgba32(&self.context, color);
        _ = c.bl_context_stroke_path_d(&self.context, &origin, &path);
    }

    // Straight arrow, drawn at the start of a new line, after wrapping text
    fn drawLineContinuationArrow(self: *Renderer, x: f64, y: f64, color: u32) !void {
        const size: f64 = 8.0;
        const origin = c.BLPoint{ .x = 0, .y = 0 };
        const metrics = self.fontMetrics();
        // Center the arrow by moving it back a bit
        const y_with_offset = y - (metrics.line_height / 4.0);

        var path: c.BLPathCore = undefined;
        _ = c.bl_path_init(&path);
        defer _ = c.bl_path_reset(&path);

        _ = c.bl_path_move_to(&path, x, y_with_offset);
        _ = c.bl_path_line_to(&path, x + size, y_with_offset);
        _ = c.bl_path_line_to(&path, x + (size * 0.6), y_with_offset - (size * 0.4));
        _ = c.bl_path_move_to(&path, x + size, y_with_offset);
        _ = c.bl_path_line_to(&path, x + (size * 0.6), y_with_offset + (size * 0.4));

        _ = c.bl_context_set_stroke_width(&self.context, 1.0);
        _ = c.bl_context_set_stroke_alpha(&self.context, 0.5);
        _ = c.bl_context_set_stroke_style_rgba32(&self.context, color);
        _ = c.bl_context_stroke_path_d(&self.context, &origin, &path);
    }

    pub fn saveImage(self: *Renderer) void {
        var codec: c.BLImageCodecCore = undefined;
        _ = c.bl_image_codec_init(&codec);
        _ = c.bl_image_codec_find_by_name(&codec, "PNG", @intCast("PNG".len), null);
        _ = c.bl_image_write_to_file(&self.image, "output.png", &codec);
        _ = c.bl_image_codec_reset(&codec);
    }
};

const FontMetrics = struct {
    ascent: f32,
    descent: f32,
    line_height: f32,
    char_width: f32,
    margin_x: f32,
    margin_y: f32,
};

const ChunkType = enum {
    text,
    wrap_indicator,
    line_continuation,
};

const DrawableChunk = struct {
    type: ChunkType = ChunkType.text,
    x: f64,
    y: f64,
    color: u32 = 0, // Hex, e.g. 0xFF6272A4
    text: []const u8 = "",
};

// TODO might be better to remove the line logic? and starting positions? just to separate stuff
const Pen = struct {
    x: f64,
    y: f64,

    num_starting_x: f64,
    text_starting_x: f64,
    starting_y: f64,
    line_num: u32,
    line_height: f32,

    pub fn init(num_x: f64, text_x: f64, y: f64, line_height: f32) Pen {
        return .{
            .x = num_x,
            .y = y,
            .num_starting_x = num_x,
            .text_starting_x = text_x,
            .starting_y = y,
            .line_num = 1,
            .line_height = line_height,
        };
    }

    pub fn nextLine(self: *Pen) void {
        self.y += self.line_height;
        self.line_num += 1;
    }

    /// Moves the pen to a new line but does not increment lines
    pub fn nextLineIndentation(self: *Pen) void {
        self.y += self.line_height;
    }

    pub fn advanceX(self: *Pen, x: f64) void {
        self.x += x;
    }

    pub fn positionAtTextStart(self: *Pen) void {
        self.x = self.text_starting_x;
    }

    pub fn positionAtNumStart(self: *Pen) void {
        self.x = self.num_starting_x;
    }
};
