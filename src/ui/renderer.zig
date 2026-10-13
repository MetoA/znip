const std = @import("std");
const tree_sitter = @import("../core/tree_sitter.zig");
const SplitInclusiveIterator = @import("../util/split_inclusive_iterator.zig").SplitInclusiveIterator;
const fonts = @import("../util/fonts.zig");
const Preset = @import("../core/config.zig").Preset;
const theme = @import("theme.zig");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

const code_window_min_width: f64 = 320.0;
const code_window_max_width: f64 = 900.0;
const code_window_right_slack: f64 = 30.0; // matches the previous 700 vs 720 gap
const code_window_gutter_width: f64 = 50.0; // matches the existing +50.0 in margin_x
const code_window_radius: f64 = 12.0;
const box_shadow_offset_x: f64 = 0.0;
const box_shadow_offset_y: f64 = 5.0;
const box_shadow_blur: f64 = 20.0;
const box_shadow_color: u32 = 0x10000000;
const line_continuation_arrow_width: f64 = 14.0;
// The window is sized so its widest line ends exactly on the wrap threshold;
// without a tolerance, floating-point noise from summing advances in a
// different order decides whether that line's last word wraps.
const wrap_tolerance: f64 = 0.01;

pub const Renderer = struct {
    image: c.BLImageCore = undefined,
    context: c.BLContextCore = undefined,
    face: c.BLFontFaceCore = undefined,
    font: c.BLFontCore = undefined,
    font_data: c.BLFontDataCore = undefined,
    glyph_buffer: c.BLGlyphBufferCore = undefined,
    preset: Preset,
    active_theme: theme.Theme,
    allocator: std.mem.Allocator,
    display_file_name: ?[]const u8 = null,
    content_width: f64 = code_window_min_width,

    pub fn init(allocator: std.mem.Allocator, preset: Preset, active_theme: theme.Theme, display_file_name: ?[]const u8) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;
        self.preset = preset;
        self.active_theme = active_theme;
        self.display_file_name = display_file_name;

        // Default-initialized here (not just at initImage() time) so that
        // deinit() is always safe to call, even if rendering fails before
        // initImage() runs (e.g. an unresolvable language via --lang) -
        // calling bl_image_reset/bl_context_reset on undefined memory is
        // undefined behavior in Blend2D.
        _ = c.bl_image_init(&self.image);
        errdefer _ = c.bl_image_reset(&self.image);

        _ = c.bl_context_init(&self.context);
        errdefer _ = c.bl_context_reset(&self.context);

        _ = c.bl_font_face_init(&self.face);
        errdefer _ = c.bl_font_face_reset(&self.face);

        _ = c.bl_font_data_init(&self.font_data);
        errdefer _ = c.bl_font_data_reset(&self.font_data);

        _ = c.bl_glyph_buffer_init(&self.glyph_buffer);
        errdefer _ = c.bl_glyph_buffer_reset(&self.glyph_buffer);

        const font_bytes = try fonts.loadFontBytes(allocator, self.preset.font);

        if (c.bl_font_data_create_from_data(&self.font_data, font_bytes.ptr, font_bytes.len, null, null) != c.BL_SUCCESS) {
            return error.FontDataCreationFailed;
        }

        if (c.bl_font_face_create_from_data(&self.face, &self.font_data, 0) != c.BL_SUCCESS) {
            return error.FontFaceCreationFailed;
        }

        _ = c.bl_font_init(&self.font);
        _ = c.bl_font_create_from_face(&self.font, &self.face, @floatFromInt(self.preset.font_size));
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
        const header_height: f32 = if (self.preset.window_controls or self.display_file_name != null) 50.0 else 20.0;

        return .{
            .ascent = ascent,
            .descent = descent,
            .line_height = ascent + descent + font_metrics.line_gap,
            .char_width = char_width,
            .margin_x = @as(f32, @floatFromInt(self.preset.horizontal_padding_px)) + 50.0,
            .margin_y = @as(f32, @floatFromInt(self.preset.vertical_padding_px)) + header_height,
        };
    }

    // Measures the widest source line's natural (unwrapped) rendered pixel
    // width, so the code window can be sized to the content instead of a
    // fixed constant.
    fn measureMaxLineWidth(self: *Renderer, tokens: []const tree_sitter.Token) f64 {
        var line_width: f64 = 0.0;
        var max_width: f64 = 0.0;

        for (tokens) |token| {
            var iterator = std.mem.splitScalar(u8, token.text, '\n');
            var first_part = true;
            while (iterator.next()) |chunk| {
                if (!first_part) {
                    if (line_width > max_width) max_width = line_width;
                    line_width = 0.0;
                }
                first_part = false;

                if (chunk.len > 0) {
                    var text_metrics: c.BLTextMetrics = undefined;
                    self.calculateTextMetrics(&text_metrics, chunk);
                    line_width += text_metrics.advance.x;
                }
            }
        }
        if (line_width > max_width) max_width = line_width;

        return max_width;
    }

    pub fn prepareDrawableChunks(self: *Renderer, tokens: []const tree_sitter.Token, starting_line: u32, highlight_lines: []const usize) !PreparedChunks {
        const font_metrics = self.fontMetrics();
        const pad_x = @as(f64, @floatFromInt(self.preset.horizontal_padding_px));

        const raw_max_line_width = self.measureMaxLineWidth(tokens);
        // + char_width to match the trailing safety margin the wrap check below adds
        // to every word (pen.x + advance + char_width > wrap_x), so a line that just
        // fits doesn't get pushed past the threshold by its own last word.
        const computed_width = code_window_gutter_width + raw_max_line_width + code_window_right_slack + @as(f64, font_metrics.char_width);
        self.content_width = std.math.clamp(computed_width, code_window_min_width, code_window_max_width);
        const wrap_x = pad_x + self.content_width - code_window_right_slack;

        var drawableChunks = std.ArrayList(DrawableChunk).empty;
        errdefer {
            for (drawableChunks.items) |d| {
                self.allocator.free(d.text);
            }
            drawableChunks.deinit(self.allocator);
        }
        var highlights = std.ArrayList(HighlightRect).empty;
        errdefer highlights.deinit(self.allocator);

        var pen = Pen.init(@as(f64, @floatFromInt(self.preset.horizontal_padding_px)) + 5.0, font_metrics.margin_x, font_metrics.margin_y + font_metrics.ascent, font_metrics.line_height, starting_line);

        // Tracks the vertical extent (top/bottom of the glyph box) of the
        // line currently being drawn, so a highlight rect can be emitted
        // once the line is known to be finished - including every wrapped
        // continuation row, which share the same line_num.
        var current_line_top = pen.y - font_metrics.ascent;
        var current_line_bottom = current_line_top + font_metrics.line_height;

        try drawableChunks.append(self.allocator, .{
            .x = pen.x,
            .y = pen.y,
            .color = if (lineIsHighlighted(highlight_lines, pen.line_num)) self.active_theme.ui.foreground else self.active_theme.ui.line_number,
            .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
        });
        pen.positionAtTextStart();
        for (tokens) |token| {
            var iterator = std.mem.splitScalar(u8, token.text, '\n');
            var first_part = true;
            while (iterator.next()) |chunk| {
                // Mostly helps with new lines
                if (!first_part) {
                    if (lineIsHighlighted(highlight_lines, pen.line_num)) {
                        try highlights.append(self.allocator, .{
                            .x = pad_x,
                            .y = current_line_top,
                            .w = self.content_width,
                            .h = current_line_bottom - current_line_top,
                        });
                    }

                    pen.nextLine();
                    pen.positionAtNumStart();
                    current_line_top = pen.y - font_metrics.ascent;
                    current_line_bottom = current_line_top + font_metrics.line_height;

                    try drawableChunks.append(self.allocator, .{
                        .x = pen.x,
                        .y = pen.y,
                        .color = if (lineIsHighlighted(highlight_lines, pen.line_num)) self.active_theme.ui.foreground else self.active_theme.ui.line_number,
                        .text = std.fmt.allocPrint(self.allocator, "{d: >3}", .{pen.line_num}) catch "   ",
                    });
                    pen.positionAtTextStart();
                }

                first_part = false;

                if (chunk.len > 0) {
                    var wordsIterator = SplitInclusiveIterator{ .buffer = chunk, .delimiter = " ", .index = 0 };
                    while (wordsIterator.next()) |raw_word| {
                        var word = raw_word;
                        var text_metrics: c.BLTextMetrics = undefined;
                        self.calculateTextMetrics(&text_metrics, word);

                        if (pen.x + text_metrics.advance.x + font_metrics.char_width > wrap_x + wrap_tolerance) {
                            try drawableChunks.append(self.allocator, .{
                                .type = ChunkType.wrap_indicator,
                                .x = pen.x + 5.0,
                                .y = pen.y,
                                .color = self.active_theme.getColor(tree_sitter.TokenCategory.default_text),
                            });
                            pen.nextLineIndentation();
                            current_line_bottom += font_metrics.line_height;
                            pen.positionAtTextStart();

                            try drawableChunks.append(self.allocator, .{
                                .type = ChunkType.line_continuation,
                                .x = pen.x,
                                .y = pen.y,
                                .color = self.active_theme.getColor(tree_sitter.TokenCategory.default_text),
                            });
                            pen.advanceX(line_continuation_arrow_width);

                            word = std.mem.trimLeft(u8, word, " ");
                            if (word.len == 0) continue;
                            self.calculateTextMetrics(&text_metrics, word);
                        }

                        try drawableChunks.append(self.allocator, .{
                            .x = pen.x,
                            .y = pen.y,
                            .color = self.active_theme.getColor(tree_sitter.TokenCategory.categorizeCapture(token.capture_name)),
                            .text = try self.allocator.dupe(u8, word),
                        });
                        pen.advanceX(text_metrics.advance.x);
                    }
                }
            }
        }

        if (lineIsHighlighted(highlight_lines, pen.line_num)) {
            try highlights.append(self.allocator, .{
                .x = pad_x,
                .y = current_line_top,
                .w = self.content_width,
                .h = current_line_bottom - current_line_top,
            });
        }

        return .{ .chunks = drawableChunks, .highlights = highlights };
    }

    pub fn drawChunks(self: *Renderer, chunks: []DrawableChunk) !void {
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
        const pad_x = @as(f64, @floatFromInt(self.preset.horizontal_padding_px));
        const pad_y = @as(f64, @floatFromInt(self.preset.vertical_padding_px));
        const width = @as(i32, @intFromFloat(self.content_width + 2 * pad_x));
        const height = @as(i32, @intFromFloat(last_line_y + 25.0 + pad_y));
        // self.image/self.context are already default-initialized (in
        // init()), so we (re)create/begin against them rather than
        // "_init_as", which assumes uninitialized memory.
        _ = c.bl_image_create(&self.image, width, height, c.BL_FORMAT_PRGB32);
        _ = c.bl_context_begin(&self.context, &self.image, null);
    }

    pub fn fillBackground(self: *Renderer) void {
        if (self.preset.transparent_background) {
            // bl_image_create doesn't zero the pixel buffer, so a transparent
            // canvas has to be cleared explicitly or it shows stale memory.
            _ = c.bl_context_clear_all(&self.context);
            return;
        }
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.ui.background);
        _ = c.bl_context_fill_all(&self.context);
    }

    pub fn drawCodeWindow(self: *Renderer, last_line_y: f64) !void {
        const pad_x = @as(f64, @floatFromInt(self.preset.horizontal_padding_px));
        const pad_y = @as(f64, @floatFromInt(self.preset.vertical_padding_px));
        const rect = c.BLRoundRect{
            .x = pad_x,
            .y = pad_y,
            .w = self.content_width,
            .h = last_line_y + 25.0 - pad_y,
            .rx = code_window_radius,
            .ry = code_window_radius,
        };

        if (self.preset.include_drop_shadow) {
            try self.drawBoxShadow(rect);
        }
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.ui.code_window_background);
        _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);
    }

    pub fn drawHighlights(self: *Renderer, rects: []const HighlightRect) void {
        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.ui.highlight_background);
        for (rects) |rect| {
            const bl_rect = c.BLRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_RECTD, &bl_rect);
        }
    }

    // Fake blur by rendering multiple gray rectangles with decreasing alpha values as they spread out
    fn drawBoxShadow(self: *Renderer, code_rect: c.BLRoundRect) !void {
        const passes: usize = 12;

        var pass: usize = 0;
        while (pass < passes) : (pass += 1) {
            const spread_range = @as(f64, @floatFromInt(passes - pass)) / @as(f64, @floatFromInt(passes));
            const spread = box_shadow_blur * spread_range;

            // Alpha fades out toward the outer passes
            const base_alpha: f64 = @as(f64, @floatFromInt((box_shadow_color >> 24) & 0xFF));
            const alpha = @as(u32, @intFromFloat(base_alpha * (1.0 - spread_range) * (2.0 / @as(f64, @floatFromInt(passes)))));
            const color = (alpha << 24) | (box_shadow_color & 0x00FFFFFF);

            _ = c.bl_context_set_fill_style_rgba32(&self.context, color);

            var rect = c.BLRoundRect{
                .x = code_rect.x + box_shadow_offset_x - spread,
                .y = code_rect.y + box_shadow_offset_y - spread,
                .w = code_rect.w + spread * 2.0,
                .h = code_rect.h + spread * 2.0,
                .rx = code_rect.rx,
                .ry = code_rect.ry,
            };

            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);
        }
    }

    pub fn drawCodeWindowControls(self: *Renderer) void {
        if (!self.preset.window_controls) return;

        const colors = [_]u32{
            self.active_theme.ui.window_close,
            self.active_theme.ui.window_minimize,
            self.active_theme.ui.window_expand,
        };
        const pad_x = @as(f64, @floatFromInt(self.preset.horizontal_padding_px));
        const pad_y = @as(f64, @floatFromInt(self.preset.vertical_padding_px));
        for (colors, 0..) |color, index| {
            const center_x = pad_x + 25.0 + @as(f64, @floatFromInt(index * 20));
            const center_y = pad_y + 25.0;
            const radius = @as(f64, @floatFromInt(6));
            const circle = c.BLCircle{ .cx = center_x, .cy = center_y, .r = radius };
            _ = c.bl_context_set_fill_style_rgba32(&self.context, color);
            _ = c.bl_context_fill_geometry(&self.context, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
        }
    }

    pub fn drawFileName(self: *Renderer) void {
        const name = self.display_file_name orelse return;

        const pad_x = @as(f64, @floatFromInt(self.preset.horizontal_padding_px));
        const pad_y = @as(f64, @floatFromInt(self.preset.vertical_padding_px));
        const start_x = if (self.preset.window_controls) pad_x + 90.0 else pad_x + 25.0;
        const baseline_y = pad_y + 25.0 + @as(f64, self.fontMetrics().ascent / 4.0);

        _ = c.bl_context_set_fill_style_rgba32(&self.context, self.active_theme.ui.line_number);
        _ = c.bl_context_fill_utf8_text_d(&self.context, &c.BLPoint{ .x = start_x, .y = baseline_y }, &self.font, name.ptr, name.len);
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
        const size: f64 = line_continuation_arrow_width - 6.0;
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

    pub fn saveImage(self: *Renderer, file_name: []const u8) !void {
        var codec: c.BLImageCodecCore = undefined;
        _ = c.bl_image_codec_init(&codec);
        defer _ = c.bl_image_codec_reset(&codec);

        if (c.bl_image_codec_find_by_name(&codec, "PNG", @intCast("PNG".len), null) != c.BL_SUCCESS) {
            return error.ImageWriteFailed;
        }
        if (c.bl_image_write_to_file(&self.image, file_name.ptr, &codec) != c.BL_SUCCESS) {
            return error.ImageWriteFailed;
        }
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

pub const HighlightRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const PreparedChunks = struct {
    chunks: std.ArrayList(DrawableChunk),
    highlights: std.ArrayList(HighlightRect),
};

// `highlight_lines` is small and sorted (see cli.zig's parseHighlightSpec),
// so a linear scan per line is fine.
fn lineIsHighlighted(highlight_lines: []const usize, line_num: u32) bool {
    for (highlight_lines) |line| {
        if (line == line_num) return true;
    }
    return false;
}

// TODO might be better to remove the line logic? and starting positions? just to separate stuff
const Pen = struct {
    x: f64,
    y: f64,

    num_starting_x: f64,
    text_starting_x: f64,
    starting_y: f64,
    line_num: u32,
    line_height: f32,

    pub fn init(num_x: f64, text_x: f64, y: f64, line_height: f32, starting_line: u32) Pen {
        return .{
            .x = num_x,
            .y = y,
            .num_starting_x = num_x,
            .text_starting_x = text_x,
            .starting_y = y,
            .line_num = starting_line,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Token = tree_sitter.Token;

fn testPreset() Preset {
    return .{
        .name = "test",
        .theme = "One Darker",
        .font = fonts.default_font_name,
        .font_size = 16,
        .window_controls = true,
        .show_file_name = true,
        .vertical_padding_px = 40,
        .horizontal_padding_px = 40,
        .include_drop_shadow = false,
        .transparent_background = false,
    };
}

fn tok(text: []const u8, capture: []const u8) Token {
    return .{ .text = text, .capture_name = capture, .is_newline = false };
}

const newline_token = Token{ .text = "\n", .capture_name = "", .is_newline = true };

fn newRenderer(allocator: std.mem.Allocator, preset: Preset, file_name: ?[]const u8) !Renderer {
    return Renderer.init(allocator, preset, theme.OneDarker, file_name);
}

/// Mirrors the drawing pipeline in `root.renderImage`, stopping before the PNG
/// is written so the in-memory image can be inspected.
fn drawAll(r: *Renderer, tokens: []const Token, starting_line: u32, highlight_lines: []const usize) !void {
    var prepared = try r.prepareDrawableChunks(tokens, starting_line, highlight_lines);
    const last_y: f64 = if (prepared.chunks.items.len > 0) prepared.chunks.getLast().y else 300.0;
    r.initImage(last_y);
    r.fillBackground();
    try r.drawCodeWindow(last_y);
    r.drawHighlights(prepared.highlights.items);
    r.drawCodeWindowControls();
    r.drawFileName();
    try r.drawChunks(prepared.chunks.items);
}

fn imageData(r: *Renderer) c.BLImageData {
    var data: c.BLImageData = undefined;
    _ = c.bl_image_get_data(&r.image, &data);
    return data;
}

fn imageWidth(r: *Renderer) usize {
    return @intCast(imageData(r).size.w);
}

fn imageHeight(r: *Renderer) usize {
    return @intCast(imageData(r).size.h);
}

/// Premultiplied 0xAARRGGBB.
fn pixelAt(r: *Renderer, x: usize, y: usize) u32 {
    const data = imageData(r);
    const base: [*]const u8 = @ptrCast(data.pixel_data.?);
    const stride: usize = @intCast(data.stride);
    const p: *align(1) const u32 = @ptrCast(base + y * stride + x * 4);
    return p.*;
}

/// A copy of every pixel row, for whole-image comparisons.
fn snapshot(allocator: std.mem.Allocator, r: *Renderer) ![]u8 {
    const data = imageData(r);
    const w = imageWidth(r);
    const h = imageHeight(r);
    const base: [*]const u8 = @ptrCast(data.pixel_data.?);
    const stride: usize = @intCast(data.stride);

    const out = try allocator.alloc(u8, w * h * 4);
    for (0..h) |row| {
        @memcpy(out[row * w * 4 ..][0 .. w * 4], base[row * stride ..][0 .. w * 4]);
    }
    return out;
}

fn countType(chunks: []const DrawableChunk, chunk_type: ChunkType) usize {
    var n: usize = 0;
    for (chunks) |chunk| {
        if (chunk.type == chunk_type) n += 1;
    }
    return n;
}

/// Line-number chunks are the text chunks drawn in the gutter, left of the code.
fn lineNumberChunks(allocator: std.mem.Allocator, r: *Renderer, chunks: []const DrawableChunk) ![]DrawableChunk {
    const text_x = @as(f64, @floatFromInt(r.preset.horizontal_padding_px)) + 50.0;
    var out = std.ArrayList(DrawableChunk).empty;
    for (chunks) |chunk| {
        if (chunk.type == .text and chunk.x < text_x) try out.append(allocator, chunk);
    }
    return out.toOwnedSlice(allocator);
}

fn codeText(allocator: std.mem.Allocator, r: *Renderer, chunks: []const DrawableChunk) ![]u8 {
    const text_x = @as(f64, @floatFromInt(r.preset.horizontal_padding_px)) + 50.0;
    var out = std.ArrayList(u8).empty;
    for (chunks) |chunk| {
        if (chunk.type == .text and chunk.x >= text_x) try out.appendSlice(allocator, chunk.text);
    }
    return out.toOwnedSlice(allocator);
}

test "lineIsHighlighted finds a line in the list" {
    try std.testing.expect(lineIsHighlighted(&.{ 2, 5, 9 }, 5));
    try std.testing.expect(lineIsHighlighted(&.{7}, 7));
}

test "lineIsHighlighted is false for absent lines and an empty list" {
    try std.testing.expect(!lineIsHighlighted(&.{ 2, 5, 9 }, 4));
    try std.testing.expect(!lineIsHighlighted(&.{ 2, 5, 9 }, 0));
    try std.testing.expect(!lineIsHighlighted(&.{}, 1));
}

test "Pen starts at the line-number column" {
    const pen = Pen.init(45.0, 90.0, 120.0, 20.0, 7);
    try std.testing.expectEqual(@as(f64, 45.0), pen.x);
    try std.testing.expectEqual(@as(f64, 120.0), pen.y);
    try std.testing.expectEqual(@as(u32, 7), pen.line_num);
}

test "Pen.nextLine moves down one line and increments the line number" {
    var pen = Pen.init(0, 0, 100.0, 20.0, 1);
    pen.nextLine();
    pen.nextLine();
    try std.testing.expectEqual(@as(f64, 140.0), pen.y);
    try std.testing.expectEqual(@as(u32, 3), pen.line_num);
}

test "Pen.nextLineIndentation moves down without changing the line number" {
    var pen = Pen.init(0, 0, 100.0, 20.0, 4);
    pen.nextLineIndentation();
    try std.testing.expectEqual(@as(f64, 120.0), pen.y);
    try std.testing.expectEqual(@as(u32, 4), pen.line_num);
}

test "Pen horizontal moves" {
    var pen = Pen.init(45.0, 90.0, 0, 20.0, 1);
    pen.positionAtTextStart();
    try std.testing.expectEqual(@as(f64, 90.0), pen.x);
    pen.advanceX(10.5);
    pen.advanceX(4.5);
    try std.testing.expectEqual(@as(f64, 105.0), pen.x);
    pen.positionAtNumStart();
    try std.testing.expectEqual(@as(f64, 45.0), pen.x);
    // Horizontal moves never touch the vertical position.
    try std.testing.expectEqual(@as(f64, 0), pen.y);
}

test "Pen vertical moves leave the column alone" {
    var pen = Pen.init(45.0, 90.0, 0, 20.0, 1);
    pen.advanceX(10.0);
    pen.nextLine();
    try std.testing.expectEqual(@as(f64, 55.0), pen.x);
}

test "Renderer init and deinit with the bundled font" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    r.deinit();
}

test "fontMetrics derives layout values from the font and preset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const m = r.fontMetrics();
    try std.testing.expect(m.ascent > 0);
    try std.testing.expect(m.descent > 0);
    try std.testing.expect(m.line_height >= m.ascent + m.descent);
    try std.testing.expectApproxEqAbs(m.ascent * 0.6, m.char_width, 1e-4);
    try std.testing.expectEqual(@as(f32, 90.0), m.margin_x); // 40 + 50
    try std.testing.expectEqual(@as(f32, 90.0), m.margin_y); // 40 + 50 header
}

test "fontMetrics header is shorter without window controls or a file name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var preset = testPreset();
    preset.window_controls = false;

    var bare = try newRenderer(arena.allocator(), preset, null);
    defer bare.deinit();
    try std.testing.expectEqual(@as(f32, 60.0), bare.fontMetrics().margin_y); // 40 + 20

    var named = try newRenderer(arena.allocator(), preset, "main.zig");
    defer named.deinit();
    try std.testing.expectEqual(@as(f32, 90.0), named.fontMetrics().margin_y); // file name needs the tall header

    preset.window_controls = true;
    var controls = try newRenderer(arena.allocator(), preset, null);
    defer controls.deinit();
    try std.testing.expectEqual(@as(f32, 90.0), controls.fontMetrics().margin_y);
}

test "fontMetrics scales with the font size and padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var small_preset = testPreset();
    small_preset.font_size = 12;
    var large_preset = testPreset();
    large_preset.font_size = 24;
    large_preset.horizontal_padding_px = 100;
    large_preset.vertical_padding_px = 10;

    var small = try newRenderer(arena.allocator(), small_preset, null);
    defer small.deinit();
    var large = try newRenderer(arena.allocator(), large_preset, null);
    defer large.deinit();

    const sm = small.fontMetrics();
    const lm = large.fontMetrics();
    try std.testing.expectApproxEqAbs(sm.line_height * 2.0, lm.line_height, 0.1);
    try std.testing.expectApproxEqAbs(sm.char_width * 2.0, lm.char_width, 0.01);
    try std.testing.expectEqual(@as(f32, 150.0), lm.margin_x);
    try std.testing.expectEqual(@as(f32, 60.0), lm.margin_y);
}

test "measureMaxLineWidth of nothing is zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), r.measureMaxLineWidth(&.{}));
    try std.testing.expectEqual(@as(f64, 0.0), r.measureMaxLineWidth(&.{newline_token}));
}

test "measureMaxLineWidth scales with the number of characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const one = r.measureMaxLineWidth(&.{tok("a", "x")});
    const four = r.measureMaxLineWidth(&.{tok("abcd", "x")});
    try std.testing.expect(one > 0);
    // The bundled font is monospaced.
    try std.testing.expectApproxEqAbs(one * 4.0, four, 0.01);
}

