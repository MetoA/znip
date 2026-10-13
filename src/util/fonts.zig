const std = @import("std");
const builtin = @import("builtin");
const embedded_fonts = @import("../assets/fonts/fonts.zig");
const config = @import("../core/config.zig");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

pub const default_font_name = "JetBrainsMono-Bold";

pub const FontSource = enum { bundled, user, extra, system };

pub const FontEntry = struct {
    name: []const u8,
    path: ?[]const u8,
    source: FontSource,
};

/// `.ttc`/`.otc` collections are included (their first face is used, which is
/// what the renderer asks Blend2D for): macOS ships several of its monospace
/// fonts, e.g. Menlo, that way.
const font_extensions = [_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" };

/// Fonts bigger than this are ignored (CJK families can be tens of MB).
const max_font_file_bytes = 64 * 1024 * 1024;

fn hasFontExtension(name: []const u8) bool {
    for (font_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

fn stripFontExtension(name: []const u8) []const u8 {
    for (font_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return name[0 .. name.len - ext.len];
    }
    return name;
}

pub fn userFontsDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try config.homeDir(allocator);
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".znip", "fonts" });
}

/// Well-known OS font directories, highest priority first. Directory-scan
/// based (no fontconfig/CoreText dependency) - matches the project's existing
/// preference for zero extra system dependencies.
fn systemFontDirPaths(allocator: std.mem.Allocator) ![]const []const u8 {
    var dirs = std.ArrayList([]const u8).empty;
    errdefer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    switch (builtin.os.tag) {
        .macos => {
            try dirs.append(allocator, try allocator.dupe(u8, "/System/Library/Fonts"));
            try dirs.append(allocator, try allocator.dupe(u8, "/Library/Fonts"));
            if (config.homeDir(allocator)) |home| {
                defer allocator.free(home);
                try dirs.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Fonts" }));
            } else |_| {}
        },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => {
            try appendUniqueDir(allocator, &dirs, try allocator.dupe(u8, "/usr/share/fonts"));
            try appendUniqueDir(allocator, &dirs, try allocator.dupe(u8, "/usr/local/share/fonts"));
            // XDG base directories: distributions like NixOS or Guix keep
            // fonts outside the fixed locations above.
            const xdg_data_dirs: []const u8 = std.posix.getenv("XDG_DATA_DIRS") orelse "";
            var xdg_it = std.mem.tokenizeScalar(u8, xdg_data_dirs, ':');
            while (xdg_it.next()) |data_dir| {
                if (!std.fs.path.isAbsolute(data_dir)) continue;
                try appendUniqueDir(allocator, &dirs, try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "fonts" }));
            }
            if (config.homeDir(allocator)) |home| {
                defer allocator.free(home);
                const data_home: ?[]const u8 = std.posix.getenv("XDG_DATA_HOME");
                if (data_home != null and std.fs.path.isAbsolute(data_home.?)) {
                    try appendUniqueDir(allocator, &dirs, try std.fs.path.join(allocator, &[_][]const u8{ data_home.?, "fonts" }));
                }
                try appendUniqueDir(allocator, &dirs, try std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "fonts" }));
                try appendUniqueDir(allocator, &dirs, try std.fs.path.join(allocator, &[_][]const u8{ home, ".fonts" }));
            } else |_| {}
        },
        else => {},
    }

    return dirs.toOwnedSlice(allocator);
}

/// Appends `path` (taking ownership) unless an equal one is already listed.
fn appendUniqueDir(allocator: std.mem.Allocator, dirs: *std.ArrayList([]const u8), path: []const u8) !void {
    for (dirs.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            allocator.free(path);
            return;
        }
    }
    errdefer allocator.free(path);
    try dirs.append(allocator, path);
}

/// A directory to scan for font files, tagged with the priority source it
/// represents. Order matters: earlier sources shadow same-named fonts found
/// in later ones.
const FontDir = struct {
    path: []const u8,
    source: FontSource,
    owned: bool,
};

