//! A selectable, scrolling list — the widget the id picker and the board both need.
//!
//! Selection and scroll are kept apart on purpose. `cursor` is which row the user is on,
//! in the full set; `offset` is which row is drawn first. Conflating them is what produces
//! a list that jumps a page when you arrow past the bottom, and keeping them apart is what
//! lets `visible` stay a pure slice calculation.
//!
//! No terminal, no allocator, no rendering: the caller owns the rows and draws them. That
//! is what makes every rule below testable without a tty.

const std = @import("std");
const screen = @import("screen.zig");

/// What a keypress did, so the caller knows whether a repaint is needed and whether the
/// key was the widget's business at all.
pub const Action = enum {
    /// The cursor or the viewport moved.
    moved,
    /// The widget did not claim this key; the caller should handle it.
    ignored,
};

pub const List = struct {
    /// How many rows exist in total.
    len: usize = 0,
    /// How many rows fit on screen. Zero means nothing is drawn.
    height: usize = 0,
    /// Index of the selected row, always < len (or 0 when empty).
    cursor: usize = 0,
    /// Index of the first drawn row.
    offset: usize = 0,
    /// How close to an edge the cursor gets before the viewport starts moving. One line of
    /// lookahead is what stops the selection sitting on the last visible row with no idea
    /// whether anything follows.
    margin: usize = 1,

    /// Re-applies every invariant after `len` or `height` changes underneath the widget —
    /// which happens on every refresh, because the daemon's answer is polled.
    ///
    /// Written as one function rather than checked at each call site because a list whose
    /// backing data shrank is exactly when an unclamped cursor indexes out of bounds.
    pub fn clamp(self: *List) void {
        if (self.len == 0) {
            self.cursor = 0;
            self.offset = 0;
            return;
        }
        if (self.cursor >= self.len) self.cursor = self.len - 1;

        if (self.height == 0) {
            self.offset = 0;
            return;
        }
        // Never leave blank rows below when there is content above to show instead.
        const max_offset = if (self.len > self.height) self.len - self.height else 0;
        if (self.offset > max_offset) self.offset = max_offset;

        const margin = @min(self.margin, self.height / 2);
        if (self.cursor < self.offset + margin) {
            self.offset = self.cursor -| margin;
        }
        const bottom = self.offset + self.height;
        if (self.cursor + margin >= bottom) {
            self.offset = @min(max_offset, self.cursor + margin + 1 -| self.height);
        }
    }

    pub fn moveTo(self: *List, index: usize) void {
        self.cursor = index;
        self.clamp();
    }

    pub fn move(self: *List, delta: isize) void {
        if (self.len == 0) return;
        const signed = @as(isize, @intCast(self.cursor)) + delta;
        const last = @as(isize, @intCast(self.len - 1));
        self.cursor = @intCast(std.math.clamp(signed, 0, last));
        self.clamp();
    }

    /// Handles the navigation keys and reports whether it took the key. Deliberately
    /// includes the vi pair: this replaces an `fzf` invocation, and muscle memory is the
    /// point of a daily driver.
    pub fn handle(self: *List, key: anytype) Action {
        switch (key) {
            .up => self.move(-1),
            .down => self.move(1),
            .page_up => self.move(-@as(isize, @intCast(@max(1, self.height)))),
            .page_down => self.move(@as(isize, @intCast(@max(1, self.height)))),
            .home => self.moveTo(0),
            .end => self.moveTo(if (self.len == 0) 0 else self.len - 1),
            .key => |b| return self.handleByte(b),
            else => return .ignored,
        }
        return .moved;
    }

    /// The vi-style bindings, split out because a switch nested inside a switch over an
    /// `anytype` union cannot infer its own subject type.
    fn handleByte(self: *List, b: u8) Action {
        switch (b) {
            'k' => self.move(-1),
            'j' => self.move(1),
            'g' => self.moveTo(0),
            'G' => self.moveTo(if (self.len == 0) 0 else self.len - 1),
            else => return .ignored,
        }
        return .moved;
    }

    /// The half-open range of row indices to draw, already clamped to what exists.
    pub fn visible(self: List) struct { start: usize, end: usize } {
        if (self.len == 0 or self.height == 0) return .{ .start = 0, .end = 0 };
        const end = @min(self.len, self.offset + self.height);
        return .{ .start = self.offset, .end = end };
    }

    /// The style a row is drawn with. Reverse video rather than a colour, so it reads the
    /// same on a light terminal as on a dark one and needs no palette agreement.
    pub fn styleFor(self: List, index: usize, base: screen.Style) screen.Style {
        if (index != self.cursor) return base;
        var selected = base;
        selected.reverse = true;
        return selected;
    }

    /// Whether anything is scrolled out of view, for a caller that wants to say so.
    pub fn hasMoreAbove(self: List) bool {
        return self.offset > 0;
    }

    pub fn hasMoreBelow(self: List) bool {
        return self.visible().end < self.len;
    }
};

