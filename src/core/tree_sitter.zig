const std = @import("std");
const build_options = @import("build_options");
const mini_regex = @import("mini_regex.zig");
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
    // Like upstream's own configuration (tree-sitter-cpp's `highlights` lists
    // tree-sitter-c's query first), the C++ query only holds what C++ adds on
    // top of C - on its own it highlights next to nothing.
    pub const cpp = @embedFile("../deps/tree-sitter-c/queries/highlights.scm") ++ "\n" ++ @embedFile("../deps/tree-sitter-cpp/queries/highlights.scm");
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
// explicitly deleted - a crash was found inside this vendored tree-sitter
// snapshot's own ts_wasm_store_delete cleanup (see the Phase 2 WASM spike
// test). Since znip is a short-lived, one-shot CLI process, leaking these for
// process lifetime is an acceptable stance; revisit if this is ever used in a
// long-lived process.
//
// Note that ts_parser_set_wasm_store transfers ownership of the store to the
// parser (ts_parser_delete frees it), so a parser borrowing this registry's
// store must hand it back with ts_parser_take_wasm_store before it is deleted
// (see Parser.sourceCodeMatches); otherwise the registry is left dangling.
pub const LanguageRegistry = struct {
    allocator: std.mem.Allocator,
    wasm_engine: ?*c.TSWasmEngine = null,
    wasm_store: ?*c.TSWasmStore = null,
    // Entries are individually heap-allocated so the `*const DynamicLanguage`
    // handed out by resolve() stays valid when the map rehashes on a later put.
    loaded: std.StringHashMap(*DynamicLanguage),

    pub fn init(allocator: std.mem.Allocator) LanguageRegistry {
        return .{
            .allocator = allocator,
            .loaded = std.StringHashMap(*DynamicLanguage).init(allocator),
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

        if (self.loaded.get(name)) |existing| return existing;
        if (!@import("grammar_cache.zig").isValidGrammarName(name)) return null;

        const home = @import("config.zig").homeDir(self.allocator) catch return null;
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

        // tree-sitter reads the language name as a C string.
        const dir_name_z = try self.allocator.dupeZ(u8, dir_name);
        defer self.allocator.free(dir_name_z);

        var wasm_err: c.TSWasmError = undefined;
        const ts_language = c.ts_wasm_store_load_language(store, dir_name_z.ptr, wasm_bytes.ptr, @intCast(wasm_bytes.len), &wasm_err) orelse {
            std.log.err("ts_wasm_store_load_language failed for '{s}': kind={d} message={s}", .{ dir_name, wasm_err.kind, wasm_err.message });
            return error.WasmLanguageLoadFailed;
        };

        const owned_register_key = try self.allocator.dupe(u8, register_as);
        const owned_display_name = try self.allocator.dupe(u8, dir_name);
        const entry = try self.allocator.create(DynamicLanguage);
        entry.* = .{
            .name = owned_display_name,
            .ts_language = ts_language,
            .highlights_query = query_source,
        };
        try self.loaded.put(owned_register_key, entry);

        return entry;
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

            var parsed = std.json.parseFromSlice(CachedGrammarMeta, self.allocator, meta_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue;
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

/// Evaluates the text predicates of a query pattern (`#eq?`, `#match?`,
/// `#any-of?`, ... and their `not-`/`any-` variants). libtree-sitter only
/// parses predicates; it leaves running them to the caller, and without that a
/// pattern like `((identifier) @constant (#match? @constant "^[A-Z]"))` would
/// capture every identifier.
///
/// Predicates that aren't text filters (`#set!`, `#is-not?`, ...), unknown
/// ones, and `#match?` patterns outside mini_regex's supported subset are
/// treated as satisfied, i.e. they don't filter anything.
const PredicateEvaluator = struct {
    arena: std.heap.ArenaAllocator,
    regexes: std.StringHashMapUnmanaged(?mini_regex.Regex) = .empty,
    lua_patterns: std.StringHashMapUnmanaged(?mini_regex.Regex) = .empty,

    const Op = enum { eq, match, lua_match, any_of };
    const ParsedName = struct { op: Op, negate: bool, any: bool };

    fn init(allocator: std.mem.Allocator) PredicateEvaluator {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *PredicateEvaluator) void {
        self.arena.deinit();
    }

    fn parseName(name: []const u8) ?ParsedName {
        var rest = name;
        var negate = false;
        var any = false;
        while (true) {
            if (std.mem.startsWith(u8, rest, "not-")) {
                negate = true;
                rest = rest["not-".len..];
            } else if (std.mem.startsWith(u8, rest, "any-") and !std.mem.eql(u8, rest, "any-of?")) {
                any = true;
                rest = rest["any-".len..];
            } else break;
        }
        const op: Op = if (std.mem.eql(u8, rest, "eq?"))
            .eq
        else if (std.mem.eql(u8, rest, "match?"))
            .match
        else if (std.mem.eql(u8, rest, "lua-match?"))
            .lua_match
        else if (std.mem.eql(u8, rest, "any-of?"))
            .any_of
        else
            return null;
        return .{ .op = op, .negate = negate, .any = any };
    }

    /// Whether every predicate attached to the pattern `match` came from holds.
    fn matchPasses(self: *PredicateEvaluator, query: *const c.TSQuery, match: c.TSQueryMatch, source: []const u8) bool {
        var step_count: u32 = 0;
        const steps = c.ts_query_predicates_for_pattern(query, match.pattern_index, &step_count);
        if (step_count == 0) return true;

        // The steps are every predicate of the pattern back to back, each
        // terminated by a `Done` step.
        var i: usize = 0;
        while (i < step_count) {
            const start = i;
            while (i < step_count and steps[i].type != c.TSQueryPredicateStepTypeDone) i += 1;
            const predicate = steps[start..i];
            i += 1;
            if (predicate.len == 0) continue;
            if (!self.predicatePasses(query, match, source, predicate)) return false;
        }
        return true;
    }

    fn predicatePasses(self: *PredicateEvaluator, query: *const c.TSQuery, match: c.TSQueryMatch, source: []const u8, predicate: []const c.TSQueryPredicateStep) bool {
        if (predicate[0].type != c.TSQueryPredicateStepTypeString) return true;
        const parsed = parseName(stringValue(query, predicate[0].value_id)) orelse return true;

        const args = predicate[1..];
        if (args.len < 2 or args[0].type != c.TSQueryPredicateStepTypeCapture) return true;

        // A capture can hold several nodes (quantified captures): by default
        // all of them must satisfy the predicate, with `any-` just one.
        var seen = false;
        var all_ok = true;
        var any_ok = false;
        for (match.captures[0..match.capture_count]) |capture| {
            if (capture.index != args[0].value_id) continue;
            const satisfied = self.textSatisfies(query, match, source, parsed.op, args[1..], nodeText(source, capture.node)) orelse continue;
            seen = true;
            if (satisfied != parsed.negate) any_ok = true else all_ok = false;
        }
        if (!seen) return true; // e.g. an optional capture that didn't match
        return if (parsed.any) any_ok else all_ok;
    }

    /// null means "can't evaluate" (malformed predicate, unsupported regex).
    fn textSatisfies(self: *PredicateEvaluator, query: *const c.TSQuery, match: c.TSQueryMatch, source: []const u8, op: Op, operands: []const c.TSQueryPredicateStep, text: []const u8) ?bool {
        switch (op) {
            .eq => {
                const operand = operands[0];
                if (operand.type == c.TSQueryPredicateStepTypeString) {
                    return std.mem.eql(u8, text, stringValue(query, operand.value_id));
                }
                if (operand.type != c.TSQueryPredicateStepTypeCapture) return null;
                for (match.captures[0..match.capture_count]) |other| {
                    if (other.index == operand.value_id) return std.mem.eql(u8, text, nodeText(source, other.node));
                }
                return null;
            },
            .match, .lua_match => {
                if (operands[0].type != c.TSQueryPredicateStepTypeString) return null;
                const regex = self.regexFor(stringValue(query, operands[0].value_id), if (op == .match) .regex else .lua) orelse return null;
                return regex.isMatch(text);
            },
            .any_of => {
                for (operands) |operand| {
                    if (operand.type != c.TSQueryPredicateStepTypeString) return null;
                    if (std.mem.eql(u8, text, stringValue(query, operand.value_id))) return true;
                }
                return false;
            },
        }
    }

    /// Compiled (and cached) pattern, or null if it uses unsupported syntax.
    fn regexFor(self: *PredicateEvaluator, pattern: []const u8, flavor: mini_regex.Flavor) ?mini_regex.Regex {
        const arena = self.arena.allocator();
        const cache = if (flavor == .regex) &self.regexes else &self.lua_patterns;
        const entry = cache.getOrPut(arena, pattern) catch return null;
        if (!entry.found_existing) {
            entry.value_ptr.* = mini_regex.Regex.compile(arena, pattern, flavor) catch null;
        }
        return entry.value_ptr.*;
    }

    fn stringValue(query: *const c.TSQuery, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = c.ts_query_string_value_for_id(query, id, &len);
        return ptr[0..len];
    }

    fn nodeText(source: []const u8, node: c.TSNode) []const u8 {
        const end = @min(c.ts_node_end_byte(node), source.len);
        const start = @min(c.ts_node_start_byte(node), end);
        return source[start..end];
    }
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
        // The parser owns the store it was given and would free it on delete,
        // but the registry still references it (and every language loaded into
        // it), so take it back first. Registered after the delete above so it
        // runs before it.
        defer if (detected_language == .dynamic) {
            _ = c.ts_parser_take_wasm_store(parser);
        };
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

        var predicates = PredicateEvaluator.init(self.allocator);
        defer predicates.deinit();

        var matches = std.ArrayList(Match).empty;
        errdefer {
            for (matches.items) |m| {
                self.allocator.free(m.capture_name);
            }
            matches.deinit(self.allocator);
        }
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!predicates.matchPasses(query, match, self.source_code)) continue;
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
        if (eqExt(ext, ".py") or eqExt(ext, ".pyi")) return .python;
        // tree-sitter-javascript's grammar covers JSX.
        if (eqExt(ext, ".js") or eqExt(ext, ".mjs") or eqExt(ext, ".cjs") or eqExt(ext, ".jsx")) return .javascript;
        if (eqExt(ext, ".ts") or eqExt(ext, ".tsx") or eqExt(ext, ".mts") or eqExt(ext, ".cts")) return .typescript;
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
            // Only the text is ours: capture names are shared with `matches`
            // (or are the literal "" for gaps), which own/outlive them.
            for (tokens.items) |t| self.allocator.free(t.text);
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

const NL = NativeLanguageId;

test "candidateNameFromPath returns the extension without its dot" {
    try std.testing.expectEqualStrings("cob", candidateNameFromPath("prog.cob").?);
    try std.testing.expectEqualStrings("rs", candidateNameFromPath("/a/b/main.rs").?);
    try std.testing.expectEqualStrings("gz", candidateNameFromPath("archive.tar.gz").?);
    try std.testing.expectEqualStrings("RS", candidateNameFromPath("MAIN.RS").?);
}

test "candidateNameFromPath returns null without a usable extension" {
    try std.testing.expect(candidateNameFromPath("Makefile") == null);
    try std.testing.expect(candidateNameFromPath("trailing.") == null);
    try std.testing.expect(candidateNameFromPath(".bashrc") == null);
    try std.testing.expect(candidateNameFromPath("dir.d/file") == null);
    try std.testing.expect(candidateNameFromPath("") == null);
}

test "nativeLanguageFromHint maps names and aliases" {
    const cases = [_]struct { []const u8, NL }{
        .{ "zig", .zig },
        .{ "rust", .rust },
        .{ "rs", .rust },
        .{ "python", .python },
        .{ "py", .python },
        .{ "javascript", .javascript },
        .{ "js", .javascript },
        .{ "jsx", .javascript },
        .{ "typescript", .typescript },
        .{ "ts", .typescript },
        .{ "tsx", .typescript },
        .{ "c", .c },
        .{ "cpp", .cpp },
        .{ "c++", .cpp },
        .{ "cc", .cpp },
        .{ "cxx", .cpp },
        .{ "go", .go },
        .{ "golang", .go },
        .{ "html", .html },
        .{ "css", .css },
        .{ "java", .java },
        .{ "ruby", .ruby },
        .{ "rb", .ruby },
        .{ "json", .json },
        .{ "php", .php },
        .{ "markdown", .markdown },
        .{ "md", .markdown },
        .{ "sql", .sql },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(?NL, case[1]), nativeLanguageFromHint(case[0]));
    }
}

test "nativeLanguageFromHint ignores case" {
    try std.testing.expectEqual(@as(?NL, .rust), nativeLanguageFromHint("RUST"));
    try std.testing.expectEqual(@as(?NL, .cpp), nativeLanguageFromHint("C++"));
    try std.testing.expectEqual(@as(?NL, .typescript), nativeLanguageFromHint("TsX"));
}

test "nativeLanguageFromHint returns null for unknown or malformed names" {
    try std.testing.expect(nativeLanguageFromHint("cobol") == null);
    try std.testing.expect(nativeLanguageFromHint("") == null);
    try std.testing.expect(nativeLanguageFromHint(" rust") == null);
    try std.testing.expect(nativeLanguageFromHint("rust ") == null);
    try std.testing.expect(nativeLanguageFromHint(".rs") == null);
}

test "every native language is reachable through a hint" {
    for (std.meta.tags(NL)) |lang| {
        try std.testing.expectEqual(@as(?NL, lang), nativeLanguageFromHint(Parser.nativeLanguageName(lang)));
    }
}

test "native_languages lists each language exactly once" {
    try std.testing.expectEqual(std.meta.tags(NL).len, native_languages.len);
    for (native_languages, 0..) |a, i| {
        for (native_languages[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
}

test "detectLanguageFromPath maps every supported extension" {
    const cases = [_]struct { []const u8, NL }{
        .{ "a.zig", .zig },
        .{ "a.rs", .rust },
        .{ "a.py", .python },
        .{ "a.pyi", .python },
        .{ "a.js", .javascript },
        .{ "a.jsx", .javascript },
        .{ "a.mjs", .javascript },
        .{ "a.cjs", .javascript },
        .{ "a.ts", .typescript },
        .{ "a.tsx", .typescript },
        .{ "a.mts", .typescript },
        .{ "a.cts", .typescript },
        .{ "a.c", .c },
        .{ "a.cpp", .cpp },
        .{ "a.cc", .cpp },
        .{ "a.cxx", .cpp },
        .{ "a.hpp", .cpp },
        .{ "a.hh", .cpp },
        .{ "a.hxx", .cpp },
        .{ "a.go", .go },
        .{ "a.html", .html },
        .{ "a.htm", .html },
        .{ "a.css", .css },
        .{ "a.java", .java },
        .{ "a.rb", .ruby },
        .{ "a.json", .json },
        .{ "a.php", .php },
        .{ "a.md", .markdown },
        .{ "a.markdown", .markdown },
        .{ "a.sql", .sql },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(?NL, case[1]), Parser.detectLanguageFromPath(case[0]));
    }
}

test "detectLanguageFromPath ignores case and uses only the last extension" {
    try std.testing.expectEqual(@as(?NL, .rust), Parser.detectLanguageFromPath("MAIN.RS"));
    try std.testing.expectEqual(@as(?NL, .json), Parser.detectLanguageFromPath("/x/y/data.JSON"));
    try std.testing.expectEqual(@as(?NL, .javascript), Parser.detectLanguageFromPath("bundle.min.js"));
    try std.testing.expect(Parser.detectLanguageFromPath("main.rs.bak") == null);
}

test "detectLanguageFromPath returns null for unknown or missing extensions" {
    try std.testing.expect(Parser.detectLanguageFromPath("Makefile") == null);
    try std.testing.expect(Parser.detectLanguageFromPath("notes.txt") == null);
    try std.testing.expect(Parser.detectLanguageFromPath("prog.cob") == null);
    try std.testing.expect(Parser.detectLanguageFromPath("dir.zig/file") == null);
    try std.testing.expect(Parser.detectLanguageFromPath(".zig") == null);
    try std.testing.expect(Parser.detectLanguageFromPath("") == null);
}

test "extractFenceTag reads the tag from a leading code fence" {
    try std.testing.expectEqualStrings("rust", Parser.extractFenceTag("```rust\nfn main() {}").?);
    try std.testing.expectEqualStrings("rust", Parser.extractFenceTag("```rust").?);
    try std.testing.expectEqualStrings("py", Parser.extractFenceTag("  ```py  \nx = 1").?);
    try std.testing.expectEqualStrings("js", Parser.extractFenceTag("``` js \r\nlet x").?);
}

test "extractFenceTag returns null without a fence or tag" {
    try std.testing.expect(Parser.extractFenceTag("```\ncode") == null);
    try std.testing.expect(Parser.extractFenceTag("```") == null);
    try std.testing.expect(Parser.extractFenceTag("fn main() {}") == null);
    try std.testing.expect(Parser.extractFenceTag("") == null);
    try std.testing.expect(Parser.extractFenceTag("code\n```rust\n") == null);
    try std.testing.expect(Parser.extractFenceTag("``rust\n") == null);
}

test "detectLanguageFromFence resolves native tags only" {
    try std.testing.expectEqual(@as(?NL, .python), Parser.detectLanguageFromFence("```python\nx = 1"));
    try std.testing.expectEqual(@as(?NL, .typescript), Parser.detectLanguageFromFence("```ts\nlet x"));
    try std.testing.expectEqual(@as(?NL, .cpp), Parser.detectLanguageFromFence("```c++\nint x;"));
    try std.testing.expect(Parser.detectLanguageFromFence("```cobol\nMOVE") == null);
    try std.testing.expect(Parser.detectLanguageFromFence("```\nplain") == null);
    try std.testing.expect(Parser.detectLanguageFromFence("no fence") == null);
}

test "detectLanguageFromShebang recognizes python, ruby and javascript runtimes" {
    try std.testing.expectEqual(@as(?NL, .python), Parser.detectLanguageFromShebang("#!/usr/bin/env python3\nprint(1)"));
    try std.testing.expectEqual(@as(?NL, .python), Parser.detectLanguageFromShebang("#!/usr/bin/python"));
    try std.testing.expectEqual(@as(?NL, .ruby), Parser.detectLanguageFromShebang("#!/usr/bin/env ruby\nputs 1"));
    try std.testing.expectEqual(@as(?NL, .javascript), Parser.detectLanguageFromShebang("#!/usr/bin/env node\n"));
    try std.testing.expectEqual(@as(?NL, .javascript), Parser.detectLanguageFromShebang("#!/usr/bin/env -S deno run\n"));
    try std.testing.expectEqual(@as(?NL, .javascript), Parser.detectLanguageFromShebang("#!/usr/bin/env bun\n"));
}

test "detectLanguageFromShebang ignores case and surrounding whitespace" {
    try std.testing.expectEqual(@as(?NL, .python), Parser.detectLanguageFromShebang("#!/usr/bin/env PYTHON\n"));
    try std.testing.expectEqual(@as(?NL, .ruby), Parser.detectLanguageFromShebang("  #!/usr/bin/ruby \r\n"));
}

test "detectLanguageFromShebang returns null when there is nothing to detect" {
    try std.testing.expect(Parser.detectLanguageFromShebang("#!/bin/bash\necho hi") == null);
    try std.testing.expect(Parser.detectLanguageFromShebang("# python script") == null);
    try std.testing.expect(Parser.detectLanguageFromShebang("print(1)\n#!/usr/bin/env python") == null);
    try std.testing.expect(Parser.detectLanguageFromShebang("") == null);
    try std.testing.expect(Parser.detectLanguageFromShebang("#!") == null);
}

test "containsIgnoreCase finds substrings regardless of case" {
    try std.testing.expect(Parser.containsIgnoreCase("Hello World", "WORLD"));
    try std.testing.expect(Parser.containsIgnoreCase("Hello", "hello"));
    try std.testing.expect(Parser.containsIgnoreCase("abc", "c"));
    try std.testing.expect(Parser.containsIgnoreCase("abc", ""));
    try std.testing.expect(Parser.containsIgnoreCase("", ""));
}

test "containsIgnoreCase rejects absent or oversized needles" {
    try std.testing.expect(!Parser.containsIgnoreCase("abc", "d"));
    try std.testing.expect(!Parser.containsIgnoreCase("ab", "abc"));
    try std.testing.expect(!Parser.containsIgnoreCase("", "a"));
}

test "computeScore rewards named nodes, depth and named ratio" {
    // 2 * 5 named + 1 * 3 depth + 80 * (5 / 10) ratio
    const stats = TreeStats{ .total_nodes = 10, .named_nodes = 5, .max_depth = 3 };
    try std.testing.expectApproxEqAbs(@as(f64, 53.0), Parser.computeScore(stats), 1e-9);
}

test "computeScore of an empty tree is zero" {
    try std.testing.expectEqual(@as(f64, 0.0), Parser.computeScore(.{}));
}

test "computeScore ignores errors and missing nodes" {
    const clean = TreeStats{ .total_nodes = 10, .named_nodes = 5, .max_depth = 3 };
    const dirty = TreeStats{ .total_nodes = 10, .named_nodes = 5, .max_depth = 3, .error_nodes = 4, .missing_nodes = 2, .has_error = true };
    try std.testing.expectEqual(Parser.computeScore(clean), Parser.computeScore(dirty));
}

test "isBetterCandidate prefers a clean parse over a higher-scoring defective one" {
    const clean = TreeStats{ .has_error = false };
    const dirty = TreeStats{ .has_error = true, .error_nodes = 1 };
    try std.testing.expect(Parser.isBetterCandidate(clean, 1.0, dirty, 1000.0));
    try std.testing.expect(!Parser.isBetterCandidate(dirty, 1000.0, clean, 1.0));
}

test "isBetterCandidate prefers fewer defects when both have errors" {
    const few = TreeStats{ .has_error = true, .error_nodes = 1 };
    const many = TreeStats{ .has_error = true, .error_nodes = 1, .missing_nodes = 2 };
    try std.testing.expect(Parser.isBetterCandidate(few, 1.0, many, 1000.0));
    try std.testing.expect(!Parser.isBetterCandidate(many, 1000.0, few, 1.0));
}

test "isBetterCandidate counts error and missing nodes alike" {
    const errors = TreeStats{ .has_error = true, .error_nodes = 2 };
    const missing = TreeStats{ .has_error = true, .missing_nodes = 2 };
    // Equal defect counts fall through to the score.
    try std.testing.expect(Parser.isBetterCandidate(errors, 10.0, missing, 5.0));
    try std.testing.expect(!Parser.isBetterCandidate(errors, 5.0, missing, 10.0));
}

test "isBetterCandidate compares scores between equally clean parses" {
    const a = TreeStats{};
    try std.testing.expect(Parser.isBetterCandidate(a, 10.0, a, 9.0));
    try std.testing.expect(!Parser.isBetterCandidate(a, 9.0, a, 10.0));
}

test "isBetterCandidate does not replace on an exact tie" {
    const a = TreeStats{};
    try std.testing.expect(!Parser.isBetterCandidate(a, 7.0, a, 7.0));
}

test "categorizeCapture maps variable captures, most specific first" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.variable_parameter, TC.categorizeCapture("variable.parameter"));
    try std.testing.expectEqual(TC.variable_parameter, TC.categorizeCapture("variable.parameter.builtin"));
    try std.testing.expectEqual(TC.variable_member, TC.categorizeCapture("variable.member"));
    try std.testing.expectEqual(TC.variable_builtin, TC.categorizeCapture("variable.builtin"));
    try std.testing.expectEqual(TC.variable, TC.categorizeCapture("variable"));
    try std.testing.expectEqual(TC.variable, TC.categorizeCapture("variable.other"));
}

test "categorizeCapture maps type, tag and string captures" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.type_builtin, TC.categorizeCapture("type.builtin"));
    try std.testing.expectEqual(TC.type, TC.categorizeCapture("type"));
    try std.testing.expectEqual(TC.type, TC.categorizeCapture("type.definition"));
    try std.testing.expectEqual(TC.tag_attribute, TC.categorizeCapture("tag.attribute"));
    try std.testing.expectEqual(TC.tag, TC.categorizeCapture("tag"));
    try std.testing.expectEqual(TC.tag, TC.categorizeCapture("tag.delimiter"));
    try std.testing.expectEqual(TC.string_special, TC.categorizeCapture("string.special"));
    try std.testing.expectEqual(TC.string_special, TC.categorizeCapture("string.special.url"));
    try std.testing.expectEqual(TC.string_escape, TC.categorizeCapture("string.escape"));
    try std.testing.expectEqual(TC.string, TC.categorizeCapture("string"));
    try std.testing.expectEqual(TC.string, TC.categorizeCapture("string.documentation"));
}

test "categorizeCapture maps punctuation, property, operator and number captures" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.punctuation_delimiter, TC.categorizeCapture("punctuation.delimiter"));
    try std.testing.expectEqual(TC.punctuation_bracket, TC.categorizeCapture("punctuation.bracket"));
    try std.testing.expectEqual(TC.punctuation, TC.categorizeCapture("punctuation"));
    try std.testing.expectEqual(TC.punctuation, TC.categorizeCapture("punctuation.special"));
    try std.testing.expectEqual(TC.property, TC.categorizeCapture("property"));
    try std.testing.expectEqual(TC.operator, TC.categorizeCapture("operator"));
    try std.testing.expectEqual(TC.number, TC.categorizeCapture("number"));
    try std.testing.expectEqual(TC.number, TC.categorizeCapture("number.float"));
}