fn allFontDirs(allocator: std.mem.Allocator) ![]FontDir {
    var dirs = std.ArrayList(FontDir).empty;
    errdefer {
        for (dirs.items) |d| if (d.owned) allocator.free(d.path);
        dirs.deinit(allocator);
    }

    const user_dir = try userFontsDirPath(allocator);
    try dirs.append(allocator, .{ .path = user_dir, .source = .user, .owned = true });

    const parsed_config = config.Config.load(allocator) catch null;
    if (parsed_config) |pc| {
        var pc_mut = pc;
        defer pc_mut.deinit();
        if (pc_mut.value.font_directories) |extra_dirs| {
            for (extra_dirs) |extra_dir| {
                // `~/fonts` is as valid here as an absolute path.
                const expanded = config.expandTilde(allocator, extra_dir) catch continue;
                errdefer allocator.free(expanded);
                try dirs.append(allocator, .{ .path = expanded, .source = .extra, .owned = true });
            }
        }
    }

    const system_dirs = try systemFontDirPaths(allocator);
    defer allocator.free(system_dirs);
    for (system_dirs) |system_dir| {
        try dirs.append(allocator, .{ .path = system_dir, .source = .system, .owned = true });
    }

    return dirs.toOwnedSlice(allocator);
}

const RawFontFile = struct {
    stem: []const u8,
    parent_name: []const u8,
    abs_path: []const u8,
};

fn freeRawFontFile(allocator: std.mem.Allocator, f: RawFontFile) void {
    allocator.free(f.stem);
    allocator.free(f.parent_name);
    allocator.free(f.abs_path);
}

/// Recursively collects font files under `dir_path` (OS font directories nest
/// fonts in subfolders, e.g. `/System/Library/Fonts/Supplemental/...` or
/// `/usr/share/fonts/truetype/dejavu/...`).
fn collectFontFiles(allocator: std.mem.Allocator, dir_path: []const u8) ![]RawFontFile {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return &[_]RawFontFile{},
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files = std.ArrayList(RawFontFile).empty;
    errdefer {
        for (files.items) |f| freeRawFontFile(allocator, f);
        files.deinit(allocator);
    }

    while (true) {
        // One unreadable subdirectory (permissions, a dangling mount) must
        // not hide every other font; the walker has already moved past it, so
        // continuing is safe.
        const entry = (walker.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        }) orelse break;

        const is_file = switch (entry.kind) {
            .file => true,
            // Font packages and managers (Homebrew casks, Nix, stow) install
            // symlinks; follow them to see what they point at.
            .sym_link, .unknown => blk: {
                const stat = entry.dir.statFile(entry.basename) catch break :blk false;
                break :blk stat.kind == .file;
            },
            else => false,
        };
        if (!is_file) continue;
        if (!hasFontExtension(entry.basename)) continue;

        const stem = stripFontExtension(entry.basename);
        const parent = std.fs.path.dirname(entry.path) orelse "";
        const parent_name = std.fs.path.basename(parent);

        const abs_path = dir.realpathAlloc(allocator, entry.path) catch continue;

        try files.append(allocator, .{
            .stem = try allocator.dupe(u8, stem),
            .parent_name = try allocator.dupe(u8, parent_name),
            .abs_path = abs_path,
        });
    }

    return files.toOwnedSlice(allocator);
}

/// Family-name substrings (checked case-insensitively) that mark a font as
/// not meant for rendering ordinary text - dingbat/symbol/ornament fonts
/// remap ASCII input to non-letter shapes, so `bl_font_map_text_to_glyphs`
/// alone can't detect them (the mapping "succeeds", just to the wrong glyph).
const non_text_font_keywords = [_][]const u8{
    "wingdings", "webdings", "dingbat", "ornament", "braille", "symbol", "emoji",
};

/// A representative sample of characters that show up in source code: if a
/// font can't map all of these to real glyphs, it's not usable for rendering
/// code.
const glyph_probe_text = "AaZz09{}[]();.,:";