const testing = std.testing;

/// The key shapes `Term.Key` produces, minus the ones the list ignores. Declared here so
/// the widget's tests need neither a terminal nor an import cycle.
const TestKey = union(enum) {
    key: u8,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    escape,
    timeout,
    closed,
};

/// Typed constants: a void-payload union field named bare resolves to the tag rather
/// than to a union value, which would give `handle` two different subject types.
const K = struct {
    const up: TestKey = .up;
    const down: TestKey = .down;
    const home: TestKey = .home;
    const end: TestKey = .end;
    const page_up: TestKey = .page_up;
    const page_down: TestKey = .page_down;
    const escape: TestKey = .escape;
    const timeout: TestKey = .timeout;
    fn byte(b: u8) TestKey {
        return .{ .key = b };
    }
};

test "an empty list has nowhere to go and does not move" {
    var l = List{ .len = 0, .height = 10 };
    l.clamp();
    try testing.expectEqual(@as(usize, 0), l.cursor);

    l.move(1);
    l.move(-1);
    try testing.expectEqual(@as(usize, 0), l.cursor);
    try testing.expectEqual(@as(usize, 0), l.visible().end);
}

test "the cursor stops at both ends rather than wrapping" {
    // Wrapping in a picker is how you accept the wrong issue: you press down once too
    // often and land on the first one.
    var l = List{ .len = 3, .height = 10 };

    l.move(-1);
    try testing.expectEqual(@as(usize, 0), l.cursor);

    l.move(99);
    try testing.expectEqual(@as(usize, 2), l.cursor);
}

test "a short list is never scrolled" {
    var l = List{ .len = 3, .height = 10 };
    l.move(2);
    try testing.expectEqual(@as(usize, 0), l.offset);
    const v = l.visible();
    try testing.expectEqual(@as(usize, 0), v.start);
    try testing.expectEqual(@as(usize, 3), v.end);
    try testing.expect(!l.hasMoreAbove());
    try testing.expect(!l.hasMoreBelow());
}

test "the viewport follows the cursor one row at a time, not a page" {
    var l = List{ .len = 100, .height = 10 };

    for (0..9) |_| l.move(1);
    try testing.expectEqual(@as(usize, 9), l.cursor);
    // With one row of margin the viewport has moved by exactly the overshoot.
    try testing.expectEqual(@as(usize, 1), l.offset);

    l.move(1);
    try testing.expectEqual(@as(usize, 10), l.cursor);
    try testing.expectEqual(@as(usize, 2), l.offset);
}

test "scrolling back up keeps the margin above the cursor" {
    var l = List{ .len = 100, .height = 10, .cursor = 50, .offset = 45 };
    l.clamp();
    for (0..6) |_| l.move(-1);
    try testing.expectEqual(@as(usize, 44), l.cursor);
    try testing.expect(l.offset <= l.cursor);
    try testing.expect(l.cursor < l.offset + l.height);
}

test "the end of a long list fills the screen instead of leaving blanks" {
    var l = List{ .len = 100, .height = 10 };
    l.moveTo(99);
    const v = l.visible();
    try testing.expectEqual(@as(usize, 100), v.end);
    try testing.expectEqual(@as(usize, 90), v.start);
    try testing.expectEqual(@as(usize, 10), v.end - v.start);
    try testing.expect(!l.hasMoreBelow());
    try testing.expect(l.hasMoreAbove());
}

