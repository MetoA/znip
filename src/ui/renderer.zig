const std = @import("std");
const tree_sitter = @import("../core/tree_sitter.zig");
const split_inclusive_iterator = @import("../util/split_inclusive_iterator.zig");
const fonts = @import("../assets/fonts/fonts.zig");
const theme = @import("theme.zig");
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
    active_theme: theme.Theme,
    code_window_options: CodeWindowOptions,
    allocator: std.mem.Allocator,

    starting_whitespace: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;

        const font_size = 16.0; // TODO

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
        _ = c.bl_font_create_from_face(&self.font, &self.face, font_size);
        errdefer _ = c.bl_font_reset(&self.font);

        self.active_theme = theme.DraculaTheme;

        self.code_window_options = .{
            .x = 50.0,
            .y = 50.0,
            .margin_x = 50.0,
            .margin_y = 50.0,
            .width = 700.0,
            .height = 400.0,
            .radius = 12.0,
        };

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.bl_font_face_reset(&self.face);
        _ = c.bl_font_data_reset(&self.font_data);
        _ = c.bl_glyph_buffer_reset(&self.glyph_buffer);
        _ = c.bl_image_reset(&self.image);
        _ = c.bl_context_reset(&self.context);

        self.allocator.free(self.starting_whitespace);
    }

    pub fn fontMetrics(self: *Renderer) FontMetrics {
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
            .indentation_padding = char_width * 4,
            .margin_x = 100.0,
            .margin_y = 100.0,
        };
    }

    pub fn prepareDrawableChunks(self: *Renderer, tokens: []const tree_sitter.Token) !std.ArrayList(DrawableChunk) {
        const font_metrics = self.fontMetrics();
        var drawableChunks = std.ArrayList(DrawableChunk).empty;
        var pen = Pen.init(55.0, font_metrics.margin_x, font_metrics.margin_y + font_metrics.ascent, font_metrics.line_height);

        try drawableChunks.append(self.allocator, .{
            .x = pen.x,
            .y = pen.y,
            .color = self.active_theme.getStyle(tree_sitter.TokenCategory.default_text).fg,
            .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
        });
        pen.positionAtTextStart();

        for (tokens) |token| {
            var iterator = std.mem.splitScalar(u8, token.text, '\n');
            var first_part = true;
            while (iterator.next()) |chunk| {
                // Mostly helps with new lines
                if (!first_part) {
                    self.starting_whitespace = chunk;
                    pen.nextLine();
                    pen.positionAtNumStart();
                    try drawableChunks.append(self.allocator, .{
                        .x = pen.x,
                        .y = pen.y,
                        .color = self.active_theme.getStyle(tree_sitter.TokenCategory.default_text).fg,
                        .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
                    });
                    pen.positionAtTextStart();
                }

                first_part = false;

                if (chunk.len > 0) {
                    var wordsIterator = split_inclusive_iterator.SplitInclusiveIterator{ .buffer = chunk, .delimiter = " ", .index = 0 };
                    while (wordsIterator.next()) |word| {
                        var text_metrics: c.BLTextMetrics = undefined;
                        self.calculateTextMetrics(&text_metrics, word);

                        // max screen width, TODO
                        if (pen.x + text_metrics.advance.x + font_metrics.char_width > 700.0) {
                            pen.nextLineIndentation();
                            pen.positionAtTextStart();

                            self.calculateTextMetrics(&text_metrics, self.starting_whitespace);
                            try drawableChunks.append(self.allocator, .{
                                .x = pen.x,
                                .y = pen.y,
                                .color = self.active_theme.getStyle(tree_sitter.TokenCategory.categorizeCapture(token.capture_name)).fg,
                                .text = self.starting_whitespace,
                            });
                            pen.advanceX(text_metrics.advance.x + font_metrics.indentation_padding);
                        }

                        self.calculateTextMetrics(&text_metrics, word);
                        try drawableChunks.append(self.allocator, .{
                            .x = pen.x,
                            .y = pen.y,
                            .color = self.active_theme.getStyle(tree_sitter.TokenCategory.categorizeCapture(token.capture_name)).fg,
                            .text = word,
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
            _ = c.bl_context_set_fill_style_rgba32(&self.context, chunk.color);
            _ = c.bl_context_fill_utf8_text_d(&self.context, &c.BLPoint{ .x = chunk.x, .y = chunk.y }, &self.font, chunk.text.ptr, chunk.text.len);
        }
    }

    pub fn calculateTextMetrics(self: *Renderer, text_metrics: *c.BLTextMetrics, text: []const u8) void {
        _ = c.bl_glyph_buffer_set_text(&self.glyph_buffer, text.ptr, text.len, c.BL_TEXT_ENCODING_UTF8);
        _ = c.bl_font_shape(&self.font, &self.glyph_buffer);
        _ = c.bl_font_get_text_metrics(&self.font, &self.glyph_buffer, text_metrics);
    }

    pub fn initImage(self: *Renderer, last_line_y: f64) void {
        const width = @as(i32, @intFromFloat(self.code_window_options.width + 2 * self.code_window_options.margin_x));
        const height = @as(i32, @intFromFloat(self.code_window_options.heightFromLastY(last_line_y) + 2 * self.code_window_options.margin_y));
        _ = c.bl_image_init_as(&self.image, width, height, c.BL_FORMAT_PRGB32);
        _ = c.bl_context_init_as(&self.context, &self.image, null);
    }

    pub fn fillBackground(self: *Renderer) void {
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.bg);
        _ = c.bl_context_fill_all(&self.context);
    }

    pub fn drawCodeWindow(self: *Renderer) void {
        const rect = c.BLRoundRect{
            .x = self.code_window_options.x,
            .y = self.code_window_options.y,
            .w = self.code_window_options.width,
            .h = self.code_window_options.height,
            .rx = self.code_window_options.radius,
            .ry = self.code_window_options.radius,
        };
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.code_bg);
        _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);
    }

    pub fn drawCodeWindowControls(self: *Renderer) void {
        const colors = [_]u32{ 0xFFFF5F56, 0xFFFFBD2E, 0xFF27C93F };
        for (colors, 0..) |color, index| {
            const center_x = @as(f64, @floatFromInt(75 + (index * 20)));
            const center_y = @as(f64, @floatFromInt(75));
            const radius = @as(f64, @floatFromInt(6));
            const circle = c.BLCircle{ .cx = center_x, .cy = center_y, .r = radius };
            _ = c.bl_context_set_fill_style_rgba32(&self.context, color);
            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
        }
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
    indentation_padding: f64,
    margin_x: f32,
    margin_y: f32,
};

const DrawableChunk = struct {
    x: f64,
    y: f64,
    color: u32, // Hex, e.g. 0xFF6272A4
    text: []const u8,
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

const CodeWindowOptions = struct {
    x: f64,
    y: f64,
    margin_x: f64,
    margin_y: f64,
    width: f64,
    height: f64,
    radius: f64,

    pub fn heightFromLastY(self: *CodeWindowOptions, last_y: f64) f64 {
        const padding_bottom = 25.0;
        return last_y + padding_bottom - self.margin_y;
    }
};