/// Checks whether `font_bytes` is actually usable for rendering source code,
/// filtering out fonts that Blend2D can load but that render as garbage:
/// Apple's private system fonts (family name prefixed with `.`, e.g.
/// `.LastResort` - a fallback font whose every glyph is intentionally a
/// placeholder box; `.Keyboard` - keycap icons), and dingbat/symbol fonts
/// that remap ASCII to symbol shapes. Also rejects fonts with genuine
/// missing-glyph coverage for common code characters.
fn isFontRenderable(font_bytes: []const u8) bool {
    var font_data: c.BLFontDataCore = undefined;
    _ = c.bl_font_data_init(&font_data);
    defer _ = c.bl_font_data_reset(&font_data);
    if (c.bl_font_data_create_from_data(&font_data, font_bytes.ptr, font_bytes.len, null, null) != c.BL_SUCCESS) {
        return false;
    }

    var face: c.BLFontFaceCore = undefined;
    _ = c.bl_font_face_init(&face);
    defer _ = c.bl_font_face_reset(&face);
    if (c.bl_font_face_create_from_data(&face, &font_data, 0) != c.BL_SUCCESS) {
        return false;
    }

    var family_name: c.BLStringCore = undefined;
    _ = c.bl_string_init(&family_name);
    defer _ = c.bl_string_destroy(&family_name);
    if (c.bl_font_face_get_family_name(&face, &family_name) == c.BL_SUCCESS) {
        const len = c.bl_string_get_size(&family_name);
        const data_ptr = c.bl_string_get_data(&family_name);
        if (len > 0 and data_ptr != null) {
            const name = data_ptr[0..len];
            if (name[0] == '.') return false;
            for (non_text_font_keywords) |keyword| {
                if (std.ascii.indexOfIgnoreCase(name, keyword) != null) return false;
            }
        }
    }

    var font: c.BLFontCore = undefined;
    _ = c.bl_font_init(&font);
    defer _ = c.bl_font_reset(&font);
    if (c.bl_font_create_from_face(&font, &face, 16.0) != c.BL_SUCCESS) {
        return false;
    }

    var glyph_buffer: c.BLGlyphBufferCore = undefined;
    _ = c.bl_glyph_buffer_init(&glyph_buffer);
    defer _ = c.bl_glyph_buffer_reset(&glyph_buffer);
    if (c.bl_glyph_buffer_set_text(&glyph_buffer, glyph_probe_text.ptr, glyph_probe_text.len, c.BL_TEXT_ENCODING_UTF8) != c.BL_SUCCESS) {
        return false;
    }

    var mapping_state: c.BLGlyphMappingState = undefined;
    if (c.bl_font_map_text_to_glyphs(&font, &glyph_buffer, &mapping_state) != c.BL_SUCCESS) {
        return false;
    }

    return mapping_state.undefined_count == 0;
}

/// Scans one font directory, appending a `FontEntry` per unique font file to
/// `entries` and recording its name in `seen_names`. A name already present
/// in `seen_names` (from a higher-priority source scanned earlier) is
/// skipped, so e.g. a user font always shadows a same-named system font.
/// Stems that collide *within this directory's own recursive scan* (common
/// with system font packages) are qualified with their immediate parent
/// directory name to stay unambiguous.
fn appendFontEntries(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    source: FontSource,
    entries: *std.ArrayList(FontEntry),
    seen_names: *std.StringHashMap(void),
    validate: bool,
) !void {
    const files = try collectFontFiles(allocator, dir_path);
    defer allocator.free(files);
    // `stem_counts` is keyed by each file's `stem` slice, so the stems must stay
    // alive until the map is gone. Defers run in reverse order, so this runs
    // after `stem_counts.deinit()` below.
    defer for (files) |f| {
        allocator.free(f.stem);
        allocator.free(f.parent_name);
    };

    var stem_counts = std.StringHashMap(u32).init(allocator);
    defer stem_counts.deinit();
    for (files) |f| {
        const gop = try stem_counts.getOrPut(f.stem);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    for (files) |f| {
        const count = stem_counts.get(f.stem).?;
        const name = if (count > 1)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ f.parent_name, f.stem })
        else
            try allocator.dupe(u8, f.stem);

        if (seen_names.contains(name)) {
            allocator.free(name);
            allocator.free(f.abs_path);
            continue;
        }

        // Validating means reading and parsing the whole file, so a plain
        // name lookup skips it and checks only the font it ends up using.
        const renderable = !validate or blk: {
            const font_bytes = std.fs.cwd().readFileAlloc(allocator, f.abs_path, max_font_file_bytes) catch break :blk false;
            defer allocator.free(font_bytes);
            break :blk isFontRenderable(font_bytes);
        };
        if (!renderable) {
            allocator.free(name);
            allocator.free(f.abs_path);
            continue;
        }

        try seen_names.put(name, {});
        try entries.append(allocator, .{ .name = name, .path = f.abs_path, .source = source });
    }
}

/// Lists every discoverable font across all sources, highest priority first:
/// the bundled default, `~/.znip/fonts`, any `font_directories` from
/// config.json, then OS-default font directories. Free with `freeFontEntries`.
pub fn listAvailableFonts(allocator: std.mem.Allocator) ![]FontEntry {
    const dirs = try allFontDirs(allocator);
    defer {
        for (dirs) |d| if (d.owned) allocator.free(d.path);
        allocator.free(dirs);
    }

    return listFontsInDirs(allocator, dirs);
}

