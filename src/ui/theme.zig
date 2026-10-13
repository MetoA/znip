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

pub const Dracula = Theme {
    .name = "Dracula",
    .ui = .{
        .background = 0xFF21222C,
        .code_window_background = 0xFF282A36,
        .foreground = 0xFFF8F8F2,
        .line_number = 0xFF6272A4,
    },
    .syntax = .{
        .comment = 0xFF6272A4,
        .constant = 0xFFBD93F9,
        .constructor = 0xFF8BE9FD,
        .function = 0xFF50FA7B,
        .keyword = 0xFFFF79C6,
        .label = 0xFFFFB86C,
        .number = 0xFFBD93F9,
        .operator = 0xFFFF79C6,
        .property = 0xFFF8F8F2,
        .punctuation = 0xFFF8F8F2,
        .string = 0xFFF1FA8C,
        .type = 0xFF8BE9FD,
        .variable = 0xFFF8F8F2,
        .variable_builtin = 0xFFBD93F9,
        .variable_parameter = 0xFFFFB86C,
    },
};

pub const Nord = Theme {
    .name = "Nord",
    .ui = .{
        .background = 0xFF2B303B,
        .code_window_background = 0xFF2E3440,
        .foreground = 0xFFD8DEE9,
        .line_number = 0xFF4C566A,
    },
    .syntax = .{
        .comment = 0xFF616E88,
        .constant = 0xFF81A1C1,
        .constructor = 0xFF8FBCBB,
        .function = 0xFF88C0D0,
        .keyword = 0xFF81A1C1,
        .label = 0xFFEBCB8B,
        .number = 0xFFB48EAD,
        .operator = 0xFF81A1C1,
        .property = 0xFFD8DEE9,
        .punctuation = 0xFFD8DEE9,
        .string = 0xFFA3BE8C,
        .type = 0xFF8FBCBB,
        .variable = 0xFFD8DEE9,
        .variable_builtin = 0xFF81A1C1,
    },
};

pub const GruvboxDark = Theme {
    .name = "Gruvbox Dark",
    .ui = .{
        .background = 0xFF1D2021,
        .code_window_background = 0xFF282828,
        .foreground = 0xFFEBDBB2,
        .line_number = 0xFF7C6F64,
    },
    .syntax = .{
        .comment = 0xFF928374,
        .constant = 0xFFD3869B,
        .constructor = 0xFFFABD2F,
        .function = 0xFF8EC07C,
        .keyword = 0xFFFB4934,
        .label = 0xFFFE8019,
        .number = 0xFFD3869B,
        .operator = 0xFFFE8019,
        .property = 0xFF83A598,
        .punctuation = 0xFFEBDBB2,
        .string = 0xFFB8BB26,
        .type = 0xFFFABD2F,
        .variable = 0xFFEBDBB2,
        .variable_builtin = 0xFFFE8019,
    },
};

pub const TokyoNight = Theme {
    .name = "Tokyo Night",
    .ui = .{
        .background = 0xFF16161E,
        .code_window_background = 0xFF1A1B26,
        .foreground = 0xFFC0CAF5,
        .line_number = 0xFF3B4261,
    },
    .syntax = .{
        .comment = 0xFF565F89,
        .constant = 0xFFFF9E64,
        .constructor = 0xFF2AC3DE,
        .function = 0xFF7AA2F7,
        .keyword = 0xFFBB9AF7,
        .label = 0xFF73DACA,
        .number = 0xFFFF9E64,
        .operator = 0xFF89DDFF,
        .property = 0xFF73DACA,
        .punctuation = 0xFF89DDFF,
        .string = 0xFF9ECE6A,
        .type = 0xFF2AC3DE,
        .variable = 0xFFC0CAF5,
        .variable_builtin = 0xFFF7768E,
        .variable_parameter = 0xFFE0AF68,
    },
};