test "measureMaxLineWidth takes the widest line, wherever it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const widest = r.measureMaxLineWidth(&.{tok("abcdef", "x")});
    try std.testing.expectApproxEqAbs(widest, r.measureMaxLineWidth(&.{tok("ab\nabcdef\nabc", "x")}), 0.01);
    try std.testing.expectApproxEqAbs(widest, r.measureMaxLineWidth(&.{ tok("abcdef", "x"), newline_token, tok("ab", "x") }), 0.01);
    try std.testing.expectApproxEqAbs(widest, r.measureMaxLineWidth(&.{ tok("ab", "x"), newline_token, tok("abcdef", "x") }), 0.01);
}

test "measureMaxLineWidth sums tokens that share a line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const whole = r.measureMaxLineWidth(&.{tok("abcd", "x")});
    const split = r.measureMaxLineWidth(&.{ tok("ab", "x"), tok("", ""), tok("cd", "y") });
    try std.testing.expectApproxEqAbs(whole, split, 0.01);
}

test "prepareDrawableChunks emits a line number then each word of a single line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{ tok("fn", "keyword"), tok(" ", ""), tok("main", "function") }, 1, &.{});
    const chunks = prepared.chunks.items;
    const m = r.fontMetrics();

    try std.testing.expectEqual(@as(usize, 4), chunks.len);
    try std.testing.expectEqualStrings("  1", chunks[0].text);
    try std.testing.expectEqualStrings("fn", chunks[1].text);
    try std.testing.expectEqualStrings(" ", chunks[2].text);
    try std.testing.expectEqualStrings("main", chunks[3].text);

    // Gutter first, then the code, left to right on one baseline.
    try std.testing.expectEqual(@as(f64, 45.0), chunks[0].x);
    try std.testing.expectEqual(@as(f64, m.margin_x), chunks[1].x);
    try std.testing.expect(chunks[2].x > chunks[1].x);
    try std.testing.expect(chunks[3].x > chunks[2].x);
    for (chunks) |chunk| try std.testing.expectApproxEqAbs(@as(f64, m.margin_y + m.ascent), chunk.y, 1e-4);

    try std.testing.expectEqual(@as(usize, 0), prepared.highlights.items.len);
}

