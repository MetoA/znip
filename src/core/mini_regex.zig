//! A small backtracking regular-expression matcher, just big enough for the
//! `#match?` / `#lua-match?` predicates found in Tree-sitter highlight queries
//! (the C library leaves evaluating those to the caller).
//!
//! Supported: literals, `.`, character classes (`[a-z_]`, `[^...]`, escapes
//! inside), `\d \w \s` (and their negations), `^` / `$` anchors, groups
//! (`( )` and `(?: )`), alternation `|`, and the quantifiers `* + ?` and
//! `{n}`, `{n,}`, `{n,m}` (a trailing `?` for lazy matching is accepted; since
//! only "does it match" matters, laziness can't change the answer).
//!
//! Matching is byte-based, unanchored (like `Regex::is_match`), and a pattern
//! that uses anything else (look-around, back-references, `\b`, ...) is
//! rejected at compile time with `error.UnsupportedPattern` so callers can
//! decide what to do instead of silently mis-matching.
//!
//! The `lua` flavour uses `%` instead of `\` as the escape character, has no
//! alternation or `{}` repetition, and accepts `-` as a (lazy) `*`.

const std = @import("std");

pub const Flavor = enum { regex, lua };

pub const Regex = struct {
    alternatives: []const Sequence,

    const Sequence = []const Item;

    const Item = struct {
        atom: Atom,
        min: u32 = 1,
        max: u32 = 1,
    };

    const Atom = union(enum) {
        byte: u8,
        any,
        set: Set,
        line_start,
        line_end,
        group: []const Sequence,
    };

    const Set = std.StaticBitSet(256);

    /// Compiles `pattern`. All allocations go to `arena`, which must outlive
    /// the returned Regex.
    pub fn compile(arena: std.mem.Allocator, pattern: []const u8, flavor: Flavor) !Regex {
        var parser = Parser{ .arena = arena, .pattern = pattern, .flavor = flavor };
        const alternatives = try parser.parseAlternatives(0);
        if (parser.pos != pattern.len) return error.UnsupportedPattern; // stray ')'
        return .{ .alternatives = alternatives };
    }

    /// Whether the pattern matches anywhere in `text`.
    pub fn isMatch(self: Regex, text: []const u8) bool {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (matchAlternatives(self.alternatives, text, start, null)) return true;
        }
        return false;
    }
};

const max_group_depth = 32;
/// Upper bound for an explicit `{n,m}`; `*`, `+` and `{n,}` are unbounded.
const max_explicit_repeat = 1000;
const unbounded = std.math.maxInt(u32);

