const std = @import("std");
// const tree_sitter = @import("tree-sitter.zig");
const root = @import("root.zig");
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

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.bl_font_face_reset(self.face);
        _ = c.bl_font_data_reset(self.font_data);
        _ = c.bl_glyph_buffer_reset(self.glyph_buffer);
        
        self.allocator.free(self.starting_whitespace);
    }

    // pub fn prepareTextRender(text: []const u8) void {
    //     _ = c.bl_glyph_buffer_set_text(gb, word.ptr, word.len, c.BL_TEXT_ENCODING_UTF8);
    //     _ = c.bl_font_shape(font, gb);
    //     _ = c.bl_font_get_text_metrics(font, gb, word_metrics);
    // }

    pub fn metrics(self: *Renderer) FontMetrics {
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
            .margin_x = 100.0,
            .margin_y = 100.0,
        };
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
