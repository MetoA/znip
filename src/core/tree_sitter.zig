const std = @import("std");
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
    if (build_options.wasm_enabled) @cInclude("wasm.h");
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
    pub const sql = @embedFile("../deps/tree-sitter-sql/queries/sql/highlights.scm");
    pub const typescript = @embedFile("../deps/tree-sitter-typescript/queries/highlights.scm");
    pub const zig = @embedFile("../deps/tree-sitter-zig/queries/highlights.scm");
};

const NativeLanguageId = enum {
    c,
    cpp,
    css,
    go,
    html,
    java,
    javascript,
    json,
    markdown,
    php,
    python,
    ruby,
    rust,
    sql,
    typescript,
    zig,
};

const native_languages = [_]NativeLanguageId{
    .zig,
    .rust,
    .javascript,
    .typescript,
    .python,
    .c,
    .cpp,
    .go,
    .html,
    .css,
    .java,
    .ruby,
    .json,
    .php,
    .markdown,
    .sql,
};

// The file extension with its leading dot stripped, if any - used as a
// dynamic-language lookup name when the extension doesn't match any native
// language (e.g. ".cob" -> "cob").
pub fn candidateNameFromPath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return null;
    return ext[1..];
}

pub fn nativeLanguageFromHint(hint: []const u8) ?NativeLanguageId {
    if (eqIgnoreCase(hint, "zig")) return .zig;
    if (eqIgnoreCase(hint, "rust") or eqIgnoreCase(hint, "rs")) return .rust;
    if (eqIgnoreCase(hint, "python") or eqIgnoreCase(hint, "py")) return .python;
    if (eqIgnoreCase(hint, "javascript") or eqIgnoreCase(hint, "js") or eqIgnoreCase(hint, "jsx")) return .javascript;
    if (eqIgnoreCase(hint, "typescript") or eqIgnoreCase(hint, "ts") or eqIgnoreCase(hint, "tsx")) return .typescript;
    if (eqIgnoreCase(hint, "c")) return .c;
    if (eqIgnoreCase(hint, "cpp") or eqIgnoreCase(hint, "c++") or eqIgnoreCase(hint, "cc") or eqIgnoreCase(hint, "cxx")) return .cpp;
    if (eqIgnoreCase(hint, "go") or eqIgnoreCase(hint, "golang")) return .go;
    if (eqIgnoreCase(hint, "html")) return .html;
    if (eqIgnoreCase(hint, "css")) return .css;
    if (eqIgnoreCase(hint, "java")) return .java;
    if (eqIgnoreCase(hint, "ruby") or eqIgnoreCase(hint, "rb")) return .ruby;
    if (eqIgnoreCase(hint, "json")) return .json;
    if (eqIgnoreCase(hint, "php")) return .php;
    if (eqIgnoreCase(hint, "markdown") or eqIgnoreCase(hint, "md")) return .markdown;
    if (eqIgnoreCase(hint, "sql")) return .sql;
    return null;
}

fn eqIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

// A Tree-sitter language loaded at runtime from a cached WASM grammar,
// for languages outside the natively-compiled `NativeLanguageId` set.
pub const DynamicLanguage = struct {
    name: []const u8,
    ts_language: *const c.TSLanguage,
    highlights_query: []const u8,
};

// The common currency returned by language detection: either one of the
// natively-compiled grammars, or one loaded on demand via a LanguageRegistry.
pub const LanguageRef = union(enum) {
    native: NativeLanguageId,
    dynamic: *const DynamicLanguage,
};