pub const CatppuccinMocha = Theme {
    .name = "Catppuccin Mocha",
    .ui = .{
        .background = 0xFF11111B,
        .code_window_background = 0xFF1E1E2E,
        .foreground = 0xFFCDD6F4,
        .line_number = 0xFF45475A,
    },
    .syntax = .{
        .comment = 0xFF6C7086,
        .constant = 0xFFFAB387,
        .constructor = 0xFF74C7EC,
        .function = 0xFF89B4FA,
        .keyword = 0xFFCBA6F7,
        .label = 0xFF74C7EC,
        .number = 0xFFFAB387,
        .operator = 0xFF89DCEB,
        .property = 0xFFB4BEFE,
        .punctuation = 0xFF9399B2,
        .string = 0xFFA6E3A1,
        .type = 0xFFF9E2AF,
        .variable = 0xFFCDD6F4,
        .variable_builtin = 0xFFF38BA8,
        .variable_parameter = 0xFFEBA0AC,
    },
};

pub const Monokai = Theme {
    .name = "Monokai",
    .ui = .{
        .background = 0xFF1E1F1C,
        .code_window_background = 0xFF272822,
        .foreground = 0xFFF8F8F2,
        .line_number = 0xFF90908A,
    },
    .syntax = .{
        .comment = 0xFF75715E,
        .constant = 0xFFAE81FF,
        .constructor = 0xFF66D9EF,
        .function = 0xFFA6E22E,
        .keyword = 0xFFF92672,
        .label = 0xFFF8F8F2,
        .number = 0xFFAE81FF,
        .operator = 0xFFF92672,
        .property = 0xFFF8F8F2,
        .punctuation = 0xFFF8F8F2,
        .string = 0xFFE6DB74,
        .type = 0xFF66D9EF,
        .variable = 0xFFF8F8F2,
        .variable_builtin = 0xFFFD971F,
        .variable_parameter = 0xFFFD971F,
    },
};

pub const GitHubDark = Theme {
    .name = "GitHub Dark",
    .ui = .{
        .background = 0xFF010409,
        .code_window_background = 0xFF0D1117,
        .foreground = 0xFFE6EDF3,
        .line_number = 0xFF6E7681,
    },
    .syntax = .{
        .comment = 0xFF8B949E,
        .constant = 0xFF79C0FF,
        .constructor = 0xFFFFA657,
        .function = 0xFFD2A8FF,
        .keyword = 0xFFFF7B72,
        .label = 0xFFE6EDF3,
        .number = 0xFF79C0FF,
        .operator = 0xFFFF7B72,
        .property = 0xFF79C0FF,
        .punctuation = 0xFFE6EDF3,
        .string = 0xFFA5D6FF,
        .type = 0xFFFFA657,
        .variable = 0xFFE6EDF3,
        .variable_builtin = 0xFFFFA657,
        .variable_parameter = 0xFFE6EDF3,
    },
};

pub const RosePine = Theme {
    .name = "Rose Pine",
    .ui = .{
        .background = 0xFF141320,
        .code_window_background = 0xFF191724,
        .foreground = 0xFFE0DEF4,
        .line_number = 0xFF524F67,
    },
    .syntax = .{
        .comment = 0xFF6E6A86,
        .constant = 0xFFEA9A97,
        .constructor = 0xFF9CCFD8,
        .function = 0xFFEBBCBA,
        .keyword = 0xFF3E8FB0,
        .label = 0xFFC4A7E7,
        .number = 0xFFEA9A97,
        .operator = 0xFF908CAA,
        .property = 0xFFC4A7E7,
        .punctuation = 0xFF908CAA,
        .string = 0xFFF6C177,
        .type = 0xFF9CCFD8,
        .variable = 0xFFE0DEF4,
        .variable_builtin = 0xFFEB6F92,
        .variable_parameter = 0xFFC4A7E7,
    },
};