/// The bundled default font followed by every renderable font found in `dirs`,
/// in order (earlier directories shadow same-named fonts in later ones).
fn listFontsInDirs(allocator: std.mem.Allocator, dirs: []const FontDir) ![]FontEntry {
    var entries = std.ArrayList(FontEntry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            if (e.path) |p| allocator.free(p);
        }
        entries.deinit(allocator);
    }

    var seen_names = std.StringHashMap(void).init(allocator);
    defer seen_names.deinit();

    const bundled_name = try allocator.dupe(u8, default_font_name);
    try entries.append(allocator, .{ .name = bundled_name, .path = null, .source = .bundled });
    try seen_names.put(bundled_name, {});

    for (dirs) |dir| {
        try appendFontEntries(allocator, dir.path, dir.source, &entries, &seen_names, true);
    }

    return entries.toOwnedSlice(allocator);
}

pub fn freeFontEntries(allocator: std.mem.Allocator, entries: []const FontEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        if (e.path) |p| allocator.free(p);
    }
    allocator.free(entries);
}

/// Convenience wrapper for callers that only want display names (e.g. before
/// the wizard grouped picker existed). Kept for simplicity where the source
/// distinction doesn't matter.
pub fn listAvailableFontNames(allocator: std.mem.Allocator) ![]const []const u8 {
    const entries = try listAvailableFonts(allocator);
    defer freeFontEntries(allocator, entries);

    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    for (entries) |e| try names.append(allocator, try allocator.dupe(u8, e.name));

    return names.toOwnedSlice(allocator);
}

/// Resolves `name` against every font source (bundled, user, extra
/// directories, system) in priority order and returns the font file bytes.
/// Falls back to the embedded default (with a warning) if `name` can't be
/// found anywhere or isn't usable.
pub fn loadFontBytes(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, default_font_name)) {
        return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
    }

    const dirs = try allFontDirs(allocator);
    defer {
        for (dirs) |d| if (d.owned) allocator.free(d.path);
        allocator.free(dirs);
    }

    const bytes = try loadFontBytesFromDirs(allocator, dirs, name);
    if (bytes) |b| return b;

    std.log.warn("Font '{s}' wasn't found (or can't render code); using {s}.", .{ name, default_font_name });
    return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
}

/// Finds `name` by file name alone, stopping at the first directory that has it
/// (so the rest of the system's fonts are never touched), and validates only
/// that one font. Returns null if it's missing or not renderable.
fn loadFontBytesFromDirs(allocator: std.mem.Allocator, dirs: []const FontDir, name: []const u8) !?[]const u8 {
    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen_names = std.StringHashMap(void).init(allocator);
    defer seen_names.deinit();

    for (dirs) |dir| {
        try appendFontEntries(allocator, dir.path, dir.source, &entries, &seen_names, false);

        const entry = findEntryByName(entries.items, name) orelse continue;
        const bytes = std.fs.cwd().readFileAlloc(allocator, entry.path.?, max_font_file_bytes) catch return null;
        if (!isFontRenderable(bytes)) {
            allocator.free(bytes);
            return null;
        }
        return bytes;
    }
    return null;
}

/// Exact name match first, then ignoring case (`--font "jetbrains mono"`).
fn findEntryByName(entries: []const FontEntry, name: []const u8) ?FontEntry {
    for (entries) |e| {
        if (e.path != null and std.mem.eql(u8, e.name, name)) return e;
    }
    for (entries) |e| {
        if (e.path != null and std.ascii.eqlIgnoreCase(e.name, name)) return e;
    }
    return null;
}

fn fontBytesFromEntries(allocator: std.mem.Allocator, entries: []const FontEntry, name: []const u8) ![]const u8 {
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        const path = e.path orelse return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
        return std.fs.cwd().readFileAlloc(allocator, path, max_font_file_bytes) catch allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
    }

    return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
}

test "stripFontExtension strips known extensions only" {
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold.ttf"));
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold.otf"));
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold"));
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold.TTF"));
    try std.testing.expectEqualStrings("Menlo", stripFontExtension("Menlo.ttc"));
}