test "categorizeCapture maps keyword captures, most specific first" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.keyword_return, TC.categorizeCapture("keyword.return"));
    try std.testing.expectEqual(TC.keyword_operator, TC.categorizeCapture("keyword.operator"));
    try std.testing.expectEqual(TC.keyword_modifier, TC.categorizeCapture("keyword.modifier"));
    try std.testing.expectEqual(TC.keyword_function, TC.categorizeCapture("keyword.function"));
    try std.testing.expectEqual(TC.keyword, TC.categorizeCapture("keyword"));
    try std.testing.expectEqual(TC.keyword, TC.categorizeCapture("keyword.conditional"));
    try std.testing.expectEqual(TC.keyword, TC.categorizeCapture("keyword.repeat"));
}

test "categorizeCapture maps function, field, constructor, constant and comment captures" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.function_method, TC.categorizeCapture("function.method"));
    try std.testing.expectEqual(TC.function_call, TC.categorizeCapture("function.call"));
    try std.testing.expectEqual(TC.function_builtin, TC.categorizeCapture("function.builtin"));
    try std.testing.expectEqual(TC.function, TC.categorizeCapture("function"));
    try std.testing.expectEqual(TC.function, TC.categorizeCapture("function.macro"));
    try std.testing.expectEqual(TC.field, TC.categorizeCapture("field"));
    try std.testing.expectEqual(TC.constructor, TC.categorizeCapture("constructor"));
    try std.testing.expectEqual(TC.constant, TC.categorizeCapture("constant"));
    try std.testing.expectEqual(TC.constant, TC.categorizeCapture("constant.builtin"));
    try std.testing.expectEqual(TC.comment, TC.categorizeCapture("comment"));
    try std.testing.expectEqual(TC.comment, TC.categorizeCapture("comment.documentation"));
}

