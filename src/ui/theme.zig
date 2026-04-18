const tree_sitter = @import("../core/tree_sitter.zig");

const Color = u32; // ARGB

const Ui = struct {
    background: Color,
    code_window_background: Color,
    foreground: Color,
    line_number: Color,
};

const Syntax = struct {
    comment: Color,
    comment_doc: ?Color = null,
    constant: Color,
    constant_builtin: ?Color = null,
    constant_character: ?Color = null,
    constant_macro: ?Color = null,
    constructor: Color,
    function: Color,
    function_builtin: ?Color = null,
    function_call: ?Color = null,
    function_method: ?Color = null,
    keyword: Color,
    keyword_function: ?Color = null,
    keyword_modifier: ?Color = null,
    keyword_operator: ?Color = null,
    keyword_return: ?Color = null,
    keyword_control: ?Color = null,
    label: Color,
    number: Color,
    operator: Color,
    property: Color,
    punctuation: Color,
    punctuation_bracket: ?Color = null,
    punctuation_delimiter: ?Color = null,
    string: Color,
    string_escape: ?Color = null,
    string_regex: ?Color = null,
    type: Color,
    type_builtin: ?Color = null,
    variable: Color,
    variable_builtin: ?Color = null,
    variable_member: ?Color = null,
    variable_parameter: ?Color = null,
};

pub const Theme = struct {
    name: []const u8,
    ui: Ui,
    syntax: Syntax,
    
    pub fn getColor(self: *Theme, category: tree_sitter.TokenCategory) Color {
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
            .default_text => self.ui.foreground,
        };
    }
};