test "prepareDrawableChunks colors tokens from the theme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{ tok("fn", "keyword"), tok("x", "number"), tok("?", "mystery.capture"), tok("y", "") }, 1, &.{});
    const chunks = prepared.chunks.items;

    try std.testing.expectEqual(r.active_theme.getColor(.keyword), chunks[1].color);
    try std.testing.expectEqual(r.active_theme.getColor(.number), chunks[2].color);
    // Unknown and missing captures use the default text color.
    try std.testing.expectEqual(r.active_theme.ui.foreground, chunks[3].color);
    try std.testing.expectEqual(r.active_theme.ui.foreground, chunks[4].color);
    // Line numbers are dimmed.
    try std.testing.expectEqual(r.active_theme.ui.line_number, chunks[0].color);
}

test "prepareDrawableChunks numbers each line and steps down one line height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{ tok("a", "x"), newline_token, tok("b", "x"), newline_token, tok("c", "x") }, 1, &.{});
    const numbers = try lineNumberChunks(allocator, &r, prepared.chunks.items);
    const m = r.fontMetrics();

    try std.testing.expectEqual(@as(usize, 3), numbers.len);
    try std.testing.expectEqualStrings("  1", numbers[0].text);
    try std.testing.expectEqualStrings("  2", numbers[1].text);
    try std.testing.expectEqualStrings("  3", numbers[2].text);
    try std.testing.expectApproxEqAbs(numbers[0].y + m.line_height, numbers[1].y, 1e-3);
    try std.testing.expectApproxEqAbs(numbers[1].y + m.line_height, numbers[2].y, 1e-3);

    const text = try codeText(allocator, &r, prepared.chunks.items);
    try std.testing.expectEqualStrings("abc", text);
}

