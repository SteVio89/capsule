//! Raw mode, the alternate screen, and painting a `Screen` to a terminal.

const std = @import("std");
const posix = std.posix;
const screen_mod = @import("screen.zig");

const Screen = screen_mod.Screen;

pub const Size = struct { w: usize, h: usize };

/// The one terminal a signal or panic handler can restore. Set while raw mode is active.
var emergency: ?*Term = null;

/// Restores the terminal from a context that cannot carry state: the panic handler and
/// the fatal-signal handlers. Safe to call at any time, from any thread; does nothing
/// when no terminal is in raw mode.
pub fn emergencyRestore() void {
    if (emergency) |t| t.leaveRaw();
}

fn onFatalSignal(sig: posix.SIG) callconv(.c) void {
    emergencyRestore();
    posix.sigaction(sig, &.{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.raise(sig) catch {};
}

pub const Term = struct {
    tty: posix.fd_t,
    original: posix.termios,
    active: bool = false,

    /// Captures the current termios of stdin so `leaveRaw` can restore it. The terminal
    /// is not touched until `enterRaw`.
    pub fn init() !Term {
        const fd = posix.STDIN_FILENO;
        const original = try posix.tcgetattr(fd);
        return .{ .tty = fd, .original = original };
    }

    /// Raw mode with a 100ms read timeout, so the input loop can wake up on its own to
    /// repaint without needing a keypress.
    pub fn enterRaw(t: *Term) !void {
        var raw = t.original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;
        try posix.tcsetattr(t.tty, .FLUSH, raw);
        t.active = true;
        emergency = t;

        for ([_]posix.SIG{ .TERM, .HUP }) |sig| {
            posix.sigaction(sig, &.{
                .handler = .{ .handler = onFatalSignal },
                .mask = posix.sigemptyset(),
                .flags = 0,
            }, null);
        }

        writeAll(t.tty, "\x1b[?1049h\x1b[?25l\x1b[2J");
    }

    /// Idempotent, because it is called from a defer, a signal handler, and a panic
    /// handler — and a terminal left in raw mode after a crash is the single bug that
    /// makes people stop opening a dashboard.
    pub fn leaveRaw(t: *Term) void {
        if (!t.active) return;
        t.active = false;
        emergency = null;
        writeAll(t.tty, "\x1b[?25h\x1b[?1049l");
        posix.tcsetattr(t.tty, .FLUSH, t.original) catch {};
    }

    /// The terminal's current dimensions in cells, falling back to 80x24 when the ioctl
    /// fails or reports nonsense — a wrong guess beats a dashboard that cannot start.
    pub fn size(t: *Term) Size {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(t.tty, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS or ws.col == 0) return .{ .w = 80, .h = 24 };
        return .{ .w = ws.col, .h = ws.row };
    }

    pub const Key = union(enum) {
        key: u8,
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
        /// A bare Escape, told apart from the start of a sequence by the byte after it
        /// not arriving.
        escape,
        /// The 100ms wait elapsed — the cue to repaint, not to exit.
        timeout,
        /// The tty is gone (hangup, closed stdin). Without telling this apart from a
        /// timeout, a dead terminal spins the wait loop at full speed forever.
        closed,
    };

    /// Reads one keypress, decoding the CSI sequences a navigable list needs.
    ///
    /// The outer poll is what distinguishes "nothing yet" from "nothing ever again" — a
    /// VTIME read returns zero for both. The inner poll is shorter and does a different
    /// job: an arrow key arrives as `ESC [ A` in one burst, while a user pressing Escape
    /// sends `ESC` alone, so the wait for a following byte is what tells them apart.
    pub fn readKey(t: *Term) Key {
        const first = t.readByte(100) orelse return .timeout;
        switch (first) {
            .closed => return .closed,
            .byte => |b| {
                if (b != 0x1b) return .{ .key = b };
                return t.readEscape();
            },
        }
    }

    const Byte = union(enum) { byte: u8, closed };

    fn readByte(t: *Term, timeout_ms: i32) ?Byte {
        var fds = [_]posix.pollfd{.{ .fd = t.tty, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return null;
        if (ready == 0) return null;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return .closed;

        var buf: [1]u8 = undefined;
        const n = posix.read(t.tty, &buf) catch return .closed;
        if (n == 0) return .closed;
        return .{ .byte = buf[0] };
    }

    /// The rest of a sequence that began with Escape. 20ms is far longer than the gap
    /// inside a terminal's own burst and far shorter than a human's next keystroke.
    fn readEscape(t: *Term) Key {
        const second = t.readByte(20) orelse return .escape;
        const intro = switch (second) {
            .closed => return .closed,
            .byte => |b| b,
        };
        // `ESC O x` is the application-cursor form; some terminals send it for arrows.
        if (intro != '[' and intro != 'O') return .escape;

        const third = t.readByte(20) orelse return .escape;
        const code = switch (third) {
            .closed => return .closed,
            .byte => |b| b,
        };

        return switch (code) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            // `ESC [ N ~` — the numbered forms, whose trailing tilde must be consumed or
            // it would be read as the next keypress.
            '1', '3', '4', '5', '6', '7', '8' => blk: {
                _ = t.readByte(20);
                break :blk switch (code) {
                    '1', '7' => Key.home,
                    '4', '8' => Key.end,
                    '5' => Key.page_up,
                    '6' => Key.page_down,
                    else => Key.escape,
                };
            },
            else => .escape,
        };
    }
};

/// Paints only the rows that differ from `previous`. At a multi-second cadence a full
/// repaint flickers and fights the scrollback; this does not.
pub fn paint(fd: posix.fd_t, current: Screen, previous: ?Screen, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    out.clearRetainingCapacity();

    for (0..current.h) |y| {
        if (previous) |prev| {
            if (y < prev.h and current.rowsEqual(prev, y)) continue;
        }
        try out.print(gpa, "\x1b[{d};1H\x1b[K", .{y + 1});

        var style: screen_mod.Style = .{};
        var buf: [4]u8 = undefined;
        for (current.row(y)) |cell| {
            if (!cell.style.eql(style)) {
                style = cell.style;
                // Reset first, then re-apply: an attribute cleared between two cells has
                // no SGR of its own to turn it off individually.
                try out.print(gpa, "\x1b[0;{s};{s}m", .{ style.fg.sgr(), style.bg.bgSgr() });
                if (style.bold) try out.appendSlice(gpa, "\x1b[1m");
                if (style.reverse) try out.appendSlice(gpa, "\x1b[7m");
            }
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch 1;
            try out.appendSlice(gpa, buf[0..n]);
        }
        try out.appendSlice(gpa, "\x1b[0m");
    }
    if (out.items.len > 0) writeAll(fd, out.items);
}

/// `posix.write` moved into the Io layer in 0.16, and threading an `Io` through here
/// would only be so that a terminal escape sequence could be written to a tty. libc's
/// write is the same syscall with none of that.
fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    if (fd < 0) return;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

const testing = std.testing;

test "painting the first frame emits every row" {
    var s = try Screen.init(testing.allocator, 4, 2);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "ab", .{});
    s.write(0, 1, "cd", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, s, null, &out, testing.allocator);

    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "ab") != null);
}

