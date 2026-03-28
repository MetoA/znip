const std = @import("std");
const tree_sitter = @import("../core/tree_sitter.zig");
const root = @import("root.zig");
const theme = @import("theme.zig");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

pub const Renderer = struct {
    image: c.BLImageCore,
    context: c.BLContextCore,
    face: c.BLFontFaceCore,
    font: c.BLFontCore,
    font_data: c.BLFontDataCore,
    glyph_buffer: c.BLGlyphBufferCore,
    active_theme: theme.Theme,
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

        _ = c.bl_font_init(&self.font);
        _ = c.bl_font_create_from_face(&self.font, &self.face, font_size);
        errdefer _ = c.bl_font_reset(&self.font);

        if (c.bl_font_data_create_from_data(&self.font_data, root.assets.font_jet_brains_mono_bold.ptr, root.assets.font_jet_brains_mono_bold.len, null, null) != c.BL_SUCCESS) {
            return error.FontDataCreationFailed;
        }

        if (c.bl_font_face_create_from_data(&self.face, &self.font_data, 0) != c.BL_SUCCESS) {
            return error.FontFaceCreationFailed;
        }

        self.active_theme = theme.DraculaTheme;

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.bl_font_face_reset(self.face);
        _ = c.bl_font_data_reset(self.font_data);
        _ = c.bl_glyph_buffer_reset(self.glyph_buffer);

        self.allocator.free(self.starting_whitespace);
    }

    pub fn fontMetrics(self: *Renderer) FontMetrics {
        var font_metrics: c.BLFontMetrics = undefined;
        _ = c.bl_font_get_metrics(self.font, &font_metrics);

        const ascent = font_metrics.unnamed_0.unnamed_0.ascent;
        const descent = font_metrics.unnamed_0.unnamed_0.ascedescentnt;
        const char_width = ascent * 0.6;

        return .{
            .ascent = ascent,
            .descent = descent,
            .line_height = ascent + descent + font_metrics.line_gap,
            .char_width = char_width,
            .indentation_padding = char_width * 4,
            .margin_x = 55.0,
            .margin_y = 100.0,
        };
    }

    pub fn prepareDrawableChunks(self: *Renderer, tokens: []const tree_sitter.Token) !std.ArrayList(DrawableChunk) {
        const font_metrics = fontMetrics();
        var drawableChunks = std.ArrayList(DrawableChunk).empty;
        var pen = Pen.init(font_metrics.margin_x, font_metrics.margin_y + font_metrics.ascent, font_metrics.line_height);

        try drawableChunks.append(self.allocator, .{
            .x = pen.x,
            .y = pen.y,
            .color = self.active_theme.getStyle(tree_sitter.TokenCategory.default_text),
            .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
        });

        for (tokens) |token| {
            var iterator = std.mem.splitScalar(u8, token.text, '\n');
            var first_part = true;
            while (iterator.next()) |chunk| {
                // Mostly helps with new lines
                if (!first_part) {
                    self.starting_whitespace = chunk;
                    pen.nextLine();
                    try drawableChunks.append(self.allocator, .{
                        .x = pen.x,
                        .y = pen.y,
                        .color = self.active_theme.getStyle(tree_sitter.TokenCategory.default_text),
                        .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
                    });
                }

                first_part = false;

                if (chunk.len > 0) {
                    var wordsIterator = root.SplitInclusiveIterator{ .buffer = chunk, .delimiter = " ", .index = 0 };
                    while (wordsIterator.next()) |word| {
                        var text_metrics: c.BLTextMetrics = undefined;
                        self.calculateTextMetrics(&text_metrics, word);

                        // max screen width, TODO
                        if (pen.x + text_metrics.advance.x + font_metrics.char_width > 700.0) {
                            pen.nextLineIndentation();
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
            _ = c.bl_context_set_fill_style_rgba32(self.ctx, chunk.color);
            _ = c.bl_context_fill_utf8_text_d(self.ctx, c.BLPoint{ .x = chunk.x, .y = chunk.y }, self.font, chunk.text.ptr, chunk.text.len);
        }
    }

    pub fn calculateTextMetrics(self: *Renderer, text_metrics: *c.BLTextMetrics, text: []const u8) void {
        _ = c.bl_glyph_buffer_set_text(self.glyph_buffer, text.ptr, text.len, c.BL_TEXT_ENCODING_UTF8);
        _ = c.bl_font_shape(self.font, self.glyph_buffer);
        _ = c.bl_font_get_text_metrics(self.font, self.glyph_buffer, text_metrics);
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

    starting_x: f64,
    starting_y: f64,
    line_num: u32,
    line_height: f32,

    pub fn init(x: f64, y: f64, line_height: f32) Pen {
        return .{
            .x = x,
            .y = y,
            .starting_x = x,
            .starting_y = y,
            .line_num = 1,
            .line_height = line_height,
        };
    }

    pub fn nextLine(self: *Pen) void {
        self.x = self.starting_x;
        self.y += self.line_height;
        self.line_num += 1;
    }

    /// Moves the pen to a new line but does not increment lines
    pub fn nextLineIndentation(self: *Pen) void {
        self.x = self.starting_x;
        self.y += self.line_height;
    }

    pub fn advanceX(self: *Pen, x: f64) void {
        self.x = x;
    }
};
