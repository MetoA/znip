const std = @import("std");
const tree_sitter = @import("../core/tree_sitter.zig");

const Color = u32; // ARGB

/// Formats `c` as `#rrggbb` (alpha dropped when fully opaque) or `#rrggbbaa`
/// (alpha preserved otherwise) into `buf`, which must be at least 10 bytes.
pub fn colorToHex(buf: []u8, c: Color) []const u8 {
    const a: u8 = @truncate((c >> 24) & 0xFF);
    const r: u8 = @truncate((c >> 16) & 0xFF);
    const g: u8 = @truncate((c >> 8) & 0xFF);
    const b: u8 = @truncate(c & 0xFF);

    return if (a == 0xFF)
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch unreachable
    else
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a }) catch unreachable;
}

/// Parses `#rrggbb` (alpha assumed `0xFF`) or `#rrggbbaa`. Anything else,
/// including a missing `#`, is `error.InvalidCharacter` - one of
/// `std.json.ParseError`'s members, since this also runs as part of
/// `jsonParse`, whose return type is fixed to that error set.
pub fn colorFromHex(s: []const u8) !Color {
    if (s.len == 0 or s[0] != '#') return error.InvalidCharacter;
    const digits = s[1..];

    return switch (digits.len) {
        6 => blk: {
            const rgb = try std.fmt.parseUnsigned(u32, digits, 16);
            break :blk 0xFF000000 | rgb;
        },
        8 => blk: {
            const rgba = try std.fmt.parseUnsigned(u32, digits, 16);
            const r = (rgba >> 24) & 0xFF;
            const g = (rgba >> 16) & 0xFF;
            const b = (rgba >> 8) & 0xFF;
            const a = rgba & 0xFF;
            break :blk (a << 24) | (r << 16) | (g << 8) | b;
        },
        else => error.InvalidCharacter,
    };
}

/// Shared by `Ui.jsonStringify`/`Syntax.jsonStringify`: writes every field as
/// a hex-string color, skipping unset optional fields entirely rather than
/// emitting `null`.
fn jsonStringifyColors(comptime T: type, self: T, jws: anytype) !void {
    try jws.beginObject();
    inline for (std.meta.fields(T)) |field| {
        const maybe_color: ?Color = @field(self, field.name);
        if (maybe_color) |c| {
            try jws.objectField(field.name);
            var buf: [10]u8 = undefined;
            try jws.write(colorToHex(&buf, c));
        }
    }
    try jws.endObject();
}