const Parser = struct {
    arena: std.mem.Allocator,
    pattern: []const u8,
    flavor: Flavor,
    pos: usize = 0,

    const Error = error{ UnsupportedPattern, OutOfMemory };

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn escapeChar(self: *const Parser) u8 {
        return if (self.flavor == .lua) '%' else '\\';
    }

    fn parseAlternatives(self: *Parser, depth: u32) Error![]const Regex.Sequence {
        if (depth > max_group_depth) return error.UnsupportedPattern;
        var alternatives = std.ArrayList(Regex.Sequence).empty;
        while (true) {
            try alternatives.append(self.arena, try self.parseSequence(depth));
            if (self.flavor == .regex and self.peek() == '|') {
                self.pos += 1;
                continue;
            }
            break;
        }
        return alternatives.toOwnedSlice(self.arena);
    }

    fn parseSequence(self: *Parser, depth: u32) Error!Regex.Sequence {
        var items = std.ArrayList(Regex.Item).empty;
        while (self.peek()) |ch| {
            if (ch == ')' and depth > 0) break;
            if (ch == '|' and self.flavor == .regex) break;

            var item = Regex.Item{ .atom = try self.parseAtom(depth) };
            try self.parseQuantifier(&item);
            try items.append(self.arena, item);
        }
        return items.toOwnedSlice(self.arena);
    }

    fn parseAtom(self: *Parser, depth: u32) Error!Regex.Atom {
        const ch = self.pattern[self.pos];
        self.pos += 1;
        switch (ch) {
            '.' => return .any,
            '^' => return .line_start,
            '$' => return .line_end,
            '[' => return .{ .set = try self.parseClass() },
            '(' => {
                if (self.flavor == .regex and self.peek() == '?') {
                    // Only the non-capturing form; look-around and named
                    // groups are out of scope.
                    if (self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == ':') {
                        self.pos += 2;
                    } else return error.UnsupportedPattern;
                }
                const inner = try self.parseAlternatives(depth + 1);
                if (self.peek() != ')') return error.UnsupportedPattern;
                self.pos += 1;
                return .{ .group = inner };
            },
            '*', '+', '?' => return error.UnsupportedPattern, // nothing to repeat
            ')' => return error.UnsupportedPattern, // unbalanced (inside a group the sequence loop stops first)
            else => {
                if (ch == self.escapeChar()) return try self.parseEscape();
                return .{ .byte = ch };
            },
        }
    }

    /// The escape character has just been consumed.
    fn parseEscape(self: *Parser) Error!Regex.Atom {
        const ch = self.peek() orelse return error.UnsupportedPattern;
        self.pos += 1;
        if (classForEscape(ch, self.flavor)) |set| return .{ .set = set };
        if (std.ascii.isAlphanumeric(ch)) {
            return switch (ch) {
                'n' => .{ .byte = '\n' },
                't' => .{ .byte = '\t' },
                'r' => .{ .byte = '\r' },
                else => error.UnsupportedPattern, // \b, \A, \1, %b, %f, ...
            };
        }
        return .{ .byte = ch }; // an escaped punctuation character
    }

    fn parseClass(self: *Parser) Error!Regex.Set {
        var set = Regex.Set.initEmpty();
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.pos += 1;
        }

        var first = true;
        while (true) {
            const ch = self.peek() orelse return error.UnsupportedPattern; // unterminated
            self.pos += 1;
            if (ch == ']' and !first) break;
            first = false;

            // A single member: either a class escape (adds a whole set) or a
            // byte that may start a range.
            var low: u8 = ch;
            if (ch == self.escapeChar()) {
                const esc = self.peek() orelse return error.UnsupportedPattern;
                self.pos += 1;
                if (classForEscape(esc, self.flavor)) |class| {
                    set.setUnion(class);
                    continue;
                }
                low = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => if (std.ascii.isAlphanumeric(esc)) return error.UnsupportedPattern else esc,
                };
            }

            // `a-z` range, unless the '-' is the last member.
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                self.pos += 1;
                var high = self.pattern[self.pos];
                self.pos += 1;
                if (high == self.escapeChar()) {
                    high = self.peek() orelse return error.UnsupportedPattern;
                    self.pos += 1;
                    if (std.ascii.isAlphanumeric(high)) return error.UnsupportedPattern;
                }
                if (high < low) return error.UnsupportedPattern;
                var b: usize = low;
                while (b <= high) : (b += 1) set.set(b);
            } else {
                set.set(low);
            }
        }

        if (negate) set.toggleAll();
        return set;
    }

    fn parseQuantifier(self: *Parser, item: *Regex.Item) Error!void {
        const ch = self.peek() orelse return;
        switch (ch) {
            '*' => item.* = .{ .atom = item.atom, .min = 0, .max = unbounded },
            '+' => item.* = .{ .atom = item.atom, .min = 1, .max = unbounded },
            '?' => item.* = .{ .atom = item.atom, .min = 0, .max = 1 },
            '-' => {
                if (self.flavor != .lua) return;
                item.* = .{ .atom = item.atom, .min = 0, .max = unbounded };
            },
            '{' => {
                if (self.flavor != .regex) return;
                self.pos += 1;
                const min = try self.parseNumber();
                var max = min;
                if (self.peek() == ',') {
                    self.pos += 1;
                    max = if (self.peek() == '}') unbounded else try self.parseNumber();
                }
                if (self.peek() != '}' or max < min) return error.UnsupportedPattern;
                if (max != unbounded and max > max_explicit_repeat) return error.UnsupportedPattern;
                item.* = .{ .atom = item.atom, .min = min, .max = max };
                // `pos` is on the closing brace; the shared advance below skips it.
            },
            else => return,
        }
        self.pos += 1;
        if (self.flavor == .regex and self.peek() == '?') self.pos += 1; // lazy marker
        switch (item.atom) {
            .line_start, .line_end => return error.UnsupportedPattern,
            else => {},
        }
    }

    fn parseNumber(self: *Parser) Error!u32 {
        const start = self.pos;
        while (self.peek()) |ch| {
            if (!std.ascii.isDigit(ch)) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.UnsupportedPattern;
        return std.fmt.parseUnsigned(u32, self.pattern[start..self.pos], 10) catch error.UnsupportedPattern;
    }
};

fn classForEscape(ch: u8, flavor: Flavor) ?Regex.Set {
    var set = Regex.Set.initEmpty();
    const negated = std.ascii.isUpper(ch);
    switch (std.ascii.toLower(ch)) {
        'd' => for ('0'..'9' + 1) |b| set.set(b),
        'w' => {
            for ('0'..'9' + 1) |b| set.set(b);
            for ('a'..'z' + 1) |b| set.set(b);
            for ('A'..'Z' + 1) |b| set.set(b);
            set.set('_');
            // Lua's %w is alphanumeric only.
            if (flavor == .lua) set.unset('_');
        },
        's' => for (" \t\n\r\x0b\x0c") |b| set.set(b),
        'a' => {
            if (flavor != .lua) return null;
            for ('a'..'z' + 1) |b| set.set(b);
            for ('A'..'Z' + 1) |b| set.set(b);
        },
        'l' => {
            if (flavor != .lua) return null;
            for ('a'..'z' + 1) |b| set.set(b);
        },
        'u' => {
            if (flavor != .lua) return null;
            for ('A'..'Z' + 1) |b| set.set(b);
        },
        else => return null,
    }
    if (negated) set.toggleAll();
    return set;
}

