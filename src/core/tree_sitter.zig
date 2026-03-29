const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_c() *c.TSLanguage;
extern fn tree_sitter_cpp() *c.TSLanguage;
extern fn tree_sitter_css() *c.TSLanguage;
extern fn tree_sitter_go() *c.TSLanguage;
extern fn tree_sitter_html() *c.TSLanguage;
extern fn tree_sitter_java() *c.TSLanguage;
extern fn tree_sitter_javascript() *c.TSLanguage;
extern fn tree_sitter_json() *c.TSLanguage;
extern fn tree_sitter_markdown() *c.TSLanguage;
extern fn tree_sitter_php() *c.TSLanguage;
extern fn tree_sitter_python() *c.TSLanguage;
extern fn tree_sitter_ruby() *c.TSLanguage;
extern fn tree_sitter_sql() *c.TSLanguage;
extern fn tree_sitter_typescript() *c.TSLanguage;
extern fn tree_sitter_zig() *c.TSLanguage;

const HighlightsQueryMap = struct {
    pub const c = @embedFile("../deps/tree-sitter-c/queries/highlights.scm");
    pub const cpp = @embedFile("../deps/tree-sitter-cpp/queries/highlights.scm");
    pub const css = @embedFile("../deps/tree-sitter-css/queries/highlights.scm");
    pub const go = @embedFile("../deps/tree-sitter-go/queries/highlights.scm");
    pub const html = @embedFile("../deps/tree-sitter-html/queries/highlights.scm");
    pub const java = @embedFile("../deps/tree-sitter-java/queries/highlights.scm");
    pub const javascript = @embedFile("../deps/tree-sitter-javascript/queries/highlights.scm");
    pub const json = @embedFile("../deps/tree-sitter-json/queries/highlights.scm");
    pub const markdown = @embedFile("../deps/tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm");
    pub const php = @embedFile("../deps/tree-sitter-php/queries/highlights.scm");
    pub const python = @embedFile("../deps/tree-sitter-python/queries/highlights.scm");
    pub const ruby = @embedFile("../deps/tree-sitter-ruby/queries/highlights.scm");
    pub const rust = @embedFile("../deps/tree-sitter-rust/queries/highlights.scm");
    pub const sql = @embedFile("../deps/tree-sitter-sql/queries/highlights.scm");
    pub const typescript = @embedFile("../deps/tree-sitter-typescript/queries/highlights.scm");
    pub const zig = @embedFile("../deps/tree-sitter-zig/queries/highlights.scm");
};

pub const Parser = struct {
    source_code: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source_code: [:0]const u8) Parser {
        var self: Parser = undefined;
        self.allocator = allocator;
        self.source_code = source_code;

        return self;
    }

    pub fn sourceCodeMatches(self: *Parser) !std.ArrayList(Match) {
        // TODO Use the correct highlights query based on the language used
        const query_source = HighlightsQueryMap.zig;

        const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
        defer c.ts_parser_delete(parser);

        // TODO dynamically figure out the language
        const lang = tree_sitter_zig();
        _ = c.ts_parser_set_language(parser, lang);

        const tree = c.ts_parser_parse_string(parser, null, self.source_code.ptr, @intCast(self.source_code.len)) orelse return error.ParseFailed;
        defer c.ts_tree_delete(tree);

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = undefined;
        const query = c.ts_query_new(lang, query_source.ptr, @intCast(query_source.len), &error_offset, &error_type) orelse {
            std.log.err("Query failed at offset {d}, error type: {d}", .{ error_offset, error_type });
            return error.QueryCreationFailed;
        };
        defer c.ts_query_delete(query);

        // Places the cursor at the beginning, and begins execution
        const cursor = c.ts_query_cursor_new() orelse return error.CursorInitFailed;
        defer c.ts_query_cursor_delete(cursor);

        const root_node = c.ts_tree_root_node(tree);
        c.ts_query_cursor_exec(cursor, query, root_node);

        var matches = std.ArrayList(Match).empty;
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            for (0..match.capture_count) |i| {
                const capture = match.captures[i];
                const node = capture.node;

                const start_byte = c.ts_node_start_byte(node);
                const end_byte = c.ts_node_end_byte(node);

                var name_len: u32 = 0;
                const name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &name_len);
                const capture_name = name_ptr[0..name_len]; // @variable, @type, @constant...
                const text = self.source_code[start_byte..end_byte]; // main, pub, (), {}...

                std.log.debug("Found '{s}' at {d}:{d} -> Type: @{s}", .{ text, start_byte, end_byte, capture_name });

                // Skips same match that has multiple tags, e.g. "mainmainmain"
                if (matches.items.len > 0) {
                    const last = matches.items[matches.items.len - 1];
                    if (start_byte < last.end_byte) continue;
                }

                try matches.append(self.allocator, .{
                    .start_byte = start_byte,
                    .end_byte = end_byte,
                    .capture_name = capture_name,
                });
            }
        }

        return matches;
    }

    pub fn sourceCodeTokens(self: *Parser, matches: std.ArrayList(Match)) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token).empty;
        var current_byte: usize = 0;

        for (matches.items) |match| {
            // Repeating match, skip it
            if (match.start_byte < current_byte) continue;

            // Next match skips a byte, it is a white space, tab, newline...
            if (match.start_byte > current_byte) {
                const gap_text = self.source_code[current_byte..match.start_byte];
                const is_newline = std.mem.eql(u8, gap_text, "\n");
                try tokens.append(self.allocator, .{
                    .text = gap_text,
                    .capture_name = match.capture_name,
                    .is_newline = is_newline,
                });
            }

            try tokens.append(self.allocator, .{
                .text = self.source_code[match.start_byte..match.end_byte],
                .capture_name = match.capture_name,
                .is_newline = false,
            });

            current_byte = match.end_byte;
        }

        // Leftover bytes after last match
        if (current_byte < self.source_code.len) {
            const gap_text = self.source_code[current_byte..];
            const is_newline = std.mem.eql(u8, gap_text, "\n");
            try tokens.append(self.allocator, .{
                .text = self.source_code[current_byte..],
                .capture_name = "",
                .is_newline = is_newline,
            });
        }

        return tokens;
    }
};