/// Shared by `Ui.jsonParseFromValue`/`Syntax.jsonParseFromValue`: reads every
/// field from a hex-string color, falling back to the field's own Zig-level
/// default (or `error.MissingField` if it has none) when absent.
fn jsonParseColorsFromValue(comptime T: type, source: std.json.Value) !T {
    if (source != .object) return error.UnexpectedToken;

    var r: T = undefined;
    var fields_seen = [_]bool{false} ** std.meta.fields(T).len;

    inline for (std.meta.fields(T), 0..) |field, i| {
        if (source.object.get(field.name)) |v| {
            const hex = switch (v) {
                .string => |s| s,
                else => return error.UnexpectedToken,
            };
            @field(r, field.name) = try colorFromHex(hex);
            fields_seen[i] = true;
        }
    }

    inline for (std.meta.fields(T), 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.defaultValue()) |default| {
                @field(r, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
    }

    return r;
}

const Ui = struct {
    window_close: Color = 0xFFFF5F56,
    window_minimize: Color = 0xFFFFBD2E,
    window_expand: Color = 0xFF27C93F,
    background: Color,
    code_window_background: Color,
    foreground: Color,
    line_number: Color,
    highlight_background: Color = 0x33FFFFFF,

    pub fn jsonStringify(self: Ui, jws: anytype) !void {
        try jsonStringifyColors(Ui, self, jws);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Ui {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return try jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Ui {
        _ = allocator;
        _ = options;
        return try jsonParseColorsFromValue(Ui, source);
    }
};

const Syntax = struct {
    comment: Color,
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

    pub fn jsonStringify(self: Syntax, jws: anytype) !void {
        try jsonStringifyColors(Syntax, self, jws);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Syntax {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return try jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Syntax {
        _ = allocator;
        _ = options;
        return try jsonParseColorsFromValue(Syntax, source);
    }
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
            .number => self.syntax.number,
            .operator => self.syntax.operator,
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

pub const OneDarker = Theme {
    .name = "One Darker",
    .ui = .{
        .background = 0xFF1A1D23,
        .code_window_background = 0xFF21252B,
        .foreground = 0xFFABB2BF,
        .line_number = 0xFF4B5263,
    },
    .syntax = .{
        .comment = 0xFF5C6370,
        .constant = 0xFFD19A66,
        .constructor = 0xFFE5C07B,
        .function = 0xFF61AFEF,
        .keyword = 0xFFC678DD,
        .keyword_control = 0xFFC678DD,
        .label = 0xFFE06C75,
        .number = 0xFFD19A66,
        .operator = 0xFF56B6C2,
        .property = 0xFFE06C75,
        .punctuation = 0xFFABB2BF,
        .string = 0xFF98C379,
        .type = 0xFFE5C07B,
        .variable = 0xFFABB2BF,
        .variable_builtin = 0xFFE06C75,
    },
};

pub const MidnightAurora = Theme {
    .name = "Midnight Aurora",
    .ui = .{
        .background = 0xFF0F172A,
        .code_window_background = 0xFF1E293B,
        .foreground = 0xFFF8FAFC,
        .line_number = 0xFF475569,
    },
    .syntax = .{
        .comment = 0xFF64748B,
        .constant = 0xFF38BDF8,
        .constant_builtin = 0xFF7DD3FC,
        .constructor = 0xFFF472B6,
        .function = 0xFF2DD4BF,
        .function_call = 0xFF5EEAD4,
        .keyword = 0xFFC084FC,
        .keyword_return = 0xFFE879F9,
        .label = 0xFFFB7185,
        .number = 0xFFFACC15,
        .operator = 0xFF818CF8,
        .property = 0xFF94A3B8,
        .punctuation = 0xFFCBD5E1,
        .string = 0xFF4ADE80,
        .type = 0xFFFB923C,
        .variable = 0xFFF8FAFC,
        .variable_parameter = 0xFFFDBA74,
    },
};

pub const SolarizedLight = Theme {
    .name = "Solarized Light",
    .ui = .{
        .background = 0xFFEEE8D5,
        .code_window_background = 0xFFFDF6E3,
        .foreground = 0xFF657B83,
        .line_number = 0xFF93A1A1,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF93A1A1,
        .constant = 0xFFCB4B16,
        .constant_builtin = 0xFFCB4B16,
        .constructor = 0xFF268BD2,
        .function = 0xFF268BD2,
        .function_call = 0xFF268BD2,
        .keyword = 0xFF859900,
        .keyword_control = 0xFF859900,
        .label = 0xFFD33682,
        .number = 0xFF2AA198,
        .operator = 0xFF657B83,
        .property = 0xFF268BD2,
        .punctuation = 0xFF657B83,
        .string = 0xFF2AA198,
        .type = 0xFFB58900,
        .variable = 0xFF268BD2,
        .variable_parameter = 0xFF657B83,
    },
};

pub const PaperWhite = Theme {
    .name = "Paper White",
    .ui = .{
        .background = 0xFFF0F0F0,
        .code_window_background = 0xFFFFFFFF,
        .foreground = 0xFF24292E,
        .line_number = 0xFFBBBBBB,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF6A737D,
        .constant = 0xFF005CC5,
        .constructor = 0xFFD73A49,
        .function = 0xFF6F42C1,
        .function_call = 0xFF6F42C1,
        .keyword = 0xFFD73A49,
        .keyword_return = 0xFFD73A49,
        .label = 0xFF24292E,
        .number = 0xFF005CC5,
        .operator = 0xFFD73A49,
        .property = 0xFFE36209,
        .punctuation = 0xFF24292E,
        .string = 0xFF032F62,
        .type = 0xFFD73A49,
        .variable = 0xFF24292E,
        .variable_parameter = 0xFFE36209,
    },
};

pub const builtin_themes = [_]Theme{
    OneDarker,
    MidnightAurora,
    SolarizedLight,
    PaperWhite,
};

/// Looks up a builtin theme by exact name. Returns null instead of falling
/// back to a default, so callers can distinguish "not found" from "found".
pub fn findBuiltin(name: []const u8) ?Theme {
    for (builtin_themes) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            return t;
        }
    }
    return null;
}

/// Wraps a resolved theme so callers don't need to know whether it came from
/// a builtin (no allocation, `deinit` is a no-op) or was parsed from a user
/// theme JSON file (heap-owned via `std.json.Parsed`, must be freed exactly
/// once). `value()` is only valid while the handle is alive.
pub const ThemeHandle = union(enum) {
    static: Theme,
    owned: std.json.Parsed(Theme),

    pub fn value(self: *const ThemeHandle) Theme {
        return switch (self.*) {
            .static => |t| t,
            .owned => |p| p.value,
        };
    }

    pub fn deinit(self: *ThemeHandle) void {
        switch (self.*) {
            .static => {},
            .owned => |*p| p.deinit(),
        }
    }
};


const minimal_theme_json =
    \\{
    \\  "name": "Minimal",
    \\  "ui": {
    \\    "background": "#101010",
    \\    "code_window_background": "#202020",
    \\    "foreground": "#303030",
    \\    "line_number": "#404040"
    \\  },
    \\  "syntax": {
    \\    "comment": "#000001", "constant": "#000002", "constructor": "#000003",
    \\    "function": "#000004", "keyword": "#000005", "label": "#000006",
    \\    "number": "#000007", "operator": "#000008", "property": "#000009",
    \\    "punctuation": "#00000a", "string": "#00000b", "type": "#00000c",
    \\    "variable": "#00000d"
    \\  }
    \\}
;

/// A theme where every required color is distinct and every optional one is
/// unset, so `getColor` fallbacks are observable.
fn bareTheme() Theme {
    return .{
        .name = "Bare",
        .ui = .{
            .background = 0xFF101010,
            .code_window_background = 0xFF202020,
            .foreground = 0xFF303030,
            .line_number = 0xFF404040,
        },
        .syntax = .{
            .comment = 0xFF000001,
            .constant = 0xFF000002,
            .constructor = 0xFF000003,
            .function = 0xFF000004,
            .keyword = 0xFF000005,
            .label = 0xFF000006,
            .number = 0xFF000007,
            .operator = 0xFF000008,
            .property = 0xFF000009,
            .punctuation = 0xFF00000A,
            .string = 0xFF00000B,
            .type = 0xFF00000C,
            .variable = 0xFF00000D,
        },
    };
}

test "colorToHex drops alpha when fully opaque" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("#1a2b3c", colorToHex(&buf, 0xFF1A2B3C));
    try std.testing.expectEqualStrings("#000000", colorToHex(&buf, 0xFF000000));
    try std.testing.expectEqualStrings("#ffffff", colorToHex(&buf, 0xFFFFFFFF));
}

test "colorToHex appends alpha last when not fully opaque" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("#ff000080", colorToHex(&buf, 0x80FF0000));
    try std.testing.expectEqualStrings("#ffffff33", colorToHex(&buf, 0x33FFFFFF));
    try std.testing.expectEqualStrings("#00000000", colorToHex(&buf, 0x00000000));
}

test "colorToHex zero-pads small channel values" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("#010203", colorToHex(&buf, 0xFF010203));
}

test "colorFromHex parses six digits as opaque" {
    try std.testing.expectEqual(@as(Color, 0xFF1A2B3C), try colorFromHex("#1a2b3c"));
    try std.testing.expectEqual(@as(Color, 0xFF1A2B3C), try colorFromHex("#1A2B3C"));
    try std.testing.expectEqual(@as(Color, 0xFF000000), try colorFromHex("#000000"));
}

test "colorFromHex reads eight digits as rrggbbaa and returns argb" {
    try std.testing.expectEqual(@as(Color, 0x80FF0000), try colorFromHex("#ff000080"));
    try std.testing.expectEqual(@as(Color, 0x33FFFFFF), try colorFromHex("#ffffff33"));
    try std.testing.expectEqual(@as(Color, 0xFF112233), try colorFromHex("#112233ff"));
}

test "colorFromHex rejects malformed input" {
    try std.testing.expectError(error.InvalidCharacter, colorFromHex(""));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("1a2b3c"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#fff"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#1a2b3c4"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#1a2b3c4d5e"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#zzzzzz"));
    try std.testing.expectError(error.InvalidCharacter, colorFromHex("#12345g"));
}

test "colorToHex and colorFromHex round trip" {
    const samples = [_]Color{ 0xFF000000, 0xFFFFFFFF, 0xFF1A1D23, 0x33FFFFFF, 0x80102030, 0x00000000, 0x01020304 };
    var buf: [10]u8 = undefined;
    for (samples) |c| {
        try std.testing.expectEqual(c, try colorFromHex(colorToHex(&buf, c)));
    }
}

test "Theme parses minimal JSON and applies Ui defaults" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Theme, allocator, minimal_theme_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const t = parsed.value;
    try std.testing.expectEqualStrings("Minimal", t.name);
    try std.testing.expectEqual(@as(Color, 0xFF101010), t.ui.background);
    try std.testing.expectEqual(@as(Color, 0xFF404040), t.ui.line_number);
    // Unspecified Ui fields fall back to their declared defaults.
    try std.testing.expectEqual(@as(Color, 0xFFFF5F56), t.ui.window_close);
    try std.testing.expectEqual(@as(Color, 0xFFFFBD2E), t.ui.window_minimize);
    try std.testing.expectEqual(@as(Color, 0xFF27C93F), t.ui.window_expand);
    try std.testing.expectEqual(@as(Color, 0x33FFFFFF), t.ui.highlight_background);
    // Unspecified optional syntax colors stay null.
    try std.testing.expectEqual(@as(?Color, null), t.syntax.function_builtin);
    try std.testing.expectEqual(@as(?Color, null), t.syntax.variable_parameter);
    try std.testing.expectEqual(@as(Color, 0xFF000004), t.syntax.function);
}

test "Theme JSON honours overridden defaults and optional syntax colors" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name":"X","ui":{"background":"#000000","code_window_background":"#000000",
        \\"foreground":"#000000","line_number":"#000000","window_close":"#112233",
        \\"highlight_background":"#ffffff10"},
        \\"syntax":{"comment":"#000001","constant":"#000002","constructor":"#000003",
        \\"function":"#000004","keyword":"#000005","label":"#000006","number":"#000007",
        \\"operator":"#000008","property":"#000009","punctuation":"#00000a","string":"#00000b",
        \\"type":"#00000c","variable":"#00000d","keyword_return":"#abcdef"}}
    ;
    const parsed = try std.json.parseFromSlice(Theme, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(Color, 0xFF112233), parsed.value.ui.window_close);
    try std.testing.expectEqual(@as(Color, 0x10FFFFFF), parsed.value.ui.highlight_background);
    try std.testing.expectEqual(@as(?Color, 0xFFABCDEF), parsed.value.syntax.keyword_return);
}