test "an unchanged frame emits nothing at all" {
    var a = try Screen.init(testing.allocator, 4, 2);
    defer a.deinit(testing.allocator);
    a.write(0, 0, "ab", .{});
    var b = try Screen.init(testing.allocator, 4, 2);
    defer b.deinit(testing.allocator);
    b.write(0, 0, "ab", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, a, b, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "only the changed row is repainted" {
    var prev = try Screen.init(testing.allocator, 4, 3);
    defer prev.deinit(testing.allocator);
    prev.write(0, 0, "same", .{});
    prev.write(0, 1, "old", .{});

    var next = try Screen.init(testing.allocator, 4, 3);
    defer next.deinit(testing.allocator);
    next.write(0, 0, "same", .{});
    next.write(0, 1, "new", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, next, prev, &out, testing.allocator);

    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "new") != null);
}

test "a row is cleared to end of line so shrinking text leaves no debris" {
    var s = try Screen.init(testing.allocator, 8, 1);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "hi", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, s, null, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[K") != null);
}

test "colour is emitted when it changes and reset at the end of a row" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "ok", .{ .fg = .green });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, s, null, &out, testing.allocator);
    // Foreground and background are set together, so a cell that clears one of them does
    // not inherit the other from the cell before it.
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[0;32;49m") != null);
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b[0m"));
}

test "a selected row is drawn reversed and the attribute does not leak past it" {
    var s = try Screen.init(testing.allocator, 8, 2);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "picked", .{ .reverse = true });
    s.write(0, 1, "plain", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, s, null, &out, testing.allocator);

    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[7m") != null);
    // Exactly one row turned it on, and every row ends with a reset.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\x1b[7m"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "\x1b[0m"));
}

test "a background colour reaches the escape sequence" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit(testing.allocator);
    s.write(0, 0, "bg", .{ .bg = .blue });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, s, null, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "44") != null);
}

test "a taller frame than the last still paints its new rows" {
    var small = try Screen.init(testing.allocator, 4, 1);
    defer small.deinit(testing.allocator);
    var big = try Screen.init(testing.allocator, 4, 3);
    defer big.deinit(testing.allocator);
    big.write(0, 2, "new", .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try paint(-1, big, small, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[3;1H") != null);
}
