//! Choosing one row from a list, on the terminal capsule already owns.
//!
//! This replaces three `fzf` invocations — `run start`, `run review`, `run merge` — plus
//! the ones on the `issue` verbs. Shelling out worked, but it made `fzf` a hard runtime
//! dependency, it rendered its preview as raw JSON, and it was one of the context switches
//! that made the loop feel long.
//!
//! Matching is separated from the terminal loop, so what counts as a match is testable
//! without a tty and the loop stays a thin shell around `List`.

const std = @import("std");
const Io = std.Io;

const screen_mod = @import("tui/screen.zig");
const term = @import("tui/term.zig");
const list_mod = @import("tui/list.zig");

const Screen = screen_mod.Screen;
const Style = screen_mod.Style;

pub const Row = struct {
    /// The value handed back to the caller — an issue's short id, typically.
    id: []const u8,
    /// The column shown before the label, e.g. a state.
    tag: []const u8 = "",
    label: []const u8,
};

pub const Error = error{NotATerminal};

/// Case-insensitive subsequence match, as a picker's users expect: typing `bord` finds
/// "make the board useful" without the letters being adjacent.
///
/// Subsequence rather than substring because the whole point of typing into a picker is to
/// skip characters — requiring them contiguous means typing the title out in full.
pub fn matches(row: Row, query: []const u8) bool {
    if (query.len == 0) return true;

    var q: usize = 0;
    for (row.id) |c| {
        if (q < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[q])) q += 1;
    }
    if (q == query.len) return true;

    q = 0;
    for (row.label) |c| {
        if (q < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[q])) q += 1;
    }
    if (q == query.len) return true;

    q = 0;
    for (row.tag) |c| {
        if (q < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[q])) q += 1;
    }
    return q == query.len;
}

/// The indices of `rows` that match, in their original order. Order is preserved rather
/// than scored: the caller sorted these deliberately, and a picker that reorders under you
/// as you type is one you cannot aim.
pub fn filter(arena: std.mem.Allocator, rows: []const Row, query: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (rows, 0..) |row, i| {
        if (matches(row, query)) try out.append(arena, i);
    }
    return out.toOwnedSlice(arena);
}

/// Lays out the picker. Pure — no terminal, no clock — so the layout is covered by tests
/// the same way the dashboard's is.
pub fn render(
    gpa: std.mem.Allocator,
    prompt: []const u8,
    query: []const u8,
    rows: []const Row,
    shown: []const usize,
    list: list_mod.List,
    w: usize,
    h: usize,
) !Screen {
    var s = try Screen.init(gpa, w, h);
    errdefer s.deinit(gpa);

    s.write(0, 0, prompt, .{ .bold = true });
    s.write(prompt.len + 1, 0, query, .{});
    s.write(prompt.len + 1 + query.len, 0, "\u{2588}", .{ .fg = .cyan });

    if (shown.len == 0 and h > 2) {
        s.write(0, 2, "nothing matches", .{ .fg = .dim });
        return s;
    }

    const view = list.visible();
    var y: usize = 2;
    for (shown[view.start..view.end], view.start..) |row_index, i| {
        if (y >= h) break;
        const row = rows[row_index];
        const base = Style{};
        const style = list.styleFor(i, base);

        // The selected row is filled to the full width, so reverse video reads as a bar
        // rather than as highlighted words with gaps between them.
        if (style.reverse) {
            for (0..w) |x| s.write(x, y, " ", style);
        }
        s.write(0, y, row.id, if (style.reverse) style else Style{ .fg = .cyan });
        s.write(10, y, row.tag, if (style.reverse) style else Style{ .fg = .dim });
        s.write(28, y, row.label, style);
        y += 1;
    }

    if (h >= 2) {
        var buf: [64]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}/{d}", .{ shown.len, rows.len }) catch "";
        if (w > count.len) s.write(w - count.len, 0, count, .{ .fg = .dim });
        s.write(0, h - 1, "\u{2191}\u{2193} move   \u{21b5} choose   esc cancel", .{ .fg = .dim });
    }
    return s;
}

/// Opens the picker and blocks until a row is chosen or the user gives up. Returns the
/// index into `rows`, or null when cancelled — cancelling is not an error, it is the
/// normal way to change your mind.
pub fn choose(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    prompt: []const u8,
    rows: []const Row,
) !?usize {
    if (rows.len == 0) return null;

    var t = term.Term.init() catch return error.NotATerminal;
    try t.enterRaw();
    defer t.leaveRaw();

    var query: std.ArrayList(u8) = .empty;
    var shown = try filter(arena, rows, "");
    var list = list_mod.List{ .len = shown.len };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var previous: ?Screen = null;
    defer if (previous) |*p| p.deinit(gpa);

    while (true) {
        const size = t.size();
        list.height = if (size.h > 3) size.h - 3 else 1;
        list.len = shown.len;
        list.clamp();

        var current = try render(gpa, prompt, query.items, rows, shown, list, size.w, size.h);
        errdefer current.deinit(gpa);
        try term.paint(t.tty, current, previous, &out, gpa);
        if (previous) |*p| p.deinit(gpa);
        previous = current;

        const key = t.readKey();
        if (list.handle(key) == .moved) continue;

        switch (key) {
            .closed, .escape => return null,
            .key => |b| switch (b) {
                // Ctrl-C and Ctrl-D leave without choosing, as they do everywhere else.
                3, 4 => return null,
                '\r', '\n' => {
                    if (shown.len == 0) continue;
                    return shown[list.cursor];
                },
                // Backspace arrives as DEL from most terminals and as BS from some.
                127, 8 => {
                    if (query.items.len > 0) {
                        _ = query.pop();
                        shown = try filter(arena, rows, query.items);
                        list.cursor = 0;
                        list.offset = 0;
                    }
                },
                else => {
                    if (b >= 0x20 and b < 0x7f) {
                        try query.append(arena, b);
                        shown = try filter(arena, rows, query.items);
                        list.cursor = 0;
                        list.offset = 0;
                    }
                },
            },
            else => {},
        }
    }
}