test "hasFontExtension recognizes font files regardless of case" {
    try std.testing.expect(hasFontExtension("a.ttf"));
    try std.testing.expect(hasFontExtension("a.otf"));
    try std.testing.expect(hasFontExtension("a.TTF"));
    try std.testing.expect(hasFontExtension("Menlo.ttc"));
    try std.testing.expect(hasFontExtension("A.OTC"));
    try std.testing.expect(!hasFontExtension("a.txt"));
    try std.testing.expect(!hasFontExtension("a.ttf.bak"));
}

fn freeEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(FontEntry)) void {
    for (entries.items) |e| {
        allocator.free(e.name);
        if (e.path) |p| allocator.free(p);
    }
    entries.deinit(allocator);
}

test "appendFontEntries disambiguates same-stem files with their parent directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("fam1");
    try tmp.dir.makePath("fam2");
    try tmp.dir.writeFile(.{ .sub_path = "fam1/Regular.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });
    try tmp.dir.writeFile(.{ .sub_path = "fam2/Regular.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir_path, .user, &entries, &seen, true);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    var found_fam1 = false;
    var found_fam2 = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.name, "fam1/Regular")) found_fam1 = true;
        if (std.mem.eql(u8, e.name, "fam2/Regular")) found_fam2 = true;
    }
    try std.testing.expect(found_fam1);
    try std.testing.expect(found_fam2);
}

