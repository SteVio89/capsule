//! Where capsuled keeps things on the host.
//!
//! Resolved once, from the environment, so a test can point the whole daemon at a
//! scratch directory without a global to reset.

const std = @import("std");
const net = std.Io.net;

pub const Paths = struct {
    /// `~/.local/share/capsule/capsuled.sock`
    socket: []const u8,
    /// `~/.local/share/capsule/state.db`
    db: []const u8,
    data_dir: []const u8,
};

pub const Error = error{
    NoHome,
    /// A unix socket path is capped at 108 bytes by the kernel. Truncating would produce
    /// a socket nobody can find, so this is fatal and says so.
    SocketPathTooLong,
} || std.mem.Allocator.Error;

/// `env` is the process environment; passing it in rather than reading a global is what
/// lets the tests below cover the XDG branches.
pub fn resolve(arena: std.mem.Allocator, env: Env) Error!Paths {
    const data_dir = if (env.xdg_data_home) |x|
        try std.fmt.allocPrint(arena, "{s}/capsule", .{x})
    else if (env.home) |h|
        try std.fmt.allocPrint(arena, "{s}/.local/share/capsule", .{h})
    else
        return error.NoHome;

    const socket = if (env.capsule_socket) |s|
        s
    else
        try std.fmt.allocPrint(arena, "{s}/capsuled.sock", .{data_dir});

    if (socket.len > net.UnixAddress.max_len) return error.SocketPathTooLong;

    const db = if (env.capsule_db) |d|
        d
    else
        try std.fmt.allocPrint(arena, "{s}/state.db", .{data_dir});

    return .{ .socket = socket, .db = db, .data_dir = data_dir };
}

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    /// Overrides, for tests and for running a second daemon against a scratch store.
    capsule_socket: ?[]const u8 = null,
    capsule_db: ?[]const u8 = null,
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "defaults hang off HOME" {
    var a = testArena();
    defer a.deinit();
    const p = try resolve(a.allocator(), .{ .home = "/home/me" });
    try testing.expectEqualStrings("/home/me/.local/share/capsule/capsuled.sock", p.socket);
    try testing.expectEqualStrings("/home/me/.local/share/capsule/state.db", p.db);
}

test "XDG_DATA_HOME wins over HOME" {
    var a = testArena();
    defer a.deinit();
    const p = try resolve(a.allocator(), .{ .home = "/home/me", .xdg_data_home = "/xdg" });
    try testing.expectEqualStrings("/xdg/capsule/capsuled.sock", p.socket);
}

test "explicit overrides win over both" {
    var a = testArena();
    defer a.deinit();
    const p = try resolve(a.allocator(), .{
        .home = "/home/me",
        .capsule_socket = "/tmp/s.sock",
        .capsule_db = "/tmp/s.db",
    });
    try testing.expectEqualStrings("/tmp/s.sock", p.socket);
    try testing.expectEqualStrings("/tmp/s.db", p.db);
}

test "no home at all is an error, not a path relative to nowhere" {
    var a = testArena();
    defer a.deinit();
    try testing.expectError(error.NoHome, resolve(a.allocator(), .{}));
}

test "an over-long socket path is refused rather than truncated" {
    var a = testArena();
    defer a.deinit();
    const long = "/" ++ "x" ** 120;
    try testing.expectError(
        error.SocketPathTooLong,
        resolve(a.allocator(), .{ .home = "/h", .capsule_socket = long }),
    );
}

test "a socket path at exactly the limit is allowed" {
    var a = testArena();
    defer a.deinit();
    const exact = "x" ** net.UnixAddress.max_len;
    const p = try resolve(a.allocator(), .{ .home = "/h", .capsule_socket = exact });
    try testing.expectEqual(@as(usize, net.UnixAddress.max_len), p.socket.len);
}