const testing = std.testing;

const sample = [_]Row{
    .{ .id = "3f2a1b9c", .tag = "in_progress", .label = "make the board useful" },
    .{ .id = "b8e01d77", .tag = "ready", .label = "split zig and bash cleanly" },
    .{ .id = "9c4a2f01", .tag = "open", .label = "port vm start to zig" },
};

test "an empty query matches everything" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try filter(a.allocator(), &sample, "");
    try testing.expectEqual(@as(usize, 3), got.len);
}

test "a query matches a subsequence of the label, not just a prefix" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const got = try filter(a.allocator(), &sample, "bord");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(usize, 0), got[0]);
}

test "matching ignores case in both directions" {
    try testing.expect(matches(sample[0], "BOARD"));
    try testing.expect(matches(sample[1], "SPLIT"));
    try testing.expect(matches(.{ .id = "x", .label = "UPPER CASE" }, "upper"));
}

test "an id prefix finds its row" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try filter(a.allocator(), &sample, "b8e0");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(usize, 1), got[0]);
}

test "a state can be typed to narrow to it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try filter(a.allocator(), &sample, "ready");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(usize, 1), got[0]);
}

test "the original order is kept rather than rescored" {
    // A picker that reorders as you type is one you cannot aim: the row under the cursor
    // must not move because a later keystroke changed a score.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try filter(a.allocator(), &sample, "t");
    var previous: usize = 0;
    for (got, 0..) |index, i| {
        if (i > 0) try testing.expect(index > previous);
        previous = index;
    }
}

test "a query that matches nothing yields no rows rather than everything" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try filter(a.allocator(), &sample, "zzzzz");
    try testing.expectEqual(@as(usize, 0), got.len);
}

fn rowText(s: Screen, y: usize) ![]u8 {
    return s.rowText(testing.allocator, y);
}

test "the picker draws the prompt, the rows and the match count" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const shown = try filter(a.allocator(), &sample, "");
    const list = list_mod.List{ .len = shown.len, .height = 10 };
    var s = try render(testing.allocator, "issue>", "", &sample, shown, list, 80, 14);
    defer s.deinit(testing.allocator);

    const header = try rowText(s, 0);
    defer testing.allocator.free(header);
    try testing.expect(std.mem.startsWith(u8, header, "issue>"));
    try testing.expect(std.mem.indexOf(u8, header, "3/3") != null);

    const first = try rowText(s, 2);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "3f2a1b9c") != null);
    try testing.expect(std.mem.indexOf(u8, first, "make the board useful") != null);
}

test "the selected row is the only one drawn reversed" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const shown = try filter(a.allocator(), &sample, "");
    const list = list_mod.List{ .len = shown.len, .height = 10, .cursor = 1 };
    var s = try render(testing.allocator, "issue>", "", &sample, shown, list, 80, 14);
    defer s.deinit(testing.allocator);

    try testing.expect(!s.row(2)[0].style.reverse);
    try testing.expect(s.row(3)[0].style.reverse);
    // Filled to the width, so the bar has no gaps in it.
    try testing.expect(s.row(3)[79].style.reverse);
    try testing.expect(!s.row(4)[0].style.reverse);
}

test "an empty result says so instead of drawing a blank pane" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const shown = try filter(a.allocator(), &sample, "zzz");
    const list = list_mod.List{ .len = shown.len, .height = 10 };
    var s = try render(testing.allocator, "issue>", "zzz", &sample, shown, list, 80, 14);
    defer s.deinit(testing.allocator);

    const line = try rowText(s, 2);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("nothing matches", line);
}

test "a cramped terminal renders without overflowing or crashing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const shown = try filter(a.allocator(), &sample, "");

    for ([_]usize{ 1, 5, 30, 80 }) |w| {
        for ([_]usize{ 1, 2, 3, 14 }) |h| {
            const list = list_mod.List{ .len = shown.len, .height = if (h > 3) h - 3 else 1 };
            var s = try render(testing.allocator, "issue>", "", &sample, shown, list, w, h);
            defer s.deinit(testing.allocator);
            try testing.expectEqual(w * h, s.cells.len);
        }
    }
}