test "appendFontEntries does not re-add a name already claimed by a higher-priority source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Inter.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const shadow_name = try allocator.dupe(u8, "Inter");
    defer allocator.free(shadow_name);
    try seen.put(shadow_name, {});

    try appendFontEntries(allocator, dir_path, .system, &entries, &seen, true);

    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "collectFontFiles recurses into nested directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("truetype/dejavu");
    try tmp.dir.writeFile(.{ .sub_path = "truetype/dejavu/DejaVuSans.ttf", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "not-a-font.txt", .data = "b" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const files = try collectFontFiles(allocator, dir_path);
    defer {
        for (files) |f| freeRawFontFile(allocator, f);
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("DejaVuSans", files[0].stem);
}

const bundled_font_bytes = embedded_fonts.font_jet_brains_mono_bold;

fn freeFontDirs(allocator: std.mem.Allocator, dirs: []const FontDir) void {
    for (dirs) |d| if (d.owned) allocator.free(d.path);
    allocator.free(dirs);
}

fn findEntryNamed(entries: []const FontEntry, name: []const u8) ?FontEntry {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

test "hasFontExtension rejects names that merely contain the extension" {
    try std.testing.expect(!hasFontExtension("a.ttf.bak"));
    try std.testing.expect(!hasFontExtension("ttf"));
    try std.testing.expect(!hasFontExtension(""));
    try std.testing.expect(hasFontExtension(".ttf"));
}

test "stripFontExtension only strips the final extension" {
    try std.testing.expectEqualStrings("a.ttf", stripFontExtension("a.ttf.otf"));
    try std.testing.expectEqualStrings("", stripFontExtension(".ttf"));
    try std.testing.expectEqualStrings("a.txt", stripFontExtension("a.txt"));
}

test "isFontRenderable accepts the bundled font" {
    try std.testing.expect(isFontRenderable(bundled_font_bytes));
}

test "isFontRenderable rejects data that is not a font" {
    try std.testing.expect(!isFontRenderable(""));
    try std.testing.expect(!isFontRenderable("definitely not a font"));
    try std.testing.expect(!isFontRenderable(&[_]u8{0} ** 256));
}

test "isFontRenderable rejects a truncated font" {
    try std.testing.expect(!isFontRenderable(bundled_font_bytes[0..200]));
}

test "userFontsDirPath is ~/.znip/fonts" {
    const allocator = std.testing.allocator;
    config.home_dir_override = "/home/u";
    defer config.home_dir_override = null;

    const path = try userFontsDirPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/u/.znip/fonts", path);
}

test "systemFontDirPaths includes OS directories and the user's home directories" {
    const allocator = std.testing.allocator;
    config.home_dir_override = "/home/u";
    defer config.home_dir_override = null;

    const dirs = try systemFontDirPaths(allocator);
    defer {
        for (dirs) |d| allocator.free(d);
        allocator.free(dirs);
    }

    switch (builtin.os.tag) {
        .macos => {
            try std.testing.expectEqual(@as(usize, 3), dirs.len);
            try std.testing.expectEqualStrings("/System/Library/Fonts", dirs[0]);
            try std.testing.expectEqualStrings("/Library/Fonts", dirs[1]);
            try std.testing.expectEqualStrings("/home/u/Library/Fonts", dirs[2]);
        },
        .linux => {
            try std.testing.expectEqual(@as(usize, 4), dirs.len);
            try std.testing.expectEqualStrings("/usr/share/fonts", dirs[0]);
            try std.testing.expectEqualStrings("/home/u/.local/share/fonts", dirs[2]);
            try std.testing.expectEqualStrings("/home/u/.fonts", dirs[3]);
        },
        else => {},
    }
}

test "allFontDirs orders user, configured and system directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    config.home_dir_override = home;
    defer config.home_dir_override = null;

    try tmp.dir.makePath(".znip");
    try tmp.dir.writeFile(.{
        .sub_path = ".znip/config.json",
        .data = "{\"active_preset\":\"default\",\"font_directories\":[\"/extra/one\",\"/extra/two\"]}",
    });

    const dirs = try allFontDirs(allocator);
    defer freeFontDirs(allocator, dirs);

    try std.testing.expect(dirs.len >= 3);
    try std.testing.expect(dirs[0].source == .user);
    try std.testing.expect(std.mem.endsWith(u8, dirs[0].path, ".znip/fonts"));
    try std.testing.expect(dirs[1].source == .extra);
    try std.testing.expectEqualStrings("/extra/one", dirs[1].path);
    try std.testing.expect(dirs[2].source == .extra);
    try std.testing.expectEqualStrings("/extra/two", dirs[2].path);
    for (dirs[3..]) |d| try std.testing.expect(d.source == .system);
}

test "allFontDirs without a config file only has user and system directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    config.home_dir_override = home;
    defer config.home_dir_override = null;

    const dirs = try allFontDirs(allocator);
    defer freeFontDirs(allocator, dirs);

    try std.testing.expect(dirs[0].source == .user);
    for (dirs[1..]) |d| try std.testing.expect(d.source == .system);
}

test "collectFontFiles returns nothing for a missing directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const missing = try std.fs.path.join(allocator, &.{ dir, "nope" });
    defer allocator.free(missing);

    const files = try collectFontFiles(allocator, missing);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "collectFontFiles records stem, parent directory and absolute path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("family");
    try tmp.dir.writeFile(.{ .sub_path = "family/Face-Bold.otf", .data = "x" });

    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const files = try collectFontFiles(allocator, dir);
    defer {
        for (files) |f| freeRawFontFile(allocator, f);
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("Face-Bold", files[0].stem);
    try std.testing.expectEqualStrings("family", files[0].parent_name);
    try std.testing.expect(std.fs.path.isAbsolute(files[0].abs_path));
    try std.testing.expect(std.mem.endsWith(u8, files[0].abs_path, "family/Face-Bold.otf"));
}

test "collectFontFiles skips directories named like fonts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("looks-like.ttf");

    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const files = try collectFontFiles(allocator, dir);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "appendFontEntries rejects files that are not renderable fonts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Fake.ttf", .data = "not a font" });
    try tmp.dir.writeFile(.{ .sub_path = "Real.ttf", .data = bundled_font_bytes });

    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir, .user, &entries, &seen, true);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("Real", entries.items[0].name);
    try std.testing.expect(entries.items[0].source == .user);
    try std.testing.expect(entries.items[0].path != null);
    try std.testing.expect(seen.contains("Real"));
    try std.testing.expect(!seen.contains("Fake"));
}

test "appendFontEntries handles several fonts that share a stem in one scan" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c" }) |family| {
        try tmp.dir.makePath(family);
        const sub = try std.fmt.allocPrint(allocator, "{s}/Regular.ttf", .{family});
        defer allocator.free(sub);
        try tmp.dir.writeFile(.{ .sub_path = sub, .data = bundled_font_bytes });
    }

    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir, .system, &entries, &seen, true);

    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    for ([_][]const u8{ "a/Regular", "b/Regular", "c/Regular" }) |name| {
        try std.testing.expect(findEntryNamed(entries.items, name) != null);
    }
}

test "listFontsInDirs starts with the bundled font" {
    const allocator = std.testing.allocator;
    const entries = try listFontsInDirs(allocator, &.{});
    defer freeFontEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(default_font_name, entries[0].name);
    try std.testing.expect(entries[0].path == null);
    try std.testing.expect(entries[0].source == .bundled);
}