test "Theme JSON reports a missing required Ui color" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name":"X","ui":{"background":"#000000"},"syntax":{}}
    ;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Theme, allocator, json, .{ .allocate = .alloc_always }));
}

test "Theme JSON reports a missing required syntax color" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name":"X","ui":{"background":"#000000","code_window_background":"#000000",
        \\"foreground":"#000000","line_number":"#000000"},"syntax":{"comment":"#000000"}}
    ;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Theme, allocator, json, .{ .allocate = .alloc_always }));
}

test "Theme JSON rejects non-object ui and non-string colors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(
        Theme,
        allocator,
        \\{"name":"X","ui":5,"syntax":{}}
        ,
        .{ .allocate = .alloc_always },
    ));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(
        Theme,
        allocator,
        \\{"name":"X","ui":{"background":123},"syntax":{}}
        ,
        .{ .allocate = .alloc_always },
    ));
}

test "Theme JSON rejects an invalid hex color" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(
        Theme,
        allocator,
        \\{"name":"X","ui":{"background":"red"},"syntax":{}}
        ,
        .{ .allocate = .alloc_always },
    ));
}

test "Theme stringify omits unset optional colors" {
    const allocator = std.testing.allocator;
    const t = bareTheme();
    const json = try std.json.Stringify.valueAlloc(allocator, t, .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"function_builtin\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"variable_parameter\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"function\":\"#000004\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "null") == null);
}

test "every builtin theme round-trips through JSON" {
    const allocator = std.testing.allocator;
    for (builtin_themes) |original| {
        const json = try std.json.Stringify.valueAlloc(allocator, original, .{ .whitespace = .indent_2 });
        defer allocator.free(json);

        const parsed = try std.json.parseFromSlice(Theme, allocator, json, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        try std.testing.expectEqualStrings(original.name, parsed.value.name);
        try std.testing.expect(std.meta.eql(original.ui, parsed.value.ui));
        try std.testing.expect(std.meta.eql(original.syntax, parsed.value.syntax));
    }
}

test "getColor returns the base color for every category without overrides" {
    var t = bareTheme();
    const TC = tree_sitter.TokenCategory;
    try std.testing.expectEqual(t.syntax.comment, t.getColor(TC.comment));
    try std.testing.expectEqual(t.syntax.constant, t.getColor(TC.constant));
    try std.testing.expectEqual(t.syntax.constructor, t.getColor(TC.constructor));
    try std.testing.expectEqual(t.syntax.function, t.getColor(TC.function));
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.keyword));
    try std.testing.expectEqual(t.syntax.number, t.getColor(TC.number));
    try std.testing.expectEqual(t.syntax.operator, t.getColor(TC.operator));
    try std.testing.expectEqual(t.syntax.property, t.getColor(TC.property));
    try std.testing.expectEqual(t.syntax.punctuation, t.getColor(TC.punctuation));
    try std.testing.expectEqual(t.syntax.string, t.getColor(TC.string));
    try std.testing.expectEqual(t.syntax.type, t.getColor(TC.type));
    try std.testing.expectEqual(t.syntax.variable, t.getColor(TC.variable));
}