test "a list that shrinks underneath the cursor does not index out of bounds" {
    // The daemon is polled, so the row count changes between frames — an issue merged in
    // another terminal is exactly this case.
    var l = List{ .len = 100, .height = 10 };
    l.moveTo(99);

    l.len = 3;
    l.clamp();
    try testing.expectEqual(@as(usize, 2), l.cursor);
    try testing.expectEqual(@as(usize, 0), l.offset);

    l.len = 0;
    l.clamp();
    try testing.expectEqual(@as(usize, 0), l.cursor);
    try testing.expectEqual(@as(usize, 0), l.visible().end);
}

test "a viewport shorter than the margin still renders" {
    // A one-row pane would otherwise ask for a margin it has no room for.
    for ([_]usize{ 1, 2, 3 }) |h| {
        var l = List{ .len = 50, .height = h };
        l.moveTo(25);
        const v = l.visible();
        try testing.expect(v.end > v.start);
        try testing.expect(l.cursor >= v.start and l.cursor < v.end);
    }
}

test "the arrow keys and their vi equivalents do the same thing" {
    var arrows = List{ .len = 20, .height = 5 };
    var vi = List{ .len = 20, .height = 5 };

    for (0..7) |_| {
        try testing.expectEqual(Action.moved, arrows.handle(K.down));
        try testing.expectEqual(Action.moved, vi.handle(K.byte('j')));
    }
    try testing.expectEqual(arrows.cursor, vi.cursor);
    try testing.expectEqual(arrows.offset, vi.offset);

    _ = arrows.handle(K.up);
    _ = vi.handle(K.byte('k'));
    try testing.expectEqual(arrows.cursor, vi.cursor);
}

test "home and end reach both ends whichever way they are spelled" {
    var l = List{ .len = 40, .height = 8 };
    _ = l.handle(K.end);
    try testing.expectEqual(@as(usize, 39), l.cursor);
    _ = l.handle(K.home);
    try testing.expectEqual(@as(usize, 0), l.cursor);

    _ = l.handle(K.byte('G'));
    try testing.expectEqual(@as(usize, 39), l.cursor);
    _ = l.handle(K.byte('g'));
    try testing.expectEqual(@as(usize, 0), l.cursor);
}

test "a page moves by a screenful and clamps at the ends" {
    var l = List{ .len = 40, .height = 8 };
    _ = l.handle(K.page_down);
    try testing.expectEqual(@as(usize, 8), l.cursor);

    for (0..10) |_| _ = l.handle(K.page_down);
    try testing.expectEqual(@as(usize, 39), l.cursor);

    for (0..10) |_| _ = l.handle(K.page_up);
    try testing.expectEqual(@as(usize, 0), l.cursor);
}

test "a key the list does not own is handed back to the caller" {
    var l = List{ .len = 10, .height = 5 };
    // `q`, `enter` and the action letters belong to whoever is using the widget.
    for ([_]u8{ 'q', 's', 'm', '\r', 3 }) |b| {
        try testing.expectEqual(Action.ignored, l.handle(K.byte(b)));
    }
    try testing.expectEqual(Action.ignored, l.handle(K.timeout));
    try testing.expectEqual(Action.ignored, l.handle(K.escape));
    try testing.expectEqual(@as(usize, 0), l.cursor);
}

test "only the selected row is drawn reversed, and the base style is otherwise kept" {
    var l = List{ .len = 5, .height = 5 };
    l.moveTo(2);

    const base = screen.Style{ .fg = .cyan, .bold = true };
    const selected = l.styleFor(2, base);
    try testing.expect(selected.reverse);
    try testing.expectEqual(screen.Color.cyan, selected.fg);
    try testing.expect(selected.bold);

    for ([_]usize{ 0, 1, 3, 4 }) |i| {
        try testing.expect(!l.styleFor(i, base).reverse);
    }
}