test "categorizeCapture falls back to default_text for unknown or empty names" {
    const TC = TokenCategory;
    try std.testing.expectEqual(TC.default_text, TC.categorizeCapture(""));
    try std.testing.expectEqual(TC.default_text, TC.categorizeCapture("unknown.thing"));
    try std.testing.expectEqual(TC.default_text, TC.categorizeCapture("spell"));
    // Matching is by case-sensitive prefix.
    try std.testing.expectEqual(TC.default_text, TC.categorizeCapture("Variable"));
    try std.testing.expectEqual(TC.default_text, TC.categorizeCapture(".variable"));
}

/// Runs `sourceCodeTokens` over hand-built matches. Uses an arena because the
/// function takes ownership of kept capture names and drops skipped ones.
fn tokensFor(arena: std.mem.Allocator, source: [:0]const u8, spans: []const Match) !std.ArrayList(Token) {
    var parser = Parser.init(arena, source, null);
    var matches = std.ArrayList(Match).empty;
    try matches.appendSlice(arena, spans);
    return parser.sourceCodeTokens(matches);
}

fn expectToken(token: Token, text: []const u8, capture: []const u8, is_newline: bool) !void {
    try std.testing.expectEqualStrings(text, token.text);
    try std.testing.expectEqualStrings(capture, token.capture_name);
    try std.testing.expectEqual(is_newline, token.is_newline);
}

