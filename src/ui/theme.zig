const tree_sitter = @import("../core/tree_sitter.zig");

pub const Color = u32; // ARGB

pub const Style = struct {
    fg: Color,
    bold: bool = false,
    italic: bool = false,
};

pub const Theme = struct {
    bg: Color,
    fg: Color,
    gutter_bg: Color,
    line_num: Color,

    keyword: Style,
    function: Style,
    type_def: Style,
    comment: Style,
    string: Style,
    literal: Style,
    variable: Style,
    operator: Style,

    pub fn getStyle(self: *Theme, category: tree_sitter.TokenCategory) Style {
        return switch (category) {
            .keyword => self.keyword,
            .function => self.function,
            .type_def => self.type_def,
            .comment => self.comment,
            .literal => self.literal,
            .variable => self.variable,
            .operator => self.operator,
            .text => Style{ .fg = self.fg },
            else => Style{ .fg = self.fg },
        };
    }
};

// TODO placeholder?
pub const DraculaTheme: Theme = .{
    .bg = 0xFF282A36,
    .fg = 0xFFF8F8F2,
    .gutter_bg = 0xFF282A36,
    .line_num = 0xFFF8F8F2,
    .keyword = .{
        .fg = 0xFFFF79C6,
        .bold = false,
        .italic = false,
    },
    .function = .{
        .fg = 0xFF50FA7B,
        .bold = false,
        .italic = false,
    },
    .type_def = .{
        .fg = 0xFF8BE9FD,
        .bold = false,
        .italic = false,
    },
    .comment = .{
        .fg = 0xFF6272A4,
        .bold = false,
        .italic = false,
    },
    .string = .{
        .fg = 0xFFF1FA8C,
        .bold = false,
        .italic = false,
    },
    .literal = .{
        .fg = 0xFFFFB86C,
        .bold = false,
        .italic = false,
    },
    .variable = .{
        .fg = 0xFFF8F8F2,
        .bold = false,
        .italic = false,
    },
    .operator = .{
        .fg = 0xFFF8F8F2,
        .bold = false,
        .italic = false,
    },
};
