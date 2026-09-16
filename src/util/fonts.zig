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

const font_extensions = [_][]const u8{ ".ttf", ".otf" };

fn hasFontExtension(name: []const u8) bool {
    for (font_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn stripFontExtension(name: []const u8) []const u8 {
    for (font_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return name[0 .. name.len - ext.len];
    }
    return name;
}

pub fn userFontsDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
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
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                try dirs.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Fonts" }));
            } else |_| {}
        },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => {
            try dirs.append(allocator, try allocator.dupe(u8, "/usr/share/fonts"));
            try dirs.append(allocator, try allocator.dupe(u8, "/usr/local/share/fonts"));
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                try dirs.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "fonts" }));
                try dirs.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ home, ".fonts" }));
            } else |_| {}
        },
        else => {},
    }

    return dirs.toOwnedSlice(allocator);
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
                try dirs.append(allocator, .{ .path = try allocator.dupe(u8, extra_dir), .source = .extra, .owned = true });
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
        error.FileNotFound, error.NotDir => return &[_]RawFontFile{},
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

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
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
) !void {
    const files = try collectFontFiles(allocator, dir_path);
    defer allocator.free(files);

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
            freeRawFontFile(allocator, f);
            continue;
        }

        const renderable = blk: {
            const font_bytes = std.fs.cwd().readFileAlloc(allocator, f.abs_path, 10 * 1024 * 1024) catch break :blk false;
            defer allocator.free(font_bytes);
            break :blk isFontRenderable(font_bytes);
        };
        if (!renderable) {
            allocator.free(name);
            freeRawFontFile(allocator, f);
            continue;
        }

        try seen_names.put(name, {});
        try entries.append(allocator, .{ .name = name, .path = f.abs_path, .source = source });

        allocator.free(f.stem);
        allocator.free(f.parent_name);
    }
}

/// Lists every discoverable font across all sources, highest priority first:
/// the bundled default, `~/.znip/fonts`, any `font_directories` from
/// config.json, then OS-default font directories. Free with `freeFontEntries`.
pub fn listAvailableFonts(allocator: std.mem.Allocator) ![]FontEntry {
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

    const dirs = try allFontDirs(allocator);
    defer {
        for (dirs) |d| if (d.owned) allocator.free(d.path);
        allocator.free(dirs);
    }

    for (dirs) |dir| {
        try appendFontEntries(allocator, dir.path, dir.source, &entries, &seen_names);
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
/// Falls back to the embedded default if `name` can't be found anywhere.
pub fn loadFontBytes(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, default_font_name)) {
        return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
    }

    const entries = try listAvailableFonts(allocator);
    defer freeFontEntries(allocator, entries);

    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        const path = e.path orelse return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
        return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
    }

    return allocator.dupe(u8, embedded_fonts.font_jet_brains_mono_bold);
}

test "stripFontExtension strips known extensions only" {
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold.ttf"));
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold.otf"));
    try std.testing.expectEqualStrings("Inter-Bold", stripFontExtension("Inter-Bold"));
}

test "hasFontExtension recognizes ttf and otf only" {
    try std.testing.expect(hasFontExtension("a.ttf"));
    try std.testing.expect(hasFontExtension("a.otf"));
    try std.testing.expect(!hasFontExtension("a.txt"));
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
    try tmp.dir.writeFile(.{ .sub_path = "fam1/Regular.ttf", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "fam2/Regular.ttf", .data = "b" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendFontEntries(allocator, dir_path, .user, &entries, &seen);

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

    try tmp.dir.writeFile(.{ .sub_path = "Inter.ttf", .data = "a" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var entries = std.ArrayList(FontEntry).empty;
    defer freeEntries(allocator, &entries);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const shadow_name = try allocator.dupe(u8, "Inter");
    defer allocator.free(shadow_name);
    try seen.put(shadow_name, {});

    try appendFontEntries(allocator, dir_path, .system, &entries, &seen);

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