test "sourceCodeTokens with no matches yields the source as one plain token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "abc def", &.{});
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try expectToken(tokens.items[0], "abc def", "", false);
}

test "sourceCodeTokens of an empty source is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "", &.{});
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "sourceCodeTokens fills the gaps between matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "fn main", &.{
        .{ .start_byte = 0, .end_byte = 2, .capture_name = "keyword" },
        .{ .start_byte = 3, .end_byte = 7, .capture_name = "function" },
    });
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try expectToken(tokens.items[0], "fn", "keyword", false);
    try expectToken(tokens.items[1], " ", "", false);
    try expectToken(tokens.items[2], "main", "function", false);
}

test "sourceCodeTokens emits no gap token for adjacent matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "ab", &.{
        .{ .start_byte = 0, .end_byte = 1, .capture_name = "a" },
        .{ .start_byte = 1, .end_byte = 2, .capture_name = "b" },
    });
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try expectToken(tokens.items[0], "a", "a", false);
    try expectToken(tokens.items[1], "b", "b", false);
}

test "sourceCodeTokens keeps leading and trailing text outside any match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "  x ;", &.{
        .{ .start_byte = 2, .end_byte = 3, .capture_name = "variable" },
    });
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try expectToken(tokens.items[0], "  ", "", false);
    try expectToken(tokens.items[1], "x", "variable", false);
    try expectToken(tokens.items[2], " ;", "", false);
}