test "listFontsInDirs lets earlier directories shadow later ones" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("user");
    try tmp.dir.makePath("system");
    try tmp.dir.writeFile(.{ .sub_path = "user/Shared.ttf", .data = bundled_font_bytes });
    try tmp.dir.writeFile(.{ .sub_path = "user/OnlyUser.otf", .data = bundled_font_bytes });
    try tmp.dir.writeFile(.{ .sub_path = "system/Shared.ttf", .data = bundled_font_bytes });
    try tmp.dir.writeFile(.{ .sub_path = "system/OnlySystem.ttf", .data = bundled_font_bytes });
    try tmp.dir.writeFile(.{ .sub_path = "system/readme.txt", .data = "hello" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const user_dir = try std.fs.path.join(allocator, &.{ root, "user" });
    defer allocator.free(user_dir);
    const system_dir = try std.fs.path.join(allocator, &.{ root, "system" });
    defer allocator.free(system_dir);

    const entries = try listFontsInDirs(allocator, &.{
        .{ .path = user_dir, .source = .user, .owned = false },
        .{ .path = system_dir, .source = .system, .owned = false },
    });
    defer freeFontEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(findEntryNamed(entries, "Shared").?.source == .user);
    try std.testing.expect(findEntryNamed(entries, "OnlyUser").?.source == .user);
    try std.testing.expect(findEntryNamed(entries, "OnlySystem").?.source == .system);
    try std.testing.expect(findEntryNamed(entries, "readme") == null);
}

test "listFontsInDirs does not let a directory shadow the bundled font" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = default_font_name ++ ".ttf", .data = bundled_font_bytes });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const entries = try listFontsInDirs(allocator, &.{.{ .path = root, .source = .user, .owned = false }});
    defer freeFontEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].source == .bundled);
}

test "listFontsInDirs tolerates missing directories" {
    const allocator = std.testing.allocator;
    const entries = try listFontsInDirs(allocator, &.{.{ .path = "/definitely/not/a/dir", .source = .extra, .owned = false }});
    defer freeFontEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
}

test "loadFontBytes returns the embedded font for the default name" {
    const allocator = std.testing.allocator;
    const bytes = try loadFontBytes(allocator, default_font_name);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, bundled_font_bytes, bytes);
}

test "fontBytesFromEntries reads the matching file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Custom.ttf", .data = "custom font bytes" });
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "Custom.ttf" });
    defer allocator.free(path);

    const entries = [_]FontEntry{
        .{ .name = default_font_name, .path = null, .source = .bundled },
        .{ .name = "Custom", .path = path, .source = .user },
    };
    const bytes = try fontBytesFromEntries(allocator, &entries, "Custom");
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("custom font bytes", bytes);
}

test "fontBytesFromEntries falls back to the embedded font" {
    const allocator = std.testing.allocator;
    const entries = [_]FontEntry{
        .{ .name = default_font_name, .path = null, .source = .bundled },
        .{ .name = "Gone", .path = "/definitely/not/here.ttf", .source = .user },
    };

    // Unknown name.
    const unknown = try fontBytesFromEntries(allocator, &entries, "Nope");
    defer allocator.free(unknown);
    try std.testing.expectEqualSlices(u8, bundled_font_bytes, unknown);

    // Known name whose file has disappeared.
    const gone = try fontBytesFromEntries(allocator, &entries, "Gone");
    defer allocator.free(gone);
    try std.testing.expectEqualSlices(u8, bundled_font_bytes, gone);

    // Bundled entry (no path).
    const bundled = try fontBytesFromEntries(allocator, &entries, default_font_name);
    defer allocator.free(bundled);
    try std.testing.expectEqualSlices(u8, bundled_font_bytes, bundled);
}

test "fontBytesFromEntries matches names exactly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Custom.ttf", .data = "custom" });
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "Custom.ttf" });
    defer allocator.free(path);

    const entries = [_]FontEntry{.{ .name = "Custom", .path = path, .source = .user }};
    const bytes = try fontBytesFromEntries(allocator, &entries, "custom");
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, bundled_font_bytes, bytes);
}

fn hasName(entries: []const FontEntry, name: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

test "appendFontEntries finds upper-case and collection extensions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Win.TTF", .data = embedded_fonts.font_jet_brains_mono_bold });
    try tmp.dir.writeFile(.{ .sub_path = "Coll.ttc", .data = embedded_fonts.font_jet_brains_mono_bold });
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "not a font" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir_path, .user, &entries, &seen, true);
    try std.testing.expect(hasName(entries.items, "Win"));
    try std.testing.expect(hasName(entries.items, "Coll"));
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
}