// Backtracking matcher. Rather than closures, "what to do after this part
// matches" is a linked list of continuation frames living on the call stack.
const Continuation = struct {
    next: ?*const Continuation,
    state: union(enum) {
        sequence: struct { items: Regex.Sequence, index: usize },
        repeat: struct { item: Regex.Item, count: u32, rest: Regex.Sequence, rest_index: usize, start_pos: usize },
    },
};

fn matchAlternatives(alternatives: []const Regex.Sequence, text: []const u8, pos: usize, k: ?*const Continuation) bool {
    for (alternatives) |sequence| {
        if (matchSequence(sequence, 0, text, pos, k)) return true;
    }
    return false;
}

fn resumeContinuation(k: ?*const Continuation, text: []const u8, pos: usize) bool {
    const frame = k orelse return true; // nothing left to match: success
    switch (frame.state) {
        .sequence => |s| return matchSequence(s.items, s.index, text, pos, frame.next),
        .repeat => |r| {
            // An iteration that consumed nothing can't be repeated (it would
            // loop forever); move on with the remainder instead.
            if (pos == r.start_pos) return matchSequence(r.rest, r.rest_index, text, pos, frame.next);
            return matchRepeat(r.item, r.count, r.rest, r.rest_index, text, pos, frame.next);
        },
    }
}

fn matchSequence(items: Regex.Sequence, index: usize, text: []const u8, pos: usize, k: ?*const Continuation) bool {
    if (index == items.len) return resumeContinuation(k, text, pos);

    const item = items[index];
    switch (item.atom) {
        .line_start => return pos == 0 and matchSequence(items, index + 1, text, pos, k),
        .line_end => return pos == text.len and matchSequence(items, index + 1, text, pos, k),
        .group => return matchRepeat(item, 0, items, index + 1, text, pos, k),
        else => {
            // Single-byte atoms: count how far the run goes, then back off
            // from the longest. Iterative, so a long `.*` can't blow the stack.
            var run: usize = 0;
            while (run < item.max and pos + run < text.len and atomMatchesByte(item.atom, text[pos + run])) run += 1;
            var take = run;
            while (true) {
                if (take >= item.min and matchSequence(items, index + 1, text, pos + take, k)) return true;
                if (take == 0) return false;
                take -= 1;
            }
        },
    }
}

/// Greedy repetition of a group.
fn matchRepeat(item: Regex.Item, count: u32, rest: Regex.Sequence, rest_index: usize, text: []const u8, pos: usize, k: ?*const Continuation) bool {
    if (count < item.max) {
        const frame = Continuation{
            .next = k,
            .state = .{ .repeat = .{ .item = item, .count = count + 1, .rest = rest, .rest_index = rest_index, .start_pos = pos } },
        };
        if (matchAlternatives(item.atom.group, text, pos, &frame)) return true;
    }
    if (count >= item.min) return matchSequence(rest, rest_index, text, pos, k);
    return false;
}

fn atomMatchesByte(atom: Regex.Atom, byte: u8) bool {
    return switch (atom) {
        .byte => |b| b == byte,
        .any => true,
        .set => |s| s.isSet(byte),
        else => false,
    };
}

fn expectMatch(pattern: []const u8, flavor: Flavor, text: []const u8, expected: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), pattern, flavor);
    std.testing.expectEqual(expected, re.isMatch(text)) catch |err| {
        std.debug.print("pattern /{s}/ on \"{s}\": expected {}\n", .{ pattern, text, expected });
        return err;
    };
}

test "literals and anchors" {
    try expectMatch("abc", .regex, "xxabcxx", true);
    try expectMatch("abc", .regex, "ab", false);
    try expectMatch("^abc", .regex, "abcd", true);
    try expectMatch("^abc", .regex, "xabc", false);
    try expectMatch("abc$", .regex, "xabc", true);
    try expectMatch("abc$", .regex, "abcx", false);
    try expectMatch("^$", .regex, "", true);
    try expectMatch("^$", .regex, "a", false);
    try expectMatch("", .regex, "anything", true);
}