test "sourceCodeTokens flags a gap of exactly one newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "a\nb", &.{
        .{ .start_byte = 0, .end_byte = 1, .capture_name = "x" },
        .{ .start_byte = 2, .end_byte = 3, .capture_name = "y" },
    });
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try expectToken(tokens.items[1], "\n", "", true);
}

test "sourceCodeTokens does not flag longer or mixed gaps as newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "a\n\nb c\r\nd \ne", &.{
        .{ .start_byte = 0, .end_byte = 1, .capture_name = "t" },
        .{ .start_byte = 3, .end_byte = 4, .capture_name = "t" },
        .{ .start_byte = 5, .end_byte = 6, .capture_name = "t" },
        .{ .start_byte = 8, .end_byte = 9, .capture_name = "t" },
        .{ .start_byte = 11, .end_byte = 12, .capture_name = "t" },
    });
    for (tokens.items) |t| try std.testing.expect(!t.is_newline);
}

test "sourceCodeTokens flags a trailing lone newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "a\n", &.{
        .{ .start_byte = 0, .end_byte = 1, .capture_name = "x" },
    });
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try expectToken(tokens.items[1], "\n", "", true);
}

test "sourceCodeTokens sorts out-of-order matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "ab cd", &.{
        .{ .start_byte = 3, .end_byte = 5, .capture_name = "second" },
        .{ .start_byte = 0, .end_byte = 2, .capture_name = "first" },
    });
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try expectToken(tokens.items[0], "ab", "first", false);
    try expectToken(tokens.items[1], " ", "", false);
    try expectToken(tokens.items[2], "cd", "second", false);
}

test "sourceCodeTokens keeps the wider match when two start at the same byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Listed narrow-first on purpose: sorting must still put the wide one first.
    const tokens = try tokensFor(arena.allocator(), "hello", &.{
        .{ .start_byte = 0, .end_byte = 2, .capture_name = "inner" },
        .{ .start_byte = 0, .end_byte = 5, .capture_name = "outer" },
    });
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try expectToken(tokens.items[0], "hello", "outer", false);
}

test "sourceCodeTokens skips matches nested inside an earlier one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "0123456789", &.{
        .{ .start_byte = 0, .end_byte = 10, .capture_name = "outer" },
        .{ .start_byte = 3, .end_byte = 5, .capture_name = "nested" },
    });
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try expectToken(tokens.items[0], "0123456789", "outer", false);
}

test "sourceCodeTokens skips a partially overlapping match and keeps the rest as plain text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokensFor(arena.allocator(), "abcdefgh", &.{
        .{ .start_byte = 0, .end_byte = 4, .capture_name = "A" },
        .{ .start_byte = 2, .end_byte = 6, .capture_name = "B" },
    });
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try expectToken(tokens.items[0], "abcd", "A", false);
    try expectToken(tokens.items[1], "efgh", "", false);
}

test "sourceCodeTokens hands matched capture names to the tokens without copying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const name: []const u8 = "keyword";
    const tokens = try tokensFor(arena.allocator(), "fn", &.{
        .{ .start_byte = 0, .end_byte = 2, .capture_name = name },
    });
    try std.testing.expect(tokens.items[0].capture_name.ptr == name.ptr);
}

test "sourceCodeTokens copies token text out of the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 = "fn x";
    const tokens = try tokensFor(arena.allocator(), source, &.{
        .{ .start_byte = 0, .end_byte = 2, .capture_name = "keyword" },
    });
    try std.testing.expect(tokens.items[0].text.ptr != source.ptr);
}

test "sourceCodeTokens text always reassembles the source when matches don't overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "const x = 1;\n// hi\n";
    const tokens = try tokensFor(allocator, source, &.{
        .{ .start_byte = 0, .end_byte = 5, .capture_name = "keyword" },
        .{ .start_byte = 6, .end_byte = 7, .capture_name = "variable" },
        .{ .start_byte = 10, .end_byte = 11, .capture_name = "number" },
        .{ .start_byte = 13, .end_byte = 18, .capture_name = "comment" },
    });

    var rebuilt = std.ArrayList(u8).empty;
    for (tokens.items) |t| try rebuilt.appendSlice(allocator, t.text);
    try std.testing.expectEqualStrings(source, rebuilt.items);
}

// ---------------------------------------------------------------------------
// Integration tests: these run the real, statically linked tree-sitter
// grammars and highlight queries (no mocks).
// ---------------------------------------------------------------------------

const LanguageSample = struct {
    lang: []const u8,
    source: [:0]const u8,
    /// Tokens (by exact text) that must be highlighted with the given category.
    expect: []const struct { []const u8, TokenCategory },
};

