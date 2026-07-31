//! A character grid, and the diff between two of them.
//!
//! Repainting the whole terminal every few seconds flickers and fights the scrollback.
//! Diffing two grids and emitting only the rows that changed costs about sixty lines and
//! removes the problem entirely.
//!
//! Row-level rather than cell-level: at a three-second cadence the extra precision buys
//! nothing measurable, and whole-row repaints are far easier to be sure are correct.

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
};

pub const Style = struct {
    fg: Color = .default,
    bold: bool = false,
};

pub const Cell = struct {
    /// Codepoint, so a box-drawing character occupies one cell rather than three.
    ch: u21 = ' ',
    style: Style = .{},
};

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
    /// `y` must be in bounds.
    pub fn row(s: Screen, y: usize) []Cell {
        return s.cells[y * s.w ..][0..s.w];
    }

    /// Writes as much of `text` as fits and silently drops the rest. A dashboard on a
    /// narrow terminal should truncate, never wrap into the next panel or crash.
    pub fn write(s: *Screen, x: usize, y: usize, text: []const u8, style: Style) void {
        if (y >= s.h) return;
        var cursor = x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cursor >= s.w) return;
            s.cells[y * s.w + cursor] = .{ .ch = cp, .style = style };
            cursor += 1;
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
            if (x.ch != z.ch or x.style.fg != z.style.fg or x.style.bold != z.style.bold) {
                return false;
            }
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
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch 1;
            try out.appendSlice(gpa, buf[0..n]);
        }
        const trimmed = std.mem.trimEnd(u8, out.items, " ");
        out.shrinkRetainingCapacity(trimmed.len);
        return out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------- tests

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

    // Same characters, different colour, is still a change worth repainting.
    b.write(0, 0, "x", .{ .fg = .red });
    try testing.expect(!a.rowsEqual(b, 0));
}

test "multi-byte characters occupy one cell" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "──ab", .{});
    const text = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("──ab", text);
}
