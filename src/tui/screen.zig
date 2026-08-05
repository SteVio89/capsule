//! A character grid, and the diff between two of them.

const std = @import("std");

pub const Color = enum {
    default,
    red,
    green,
    yellow,
    blue,
    cyan,
    dim,

    /// The SGR parameter for this colour, as a static string ready to splice into an
    /// escape sequence.
    pub fn sgr(c: Color) []const u8 {
        return switch (c) {
            .default => "0",
            .red => "31",
            .green => "32",
            .yellow => "33",
            .blue => "34",
            .cyan => "36",
            .dim => "2",
        };
    }

    /// The same colour as a background. `dim` is an intensity attribute rather than a
    /// colour, so it has no background form and falls back to the terminal's own.
    pub fn bgSgr(c: Color) []const u8 {
        return switch (c) {
            .default, .dim => "49",
            .red => "41",
            .green => "42",
            .yellow => "43",
            .blue => "44",
            .cyan => "46",
        };
    }
};

/// The columns `text` occupies once drawn.
///
/// Neither byte length nor codepoint count answers this, and callers that position
/// something *after* a string need what the terminal will actually advance by — the
/// picker's cursor sits after whatever the user has typed, which is the one string here
/// that is not ASCII by construction.
pub fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| total += width(cp);
    return total;
}

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    /// Swaps foreground and background. This is how a selected row is drawn, and its
    /// absence is why the dashboard could only ever render counters: without it there is
    /// no way to say "this line is the one you are on".
    reverse: bool = false,

    /// Field-by-field, because `Style` has no scalar identity and `==` does not apply.
    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold and a.reverse == b.reverse;
    }
};

pub const Cell = struct {
    /// Codepoint, so a box-drawing character occupies one cell rather than three.
    ///
    /// Zero means "the right half of the wide character to my left" — see `width`. It is
    /// never drawn and never counted; the terminal is already covering that column.
    ch: u21 = ' ',
    style: Style = .{},

    pub const continuation: u21 = 0;
};

/// How many terminal columns a codepoint occupies.
///
/// `Screen` models a grid, and a grid only lines up if its idea of a character's width
/// matches the terminal's. A CJK ideograph or an emoji is drawn two columns wide, so
/// counting it as one puts every column after it out by one — and issue titles are exactly
/// where such characters turn up.
///
/// The ranges are the East Asian Wide and Fullwidth blocks plus the emoji planes, which is
/// the approximation every terminal-side `wcwidth` uses. Combining marks are zero: they
/// render into the cell before them rather than taking one of their own.
pub fn width(cp: u21) u2 {
    if (cp == Cell.continuation) return 0;
    if (cp < 0x300) return 1;

    const zero = [_][2]u21{
        .{ 0x0300, 0x036F }, // combining diacriticals
        .{ 0x200B, 0x200F }, // zero-width space through RTL mark
        .{ 0xFE00, 0xFE0F }, // variation selectors
        .{ 0xFE20, 0xFE2F }, // combining half marks
    };
    for (zero) |r| if (cp >= r[0] and cp <= r[1]) return 0;

    const wide = [_][2]u21{
        .{ 0x1100, 0x115F }, // hangul jamo
        .{ 0x2E80, 0x303E }, // CJK radicals, kangxi, symbols
        .{ 0x3041, 0x33FF }, // hiragana through CJK compatibility
        .{ 0x3400, 0x4DBF }, // CJK extension A
        .{ 0x4E00, 0x9FFF }, // CJK unified ideographs
        .{ 0xA000, 0xA4CF }, // yi
        .{ 0xAC00, 0xD7A3 }, // hangul syllables
        .{ 0xF900, 0xFAFF }, // CJK compatibility ideographs
        .{ 0xFE30, 0xFE6F }, // CJK compatibility forms
        .{ 0xFF00, 0xFF60 }, // fullwidth forms
        .{ 0xFFE0, 0xFFE6 }, // fullwidth signs
        // One span rather than the individual emoji blocks: pictographs, emoticons,
        // transport and supplemental are all drawn double-width, and splitting them is how
        // a rocket at U+1F680 ends up one column past the end of a carefully chosen range.
        .{ 0x1F300, 0x1F9FF },
        .{ 0x1FA70, 0x1FAFF }, // symbols and pictographs extended-A
        .{ 0x20000, 0x3FFFD }, // CJK extension B and beyond
    };
    for (wide) |r| if (cp >= r[0] and cp <= r[1]) return 2;

    return 1;
}

