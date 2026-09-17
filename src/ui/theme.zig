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