test "prepareDrawableChunks splits a multi-line token into numbered lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{tok("/* a\n b\n c */", "comment")}, 1, &.{});
    const numbers = try lineNumberChunks(allocator, &r, prepared.chunks.items);
    try std.testing.expectEqual(@as(usize, 3), numbers.len);
    try std.testing.expectEqualStrings("  3", numbers[2].text);
}

test "prepareDrawableChunks of no tokens is just the first line number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{}, 1, &.{});
    try std.testing.expectEqual(@as(usize, 1), prepared.chunks.items.len);
    try std.testing.expectEqualStrings("  1", prepared.chunks.items[0].text);
    try std.testing.expectEqual(code_window_min_width, r.content_width);
}

test "prepareDrawableChunks starts numbering at the requested line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{ tok("a", "x"), newline_token, tok("b", "x"), newline_token, tok("c", "x") }, 98, &.{});
    const numbers = try lineNumberChunks(allocator, &r, prepared.chunks.items);
    try std.testing.expectEqualStrings(" 98", numbers[0].text);
    try std.testing.expectEqualStrings(" 99", numbers[1].text);
    try std.testing.expectEqualStrings("100", numbers[2].text);
}

test "prepareDrawableChunks brightens highlighted line numbers only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{ tok("a", "x"), newline_token, tok("b", "x"), newline_token, tok("c", "x") }, 1, &.{2});
    const numbers = try lineNumberChunks(allocator, &r, prepared.chunks.items);
    try std.testing.expectEqual(r.active_theme.ui.line_number, numbers[0].color);
    try std.testing.expectEqual(r.active_theme.ui.foreground, numbers[1].color);
    try std.testing.expectEqual(r.active_theme.ui.line_number, numbers[2].color);
}