pub const Screen = struct {
    w: usize,
    h: usize,
    cells: []Cell,

    /// A blank w-by-h grid. The cells are allocated from `gpa`; the caller owns the
    /// screen and must `deinit` it with the same allocator.
    pub fn init(gpa: std.mem.Allocator, w: usize, h: usize) !Screen {
        const cells = try gpa.alloc(Cell, w * h);
        @memset(cells, .{});
        return .{ .w = w, .h = h, .cells = cells };
    }

    /// Frees the cells. `gpa` must be the allocator `init` was given.
    pub fn deinit(s: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(s.cells);
        s.* = undefined;
    }

    /// Row `y` as a mutable slice into the screen's own cells — a view, not a copy.
    pub fn row(s: Screen, y: usize) []Cell {
        return s.cells[y * s.w ..][0..s.w];
    }

    /// Writes as much of `text` as fits and silently drops the rest. A dashboard on a
    /// narrow terminal should truncate, never wrap into the next panel or crash.
    ///
    /// Advances by display width, not by codepoint. A wide character claims two cells —
    /// the second a `continuation` nothing draws — and one that would straddle the right
    /// edge is dropped rather than half-drawn, because half of a glyph is a column the
    /// terminal and this grid would disagree about from then on.
    pub fn write(s: *Screen, x: usize, y: usize, text: []const u8, style: Style) void {
        if (y >= s.h) return;
        var cursor = x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const w = width(cp);
            // A combining mark belongs to the cell already written; giving it one of its
            // own would shift the rest of the line.
            if (w == 0) continue;
            if (cursor + w > s.w) return;

            s.cells[y * s.w + cursor] = .{ .ch = cp, .style = style };
            if (w == 2) {
                s.cells[y * s.w + cursor + 1] = .{ .ch = Cell.continuation, .style = style };
            }
            cursor += w;
        }
    }

    /// Text a reader scans down the left edge of, so it gets its own helper.
    pub fn writeKeyValue(
        s: *Screen,
        x: usize,
        y: usize,
        key: []const u8,
        value: []const u8,
        value_style: Style,
    ) void {
        s.write(x, y, key, .{ .fg = .dim });
        s.write(x + 10, y, value, value_style);
    }

    /// Compared field by field rather than with `std.mem.eql`, which needs `!=` and so
    /// only works on scalars. A colour change with the same characters is still a change.
    pub fn rowsEqual(a: Screen, b: Screen, y: usize) bool {
        if (a.w != b.w) return false;
        for (a.row(y), b.row(y)) |x, z| {
            if (x.ch != z.ch or !x.style.eql(z.style)) return false;
        }
        return true;
    }

    /// The text of one row with trailing blanks removed — what the golden tests assert on,
    /// so they read as the thing a person would see rather than as a cell array.
    pub fn rowText(s: Screen, gpa: std.mem.Allocator, y: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [4]u8 = undefined;
        for (s.row(y)) |cell| {
            if (cell.ch == Cell.continuation) continue;
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch 1;
            try out.appendSlice(gpa, buf[0..n]);
        }
        const trimmed = std.mem.trimEnd(u8, out.items, " ");
        out.shrinkRetainingCapacity(trimmed.len);
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "text lands where it is put" {
    var s = try Screen.init(testing.allocator, 20, 3);
    defer s.deinit(testing.allocator);
    s.write(2, 1, "hello", .{});
    const text = try s.rowText(testing.allocator, 1);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("  hello", text);
}

test "an over-long line truncates rather than wrapping" {
    var s = try Screen.init(testing.allocator, 8, 2);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "0123456789abc", .{});
    const first = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(first);
    const second = try s.rowText(testing.allocator, 1);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("01234567", first);
    try testing.expectEqualStrings("", second);
}