const language_samples = [_]LanguageSample{
    .{
        .lang = "zig",
        .source = "const std = @import(\"std\");\n\npub fn main() void {\n    const x: u32 = 5;\n    return;\n}\n",
        .expect = &.{
            .{ "const", .keyword },
            .{ "pub", .keyword_modifier },
            .{ "fn", .keyword_function },
            .{ "main", .function },
            .{ "void", .type_builtin },
            .{ "u32", .type_builtin },
            .{ "5", .number },
            .{ "return", .keyword_return },
            .{ "\"std\"", .string },
        },
    },
    .{
        .lang = "rust",
        .source = "fn main() {\n    let x: i32 = 5;\n    println!(\"{}\", x);\n}\n",
        .expect = &.{ .{ "fn", .keyword }, .{ "main", .function }, .{ "let", .keyword }, .{ "i32", .type_builtin }, .{ "\"{}\"", .string } },
    },
    .{
        .lang = "python",
        .source = "# note\ndef add(a, b):\n    return a + b\n\nprint(add(1, \"two\"))\n",
        .expect = &.{ .{ "# note", .comment }, .{ "def", .keyword }, .{ "add", .function }, .{ "1", .number }, .{ "\"two\"", .string } },
    },
    .{
        .lang = "javascript",
        .source = "// note\nfunction add(a, b) {\n  return a + b;\n}\nconsole.log(add(1, 2));\n",
        .expect = &.{ .{ "// note", .comment }, .{ "function", .keyword }, .{ "log", .function_method }, .{ "2", .number } },
    },
    .{
        .lang = "typescript",
        .source = "function add(a: number, b: number): number {\n  return a + b;\n}\n",
        .expect = &.{ .{ "number", .type_builtin }, .{ "a", .variable_parameter } },
    },
    .{
        .lang = "json",
        .source = "{\"a\": 1, \"b\": [true, false, null], \"c\": \"text\"}",
        .expect = &.{ .{ "\"a\"", .string_special }, .{ "1", .number }, .{ "true", .constant }, .{ "\"text\"", .string } },
    },
    .{
        .lang = "go",
        .source = "package main\n\nfunc main() {\n\tx := 5\n}\n",
        .expect = &.{ .{ "package", .keyword }, .{ "func", .keyword }, .{ "main", .function }, .{ ":=", .operator }, .{ "5", .number } },
    },
    .{
        .lang = "c",
        .source = "#include <stdio.h>\n\nint main(void) {\n    return 0;\n}\n",
        .expect = &.{ .{ "int", .type }, .{ "main", .function }, .{ "return", .keyword }, .{ "0", .number } },
    },
    .{
        .lang = "cpp",
        .source = "#include <iostream>\nint main() {\n    std::cout << 1;\n}\n",
        .expect = &.{ .{ "int", .type }, .{ "main", .function }, .{ "1", .number } },
    },
    .{
        .lang = "java",
        .source = "public class A {\n    public static void main(String[] args) {\n    }\n}\n",
        .expect = &.{ .{ "class", .keyword }, .{ "A", .type }, .{ "void", .type_builtin }, .{ "main", .function_method } },
    },
    .{
        .lang = "ruby",
        .source = "def add(a, b)\n  a + b\nend\nputs add(1, 2)\n",
        .expect = &.{ .{ "def", .keyword }, .{ "end", .keyword }, .{ "1", .number } },
    },
    .{
        .lang = "css",
        .source = "body {\n  color: red;\n}\n",
        .expect = &.{ .{ "body", .tag }, .{ "{", .punctuation_bracket } },
    },
    .{
        .lang = "html",
        .source = "<div class=\"a\">hi</div>\n",
        .expect = &.{ .{ "div", .tag }, .{ "<", .punctuation_bracket } },
    },
    .{
        .lang = "sql",
        .source = "SELECT id, name FROM users WHERE id = 1;\n",
        .expect = &.{ .{ "SELECT", .keyword }, .{ "FROM", .keyword }, .{ "WHERE", .keyword } },
    },
    .{
        .lang = "php",
        .source = "<?php\nfunction add($a, $b) {\n    return $a + $b;\n}\n",
        .expect = &.{ .{ "function", .keyword }, .{ "add", .function }, .{ "return", .keyword } },
    },
    .{
        .lang = "markdown",
        .source = "# Title\n\nSome *text* here.\n",
        .expect = &.{ .{ "#", .punctuation } },
    },
};

fn findCategory(tokens: []const Token, text: []const u8) ?TokenCategory {
    for (tokens) |t| {
        if (t.capture_name.len == 0) continue;
        if (std.mem.eql(u8, t.text, text)) return TokenCategory.categorizeCapture(t.capture_name);
    }
    return null;
}

fn expectReassembles(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token) !void {
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    for (tokens) |t| try rebuilt.appendSlice(allocator, t.text);
    try std.testing.expectEqualStrings(source, rebuilt.items);
}

test "every native grammar loads, parses and highlights its sample" {
    for (language_samples) |sample| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var parser = Parser.init(allocator, sample.source, null);
        parser.setRequestedLanguage(sample.lang);
        const matches = try parser.sourceCodeMatches();
        if (matches.items.len == 0) std.debug.print("{s}: no highlight matches at all\n", .{sample.lang});
        try std.testing.expect(matches.items.len > 0);

        const tokens = try parser.sourceCodeTokens(matches);
        try expectReassembles(allocator, sample.source, tokens.items);

        for (sample.expect) |want| {
            const got = findCategory(tokens.items, want[0]) orelse {
                std.debug.print("{s}: no highlighted token '{s}'\n", .{ sample.lang, want[0] });
                return error.TestUnexpectedResult;
            };
            if (got != want[1]) {
                std.debug.print("{s}: '{s}' is {s}, expected {s}\n", .{ sample.lang, want[0], @tagName(got), @tagName(want[1]) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "sourceCodeMatches never reports the spell capture" {
    for (language_samples) |sample| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var parser = Parser.init(arena.allocator(), sample.source, null);
        parser.setRequestedLanguage(sample.lang);
        const matches = try parser.sourceCodeMatches();
        for (matches.items) |m| {
            try std.testing.expect(!std.mem.eql(u8, m.capture_name, "spell"));
        }
    }
}

test "sourceCodeMatches reports valid byte spans inside the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 = "const x = 1;\n";
    var parser = Parser.init(arena.allocator(), source, "a.zig");
    const matches = try parser.sourceCodeMatches();
    try std.testing.expect(matches.items.len > 0);
    for (matches.items) |m| {
        try std.testing.expect(m.start_byte < m.end_byte);
        try std.testing.expect(m.end_byte <= source.len);
        try std.testing.expect(m.capture_name.len > 0);
    }
}

test "tokens use byte offsets, so multi-byte UTF-8 survives intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "s = \"héllo ✓\"\nn = 1\n";
    var parser = Parser.init(allocator, source, "a.py");
    const matches = try parser.sourceCodeMatches();
    const tokens = try parser.sourceCodeTokens(matches);

    try expectReassembles(allocator, source, tokens.items);
    try std.testing.expectEqual(@as(?TokenCategory, .string), findCategory(tokens.items, "\"héllo ✓\""));
    try std.testing.expectEqual(@as(?TokenCategory, .number), findCategory(tokens.items, "1"));
}

test "tokens preserve CRLF line endings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "x = 1\r\ny = 2\r\n";
    var parser = Parser.init(allocator, source, "a.py");
    const matches = try parser.sourceCodeMatches();
    const tokens = try parser.sourceCodeTokens(matches);
    try expectReassembles(allocator, source, tokens.items);
}

test "malformed source still tokenizes without crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn ((( }}} \x01 \"unterminated\n";
    var parser = Parser.init(allocator, source, "a.rs");
    const matches = try parser.sourceCodeMatches();
    const tokens = try parser.sourceCodeTokens(matches);
    try expectReassembles(allocator, source, tokens.items);
}

test "a source with no highlightable content yields a single plain token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "   \n  \n";
    var parser = Parser.init(allocator, source, null);
    const matches = try parser.sourceCodeMatches();
    const tokens = try parser.sourceCodeTokens(matches);
    try expectReassembles(allocator, source, tokens.items);
    for (tokens.items) |t| try std.testing.expectEqualStrings("", t.capture_name);
}

fn detect(source: [:0]const u8, hint: ?[]const u8, requested: ?[]const u8) !LanguageRef {
    var parser = Parser.init(std.testing.allocator, source, hint);
    if (requested) |name| parser.setRequestedLanguage(name);
    return parser.detectLanguage();
}