test "prepareDrawableChunks emits one highlight rectangle per highlighted line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const tokens = [_]Token{ tok("a", "x"), newline_token, tok("b", "x"), newline_token, tok("c", "x") };
    const prepared = try r.prepareDrawableChunks(&tokens, 1, &.{ 1, 3 });
    const m = r.fontMetrics();

    try std.testing.expectEqual(@as(usize, 2), prepared.highlights.items.len);
    const first = prepared.highlights.items[0];
    const last = prepared.highlights.items[1];

    try std.testing.expectEqual(@as(f64, 40.0), first.x);
    try std.testing.expectEqual(r.content_width, first.w);
    try std.testing.expectApproxEqAbs(@as(f64, m.margin_y), first.y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, m.line_height), first.h, 1e-3);
    // The final line has no trailing newline but is still highlighted.
    try std.testing.expectApproxEqAbs(@as(f64, m.margin_y + 2 * m.line_height), last.y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, m.line_height), last.h, 1e-3);
}

test "prepareDrawableChunks ignores highlight lines outside the rendered range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const tokens = [_]Token{ tok("a", "x"), newline_token, tok("b", "x") };
    const prepared = try r.prepareDrawableChunks(&tokens, 10, &.{ 1, 9, 12, 500 });
    try std.testing.expectEqual(@as(usize, 0), prepared.highlights.items.len);
}