test "constant-style identifiers from real highlight queries" {
    const patterns = [_][]const u8{ "^[A-Z][A-Z_0-9]+$", "^[A-Z][A-Z\\d_]+$", "^_?[A-Z][A-Z\\d_]+$", "^_*[A-Z][A-Z\\d_]+$" };
    for (patterns) |p| {
        try expectMatch(p, .regex, "MAX_SIZE", true);
        try expectMatch(p, .regex, "FOO2", true);
        try expectMatch(p, .regex, "maxSize", false);
        try expectMatch(p, .regex, "Foo", false);
        try expectMatch(p, .regex, "A", false);
    }
    try expectMatch("^_?[A-Z][A-Z\\d_]+$", .regex, "_FOO", true);
    try expectMatch("^_*[A-Z][A-Z\\d_]+$", .regex, "__FOO", true);
    try expectMatch("^[A-Z]", .regex, "Type", true);
    try expectMatch("^[A-Z]", .regex, "type", false);
    try expectMatch("^[A-Z]", .regex, "", false);
}

test "alternation and groups" {
    const p = "^(private|protected|public)$";
    try expectMatch(p, .regex, "private", true);
    try expectMatch(p, .regex, "public", true);
    try expectMatch(p, .regex, "publicly", false);
    try expectMatch("^__(FILE|LINE|ENCODING)__$", .regex, "__FILE__", true);
    try expectMatch("^__(FILE|LINE|ENCODING)__$", .regex, "__FOO__", false);
    try expectMatch("^(?:ab)+$", .regex, "ababab", true);
    try expectMatch("^(?:ab)+$", .regex, "ababa", false);
    try expectMatch("^(a|ab)c$", .regex, "abc", true); // needs backtracking into the group
    try expectMatch("^(a*)*b", .regex, "aaab", true); // empty iterations terminate
}

test "quantifiers" {
    try expectMatch("^a*$", .regex, "", true);
    try expectMatch("^a+$", .regex, "", false);
    try expectMatch("^colou?r$", .regex, "color", true);
    try expectMatch("^colou?r$", .regex, "colour", true);
    try expectMatch("^a{2}$", .regex, "aa", true);
    try expectMatch("^a{2}$", .regex, "aaa", false);
    try expectMatch("^a{2,}$", .regex, "aaaa", true);
    try expectMatch("^a{2,3}$", .regex, "aaaa", false);
    try expectMatch("^a.*z$", .regex, "a---z", true);
    try expectMatch("^a.+?z$", .regex, "az", false);
}

test "character classes" {
    try expectMatch("^[a-c]+$", .regex, "abcabc", true);
    try expectMatch("^[a-c]+$", .regex, "abd", false);
    try expectMatch("^[^0-9]+$", .regex, "abc", true);
    try expectMatch("^[^0-9]+$", .regex, "ab1", false);
    try expectMatch("^[\\w.-]+$", .regex, "foo.bar-baz_1", true);
    try expectMatch("^[A-Z_][a-zA-Z0-9_]*", .regex, "_foo", true);
    try expectMatch("^[A-Z_][a-zA-Z0-9_]*", .regex, "foo", false);
    try expectMatch("^\\d+$", .regex, "123", true);
    try expectMatch("^\\D+$", .regex, "12", false);
    try expectMatch("^\\s*$", .regex, " \t\n", true);
    try expectMatch("^[]a]+$", .regex, "]a]", true);
    try expectMatch("^[a\\]]+$", .regex, "a]", true);
}

test "escaped punctuation is literal" {
    try expectMatch("^//!", .regex, "//! docs", true);
    try expectMatch("^--", .regex, "-- sql comment", true);
    try expectMatch("a\\.b", .regex, "a.b", true);
    try expectMatch("a\\.b", .regex, "axb", false);
    try expectMatch("^\\$[a-z]+$", .regex, "$var", true);
}

test "lua patterns" {
    try expectMatch("^[A-Z][A-Z_0-9]+$", .lua, "FOO_1", true);
    try expectMatch("^[A-Z_][a-zA-Z0-9_]*", .lua, "Type", true);
    try expectMatch("^//!", .lua, "//! x", true);
    try expectMatch("^%d+$", .lua, "42", true);
    try expectMatch("^%a%w*$", .lua, "abc1", true);
    try expectMatch("^%u%l+$", .lua, "Abc", true);
    try expectMatch("a|b", .lua, "a|b", true); // no alternation in lua patterns
    try expectMatch("a|b", .lua, "a", false);
    try expectMatch("^a-b", .lua, "b", true); // '-' is a lazy '*'
}

test "unsupported syntax is rejected instead of mis-matched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "(?=a)b", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "(?<name>a)", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "\\bfoo", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "(a", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "a)", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "[a", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "*a", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "a{2,1}", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "[z-a]", .regex));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile(a, "%b()", .lua));
}

test "a long input doesn't overflow the stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), "^a.*z$", .regex);
    const big = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'm');
    big[0] = 'a';
    big[big.len - 1] = 'z';
    try std.testing.expect(re.isMatch(big));
}