pub const SolarizedDark = Theme {
    .name = "Solarized Dark",
    .ui = .{
        .background = 0xFF00212B,
        .code_window_background = 0xFF002B36,
        .foreground = 0xFF839496,
        .line_number = 0xFF586E75,
    },
    .syntax = .{
        .comment = 0xFF586E75,
        .constant = 0xFFCB4B16,
        .constructor = 0xFF268BD2,
        .function = 0xFF268BD2,
        .keyword = 0xFF859900,
        .label = 0xFFD33682,
        .number = 0xFFD33682,
        .operator = 0xFF839496,
        .property = 0xFF268BD2,
        .punctuation = 0xFF839496,
        .string = 0xFF2AA198,
        .type = 0xFFB58900,
        .variable = 0xFF839496,
        .variable_builtin = 0xFFCB4B16,
    },
};

pub const NightOwl = Theme {
    .name = "Night Owl",
    .ui = .{
        .background = 0xFF010E1A,
        .code_window_background = 0xFF011627,
        .foreground = 0xFFD6DEEB,
        .line_number = 0xFF4B6479,
    },
    .syntax = .{
        .comment = 0xFF637777,
        .constant = 0xFFF78C6C,
        .constructor = 0xFFFFCB8B,
        .function = 0xFF82AAFF,
        .keyword = 0xFFC792EA,
        .label = 0xFF7FDBCA,
        .number = 0xFFF78C6C,
        .operator = 0xFFC792EA,
        .property = 0xFF7FDBCA,
        .punctuation = 0xFF7FDBCA,
        .string = 0xFFECC48D,
        .type = 0xFFFFCB8B,
        .variable = 0xFFD6DEEB,
        .variable_builtin = 0xFF7FDBCA,
    },
};

pub const GitHubLight = Theme {
    .name = "GitHub Light",
    .ui = .{
        .background = 0xFFF6F8FA,
        .code_window_background = 0xFFFFFFFF,
        .foreground = 0xFF24292F,
        .line_number = 0xFF8C959F,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF6E7781,
        .constant = 0xFF0550AE,
        .constructor = 0xFF953800,
        .function = 0xFF8250DF,
        .keyword = 0xFFCF222E,
        .label = 0xFF24292F,
        .number = 0xFF0550AE,
        .operator = 0xFF0550AE,
        .property = 0xFF0550AE,
        .punctuation = 0xFF24292F,
        .string = 0xFF0A3069,
        .type = 0xFF953800,
        .variable = 0xFF24292F,
        .variable_builtin = 0xFF953800,
        .variable_parameter = 0xFF953800,
    },
};

pub const OneLight = Theme {
    .name = "One Light",
    .ui = .{
        .background = 0xFFEAEAEB,
        .code_window_background = 0xFFFAFAFA,
        .foreground = 0xFF383A42,
        .line_number = 0xFF9D9D9F,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFFA0A1A7,
        .constant = 0xFF986801,
        .constructor = 0xFFC18401,
        .function = 0xFF4078F2,
        .keyword = 0xFFA626A4,
        .label = 0xFFE45649,
        .number = 0xFF986801,
        .operator = 0xFF0184BC,
        .property = 0xFFE45649,
        .punctuation = 0xFF383A42,
        .string = 0xFF50A14F,
        .type = 0xFFC18401,
        .variable = 0xFF383A42,
        .variable_builtin = 0xFFE45649,
    },
};

pub const GruvboxLight = Theme {
    .name = "Gruvbox Light",
    .ui = .{
        .background = 0xFFF2E5BC,
        .code_window_background = 0xFFFBF1C7,
        .foreground = 0xFF3C3836,
        .line_number = 0xFFA89984,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF928374,
        .constant = 0xFF8F3F71,
        .constructor = 0xFFB57614,
        .function = 0xFF427B58,
        .keyword = 0xFF9D0006,
        .label = 0xFFAF3A03,
        .number = 0xFF8F3F71,
        .operator = 0xFFAF3A03,
        .property = 0xFF076678,
        .punctuation = 0xFF3C3836,
        .string = 0xFF79740E,
        .type = 0xFFB57614,
        .variable = 0xFF3C3836,
        .variable_builtin = 0xFFAF3A03,
    },
};