test "prepareDrawableChunks highlight lines use the starting line offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const tokens = [_]Token{ tok("a", "x"), newline_token, tok("b", "x") };
    const prepared = try r.prepareDrawableChunks(&tokens, 10, &.{11});
    const m = r.fontMetrics();

    try std.testing.expectEqual(@as(usize, 1), prepared.highlights.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, m.margin_y + m.line_height), prepared.highlights.items[0].y, 1e-3);
}

test "prepareDrawableChunks highlights a single-line source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{tok("only", "x")}, 1, &.{1});
    try std.testing.expectEqual(@as(usize, 1), prepared.highlights.items.len);
}

test "prepareDrawableChunks sizes the window to the widest line within the limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    // Short code: the minimum width.
    _ = try r.prepareDrawableChunks(&.{tok("a", "x")}, 1, &.{});
    try std.testing.expectEqual(code_window_min_width, r.content_width);

    // A line in between is sized to fit: gutter + line + slack + one char.
    const medium = [_]Token{tok("x" ** 50, "x")};
    _ = try r.prepareDrawableChunks(&medium, 1, &.{});
    const expected = code_window_gutter_width + r.measureMaxLineWidth(&medium) + code_window_right_slack + @as(f64, r.fontMetrics().char_width);
    try std.testing.expect(expected > code_window_min_width and expected < code_window_max_width);
    try std.testing.expectApproxEqAbs(expected, r.content_width, 1e-6);

    // A very long line: capped at the maximum width.
    const long = [_]Token{tok("x" ** 400, "x")};
    _ = try r.prepareDrawableChunks(&long, 1, &.{});
    try std.testing.expectEqual(code_window_max_width, r.content_width);
}

test "prepareDrawableChunks keeps every word of a line that fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{tok("a b  c", "x")}, 1, &.{});
    try std.testing.expectEqual(@as(usize, 0), countType(prepared.chunks.items, .wrap_indicator));
    try std.testing.expectEqual(@as(usize, 0), countType(prepared.chunks.items, .line_continuation));
    try std.testing.expectEqualStrings("a b  c", try codeText(allocator, &r, prepared.chunks.items));
}

test "prepareDrawableChunks wraps an over-long line without renumbering it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const long_line = "word " ** 200;
    const prepared = try r.prepareDrawableChunks(&.{tok(long_line, "string")}, 1, &.{1});
    const chunks = prepared.chunks.items;
    const m = r.fontMetrics();

    try std.testing.expectEqual(code_window_max_width, r.content_width);

    const wraps = countType(chunks, .wrap_indicator);
    try std.testing.expect(wraps > 0);
    try std.testing.expectEqual(wraps, countType(chunks, .line_continuation));

    // Still one logical line: one number, and no word spills past the window.
    const numbers = try lineNumberChunks(allocator, &r, chunks);
    try std.testing.expectEqual(@as(usize, 1), numbers.len);
    const wrap_x = 40.0 + r.content_width - code_window_right_slack;
    for (chunks) |chunk| {
        if (chunk.type == .text and chunk.x >= 90.0) try std.testing.expect(chunk.x < wrap_x);
    }

    // The highlight spans every wrapped row.
    try std.testing.expectEqual(@as(usize, 1), prepared.highlights.items.len);
    const rows: f64 = @floatFromInt(wraps + 1);
    try std.testing.expectApproxEqAbs(rows * m.line_height, prepared.highlights.items[0].h, 1e-3);

    // The text itself is untouched apart from where lines were cut.
    const text = try codeText(allocator, &r, chunks);
    try std.testing.expect(std.mem.startsWith(u8, text, "word word"));
}

test "prepareDrawableChunks lays a wrapped line out on successive rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{tok("word " ** 200, "string")}, 1, &.{});
    const chunks = prepared.chunks.items;
    const m = r.fontMetrics();

    var indicator_y: ?f64 = null;
    var continuation_y: ?f64 = null;
    for (chunks) |chunk| {
        if (chunk.type == .wrap_indicator and indicator_y == null) indicator_y = chunk.y;
        if (chunk.type == .line_continuation and continuation_y == null) continuation_y = chunk.y;
    }
    // The wrap arrow is drawn on the row being left; the continuation arrow starts the next one.
    try std.testing.expectApproxEqAbs(indicator_y.? + m.line_height, continuation_y.?, 1e-3);
}

