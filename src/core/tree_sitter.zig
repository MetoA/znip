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
extern fn tree_sitter_rust() *c.TSLanguage;
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

const LanguageId = enum {
    c,
    cpp,
    css,
    go,
    html,
    java,
    javascript,
    json,
    python,
    ruby,
    rust,
    zig,
};

const all_languages = [_]LanguageId{
    .zig,
    .rust,
    .javascript,
    .python,
    .c,
    .cpp,
    .go,
    .html,
    .css,
    .java,
    .ruby,
    .json,
};

const TreeStats = struct {
    total_nodes: u32 = 0,
    named_nodes: u32 = 0,
    error_nodes: u32 = 0,
    missing_nodes: u32 = 0,
    max_depth: u32 = 0,
    has_error: bool = false,
};

pub const Parser = struct {
    source_code: []const u8,
    allocator: std.mem.Allocator,
    source_hint_path: ?[]const u8,

    const max_detection_bytes = 16 * 1024;

    pub fn init(allocator: std.mem.Allocator, source_code: [:0]const u8, source_hint_path: ?[]const u8) Parser {
        var self: Parser = undefined;
        self.allocator = allocator;
        self.source_code = source_code;
        self.source_hint_path = source_hint_path;

        return self;
    }

    pub fn sourceCodeMatches(self: *Parser) !std.ArrayList(Match) {
        const detected_language = try self.detectLanguage();
        const query_source = highlightsQuerySource(detected_language);
        const lang = languagePtr(detected_language);
        std.log.debug("Detected language: {s}", .{languageName(detected_language)});

        const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
        defer c.ts_parser_delete(parser);

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
        errdefer {
            for (matches.items) |m| {
                self.allocator.free(m.capture_name);
            }
            matches.deinit(self.allocator);
        }
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            for (0..match.capture_count) |i| {
                const capture = match.captures[i];
                const node = capture.node;

                const start_byte = c.ts_node_start_byte(node);
                const end_byte = c.ts_node_end_byte(node);

                var name_len: u32 = 0;
                const name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &name_len);
                const capture_name = try self.allocator.dupe(u8, name_ptr[0..name_len]); // @variable, @type, @constant...
                errdefer self.allocator.free(capture_name);
                // const text = self.source_code[start_byte..end_byte]; // main, pub, (), {}...

                // std.log.debug("Found '{s}' at {d}:{d} -> Type: @{s}", .{ text, start_byte, end_byte, capture_name });

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

    fn detectLanguage(self: *Parser) !LanguageId {
        const source = if (self.source_code.len > max_detection_bytes) self.source_code[0..max_detection_bytes] else self.source_code;
        if (std.mem.trim(u8, source, " \t\r\n").len == 0) return .zig;

        const extension_lang = if (self.source_hint_path) |hint| detectLanguageFromPath(hint) else null;
        const fence_lang = detectLanguageFromFence(source);
        const shebang_lang = detectLanguageFromShebang(source);

        var candidates = std.ArrayList(LanguageId).empty;
        defer candidates.deinit(self.allocator);

        if (extension_lang) |lang| try appendCandidate(self.allocator, &candidates, lang);
        if (fence_lang) |lang| try appendCandidate(self.allocator, &candidates, lang);
        if (shebang_lang) |lang| try appendCandidate(self.allocator, &candidates, lang);
        for (all_languages) |lang| {
            try appendCandidate(self.allocator, &candidates, lang);
        }

        const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
        defer c.ts_parser_delete(parser);

        var best_lang: LanguageId = extension_lang orelse fence_lang orelse shebang_lang orelse .zig;
        var best_score: f64 = -1e9;

        for (candidates.items) |candidate| {
            _ = c.ts_parser_set_language(parser, languagePtr(candidate));
            const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse continue;
            defer c.ts_tree_delete(tree);

            const root = c.ts_tree_root_node(tree);
            var stats = TreeStats{};
            collectTreeStats(root, 1, &stats);
            var score = computeScore(stats);

            if (extension_lang != null and candidate == extension_lang.?) score += 140.0;
            if (fence_lang != null and candidate == fence_lang.?) score += 180.0;
            if (shebang_lang != null and candidate == shebang_lang.?) score += 160.0;

            if (score > best_score) {
                best_score = score;
                best_lang = candidate;
            }
        }

        return best_lang;
    }

    fn appendCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(LanguageId), lang: LanguageId) !void {
        for (candidates.items) |existing| {
            if (existing == lang) return;
        }
        try candidates.append(allocator, lang);
    }

    fn detectLanguageFromPath(path: []const u8) ?LanguageId {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;

        if (eqExt(ext, ".zig")) return .zig;
        if (eqExt(ext, ".rs")) return .rust;
        if (eqExt(ext, ".py")) return .python;
        if (eqExt(ext, ".js") or eqExt(ext, ".mjs") or eqExt(ext, ".cjs") or eqExt(ext, ".ts") or eqExt(ext, ".tsx")) return .javascript;
        if (eqExt(ext, ".c")) return .c;
        if (eqExt(ext, ".cpp") or eqExt(ext, ".cc") or eqExt(ext, ".cxx") or eqExt(ext, ".hpp") or eqExt(ext, ".hh") or eqExt(ext, ".hxx")) return .cpp;
        if (eqExt(ext, ".go")) return .go;
        if (eqExt(ext, ".html") or eqExt(ext, ".htm")) return .html;
        if (eqExt(ext, ".css")) return .css;
        if (eqExt(ext, ".java")) return .java;
        if (eqExt(ext, ".rb")) return .ruby;
        if (eqExt(ext, ".json")) return .json;
        return null;
    }

    fn detectLanguageFromFence(source: []const u8) ?LanguageId {
        const first_newline = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        const first_line = std.mem.trim(u8, source[0..first_newline], " \t\r");
        if (!std.mem.startsWith(u8, first_line, "```")) return null;

        const tag = std.mem.trim(u8, first_line[3..], " \t\r");
        if (tag.len == 0) return null;
        return languageFromHint(tag);
    }

    fn detectLanguageFromShebang(source: []const u8) ?LanguageId {
        const first_newline = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        const first_line = std.mem.trim(u8, source[0..first_newline], " \t\r");
        if (!std.mem.startsWith(u8, first_line, "#!")) return null;

        if (containsIgnoreCase(first_line, "python")) return .python;
        if (containsIgnoreCase(first_line, "ruby")) return .ruby;
        if (containsIgnoreCase(first_line, "node") or containsIgnoreCase(first_line, "deno") or containsIgnoreCase(first_line, "bun")) return .javascript;
        return null;
    }

    fn languageFromHint(hint: []const u8) ?LanguageId {
        if (eqIgnoreCase(hint, "zig")) return .zig;
        if (eqIgnoreCase(hint, "rust") or eqIgnoreCase(hint, "rs")) return .rust;
        if (eqIgnoreCase(hint, "python") or eqIgnoreCase(hint, "py")) return .python;
        if (eqIgnoreCase(hint, "javascript") or eqIgnoreCase(hint, "js") or eqIgnoreCase(hint, "typescript") or eqIgnoreCase(hint, "ts") or eqIgnoreCase(hint, "tsx") or eqIgnoreCase(hint, "jsx")) return .javascript;
        if (eqIgnoreCase(hint, "c")) return .c;
        if (eqIgnoreCase(hint, "cpp") or eqIgnoreCase(hint, "c++") or eqIgnoreCase(hint, "cc") or eqIgnoreCase(hint, "cxx")) return .cpp;
        if (eqIgnoreCase(hint, "go") or eqIgnoreCase(hint, "golang")) return .go;
        if (eqIgnoreCase(hint, "html")) return .html;
        if (eqIgnoreCase(hint, "css")) return .css;
        if (eqIgnoreCase(hint, "java")) return .java;
        if (eqIgnoreCase(hint, "ruby") or eqIgnoreCase(hint, "rb")) return .ruby;
        if (eqIgnoreCase(hint, "json")) return .json;
        return null;
    }

    fn collectTreeStats(node: c.TSNode, depth: u32, stats: *TreeStats) void {
        stats.total_nodes += 1;
        if (c.ts_node_is_named(node)) stats.named_nodes += 1;
        if (c.ts_node_is_missing(node)) stats.missing_nodes += 1;
        if (depth > stats.max_depth) stats.max_depth = depth;

        const node_type = std.mem.span(c.ts_node_type(node));
        if (std.mem.eql(u8, node_type, "ERROR")) stats.error_nodes += 1;

        if (c.ts_node_has_error(node)) stats.has_error = true;

        const child_count = c.ts_node_child_count(node);
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            collectTreeStats(c.ts_node_child(node, i), depth + 1, stats);
        }
    }

    fn computeScore(stats: TreeStats) f64 {
        const named = @as(f64, @floatFromInt(stats.named_nodes));
        const total = @as(f64, @floatFromInt(stats.total_nodes));
        const error_nodes = @as(f64, @floatFromInt(stats.error_nodes));
        const missing_nodes = @as(f64, @floatFromInt(stats.missing_nodes));
        const depth = @as(f64, @floatFromInt(stats.max_depth));
        const named_ratio = if (stats.total_nodes > 0) named / total else 0.0;

        var score = 2.0 * named + 1.0 * depth + 80.0 * named_ratio;
        if (stats.has_error) score -= 150.0;
        score -= 14.0 * error_nodes;
        score -= 8.0 * missing_nodes;
        return score;
    }

    fn languagePtr(language: LanguageId) *c.TSLanguage {
        return switch (language) {
            .c => tree_sitter_c(),
            .cpp => tree_sitter_cpp(),
            .css => tree_sitter_css(),
            .go => tree_sitter_go(),
            .html => tree_sitter_html(),
            .java => tree_sitter_java(),
            .javascript => tree_sitter_javascript(),
            .json => tree_sitter_json(),
            .python => tree_sitter_python(),
            .ruby => tree_sitter_ruby(),
            .rust => tree_sitter_rust(),
            .zig => tree_sitter_zig(),
        };
    }

    fn highlightsQuerySource(language: LanguageId) []const u8 {
        return switch (language) {
            .c => HighlightsQueryMap.c,
            .cpp => HighlightsQueryMap.cpp,
            .css => HighlightsQueryMap.css,
            .go => HighlightsQueryMap.go,
            .html => HighlightsQueryMap.html,
            .java => HighlightsQueryMap.java,
            .javascript => HighlightsQueryMap.javascript,
            .json => HighlightsQueryMap.json,
            .python => HighlightsQueryMap.python,
            .ruby => HighlightsQueryMap.ruby,
            .rust => HighlightsQueryMap.rust,
            .zig => HighlightsQueryMap.zig,
        };
    }

    fn languageName(language: LanguageId) []const u8 {
        return switch (language) {
            .c => "c",
            .cpp => "cpp",
            .css => "css",
            .go => "go",
            .html => "html",
            .java => "java",
            .javascript => "javascript",
            .json => "json",
            .python => "python",
            .ruby => "ruby",
            .rust => "rust",
            .zig => "zig",
        };
    }

    fn eqExt(lhs: []const u8, rhs: []const u8) bool {
        return std.ascii.eqlIgnoreCase(lhs, rhs);
    }

    fn eqIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
        return std.ascii.eqlIgnoreCase(lhs, rhs);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    pub fn sourceCodeTokens(self: *Parser, matches: std.ArrayList(Match)) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token).empty;
        errdefer {
            for (tokens.items) |t| {
                self.allocator.free(t.text);
                self.allocator.free(t.capture_name);
            }
            tokens.deinit(self.allocator);
        }
        var current_byte: usize = 0;

        for (matches.items) |match| {
            // Repeating match, skip it
            if (match.start_byte < current_byte) continue;

            // Next match skips a byte, it is a white space, tab, newline...
            if (match.start_byte > current_byte) {
                const gap_text = try self.allocator.dupe(u8, self.source_code[current_byte..match.start_byte]);
                const is_newline = std.mem.eql(u8, gap_text, "\n");
                try tokens.append(self.allocator, .{
                    .text = gap_text,
                    .capture_name = match.capture_name,
                    .is_newline = is_newline,
                });
            }

            try tokens.append(self.allocator, .{
                .text = try self.allocator.dupe(u8, self.source_code[match.start_byte..match.end_byte]),
                .capture_name = match.capture_name,
                .is_newline = false,
            });

            current_byte = match.end_byte;
        }

        // Leftover bytes after last match
        if (current_byte < self.source_code.len) {
            const gap_text = try self.allocator.dupe(u8, self.source_code[current_byte..]);
            const is_newline = std.mem.eql(u8, gap_text, "\n");
            try tokens.append(self.allocator, .{
                .text = try self.allocator.dupe(u8, self.source_code[current_byte..]),
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