// Owns WASM-loaded grammars for languages outside the native set. The
// wasmtime engine/store are created lazily on the first cache hit, so the
// native detection/parse path never touches wasmtime.
//
// Intentionally has no deinit(): construct with an arena allocator (as
// Parser.attachRegistry's caller does) and let the arena's teardown free the
// name/query buffers and hashmap. The wasm_engine/wasm_store are never
// explicitly deleted - a real crash was found inside this vendored
// tree-sitter snapshot's own ts_wasm_store_delete cleanup, independent of how
// the caller manages lifetimes (see the Phase 2 WASM spike test). Since znip
// is a short-lived, one-shot CLI process, leaking these for process lifetime
// is an acceptable stance; revisit if this is ever used in a long-lived process.
pub const LanguageRegistry = struct {
    allocator: std.mem.Allocator,
    wasm_engine: ?*c.TSWasmEngine = null,
    wasm_store: ?*c.TSWasmStore = null,
    loaded: std.StringHashMap(DynamicLanguage),

    pub fn init(allocator: std.mem.Allocator) LanguageRegistry {
        return .{
            .allocator = allocator,
            .loaded = std.StringHashMap(DynamicLanguage).init(allocator),
        };
    }

    // Returns an already-loaded entry, or tries to load one from disk.
    // Tries <home>/.znip/grammars/<name>/ directly first (the common case:
    // `name` is already the grammar's canonical name); if that doesn't
    // exist, scans sibling cache directories for one whose meta.json lists
    // `name` as one of its extensions (e.g. a lookup for "cob" finding a
    // grammar cached under "cobol"). Returns null (not an error) if nothing
    // matches either way.
    pub fn resolve(self: *LanguageRegistry, name: []const u8) !?*const DynamicLanguage {
        // ts_wasm_store_new/ts_wasm_store_load_language have no fallback
        // stub in the vendored tree-sitter source when TREE_SITTER_FEATURE_WASM
        // is undefined (unlike most other ts_wasm_store_* functions) - so
        // this whole body must stay unreached (not just error out at
        // runtime) in non-wasm builds, or the default build fails to link.
        if (comptime !build_options.wasm_enabled) return null;

        if (self.loaded.getPtr(name)) |existing| return existing;

        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return null;
        defer self.allocator.free(home);

        const grammars_dir = try std.fs.path.join(self.allocator, &.{ home, ".znip", "grammars" });
        defer self.allocator.free(grammars_dir);

        if (try self.loadFromDir(grammars_dir, name, name)) |dynamic| return dynamic;

        if (try self.findCanonicalNameByExtension(grammars_dir, name)) |canonical_name| {
            defer self.allocator.free(canonical_name);
            return try self.loadFromDir(grammars_dir, canonical_name, name);
        }

        return null;
    }

    // Loads <grammars_dir>/<dir_name>/{grammar.wasm,highlights.scm}, if
    // present, and registers it in `self.loaded` under `register_as` (so a
    // lookup by an alias like "cob" hits the fast in-memory path on repeat
    // calls within this process). `dir_name` is what's passed to
    // ts_wasm_store_load_language, since that must match the grammar's
    // actual exported tree_sitter_<dir_name> function.
    fn loadFromDir(self: *LanguageRegistry, grammars_dir: []const u8, dir_name: []const u8, register_as: []const u8) !?*const DynamicLanguage {
        const dir_path = try std.fs.path.join(self.allocator, &.{ grammars_dir, dir_name });
        defer self.allocator.free(dir_path);

        const wasm_path = try std.fs.path.join(self.allocator, &.{ dir_path, "grammar.wasm" });
        defer self.allocator.free(wasm_path);
        const query_path = try std.fs.path.join(self.allocator, &.{ dir_path, "highlights.scm" });
        defer self.allocator.free(query_path);

        const wasm_bytes = std.fs.cwd().readFileAlloc(self.allocator, wasm_path, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(wasm_bytes);

        const query_source = std.fs.cwd().readFileAlloc(self.allocator, query_path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer self.allocator.free(query_source);

        const store = try self.ensureWasmStore();

        var wasm_err: c.TSWasmError = undefined;
        const ts_language = c.ts_wasm_store_load_language(store, dir_name.ptr, wasm_bytes.ptr, @intCast(wasm_bytes.len), &wasm_err) orelse {
            std.log.err("ts_wasm_store_load_language failed for '{s}': kind={d} message={s}", .{ dir_name, wasm_err.kind, wasm_err.message });
            self.allocator.free(query_source);
            return error.WasmLanguageLoadFailed;
        };

        const owned_register_key = try self.allocator.dupe(u8, register_as);
        const owned_display_name = try self.allocator.dupe(u8, dir_name);
        try self.loaded.put(owned_register_key, .{
            .name = owned_display_name,
            .ts_language = ts_language,
            .highlights_query = query_source,
        });

        return self.loaded.getPtr(owned_register_key);
    }

    const CachedGrammarMeta = struct {
        extensions: []const []const u8 = &.{},
    };

    // Scans immediate subdirectories of `grammars_dir` for one whose
    // meta.json (written by grammar_cache.fetchGrammar) lists `name` as one
    // of its extensions. Returns the subdirectory's (canonical) name if
    // found - caller owns the returned slice.
    fn findCanonicalNameByExtension(self: *LanguageRegistry, grammars_dir: []const u8, name: []const u8) !?[]const u8 {
        var dir = std.fs.cwd().openDir(grammars_dir, .{ .iterate = true }) catch return null;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (std.ascii.eqlIgnoreCase(entry.name, name)) continue; // already tried directly

            const meta_path = try std.fs.path.join(self.allocator, &.{ grammars_dir, entry.name, "meta.json" });
            defer self.allocator.free(meta_path);

            const meta_bytes = std.fs.cwd().readFileAlloc(self.allocator, meta_path, 64 * 1024) catch continue;
            defer self.allocator.free(meta_bytes);

            var parsed = std.json.parseFromSlice(CachedGrammarMeta, self.allocator, meta_bytes, .{ .allocate = .alloc_always }) catch continue;
            defer parsed.deinit();

            for (parsed.value.extensions) |ext| {
                const bare = if (std.mem.startsWith(u8, ext, ".")) ext[1..] else ext;
                if (std.ascii.eqlIgnoreCase(bare, name)) {
                    return try self.allocator.dupe(u8, entry.name);
                }
            }
        }

        return null;
    }

    fn ensureWasmStore(self: *LanguageRegistry) !*c.TSWasmStore {
        if (self.wasm_store) |store| return store;

        // wasm_engine_new comes from wasmtime's wasm.h, only cImported when
        // built with -Dwasm=true (see the top of this file) - gate this
        // whole branch on that so the default build never references it.
        if (comptime !build_options.wasm_enabled) return error.WasmSupportNotBuilt;

        const engine = self.wasm_engine orelse c.wasm_engine_new() orelse return error.WasmEngineInitFailed;
        self.wasm_engine = engine;

        var wasm_err: c.TSWasmError = undefined;
        const store = c.ts_wasm_store_new(engine, &wasm_err) orelse {
            std.log.err("ts_wasm_store_new failed: kind={d} message={s}", .{ wasm_err.kind, wasm_err.message });
            return error.WasmStoreInitFailed;
        };
        self.wasm_store = store;
        return store;
    }
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
    registry: ?*LanguageRegistry,
    requested_lang: ?[]const u8,

    const max_detection_bytes = 16 * 1024;

    pub fn init(allocator: std.mem.Allocator, source_code: [:0]const u8, source_hint_path: ?[]const u8) Parser {
        var self: Parser = undefined;
        self.allocator = allocator;
        self.source_code = source_code;
        self.source_hint_path = source_hint_path;
        self.registry = null;
        self.requested_lang = null;

        return self;
    }

    // Opts this parser into the on-demand WASM fallback for languages
    // outside the native set. Optional: callers that don't attach a
    // registry get exactly today's native-only detection behavior.
    pub fn attachRegistry(self: *Parser, registry: *LanguageRegistry) void {
        self.registry = registry;
    }

    // Explicit language override (e.g. from --lang): bypasses heuristic
    // detection entirely. Resolves against the native set first, then a
    // cached dynamic grammar (if a registry is attached); errors loudly with
    // error.LanguageNotAvailable if neither resolves, unlike the automatic
    // detection path which silently falls back to heuristic scoring.
    pub fn setRequestedLanguage(self: *Parser, name: []const u8) void {
        self.requested_lang = name;
    }

    pub fn sourceCodeMatches(self: *Parser) !std.ArrayList(Match) {
        const detected_language = try self.detectLanguage();
        const query_source = highlightsQuerySource(detected_language);
        const lang = languagePtr(detected_language);

        const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
        defer c.ts_parser_delete(parser);

        if (detected_language == .dynamic) {
            c.ts_parser_set_wasm_store(parser, self.registry.?.wasm_store.?);
        }
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
                const raw_name = name_ptr[0..name_len];

                // "spell" isn't a real highlight group - it's a Neovim
                // spell-check marker that some grammars attach alongside a
                // real capture on the same node (e.g. `(comment) @comment
                // @spell`). Left in, it'd be a same-range duplicate that can
                // shadow the real capture and fall back to .default_text.
                if (std.mem.eql(u8, raw_name, "spell")) continue;

                const capture_name = try self.allocator.dupe(u8, raw_name); // @variable, @type, @constant...
                errdefer self.allocator.free(capture_name);

                try matches.append(self.allocator, .{
                    .start_byte = start_byte,
                    .end_byte = end_byte,
                    .capture_name = capture_name,
                });
            }
        }

        return matches;
    }

    fn detectLanguage(self: *Parser) !LanguageRef {
        if (self.requested_lang) |name| {
            if (nativeLanguageFromHint(name)) |native| return .{ .native = native };
            if (self.registry) |registry| {
                if (try registry.resolve(name)) |dynamic| return .{ .dynamic = dynamic };
            }
            return error.LanguageNotAvailable;
        }

        const source = if (self.source_code.len > max_detection_bytes) self.source_code[0..max_detection_bytes] else self.source_code;
        if (std.mem.trim(u8, source, " \t\r\n").len == 0) return .{ .native = .zig };

        const extension_lang = if (self.source_hint_path) |hint| detectLanguageFromPath(hint) else null;
        const fence_lang = detectLanguageFromFence(source);
        const shebang_lang = detectLanguageFromShebang(source);

        // No native signal at all for this input - before falling back to
        // scoring against every native grammar (which bottoms out at .zig),
        // see if an on-demand WASM grammar is already cached for whatever
        // raw name the extension/fence tag suggests.
        if (extension_lang == null and fence_lang == null) {
            if (self.registry) |registry| {
                const path_ext_name = if (self.source_hint_path) |hint| candidateNameFromPath(hint) else null;
                const raw_name = path_ext_name orelse extractFenceTag(source);
                if (raw_name) |name| {
                    if (try registry.resolve(name)) |dynamic| {
                        return .{ .dynamic = dynamic };
                    }
                }
            }
        }

        // A recognized file extension, fenced-code-block tag, or shebang is
        // an explicit, unambiguous signal - trust it outright instead of
        // letting the content-based heuristic below potentially override
        // it. That heuristic exists for input with no such signal at all
        // (piped stdin/clipboard content); scoring a file's own correct
        // grammar against every other one can otherwise lose, since a
        // comment-heavy file's prose can make an unrelated grammar's much
        // more fragmented error recovery look artificially "richer" by raw
        // named-node count than the correct grammar's clean parse.
        if (extension_lang orelse fence_lang orelse shebang_lang) |lang| return .{ .native = lang };

        var candidates = std.ArrayList(NativeLanguageId).empty;
        defer candidates.deinit(self.allocator);

        for (native_languages) |lang| {
            try appendCandidate(self.allocator, &candidates, lang);
        }

        const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
        defer c.ts_parser_delete(parser);

        var best_lang: NativeLanguageId = .zig;
        var best_stats: TreeStats = .{};
        var best_score: f64 = -1e9;
        var have_best = false;

        for (candidates.items) |candidate| {
            _ = c.ts_parser_set_language(parser, nativeLanguagePtr(candidate));
            const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse continue;
            defer c.ts_tree_delete(tree);

            const root = c.ts_tree_root_node(tree);
            var stats = TreeStats{};
            collectTreeStats(root, 1, &stats);
            const score = computeScore(stats);

            if (!have_best or isBetterCandidate(stats, score, best_stats, best_score)) {
                have_best = true;
                best_stats = stats;
                best_score = score;
                best_lang = candidate;
            }
        }

        return .{ .native = best_lang };
    }

    fn appendCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(NativeLanguageId), lang: NativeLanguageId) !void {
        for (candidates.items) |existing| {
            if (existing == lang) return;
        }
        try candidates.append(allocator, lang);
    }

    fn detectLanguageFromPath(path: []const u8) ?NativeLanguageId {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;

        if (eqExt(ext, ".zig")) return .zig;
        if (eqExt(ext, ".rs")) return .rust;
        if (eqExt(ext, ".py")) return .python;
        if (eqExt(ext, ".js") or eqExt(ext, ".mjs") or eqExt(ext, ".cjs")) return .javascript;
        if (eqExt(ext, ".ts") or eqExt(ext, ".tsx")) return .typescript;
        if (eqExt(ext, ".c")) return .c;
        if (eqExt(ext, ".cpp") or eqExt(ext, ".cc") or eqExt(ext, ".cxx") or eqExt(ext, ".hpp") or eqExt(ext, ".hh") or eqExt(ext, ".hxx")) return .cpp;
        if (eqExt(ext, ".go")) return .go;
        if (eqExt(ext, ".html") or eqExt(ext, ".htm")) return .html;
        if (eqExt(ext, ".css")) return .css;
        if (eqExt(ext, ".java")) return .java;
        if (eqExt(ext, ".rb")) return .ruby;
        if (eqExt(ext, ".json")) return .json;
        if (eqExt(ext, ".php")) return .php;
        if (eqExt(ext, ".md") or eqExt(ext, ".markdown")) return .markdown;
        if (eqExt(ext, ".sql")) return .sql;
        return null;
    }

    fn detectLanguageFromFence(source: []const u8) ?NativeLanguageId {
        const tag = extractFenceTag(source) orelse return null;
        return nativeLanguageFromHint(tag);
    }

    // The raw ```tag string from a fenced code block, if any - used as a
    // dynamic-language lookup name when the tag doesn't match any native
    // language.
    fn extractFenceTag(source: []const u8) ?[]const u8 {
        const first_newline = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        const first_line = std.mem.trim(u8, source[0..first_newline], " \t\r");
        if (!std.mem.startsWith(u8, first_line, "```")) return null;

        const tag = std.mem.trim(u8, first_line[3..], " \t\r");
        if (tag.len == 0) return null;
        return tag;
    }

    fn detectLanguageFromShebang(source: []const u8) ?NativeLanguageId {
        const first_newline = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        const first_line = std.mem.trim(u8, source[0..first_newline], " \t\r");
        if (!std.mem.startsWith(u8, first_line, "#!")) return null;

        if (containsIgnoreCase(first_line, "python")) return .python;
        if (containsIgnoreCase(first_line, "ruby")) return .ruby;
        if (containsIgnoreCase(first_line, "node") or containsIgnoreCase(first_line, "deno") or containsIgnoreCase(first_line, "bun")) return .javascript;
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

    // A pure "richness" measure - used only to rank among candidates that
    // are already comparably clean (see isBetterCandidate). It intentionally
    // doesn't penalize errors/missing nodes itself: that's handled up front,
    // lexicographically, because a badly-fragmented wrong-grammar parse can
    // rack up far more named nodes than a small, correct, clean one, and a
    // flat additive penalty here isn't enough to make up that gap.
    fn computeScore(stats: TreeStats) f64 {
        const named = @as(f64, @floatFromInt(stats.named_nodes));
        const total = @as(f64, @floatFromInt(stats.total_nodes));
        const depth = @as(f64, @floatFromInt(stats.max_depth));
        const named_ratio = if (stats.total_nodes > 0) named / total else 0.0;

        return 2.0 * named + 1.0 * depth + 80.0 * named_ratio;
    }

    // Prefers a cleaner parse over a merely more voluminous one: a grammar
    // that parses the input with zero errors is almost certainly the right
    // one, even if a wrong grammar's error-recovery fragmented the input
    // into more (bogus) named nodes and would otherwise win on raw score.
    fn isBetterCandidate(a_stats: TreeStats, a_score: f64, b_stats: TreeStats, b_score: f64) bool {
        if (a_stats.has_error != b_stats.has_error) return !a_stats.has_error;

        const a_defects = a_stats.error_nodes + a_stats.missing_nodes;
        const b_defects = b_stats.error_nodes + b_stats.missing_nodes;
        if (a_defects != b_defects) return a_defects < b_defects;

        return a_score > b_score;
    }

    fn languagePtr(language: LanguageRef) *const c.TSLanguage {
        return switch (language) {
            .native => |n| nativeLanguagePtr(n),
            .dynamic => |d| d.ts_language,
        };
    }

    fn highlightsQuerySource(language: LanguageRef) []const u8 {
        return switch (language) {
            .native => |n| nativeHighlightsQuerySource(n),
            .dynamic => |d| d.highlights_query,
        };
    }

    fn languageName(language: LanguageRef) []const u8 {
        return switch (language) {
            .native => |n| nativeLanguageName(n),
            .dynamic => |d| d.name,
        };
    }

    fn nativeLanguagePtr(language: NativeLanguageId) *c.TSLanguage {
        return switch (language) {
            .c => tree_sitter_c(),
            .cpp => tree_sitter_cpp(),
            .css => tree_sitter_css(),
            .go => tree_sitter_go(),
            .html => tree_sitter_html(),
            .java => tree_sitter_java(),
            .javascript => tree_sitter_javascript(),
            .json => tree_sitter_json(),
            .markdown => tree_sitter_markdown(),
            .php => tree_sitter_php(),
            .python => tree_sitter_python(),
            .ruby => tree_sitter_ruby(),
            .rust => tree_sitter_rust(),
            .sql => tree_sitter_sql(),
            .typescript => tree_sitter_typescript(),
            .zig => tree_sitter_zig(),
        };
    }

    fn nativeHighlightsQuerySource(language: NativeLanguageId) []const u8 {
        return switch (language) {
            .c => HighlightsQueryMap.c,
            .cpp => HighlightsQueryMap.cpp,
            .css => HighlightsQueryMap.css,
            .go => HighlightsQueryMap.go,
            .html => HighlightsQueryMap.html,
            .java => HighlightsQueryMap.java,
            .javascript => HighlightsQueryMap.javascript,
            .json => HighlightsQueryMap.json,
            .markdown => HighlightsQueryMap.markdown,
            .php => HighlightsQueryMap.php,
            .python => HighlightsQueryMap.python,
            .ruby => HighlightsQueryMap.ruby,
            .rust => HighlightsQueryMap.rust,
            .sql => HighlightsQueryMap.sql,
            .typescript => HighlightsQueryMap.typescript,
            .zig => HighlightsQueryMap.zig,
        };
    }

    fn nativeLanguageName(language: NativeLanguageId) []const u8 {
        return switch (language) {
            .c => "c",
            .cpp => "cpp",
            .css => "css",
            .go => "go",
            .html => "html",
            .java => "java",
            .javascript => "javascript",
            .json => "json",
            .markdown => "markdown",
            .php => "php",
            .python => "python",
            .ruby => "ruby",
            .rust => "rust",
            .sql => "sql",
            .typescript => "typescript",
            .zig => "zig",
        };
    }

    fn eqExt(lhs: []const u8, rhs: []const u8) bool {
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
        // ts_query_cursor_next_match doesn't guarantee matches come out
        // ordered by position - the merge below does a single forward sweep
        // and relies on that ordering, so sort first. Ties (same start_byte)
        // put the wider capture first, so a narrower nested/duplicate one
        // starting at the same byte gets shadowed by the dedup check below.
        std.mem.sort(Match, matches.items, {}, struct {
            fn lessThan(_: void, a: Match, b: Match) bool {
                if (a.start_byte != b.start_byte) return a.start_byte < b.start_byte;
                return a.end_byte > b.end_byte;
            }
        }.lessThan);

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
                    .capture_name = "",
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
                .text = gap_text,
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
    number,
    operator,
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
        
        if (std.mem.startsWith(u8, capture_name, "operator")) return .operator;
        
        if (std.mem.startsWith(u8, capture_name, "number")) return .number;

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
        
        if (std.mem.startsWith(u8, capture_name, "comment")) return .comment;

        return .default_text;
    }
};