test "prepareDrawableChunks handles multi-byte text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();

    const prepared = try r.prepareDrawableChunks(&.{tok("héllo ✓ wörld", "string")}, 1, &.{});
    try std.testing.expectEqualStrings("héllo ✓ wörld", try codeText(allocator, &r, prepared.chunks.items));
}

test "initImage sizes the canvas from the window width, padding and last line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var preset = testPreset();
    preset.horizontal_padding_px = 10;
    preset.vertical_padding_px = 20;
    var r = try newRenderer(arena.allocator(), preset, null);
    defer r.deinit();

    r.content_width = 400.0;
    r.initImage(100.5);
    try std.testing.expectEqual(@as(usize, 420), imageWidth(&r)); // 400 + 2 * 10
    try std.testing.expectEqual(@as(usize, 145), imageHeight(&r)); // 100.5 + 25 + 20, truncated
}

test "fillBackground paints the theme background" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});
    try std.testing.expectEqual(r.active_theme.ui.background, pixelAt(&r, 0, 0));
    try std.testing.expectEqual(r.active_theme.ui.background, pixelAt(&r, imageWidth(&r) - 1, imageHeight(&r) - 1));
}

test "a transparent canvas leaves the outer area clear but keeps the window opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var preset = testPreset();
    preset.transparent_background = true;
    var r = try newRenderer(arena.allocator(), preset, null);
    defer r.deinit();

    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});
    try std.testing.expectEqual(@as(u32, 0), pixelAt(&r, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), pixelAt(&r, imageWidth(&r) - 1, 0));

    const inside_x: usize = @intFromFloat(40.0 + r.content_width - 20.0);
    try std.testing.expectEqual(r.active_theme.ui.code_window_background, pixelAt(&r, inside_x, 70));
}

test "the code window is filled with its own background" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});
    const inside_x: usize = @intFromFloat(40.0 + r.content_width - 20.0);
    try std.testing.expectEqual(r.active_theme.ui.code_window_background, pixelAt(&r, inside_x, 70));
    // Just inside the left edge, away from the controls row and text.
    try std.testing.expectEqual(r.active_theme.ui.code_window_background, pixelAt(&r, 44, 45));
}

test "window controls are drawn in the theme's colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});
    // Centers at (pad + 25 + 20 * i, pad + 25).
    try std.testing.expectEqual(r.active_theme.ui.window_close, pixelAt(&r, 65, 65));
    try std.testing.expectEqual(r.active_theme.ui.window_minimize, pixelAt(&r, 85, 65));
    try std.testing.expectEqual(r.active_theme.ui.window_expand, pixelAt(&r, 105, 65));
}

test "window controls are omitted when disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var preset = testPreset();
    preset.window_controls = false;
    var r = try newRenderer(arena.allocator(), preset, null);
    defer r.deinit();

    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});
    try std.testing.expectEqual(r.active_theme.ui.code_window_background, pixelAt(&r, 65, 65));
}

test "the drop shadow only appears when enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The shadow is faint (alpha <= 2), so it needs a light background to show up.
    var flat = try Renderer.init(arena.allocator(), testPreset(), theme.PaperWhite, null);
    defer flat.deinit();
    try drawAll(&flat, &.{tok("a", "x")}, 1, &.{});

    var preset = testPreset();
    preset.include_drop_shadow = true;
    var shadowed = try Renderer.init(arena.allocator(), preset, theme.PaperWhite, null);
    defer shadowed.deinit();
    try drawAll(&shadowed, &.{tok("a", "x")}, 1, &.{});

    // Same canvas, so the pixel just under the window's bottom edge is comparable.
    try std.testing.expectEqual(imageHeight(&flat), imageHeight(&shadowed));
    const below_y = imageHeight(&flat) - 40 + 2;
    const x = imageWidth(&flat) / 2;
    try std.testing.expectEqual(flat.active_theme.ui.background, pixelAt(&flat, x, below_y));
    try std.testing.expect(pixelAt(&shadowed, x, below_y) != shadowed.active_theme.ui.background);
    // The shadow never reaches the canvas corner.
    try std.testing.expectEqual(shadowed.active_theme.ui.background, pixelAt(&shadowed, 0, 0));
}

test "a highlighted line is tinted across the window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var plain = try newRenderer(arena.allocator(), testPreset(), null);
    defer plain.deinit();
    try drawAll(&plain, &.{tok("a", "x")}, 1, &.{});

    var marked = try newRenderer(arena.allocator(), testPreset(), null);
    defer marked.deinit();
    try drawAll(&marked, &.{tok("a", "x")}, 1, &.{1});

    const x: usize = @intFromFloat(40.0 + plain.content_width - 20.0);
    const y: usize = 94; // inside the first line's band (margin_y = 90)
    try std.testing.expectEqual(plain.active_theme.ui.code_window_background, pixelAt(&plain, x, y));
    try std.testing.expect(pixelAt(&marked, x, y) != marked.active_theme.ui.code_window_background);
}

test "the file name is only drawn when one is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var unnamed = try newRenderer(allocator, testPreset(), null);
    defer unnamed.deinit();
    try drawAll(&unnamed, &.{tok("a", "x")}, 1, &.{});

    var named = try newRenderer(allocator, testPreset(), "main.zig");
    defer named.deinit();
    try drawAll(&named, &.{tok("a", "x")}, 1, &.{});

    try std.testing.expectEqual(imageWidth(&unnamed), imageWidth(&named));
    try std.testing.expect(!std.mem.eql(u8, try snapshot(allocator, &unnamed), try snapshot(allocator, &named)));
}

test "drawing text changes the image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var empty = try newRenderer(allocator, testPreset(), null);
    defer empty.deinit();
    try drawAll(&empty, &.{}, 1, &.{});

    var filled = try newRenderer(allocator, testPreset(), null);
    defer filled.deinit();
    try drawAll(&filled, &.{tok("const x = 1;", "keyword")}, 1, &.{});

    try std.testing.expect(!std.mem.eql(u8, try snapshot(allocator, &empty), try snapshot(allocator, &filled)));
}