pub const Token = struct {
    text: []const u8,
    capture_name: []const u8,
    is_newline: bool,
};

pub const Match = struct {
    start_byte: u32,
    end_byte: u32,
    capture_name: []const u8,
};

pub const TokenCategory = enum {
    comment,
    constant,
    constructor,
    field,
    function,
    function_builtin,
    function_call,
    function_method,
    keyword,
    keyword_function,
    keyword_modifier,
    keyword_operator,
    keyword_return,
    property,
    punctuation,
    punctuation_bracket,
    punctuation_delimiter,
    string,
    string_escape,
    string_special,
    tag,
    tag_attribute,
    type,
    type_builtin,
    variable,
    variable_builtin,
    variable_member,
    variable_parameter,
    default_text,

    pub fn categorizeCapture(capture_name: []const u8) TokenCategory {
        if (std.mem.startsWith(u8, capture_name, "variable.parameter")) return .variable_parameter;
        if (std.mem.startsWith(u8, capture_name, "variable.member")) return .variable_member;
        if (std.mem.startsWith(u8, capture_name, "variable.builtin")) return .variable_builtin;
        if (std.mem.startsWith(u8, capture_name, "variable")) return .variable;
        
        if (std.mem.startsWith(u8, capture_name, "type.builtin")) return .type_builtin;
        if (std.mem.startsWith(u8, capture_name, "type")) return .type;
        
        if (std.mem.startsWith(u8, capture_name, "tag.attribute")) return .tag_attribute;
        if (std.mem.startsWith(u8, capture_name, "tag")) return .tag;
        
        if (std.mem.startsWith(u8, capture_name, "string.special")) return .string_special;
        if (std.mem.startsWith(u8, capture_name, "string.escape")) return .string_escape;
        if (std.mem.startsWith(u8, capture_name, "string")) return .string;
        
        if (std.mem.startsWith(u8, capture_name, "punctuation.delimiter")) return .punctuation_delimiter;
        if (std.mem.startsWith(u8, capture_name, "punctuation.bracket")) return .punctuation_bracket;
        if (std.mem.startsWith(u8, capture_name, "punctuation")) return .punctuation;
        
        if (std.mem.startsWith(u8, capture_name, "property")) return .property;
        
        if (std.mem.startsWith(u8, capture_name, "keyword.return")) return .keyword_return;
        if (std.mem.startsWith(u8, capture_name, "keyword.operator")) return .keyword_operator;
        if (std.mem.startsWith(u8, capture_name, "keyword.modifier")) return .keyword_modifier;
        if (std.mem.startsWith(u8, capture_name, "keyword.function")) return .keyword_function;
        if (std.mem.startsWith(u8, capture_name, "keyword")) return .keyword;
        
        if (std.mem.startsWith(u8, capture_name, "function.method")) return .function_method;
        if (std.mem.startsWith(u8, capture_name, "function.call")) return .function_call;
        if (std.mem.startsWith(u8, capture_name, "function.builtin")) return .function_builtin;
        if (std.mem.startsWith(u8, capture_name, "function")) return .function;
        
        if (std.mem.startsWith(u8, capture_name, "field")) return .field;
        
        if (std.mem.startsWith(u8, capture_name, "constructor")) return .constructor;
        
        if (std.mem.startsWith(u8, capture_name, "constant")) return .constant;
        
        return .default_text;
    }
};