test "getColor falls back to the parent color when an optional is unset" {
    var t = bareTheme();
    const TC = tree_sitter.TokenCategory;
    try std.testing.expectEqual(t.syntax.function, t.getColor(TC.function_builtin));
    try std.testing.expectEqual(t.syntax.function, t.getColor(TC.function_call));
    try std.testing.expectEqual(t.syntax.function, t.getColor(TC.function_method));
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.keyword_function));
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.keyword_modifier));
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.keyword_operator));
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.keyword_return));
    try std.testing.expectEqual(t.syntax.punctuation, t.getColor(TC.punctuation_bracket));
    try std.testing.expectEqual(t.syntax.punctuation, t.getColor(TC.punctuation_delimiter));
    try std.testing.expectEqual(t.syntax.string, t.getColor(TC.string_escape));
    try std.testing.expectEqual(t.syntax.string, t.getColor(TC.string_special));
    try std.testing.expectEqual(t.syntax.type, t.getColor(TC.type_builtin));
    try std.testing.expectEqual(t.syntax.variable, t.getColor(TC.variable_builtin));
    try std.testing.expectEqual(t.syntax.variable, t.getColor(TC.variable_member));
    try std.testing.expectEqual(t.syntax.variable, t.getColor(TC.variable_parameter));
}