pub const CatppuccinLatte = Theme {
    .name = "Catppuccin Latte",
    .ui = .{
        .background = 0xFFDCE0E8,
        .code_window_background = 0xFFEFF1F5,
        .foreground = 0xFF4C4F69,
        .line_number = 0xFFACB0BE,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF8C8FA1,
        .constant = 0xFFFE640B,
        .constructor = 0xFF209FB5,
        .function = 0xFF1E66F5,
        .keyword = 0xFF8839EF,
        .label = 0xFF209FB5,
        .number = 0xFFFE640B,
        .operator = 0xFF04A5E5,
        .property = 0xFF7287FD,
        .punctuation = 0xFF7C7F93,
        .string = 0xFF40A02B,
        .type = 0xFFDF8E1D,
        .variable = 0xFF4C4F69,
        .variable_builtin = 0xFFD20F39,
        .variable_parameter = 0xFFE64553,
    },
};

pub const TokyoNightDay = Theme {
    .name = "Tokyo Night Day",
    .ui = .{
        .background = 0xFFD0D5E3,
        .code_window_background = 0xFFE1E2E7,
        .foreground = 0xFF3760BF,
        .line_number = 0xFFA8AECB,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF848CB5,
        .constant = 0xFFB15C00,
        .constructor = 0xFF007197,
        .function = 0xFF2E7DE9,
        .keyword = 0xFF9854F1,
        .label = 0xFF118C74,
        .number = 0xFFB15C00,
        .operator = 0xFF006A83,
        .property = 0xFF118C74,
        .punctuation = 0xFF3760BF,
        .string = 0xFF587539,
        .type = 0xFF007197,
        .variable = 0xFF3760BF,
        .variable_builtin = 0xFFF52A65,
        .variable_parameter = 0xFF8C6C3E,
    },
};

pub const RosePineDawn = Theme {
    .name = "Rose Pine Dawn",
    .ui = .{
        .background = 0xFFF2E9E1,
        .code_window_background = 0xFFFAF4ED,
        .foreground = 0xFF575279,
        .line_number = 0xFFB8B2BE,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFF9893A5,
        .constant = 0xFFB4637A,
        .constructor = 0xFF56949F,
        .function = 0xFFD7827E,
        .keyword = 0xFF286983,
        .label = 0xFF907AA9,
        .number = 0xFFB4637A,
        .operator = 0xFF797593,
        .property = 0xFF907AA9,
        .punctuation = 0xFF797593,
        .string = 0xFFD08523,
        .type = 0xFF56949F,
        .variable = 0xFF575279,
        .variable_builtin = 0xFFB4637A,
        .variable_parameter = 0xFF907AA9,
    },
};

pub const AyuLight = Theme {
    .name = "Ayu Light",
    .ui = .{
        .background = 0xFFEEEEEE,
        .code_window_background = 0xFFFCFCFC,
        .foreground = 0xFF5C6166,
        .line_number = 0xFF8A9199,
        .highlight_background = 0x1F000000,
    },
    .syntax = .{
        .comment = 0xFFABB0B6,
        .constant = 0xFFA37ACC,
        .constructor = 0xFF399EE6,
        .function = 0xFFEB9A2A,
        .keyword = 0xFFFA8D3E,
        .label = 0xFF55B4D4,
        .number = 0xFFA37ACC,
        .operator = 0xFFED9366,
        .property = 0xFF41A6D9,
        .punctuation = 0xFF5C6166,
        .string = 0xFF86B300,
        .type = 0xFF399EE6,
        .variable = 0xFF5C6166,
        .variable_builtin = 0xFFF07171,
        .variable_parameter = 0xFFA37ACC,
    },
};

pub const builtin_themes = [_]Theme{
    OneDarker,
    MidnightAurora,
    SolarizedLight,
    PaperWhite,
    // Dark
    Dracula,
    Nord,
    GruvboxDark,
    TokyoNight,
    CatppuccinMocha,
    Monokai,
    GitHubDark,
    RosePine,
    SolarizedDark,
    NightOwl,
    // Light
    GitHubLight,
    OneLight,
    GruvboxLight,
    CatppuccinLatte,
    TokyoNightDay,
    RosePineDawn,
    AyuLight,
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