test "more lines make a taller image of the same width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var short = try newRenderer(allocator, testPreset(), null);
    defer short.deinit();
    try drawAll(&short, &.{tok("a", "x")}, 1, &.{});

    var tall = try newRenderer(allocator, testPreset(), null);
    defer tall.deinit();
    const lines = [_]Token{ tok("a", "x"), newline_token, tok("b", "x"), newline_token, tok("c", "x"), newline_token, tok("d", "x") };
    try drawAll(&tall, &lines, 1, &.{});

    try std.testing.expectEqual(imageWidth(&short), imageWidth(&tall));
    try std.testing.expect(imageHeight(&tall) > imageHeight(&short));
    const line_height: usize = @intFromFloat(short.fontMetrics().line_height);
    try std.testing.expect(imageHeight(&tall) - imageHeight(&short) >= 3 * line_height - 3);
}

test "padding grows the image on every side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tight_preset = testPreset();
    tight_preset.horizontal_padding_px = 10;
    tight_preset.vertical_padding_px = 10;
    var tight = try newRenderer(allocator, tight_preset, null);
    defer tight.deinit();
    try drawAll(&tight, &.{tok("a", "x")}, 1, &.{});

    var roomy_preset = testPreset();
    roomy_preset.horizontal_padding_px = 60;
    roomy_preset.vertical_padding_px = 30;
    var roomy = try newRenderer(allocator, roomy_preset, null);
    defer roomy.deinit();
    try drawAll(&roomy, &.{tok("a", "x")}, 1, &.{});

    try std.testing.expectEqual(imageWidth(&tight) + 100, imageWidth(&roomy));
    try std.testing.expect(imageHeight(&roomy) > imageHeight(&tight));
}

test "rendering is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tokens = [_]Token{ tok("fn", "keyword"), tok(" ", ""), tok("main", "function"), newline_token, tok("x", "variable") };

    var first = try newRenderer(allocator, testPreset(), "a.zig");
    defer first.deinit();
    try drawAll(&first, &tokens, 1, &.{2});

    var second = try newRenderer(allocator, testPreset(), "a.zig");
    defer second.deinit();
    try drawAll(&second, &tokens, 1, &.{2});

    try std.testing.expectEqualSlices(u8, try snapshot(allocator, &first), try snapshot(allocator, &second));
}

test "the starting line number changes what is drawn but not the size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var from_one = try newRenderer(allocator, testPreset(), null);
    defer from_one.deinit();
    try drawAll(&from_one, &.{tok("a", "x")}, 1, &.{});

    var from_forty = try newRenderer(allocator, testPreset(), null);
    defer from_forty.deinit();
    try drawAll(&from_forty, &.{tok("a", "x")}, 40, &.{});

    try std.testing.expectEqual(imageWidth(&from_one), imageWidth(&from_forty));
    try std.testing.expectEqual(imageHeight(&from_one), imageHeight(&from_forty));
    try std.testing.expect(!std.mem.eql(u8, try snapshot(allocator, &from_one), try snapshot(allocator, &from_forty)));
}

test "a larger font size produces a larger image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tokens = [_]Token{ tok("x" ** 60, "x"), newline_token, tok("y", "x") };

    var small_preset = testPreset();
    small_preset.font_size = 12;
    var small = try newRenderer(allocator, small_preset, null);
    defer small.deinit();
    try drawAll(&small, &tokens, 1, &.{});

    var large_preset = testPreset();
    large_preset.font_size = 24;
    var large = try newRenderer(allocator, large_preset, null);
    defer large.deinit();
    try drawAll(&large, &tokens, 1, &.{});

    try std.testing.expect(imageWidth(&large) > imageWidth(&small));
    try std.testing.expect(imageHeight(&large) > imageHeight(&small));
}

test "saveImage writes a PNG whose header matches the image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), "a.zig");
    defer r.deinit();
    try drawAll(&r, &.{tok("const x = 1;", "keyword")}, 1, &.{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    const path = try std.fs.path.joinZ(allocator, &.{ dir, "out.png" });

    try r.saveImage(path);

    const bytes = try tmp.dir.readFileAlloc(allocator, "out.png", 16 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, @intCast(imageWidth(&r))), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, @intCast(imageHeight(&r))), std.mem.readInt(u32, bytes[20..24], .big));
}

test "a saved PNG decodes back to the same pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = try newRenderer(allocator, testPreset(), null);
    defer r.deinit();
    try drawAll(&r, &.{tok("const x = 1;", "keyword")}, 1, &.{1});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    const path = try std.fs.path.joinZ(allocator, &.{ dir, "round.png" });
    try r.saveImage(path);

    var decoded: Renderer = try newRenderer(allocator, testPreset(), null);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(c.BLResult, c.BL_SUCCESS), c.bl_image_read_from_file(&decoded.image, path.ptr, null));

    try std.testing.expectEqualSlices(u8, try snapshot(allocator, &r), try snapshot(allocator, &decoded));
}

test "saveImage reports an unwritable destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();
    try drawAll(&r, &.{tok("a", "x")}, 1, &.{});

    try std.testing.expectError(error.ImageWriteFailed, r.saveImage("/definitely/not/a/dir/out.png"));
}

test "prepareDrawableChunks never wraps a line the window was sized to fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    // Words of varied length, so the widest line ends on a different pixel each time.
    var n: usize = 12;
    while (n <= 70) : (n += 1) {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        var i: usize = 0;
        while (len < n) : (i += 1) {
            const word_len = 2 + (i * 3) % 5;
            for (0..word_len) |_| {
                if (len < n) {
                    buf[len] = 'a' + @as(u8, @intCast(i % 26));
                    len += 1;
                }
            }
            if (len < n) {
                buf[len] = ' ';
                len += 1;
            }
        }

        const tokens = [_]Token{tok(buf[0..len], "x")};
        const prepared = try r.prepareDrawableChunks(&tokens, 1, &.{});
        try std.testing.expect(r.content_width < code_window_max_width);
        if (countType(prepared.chunks.items, .wrap_indicator) != 0) {
            std.debug.print("line of {d} chars wrapped inside its own window\n", .{len});
            return error.TestUnexpectedResult;
        }
    }
}

test "prepareDrawableChunks does not wrap when the widest of several lines exactly fills the window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try newRenderer(arena.allocator(), testPreset(), null);
    defer r.deinit();

    const tokens = [_]Token{ tok("std.debug.print(\"hi\\n\", .{});", "x"), newline_token, tok("short", "x") };
    const prepared = try r.prepareDrawableChunks(&tokens, 1, &.{});
    try std.testing.expectEqual(@as(usize, 0), countType(prepared.chunks.items, .wrap_indicator));
}