// Phase 2 proof-of-concept for on-demand WASM grammar loading: loads a
// hand-built tree-sitter-json.wasm (via `tree-sitter build --wasm`) through
// wasmtime + ts_wasm_store_*, and asserts it produces identical highlight
// matches to the natively-compiled JSON grammar on the same input. This is
// the go/no-go check for whether wasmtime+tree-sitter-wasm works at all in
// this Zig build; it is not wired into detectLanguage/Parser yet (Phase 3).

test "wasm-loaded json grammar matches the native json grammar" {
    if (comptime !build_options.wasm_enabled) return error.SkipZigTest;

    const wasm_bytes = @embedFile("test_fixtures/tree-sitter-json.wasm");
    const sample = "{\"a\": 1, \"b\": [true, false, null], \"c\": \"text\"}";

    const native_matches = try matchesForLanguage(std.testing.allocator, tree_sitter_json(), HighlightsQueryMap.json, sample, null);
    defer freeMatches(std.testing.allocator, native_matches);

    var wasm_err: c.TSWasmError = undefined;
    const engine = c.wasm_engine_new() orelse return error.WasmEngineInitFailed;
    defer c.wasm_engine_delete(engine);

    const store = c.ts_wasm_store_new(engine, &wasm_err) orelse {
        std.log.err("ts_wasm_store_new failed: kind={d} message={s}", .{ wasm_err.kind, wasm_err.message });
        return error.WasmStoreInitFailed;
    };
    // Deliberately not calling ts_wasm_store_delete: this vendored tree-sitter
    // snapshot's wasm_store.c segfaults inside its own globaltype cleanup
    // (wasm_globaltype_delete -> a shared Rust externtype drop path) against
    // this exact wasmtime v36.0.7 C API release binary, independent of how
    // this test manages the store/engine/parser it owns - reproduced with
    // engine/parser lifetimes held constant. The load/parse/query pipeline
    // itself (the part this spike is actually validating) is unaffected and
    // matches the native grammar's output exactly. znip is a short-lived,
    // one-shot CLI process, so leaking the store for process lifetime is an
    // acceptable stance for now; the underlying crash is a risk to track
    // upstream (or retest against a different wasmtime release) before this
    // is ever used in a long-lived process.

    const wasm_lang = c.ts_wasm_store_load_language(store, "json", wasm_bytes.ptr, @intCast(wasm_bytes.len), &wasm_err) orelse {
        std.log.err("ts_wasm_store_load_language failed: kind={d} message={s}", .{ wasm_err.kind, wasm_err.message });
        return error.WasmLanguageLoadFailed;
    };

    const wasm_matches = try matchesForLanguage(std.testing.allocator, wasm_lang, HighlightsQueryMap.json, sample, store);
    defer freeMatches(std.testing.allocator, wasm_matches);

    try std.testing.expectEqual(native_matches.items.len, wasm_matches.items.len);
    for (native_matches.items, wasm_matches.items) |native_match, wasm_match| {
        try std.testing.expectEqual(native_match.start_byte, wasm_match.start_byte);
        try std.testing.expectEqual(native_match.end_byte, wasm_match.end_byte);
        try std.testing.expectEqualStrings(native_match.capture_name, wasm_match.capture_name);
    }
}