fn expectNative(expected: NL, actual: LanguageRef) !void {
    switch (actual) {
        .native => |n| try std.testing.expectEqual(expected, n),
        .dynamic => return error.TestUnexpectedResult,
    }
}

test "detectLanguage honours an explicit language over everything else" {
    try expectNative(.rust, try detect("def f(): pass", "a.py", "rust"));
    try expectNative(.rust, try detect("def f(): pass", null, "RS"));
    try expectNative(.cpp, try detect("", null, "c++"));
}

test "detectLanguage errors for an explicit language that is not available" {
    try std.testing.expectError(error.LanguageNotAvailable, detect("x", null, "cobol"));
    try std.testing.expectError(error.LanguageNotAvailable, detect("x", "a.rs", ""));
}

test "detectLanguage defaults empty and whitespace-only input to zig" {
    try expectNative(.zig, try detect("", null, null));
    try expectNative(.zig, try detect("  \n\t\r\n", null, null));
    try expectNative(.zig, try detect("   ", "main.py", null));
}

test "detectLanguage trusts the file extension over the content" {
    try expectNative(.rust, try detect("def add(a, b):\n    return a + b\n", "x.rs", null));
    try expectNative(.python, try detect("fn main() {}\n", "x.py", null));
    try expectNative(.json, try detect("print('hi')", "/some/dir/data.JSON", null));
}

test "detectLanguage prefers the extension over a fence tag and the fence over a shebang" {
    try expectNative(.python, try detect("```rust\nfn main() {}\n```", "x.py", null));
    try expectNative(.go, try detect("```go\npackage main\n```", null, null));
}

test "detectLanguage uses a code fence tag when there is no extension" {
    try expectNative(.rust, try detect("```rust\nlet x = 1;\n```", null, null));
    try expectNative(.typescript, try detect("```ts\nlet x = 1;\n```", "notes.txt", null));
}

test "detectLanguage uses a shebang when there is no other signal" {
    try expectNative(.python, try detect("#!/usr/bin/env python3\nx = 1\n", null, null));
    try expectNative(.ruby, try detect("#!/usr/bin/env ruby\nputs 1\n", null, null));
    try expectNative(.javascript, try detect("#!/usr/bin/env node\nlet x = 1;\n", null, null));
}

test "detectLanguage falls back to content scoring for unrecognized hints" {
    const python: [:0]const u8 = "def add(a, b):\n    return a + b\n\nprint(add(1, \"two\"))\n";
    try expectNative(.python, try detect(python, null, null));
    try expectNative(.python, try detect(python, "notes.txt", null));

    try expectNative(.java, try detect("public class A {\n    public static void main(String[] args) {\n    }\n}\n", null, null));
    try expectNative(.php, try detect("<?php\nfunction add($a, $b) {\n    return $a + $b;\n}\n", null, null));
}

test "detectLanguage only ever returns a native language without a registry" {
    for (language_samples) |sample| {
        const lang = try detect(sample.source, null, null);
        try std.testing.expect(lang == .native);
    }
}

test "detectLanguage only looks at the first 16KB of a large input" {
    const allocator = std.testing.allocator;
    var big = std.ArrayList(u8).empty;
    defer big.deinit(allocator);
    try big.appendNTimes(allocator, ' ', Parser.max_detection_bytes);
    try big.appendSlice(allocator, "\ndef f(a):\n    return a\n");
    const source = try allocator.dupeZ(u8, big.items);
    defer allocator.free(source);

    // Everything inside the detection window is blank, so it counts as empty
    // input and defaults to zig; the trailing Python is never considered.
    try expectNative(.zig, try detect(source, null, null));
}

// ---------------------------------------------------------------------------
// LanguageRegistry: on-disk grammar cache lookups (no WASM is ever loaded).
// ---------------------------------------------------------------------------

fn writeCachedGrammar(tmp: *std.testing.TmpDir, name: []const u8, meta_json: ?[]const u8) !void {
    try tmp.dir.makePath(name);
    if (meta_json) |meta| {
        var dir = try tmp.dir.openDir(name, .{});
        defer dir.close();
        try dir.writeFile(.{ .sub_path = "meta.json", .data = meta });
    }
}

fn expectCanonical(registry: *LanguageRegistry, dir_path: []const u8, name: []const u8, expected: ?[]const u8) !void {
    const found = try registry.findCanonicalNameByExtension(dir_path, name);
    defer if (found) |f| registry.allocator.free(f);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, found orelse return error.TestUnexpectedResult);
    } else {
        try std.testing.expect(found == null);
    }
}

test "findCanonicalNameByExtension maps an alias extension to its cache directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCachedGrammar(&tmp, "cobol", "{\"extensions\":[\".cob\",\".cbl\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "cob", "cobol");
    try expectCanonical(&registry, dir, "cbl", "cobol");
    try expectCanonical(&registry, dir, "COB", "cobol");
}

test "findCanonicalNameByExtension accepts extensions with or without a dot" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCachedGrammar(&tmp, "fortran", "{\"extensions\":[\"f90\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "f90", "fortran");
}

test "findCanonicalNameByExtension picks the right directory among several" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCachedGrammar(&tmp, "cobol", "{\"extensions\":[\".cob\"]}");
    try writeCachedGrammar(&tmp, "fortran", "{\"extensions\":[\".f90\"]}");
    try writeCachedGrammar(&tmp, "zeta", "{\"extensions\":[\".zzz\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "f90", "fortran");
    try expectCanonical(&registry, dir, "cob", "cobol");
    try expectCanonical(&registry, dir, "zzz", "zeta");
}

test "findCanonicalNameByExtension returns null for unknown extensions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCachedGrammar(&tmp, "cobol", "{\"extensions\":[\".cob\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "xyz", null);
    try expectCanonical(&registry, dir, "", null);
    try expectCanonical(&registry, dir, "cobo", null);
}

test "findCanonicalNameByExtension skips the directory named like the lookup" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Looked up directly by the caller first, so it must not match itself here.
    try writeCachedGrammar(&tmp, "cobol", "{\"extensions\":[\"cobol\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "cobol", null);
    try expectCanonical(&registry, dir, "COBOL", null);
}

test "findCanonicalNameByExtension ignores broken or missing meta files and stray files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCachedGrammar(&tmp, "nometa", null);
    try writeCachedGrammar(&tmp, "garbage", "{ this is not json");
    try writeCachedGrammar(&tmp, "wrongshape", "[1, 2, 3]");
    try tmp.dir.writeFile(.{ .sub_path = "cob", .data = "{\"extensions\":[\"cob\"]}" });
    try writeCachedGrammar(&tmp, "good", "{\"extensions\":[\".cob\"]}");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try expectCanonical(&registry, dir, "cob", "good");
}

test "findCanonicalNameByExtension returns null when the cache directory is missing" {
    const allocator = std.testing.allocator;
    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();
    try expectCanonical(&registry, "/definitely/not/a/dir", "cob", null);
}