test "writing off the bottom is ignored, not a crash" {
    var s = try Screen.init(testing.allocator, 8, 2);
    defer s.deinit(testing.allocator);
    s.write(0, 5, "nope", .{});
    s.write(20, 0, "nope", .{});
}

test "rows compare equal only when they match" {
    var a = try Screen.init(testing.allocator, 10, 2);
    defer a.deinit(testing.allocator);
    var b = try Screen.init(testing.allocator, 10, 2);
    defer b.deinit(testing.allocator);

    try testing.expect(a.rowsEqual(b, 0));
    a.write(0, 0, "x", .{});
    try testing.expect(!a.rowsEqual(b, 0));
    b.write(0, 0, "x", .{});
    try testing.expect(a.rowsEqual(b, 0));

    b.write(0, 0, "x", .{ .fg = .red });
    try testing.expect(!a.rowsEqual(b, 0));
}

test "a wide character claims the two columns the terminal gives it" {
    var s = try Screen.init(testing.allocator, 10, 1);
    defer s.deinit(testing.allocator);

    // "日本" is four columns, so "ab" starts at column 4. Counting the ideographs as one
    // cell each would put them at 2 — and every column after them out by two.
    s.write(0, 0, "日本", .{});
    s.write(4, 0, "ab", .{});

    const text = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("日本ab", text);

    try testing.expectEqual(@as(u21, '日'), s.row(0)[0].ch);
    try testing.expectEqual(Cell.continuation, s.row(0)[1].ch);
    try testing.expectEqual(@as(u21, '本'), s.row(0)[2].ch);
    try testing.expectEqual(Cell.continuation, s.row(0)[3].ch);
    try testing.expectEqual(@as(u21, 'a'), s.row(0)[4].ch);
}

test "a wide character that would straddle the edge is dropped, not halved" {
    var s = try Screen.init(testing.allocator, 3, 1);
    defer s.deinit(testing.allocator);

    // Column 2 is the last one; an ideograph needs 2 and 3, so it cannot go there. Drawing
    // its left half would leave the grid and the terminal disagreeing from then on.
    s.write(0, 0, "ab日", .{});
    const text = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("ab", text);
}

test "a combining mark takes no column of its own" {
    var s = try Screen.init(testing.allocator, 8, 1);
    defer s.deinit(testing.allocator);

    // "e" followed by U+0301 renders as one glyph in one column, so the text after it
    // must not shift.
    s.write(0, 0, "e\u{0301}x", .{});
    try testing.expectEqual(@as(u21, 'e'), s.row(0)[0].ch);
    try testing.expectEqual(@as(u21, 'x'), s.row(0)[1].ch);
}

test "the width table agrees with what a terminal draws" {
    try testing.expectEqual(@as(u2, 1), width('a'));
    try testing.expectEqual(@as(u2, 1), width('ä'));
    try testing.expectEqual(@as(u2, 1), width('─'));
    try testing.expectEqual(@as(u2, 2), width('日'));
    try testing.expectEqual(@as(u2, 2), width('한'));
    try testing.expectEqual(@as(u2, 2), width(0x1F600));
    try testing.expectEqual(@as(u2, 0), width(0x0301));
    try testing.expectEqual(@as(u2, 0), width(0xFE0F));
    try testing.expectEqual(@as(u2, 0), width(Cell.continuation));
}

test "an emoji title truncates on a boundary rather than mid-glyph" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit(testing.allocator);

    // The case the board will meet: a title wider than its column.
    s.write(0, 0, "🚀🚀🚀🚀", .{});
    const text = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("🚀🚀🚀", text);
}

test "multi-byte characters occupy one cell" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "──ab", .{});
    const text = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("──ab", text);
}
