const tree_sitter = @import("../core/tree_sitter.zig");

const Color = u32; // ARGB

const Style = struct {
    color: Color,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

const Ui = struct {
    background: Color,
    code_window_background: Color,
    foreground: Color,
    line_number: Color,
};

const Syntax = struct {
    comment: Style,
    comment_doc: ?Style = null,
    constant: Style,
    constant_builtin: ?Style = null,
    constant_character: ?Style = null,
    constant_macro: ?Style = null,
    constructor: Style,
    function: Style,
    function_builtin: ?Style = null,
    function_call: ?Style = null,
    function_method: ?Style = null,
    keyword: Style,
    keyword_function: ?Style = null,
    keyword_modifier: ?Style = null,
    keyword_operator: ?Style = null,
    keyword_return: ?Style = null,
    keyword_control: ?Style = null,
    label: Style,
    number: Style,
    operator: Style,
    property: Style,
    punctuation: Style,
    punctuation_bracket: ?Style = null,
    punctuation_delimiter: ?Style = null,
    string: Style,
    string_escape: ?Style = null,
    string_regex: ?Style = null,
    type: Style,
    type_builtin: ?Style = null,
    variable: Style,
    variable_builtin: ?Style = null,
    variable_member: ?Style = null,
    variable_parameter: ?Style = null,
};

pub const Theme = struct {
    name: []const u8,
    ui: Ui,
    syntax: Syntax,
    
    pub fn getStyle(self: *Theme, category: tree_sitter.TokenCategory) Style {
        return switch (category) {
            .comment => self.syntax.comment,
            .constant => self.syntax.constant,
            .constructor => self.syntax.constructor,
            .field => self.syntax.property,
            .function => self.syntax.function,
            .function_builtin => self.syntax.function_builtin orelse self.syntax.function,
            .function_call => self.syntax.function_call orelse self.syntax.function,
            .function_method => self.syntax.function_method orelse self.syntax.function,
            .keyword => self.syntax.keyword,
            .keyword_function => self.syntax.keyword_function orelse self.syntax.keyword,
            .keyword_modifier => self.syntax.keyword_modifier orelse self.syntax.keyword,
            .keyword_operator => self.syntax.keyword_operator orelse self.syntax.keyword,
            .keyword_return => self.syntax.keyword_return orelse self.syntax.keyword,
            .property => self.syntax.property,
            .punctuation => self.syntax.punctuation,
            .punctuation_bracket => self.syntax.punctuation_bracket orelse self.syntax.punctuation,
            .punctuation_delimiter => self.syntax.punctuation_delimiter orelse self.syntax.punctuation,
            .string => self.syntax.string,
            .string_escape => self.syntax.string_escape orelse self.syntax.string,
            .string_special => self.syntax.string_regex orelse self.syntax.string,
            .tag => self.syntax.keyword,
            .tag_attribute => self.syntax.property,
            .type => self.syntax.type,
            .type_builtin => self.syntax.type_builtin orelse self.syntax.type,
            .variable => self.syntax.variable,
            .variable_builtin => self.syntax.variable_builtin orelse self.syntax.variable,
            .variable_member => self.syntax.variable_member orelse self.syntax.variable,
            .variable_parameter => self.syntax.variable_parameter orelse self.syntax.variable,
            .default_text => Style{ .color = self.ui.foreground },
        };
    }
};