test "loadFromDir returns null when the grammar files are not cached" {
    // loadFromDir references wasm-only symbols that don't link without wasm.
    if (comptime !build_options.wasm_enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("cobol");
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    // Directory missing entirely.
    try std.testing.expect(try registry.loadFromDir(dir, "nope", "nope") == null);
    // Directory present but empty.
    try std.testing.expect(try registry.loadFromDir(dir, "cobol", "cobol") == null);

    // Only the wasm is present: still not loadable, and nothing is registered.
    var cobol = try tmp.dir.openDir("cobol", .{});
    defer cobol.close();
    try cobol.writeFile(.{ .sub_path = "grammar.wasm", .data = "\x00asm" });
    try std.testing.expect(try registry.loadFromDir(dir, "cobol", "cobol") == null);
    try std.testing.expectEqual(@as(u32, 0), registry.loaded.count());
    try std.testing.expect(registry.wasm_store == null);
}

test "resolve returns null for a language that is not cached" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    @import("config.zig").home_dir_override = home;
    defer @import("config.zig").home_dir_override = null;

    var registry = LanguageRegistry.init(allocator);
    defer registry.loaded.deinit();

    try std.testing.expect(try registry.resolve("cobol") == null);

    try tmp.dir.makePath(".znip/grammars");
    try std.testing.expect(try registry.resolve("cobol") == null);
    try std.testing.expect(registry.wasm_store == null);
}

test "resolve returns an already-loaded language without touching the disk" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Point HOME somewhere that has nothing, so only the in-memory entry can hit.
    @import("config.zig").home_dir_override = "/definitely/not/a/home";
    defer @import("config.zig").home_dir_override = null;

    var registry = LanguageRegistry.init(arena.allocator());
    const preloaded = try arena.allocator().create(DynamicLanguage);
    preloaded.* = .{
        .name = "json",
        .ts_language = tree_sitter_json(),
        .highlights_query = HighlightsQueryMap.json,
    };
    try registry.loaded.put("json-alias", preloaded);

    if (comptime !build_options.wasm_enabled) {
        // Without wasm support the registry never resolves anything.
        try std.testing.expect(try registry.resolve("json-alias") == null);
        return;
    }

    const found = (try registry.resolve("json-alias")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("json", found.name);
    try std.testing.expect(found.ts_language == tree_sitter_json());
    try std.testing.expectEqual(registry.loaded.get("json-alias").?, found);
}

test "a Parser with a registry still uses native grammars for known languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = LanguageRegistry.init(allocator);
    var parser = Parser.init(allocator, "const x = 1;\n", "a.zig");
    parser.attachRegistry(&registry);

    try expectNative(.zig, try parser.detectLanguage());
    try std.testing.expect(registry.wasm_store == null);
}

test "a Parser with a registry reports an uncached explicit language as unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    @import("config.zig").home_dir_override = home;
    defer @import("config.zig").home_dir_override = null;

    var registry = LanguageRegistry.init(allocator);
    var parser = Parser.init(allocator, "MOVE 1 TO X.", null);
    parser.attachRegistry(&registry);
    parser.setRequestedLanguage("cobol");

    try std.testing.expectError(error.LanguageNotAvailable, parser.detectLanguage());
}

test "an unrecognized extension with a registry falls back to content scoring when nothing is cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    @import("config.zig").home_dir_override = home;
    defer @import("config.zig").home_dir_override = null;

    var registry = LanguageRegistry.init(allocator);
    var parser = Parser.init(allocator, "def add(a, b):\n    return a + b\n\nprint(add(1, \"two\"))\n", "prog.cob");
    parser.attachRegistry(&registry);

    try expectNative(.python, try parser.detectLanguage());
}

/// Whether the query reported `capture` for exactly the text `text`.
fn hasCapture(allocator: std.mem.Allocator, lang: []const u8, source: [:0]const u8, text: []const u8, capture: []const u8) !bool {
    var parser = Parser.init(allocator, source, null);
    parser.setRequestedLanguage(lang);
    const matches = try parser.sourceCodeMatches();
    for (matches.items) |m| {
        if (std.mem.eql(u8, m.capture_name, capture) and std.mem.eql(u8, source[m.start_byte..m.end_byte], text)) return true;
    }
    return false;
}

test "#match? predicates filter captures: only SCREAMING_CASE identifiers are constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The Python query has `((identifier) @constant (#match? @constant "^[A-Z][A-Z_0-9]+$"))`
    // and `((identifier) @constructor (#match? @constructor "^[A-Z]"))`. Without
    // predicate evaluation every identifier would get both captures.
    const src = "MAX_SIZE = 1\nvalue = MAX_SIZE\nPoint = 2\n";
    try std.testing.expect(try hasCapture(a, "python", src, "MAX_SIZE", "constant"));
    try std.testing.expect(try hasCapture(a, "python", src, "MAX_SIZE", "constructor"));
    try std.testing.expect(!try hasCapture(a, "python", src, "value", "constant"));
    try std.testing.expect(!try hasCapture(a, "python", src, "value", "constructor"));
    // Capitalised but not SCREAMING_CASE: a constructor, not a constant.
    try std.testing.expect(try hasCapture(a, "python", src, "Point", "constructor"));
    try std.testing.expect(!try hasCapture(a, "python", src, "Point", "constant"));
}

test "#lua-match? predicates are evaluated (Zig types start with a capital)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `((identifier) @type (#lua-match? @type "^[A-Z_][a-zA-Z0-9_]*"))` in the Zig query.
    const src = "const Point = struct {};\nvar point: u8 = 0;\n";
    try std.testing.expect(try hasCapture(a, "zig", src, "Point", "type"));
    try std.testing.expect(!try hasCapture(a, "zig", src, "point", "type"));
}

test "#eq? predicates are evaluated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `((identifier) @variable.builtin (#eq? @variable.builtin "_"))` in the Zig query.
    const src = "const x = 1;\nconst _ = x;\n";
    try std.testing.expect(try hasCapture(a, "zig", src, "_", "variable.builtin"));
    try std.testing.expect(!try hasCapture(a, "zig", src, "x", "variable.builtin"));
}

test "#any-of? predicates are evaluated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `(builtin_identifier) @keyword.import (#any-of? @keyword.import "@import" "@cImport")`
    const src = "const std = @import(\"std\");\nconst n = @intCast(1);\n";
    try std.testing.expect(try hasCapture(a, "zig", src, "@import", "keyword.import"));
    try std.testing.expect(!try hasCapture(a, "zig", src, "@intCast", "keyword.import"));
}

test "PredicateEvaluator.parseName understands the not-/any- variants" {
    const E = PredicateEvaluator;
    const eq = E.parseName("eq?").?;
    try std.testing.expect(eq.op == .eq and !eq.negate and !eq.any);
    const not_eq = E.parseName("not-eq?").?;
    try std.testing.expect(not_eq.op == .eq and not_eq.negate and !not_eq.any);
    const any_not_match = E.parseName("any-not-match?").?;
    try std.testing.expect(any_not_match.op == .match and any_not_match.negate and any_not_match.any);
    const any_of = E.parseName("any-of?").?;
    try std.testing.expect(any_of.op == .any_of and !any_of.negate and !any_of.any);
    const not_any_of = E.parseName("not-any-of?").?;
    try std.testing.expect(not_any_of.op == .any_of and not_any_of.negate);
    try std.testing.expect(E.parseName("lua-match?").?.op == .lua_match);
    try std.testing.expect(E.parseName("set!") == null);
    try std.testing.expect(E.parseName("is-not?") == null);
}
