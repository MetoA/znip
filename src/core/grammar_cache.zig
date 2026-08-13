const std = @import("std");

// Placeholder znip-controlled release feed - real hosting is a Phase 6
// concern (a separate build/release pipeline for grammar assets); this is
// trivially swappable once that exists.
pub const default_manifest_url = "https://github.com/MetoA/znip_grammars/releases/download/latest/manifest.json";

pub const GrammarManifestEntry = struct {
    name: []const u8,
    version: []const u8,
    wasm_url: []const u8,
    highlights_url: []const u8,
    extensions: []const []const u8,
    sha256_wasm: []const u8, // hex digest
    sha256_highlights: []const u8, // hex digest
};

pub const GrammarManifest = struct {
    manifest_version: u32,
    languages: []const GrammarManifestEntry,
};

pub fn fetchManifest(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !std.json.Parsed(GrammarManifest) {
    const body = try fetchBody(allocator, client, url, 4 * 1024 * 1024);
    defer allocator.free(body);

    return std.json.parseFromSlice(GrammarManifest, allocator, body, .{ .allocate = .alloc_always }) catch {
        return error.ManifestFetchFailed;
    };
}

// Looks up `name` in a parsed manifest, matching either the entry's
// canonical name or one of its declared extensions - e.g. a lookup for
// "cob" (from a .cob file) finds the "cobol" entry via its
// extensions: [".cob", ".cbl"] list. Both name and extension matching are
// case-insensitive (real-world COBOL files are often named PROGRAM.COB).
pub fn findEntry(manifest: GrammarManifest, name: []const u8) ?GrammarManifestEntry {
    for (manifest.languages) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        if (extensionMatches(entry.extensions, name)) return entry;
    }
    return null;
}

fn extensionMatches(extensions: []const []const u8, name: []const u8) bool {
    for (extensions) |ext| {
        const bare = if (std.mem.startsWith(u8, ext, ".")) ext[1..] else ext;
        if (std.ascii.eqlIgnoreCase(bare, name)) return true;
    }
    return false;
}

// Downloads both assets for `entry`, verifies sha256 against the manifest's
// digests, and writes them into ~/.znip/grammars/<entry.name>/ atomically
// (write to a `.tmp` sibling file, then rename into place).
pub fn fetchGrammar(allocator: std.mem.Allocator, client: *std.http.Client, entry: GrammarManifestEntry) !void {
    const wasm_bytes = try fetchBody(allocator, client, entry.wasm_url, 16 * 1024 * 1024);
    defer allocator.free(wasm_bytes);
    try verifySha256(wasm_bytes, entry.sha256_wasm);

    const highlights_bytes = try fetchBody(allocator, client, entry.highlights_url, 4 * 1024 * 1024);
    defer allocator.free(highlights_bytes);
    try verifySha256(highlights_bytes, entry.sha256_highlights);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const dir_path = try std.fs.path.join(allocator, &.{ home, ".znip", "grammars", entry.name });
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try writeFileAtomic(allocator, dir_path, "grammar.wasm", wasm_bytes);
    try writeFileAtomic(allocator, dir_path, "highlights.scm", highlights_bytes);

    // A small sidecar recording this entry's extensions, so a later lookup
    // by a different alias (e.g. ".cbl" after this was cached via ".cob")
    // can find this same cache directory purely from disk, without needing
    // to re-fetch or re-consult the manifest. See LanguageRegistry.resolve's
    // extension-alias scan in tree_sitter.zig.
    const meta_json = try std.json.Stringify.valueAlloc(allocator, .{ .extensions = entry.extensions }, .{});
    defer allocator.free(meta_json);
    try writeFileAtomic(allocator, dir_path, "meta.json", meta_json);
}

fn fetchBody(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, max_len: usize) ![]u8 {
    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_buf.writer,
    }) catch return error.AssetFetchFailed;

    if (result.status != .ok) return error.AssetFetchFailed;
    if (response_buf.written().len > max_len) return error.AssetFetchFailed;

    return try response_buf.toOwnedSlice();
}

fn verifySha256(bytes: []const u8, expected_hex: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual_hex, expected_hex)) {
        return error.AssetIntegrityMismatch;
    }
}

fn writeFileAtomic(allocator: std.mem.Allocator, dir_path: []const u8, file_name: []const u8, bytes: []const u8) !void {
    const final_path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(final_path);

    const tmp_name = try std.mem.concat(allocator, u8, &.{ file_name, ".tmp" });
    defer allocator.free(tmp_name);
    const tmp_path = try std.fs.path.join(allocator, &.{ dir_path, tmp_name });
    defer allocator.free(tmp_path);

    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    try file.writeAll(bytes);
    file.close();

    try std.fs.renameAbsolute(tmp_path, final_path);
}

test "findEntry locates a listed language and misses an unlisted one" {
    const manifest = GrammarManifest{
        .manifest_version = 1,
        .languages = &.{
            .{
                .name = "cobol",
                .version = "1.0.0",
                .wasm_url = "https://example.com/cobol.wasm",
                .highlights_url = "https://example.com/cobol.scm",
                .extensions = &.{ ".cob", ".cbl" },
                .sha256_wasm = "aa",
                .sha256_highlights = "bb",
            },
        },
    };

    const found = findEntry(manifest, "cobol") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1.0.0", found.version);
    try std.testing.expect(findEntry(manifest, "fortran") == null);
}

test "findEntry matches by extension alias, case-insensitively" {
    const manifest = GrammarManifest{
        .manifest_version = 1,
        .languages = &.{
            .{
                .name = "cobol",
                .version = "1.0.0",
                .wasm_url = "https://example.com/cobol.wasm",
                .highlights_url = "https://example.com/cobol.scm",
                .extensions = &.{ ".cob", ".cbl" },
                .sha256_wasm = "aa",
                .sha256_highlights = "bb",
            },
        },
    };

    try std.testing.expectEqualStrings("cobol", (findEntry(manifest, "cob") orelse return error.TestUnexpectedResult).name);
    try std.testing.expectEqualStrings("cobol", (findEntry(manifest, "cbl") orelse return error.TestUnexpectedResult).name);
    try std.testing.expectEqualStrings("cobol", (findEntry(manifest, "COB") orelse return error.TestUnexpectedResult).name);
    try std.testing.expectEqualStrings("cobol", (findEntry(manifest, "COBOL") orelse return error.TestUnexpectedResult).name);
    try std.testing.expect(findEntry(manifest, "cbx") == null);
}

test "verifySha256 accepts a matching digest and rejects a mismatched one" {
    const bytes = "hello world";
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const correct_hex = std.fmt.bytesToHex(digest, .lower);

    try verifySha256(bytes, &correct_hex);
    try std.testing.expectError(error.AssetIntegrityMismatch, verifySha256(bytes, "0" ** 64));
}