test "getColor prefers the optional color when it is set" {
    var t = bareTheme();
    t.syntax.function_builtin = 0xFFAA0001;
    t.syntax.function_call = 0xFFAA0002;
    t.syntax.function_method = 0xFFAA0003;
    t.syntax.keyword_function = 0xFFAA0004;
    t.syntax.keyword_modifier = 0xFFAA0005;
    t.syntax.keyword_operator = 0xFFAA0006;
    t.syntax.keyword_return = 0xFFAA0007;
    t.syntax.punctuation_bracket = 0xFFAA0008;
    t.syntax.punctuation_delimiter = 0xFFAA0009;
    t.syntax.string_escape = 0xFFAA000A;
    t.syntax.string_regex = 0xFFAA000B;
    t.syntax.type_builtin = 0xFFAA000C;
    t.syntax.variable_builtin = 0xFFAA000D;
    t.syntax.variable_member = 0xFFAA000E;
    t.syntax.variable_parameter = 0xFFAA000F;

    const TC = tree_sitter.TokenCategory;
    try std.testing.expectEqual(@as(Color, 0xFFAA0001), t.getColor(TC.function_builtin));
    try std.testing.expectEqual(@as(Color, 0xFFAA0002), t.getColor(TC.function_call));
    try std.testing.expectEqual(@as(Color, 0xFFAA0003), t.getColor(TC.function_method));
    try std.testing.expectEqual(@as(Color, 0xFFAA0004), t.getColor(TC.keyword_function));
    try std.testing.expectEqual(@as(Color, 0xFFAA0005), t.getColor(TC.keyword_modifier));
    try std.testing.expectEqual(@as(Color, 0xFFAA0006), t.getColor(TC.keyword_operator));
    try std.testing.expectEqual(@as(Color, 0xFFAA0007), t.getColor(TC.keyword_return));
    try std.testing.expectEqual(@as(Color, 0xFFAA0008), t.getColor(TC.punctuation_bracket));
    try std.testing.expectEqual(@as(Color, 0xFFAA0009), t.getColor(TC.punctuation_delimiter));
    try std.testing.expectEqual(@as(Color, 0xFFAA000A), t.getColor(TC.string_escape));
    // `string_special` is drawn with the regex color.
    try std.testing.expectEqual(@as(Color, 0xFFAA000B), t.getColor(TC.string_special));
    try std.testing.expectEqual(@as(Color, 0xFFAA000C), t.getColor(TC.type_builtin));
    try std.testing.expectEqual(@as(Color, 0xFFAA000D), t.getColor(TC.variable_builtin));
    try std.testing.expectEqual(@as(Color, 0xFFAA000E), t.getColor(TC.variable_member));
    try std.testing.expectEqual(@as(Color, 0xFFAA000F), t.getColor(TC.variable_parameter));
}