test "appendFontEntries follows symlinked font files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("store");
    try tmp.dir.writeFile(.{ .sub_path = "store/Real.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });
    try tmp.dir.makePath("fonts");
    const target = try tmp.dir.realpathAlloc(allocator, "store/Real.ttf");
    defer allocator.free(target);
    try tmp.dir.symLink(target, "fonts/Linked.ttf", .{});
    // A dangling link must be skipped quietly, not abort the scan.
    try tmp.dir.symLink("/definitely/not/here.ttf", "fonts/Dangling.ttf", .{});

    const dir_path = try tmp.dir.realpathAlloc(allocator, "fonts");
    defer allocator.free(dir_path);
    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir_path, .user, &entries, &seen, true);
    try std.testing.expect(hasName(entries.items, "Linked"));
    try std.testing.expect(!hasName(entries.items, "Dangling"));
}

test "appendFontEntries survives an unreadable subdirectory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("locked");
    try tmp.dir.makePath("open");
    try tmp.dir.writeFile(.{ .sub_path = "open/Good.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });
    try tmp.dir.writeFile(.{ .sub_path = "locked/Hidden.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });

    var locked = try tmp.dir.openDir("locked", .{});
    try locked.chmod(0o000);
    defer {
        locked.chmod(0o755) catch {};
        locked.close();
    }
    // Running as root ignores permissions; then there's nothing to test.
    if (tmp.dir.openDir("locked", .{ .iterate = true })) |opened| {
        var d = opened;
        d.close();
        return error.SkipZigTest;
    } else |_| {}

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir_path, .user, &entries, &seen, true);
    try std.testing.expect(hasName(entries.items, "Good"));
}

test "collectFontFiles treats a directory it can't open as empty" {
    const allocator = std.testing.allocator;
    const files = try collectFontFiles(allocator, "/definitely/not/a/dir");
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "loadFontBytesFromDirs resolves by name, case-insensitively, validating only the match" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "MyMono-Regular.ttf", .data = embedded_fonts.font_jet_brains_mono_bold });
    // Garbage that would fail validation if it were ever looked at.
    try tmp.dir.writeFile(.{ .sub_path = "Broken.ttf", .data = "not a font at all" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const dirs = [_]FontDir{.{ .path = dir_path, .source = .user, .owned = false }};

    const exact = (try loadFontBytesFromDirs(allocator, &dirs, "MyMono-Regular")) orelse return error.TestUnexpectedResult;
    defer allocator.free(exact);
    try std.testing.expectEqualSlices(u8, embedded_fonts.font_jet_brains_mono_bold, exact);

    const folded = (try loadFontBytesFromDirs(allocator, &dirs, "mymono-regular")) orelse return error.TestUnexpectedResult;
    defer allocator.free(folded);

    // Unknown, and present-but-unusable, both come back as null (the caller falls back).
    try std.testing.expect((try loadFontBytesFromDirs(allocator, &dirs, "Nope")) == null);
    try std.testing.expect((try loadFontBytesFromDirs(allocator, &dirs, "Broken")) == null);
}

test "loadFontBytes falls back to the bundled font for an unknown name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    config.home_dir_override = home;
    defer config.home_dir_override = null;

    const bytes = try loadFontBytes(allocator, "Definitely Not Installed 12345");
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, embedded_fonts.font_jet_brains_mono_bold, bytes);
}

test "font_directories from config.json may start with ~" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    config.home_dir_override = home;
    defer config.home_dir_override = null;

    try tmp.dir.makePath(".znip");
    try tmp.dir.writeFile(.{ .sub_path = ".znip/config.json", .data = "{\"active_preset\":\"default\",\"font_directories\":[\"~/myfonts\"]}" });

    const dirs = try allFontDirs(allocator);
    defer {
        for (dirs) |d| if (d.owned) allocator.free(d.path);
        allocator.free(dirs);
    }
    const expected = try std.fs.path.join(allocator, &.{ home, "myfonts" });
    defer allocator.free(expected);
    var found = false;
    for (dirs) |d| {
        if (d.source == .extra and std.mem.eql(u8, d.path, expected)) found = true;
    }
    try std.testing.expect(found);
}