fn matchesForLanguage(allocator: std.mem.Allocator, lang: *const c.TSLanguage, query_source: []const u8, source: []const u8, wasm_store: ?*c.TSWasmStore) !std.ArrayList(Match) {
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);
    if (wasm_store) |store| c.ts_parser_set_wasm_store(parser, store);
    _ = c.ts_parser_set_language(parser, lang);

    const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(lang, query_source.ptr, @intCast(query_source.len), &error_offset, &error_type) orelse return error.QueryCreationFailed;
    defer c.ts_query_delete(query);

    const cursor = c.ts_query_cursor_new() orelse return error.CursorInitFailed;
    defer c.ts_query_cursor_delete(cursor);

    const root_node = c.ts_tree_root_node(tree);
    c.ts_query_cursor_exec(cursor, query, root_node);

    var matches = std.ArrayList(Match).empty;
    errdefer freeMatches(allocator, matches);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        for (0..match.capture_count) |i| {
            const capture = match.captures[i];
            const node = capture.node;

            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &name_len);
            const capture_name = try allocator.dupe(u8, name_ptr[0..name_len]);
            errdefer allocator.free(capture_name);

            try matches.append(allocator, .{
                .start_byte = c.ts_node_start_byte(node),
                .end_byte = c.ts_node_end_byte(node),
                .capture_name = capture_name,
            });
        }
    }

    return matches;
}

fn freeMatches(allocator: std.mem.Allocator, matches: std.ArrayList(Match)) void {
    var m = matches;
    for (m.items) |match| {
        allocator.free(match.capture_name);
    }
    m.deinit(allocator);
}