test "getColor maps tag, tag_attribute, field and default_text onto existing colors" {
    var t = bareTheme();
    const TC = tree_sitter.TokenCategory;
    try std.testing.expectEqual(t.syntax.keyword, t.getColor(TC.tag));
    try std.testing.expectEqual(t.syntax.property, t.getColor(TC.tag_attribute));
    try std.testing.expectEqual(t.syntax.property, t.getColor(TC.field));
    try std.testing.expectEqual(t.ui.foreground, t.getColor(TC.default_text));
}

test "getColor resolves every category for every builtin theme" {
    inline for (std.meta.fields(tree_sitter.TokenCategory)) |field| {
        for (builtin_themes) |original| {
            var t = original;
            const c = t.getColor(@field(tree_sitter.TokenCategory, field.name));
            // Builtin syntax colors are opaque.
            try std.testing.expectEqual(@as(u32, 0xFF), c >> 24);
        }
    }
}

test "findBuiltin finds every builtin by its exact name" {
    for (builtin_themes) |t| {
        const found = findBuiltin(t.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(t.name, found.name);
    }
}

test "findBuiltin is case-sensitive and returns null for unknown names" {
    try std.testing.expect(findBuiltin("one darker") == null);
    try std.testing.expect(findBuiltin("ONE DARKER") == null);
    try std.testing.expect(findBuiltin("One Darker ") == null);
    try std.testing.expect(findBuiltin("") == null);
    try std.testing.expect(findBuiltin("Nope") == null);
}

test "builtin theme names are unique" {
    for (builtin_themes, 0..) |a, i| {
        for (builtin_themes[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "ThemeHandle.static returns the wrapped theme and deinit is a no-op" {
    var handle = ThemeHandle{ .static = OneDarker };
    defer handle.deinit();
    try std.testing.expectEqualStrings("One Darker", handle.value().name);
    try std.testing.expectEqual(OneDarker.ui.background, handle.value().ui.background);
}

test "ThemeHandle.owned exposes the parsed theme and frees it on deinit" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Theme, allocator, minimal_theme_json, .{ .allocate = .alloc_always });
    var handle = ThemeHandle{ .owned = parsed };
    defer handle.deinit();

    try std.testing.expectEqualStrings("Minimal", handle.value().name);
    try std.testing.expectEqual(@as(Color, 0xFF303030), handle.value().ui.foreground);
}
