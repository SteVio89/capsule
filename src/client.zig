//! The other side of the socket: one request, one response, exit.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;
const protocol = @import("protocol.zig");

pub const Error = error{
    /// Nothing is listening. The caller turns this into the message naming
    /// `capsule daemon start` — one place, one wording.
    DaemonNotRunning,
    BadResponse,
} || std.mem.Allocator.Error;

pub const Response = struct {
    ok: bool,
    /// Raw JSON for `result`, or the error object. The CLI mostly forwards this to jq.
    body: []const u8,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

/// `params_json` is pre-encoded so callers can pass whatever shape their method wants
/// without a union of every request type in the protocol.
pub fn call(
    arena: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    method: []const u8,
    params_json: []const u8,
) !Response {
    const addr = net.UnixAddress.init(socket_path) catch return error.DaemonNotRunning;
    if (!listening(socket_path)) return error.DaemonNotRunning;
    var stream = addr.connect(io) catch return error.DaemonNotRunning;
    defer stream.close(io);

    setReceiveTimeout(stream, 30);

    const write_buf = try arena.alloc(u8, protocol.max_line);
    var writer = stream.writer(io, write_buf);
    try writer.interface.print(
        "{{\"id\":1,\"method\":\"{s}\",\"params\":{s}}}\n",
        .{ method, params_json },
    );
    try writer.interface.flush();

    const read_buf = try arena.alloc(u8, protocol.max_line + 1);
    var reader = stream.reader(io, read_buf);
    const maybe_line = reader.interface.takeDelimiter('\n') catch return error.BadResponse;
    const line = maybe_line orelse return error.BadResponse;

    return parseResponse(arena, line);
}

/// Whether anything is listening, without exchanging a message.
///
/// Liveness is a connect, not a round trip. A daemon mid-shutdown can accept and then
/// never reply, so a `ping`-based poll blocks for its whole timeout on every iteration;
/// connecting answers immediately in both directions, because a unix socket with no
/// listener refuses at once.
pub fn alive(socket_path: []const u8) bool {
    return listening(socket_path);
}

/// Whether a listener is accepting on the unix socket at `path`.
///
/// Deliberately `std.c` rather than `Io.net`: `posixConnectUnix` does not classify
/// `ECONNREFUSED`, so it reaches `posix.unexpectedErrno`, which dumps a stack trace in
/// Debug builds. That makes the single most ordinary outcome in this whole program —
/// nothing is listening, because the daemon is not running — look like a crash, on every
/// command, and it fills the daemon's own log with them.
///
/// A connect is the liveness test rather than a round trip: a daemon mid-shutdown can
/// accept and then never reply, so a `ping`-based poll blocks for its whole timeout on
/// every iteration, while a socket with no listener refuses at once.
pub fn listening(path: []const u8) bool {
    var addr: std.c.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return false;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    return std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) == 0;
}

/// A connected socket that never answers would block the CLI forever: `takeDelimiter`
/// waits for a newline that is not coming.
///
/// This is reachable in ordinary use. A daemon that has been told to stop can still accept
/// a queued connection and then exit without replying, so the very next `ping` hangs — the
/// daemon guards its own accept loop the same way, for the mirror-image reason.
///
/// Best-effort: a platform that refuses the option keeps today's behaviour.
fn setReceiveTimeout(stream: net.Stream, seconds: i32) void {
    // libc's setsockopt, not std's: std maps EINVAL to `unreachable`, and a socket whose
    // peer has already gone returns exactly that. A missing timeout is not worth a panic.
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = std.c.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout, len);
    _ = std.c.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout, len);
}

/// Pure, so the shapes a daemon can return are covered without a socket.
pub fn parseResponse(arena: std.mem.Allocator, line: []const u8) Error!Response {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch
        return error.BadResponse;
    const object = switch (parsed) {
        .object => |o| o,
        else => return error.BadResponse,
    };

    const ok = switch (object.get("ok") orelse return error.BadResponse) {
        .bool => |b| b,
        else => return error.BadResponse,
    };

    if (ok) {
        const result = object.get("result") orelse std.json.Value{ .null = {} };
        return .{ .ok = true, .body = try std.json.Stringify.valueAlloc(arena, result, .{}) };
    }

    const err = switch (object.get("error") orelse return error.BadResponse) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    const err_value: std.json.Value = .{ .object = err };
    return .{
        .ok = false,
        .body = try std.json.Stringify.valueAlloc(arena, err_value, .{}),
        .code = str(err.get("code")),
        .message = str(err.get("message")),
        .hint = str(err.get("hint")),
    };
}

fn str(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "nothing listening is a quiet false, not a stack trace" {
    // The regression this pins is cosmetic but expensive: `Io.net`'s connect does not
    // classify ECONNREFUSED, so it reaches `posix.unexpectedErrno`, which dumps a stack
    // trace in Debug builds. "The daemon is not running" is the most common state this
    // program is ever in, and it must not print like a crash. Twice now it has.
    try testing.expect(!listening("/nonexistent/capsule-test/capsuled.sock"));
    try testing.expect(!alive("/nonexistent/capsule-test/capsuled.sock"));

    // A path over the sockaddr_un limit is refused rather than truncated into a
    // different, possibly live, socket.
    try testing.expect(!listening("/" ++ "x" ** 200));
}

test "a success response yields its result verbatim" {
    var a = testArena();
    defer a.deinit();
    const r = try parseResponse(a.allocator(),
        \\{"id":1,"ok":true,"result":{"pong":true}}
    );
    try testing.expect(r.ok);
    try testing.expectEqualStrings("{\"pong\":true}", r.body);
}

test "an error response carries code, message, and hint apart" {
    var a = testArena();
    defer a.deinit();
    const r = try parseResponse(a.allocator(),
        \\{"id":1,"ok":false,"error":{"code":"no_project","message":"nope","hint":"capsule project add"}}
    );
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("no_project", r.code.?);
    try testing.expectEqualStrings("nope", r.message.?);
    try testing.expectEqualStrings("capsule project add", r.hint.?);
}

test "an error without a hint is still readable" {
    var a = testArena();
    defer a.deinit();
    const r = try parseResponse(a.allocator(),
        \\{"id":1,"ok":false,"error":{"code":"internal","message":"boom"}}
    );
    try testing.expect(!r.ok);
    try testing.expectEqual(@as(?[]const u8, null), r.hint);
}

test "garbage from the socket is an error, not a crash" {
    var a = testArena();
    defer a.deinit();
    for ([_][]const u8{ "", "nonsense", "[]", "{}", "{\"ok\":\"yes\"}", "{\"ok\":false}" }) |line| {
        try testing.expectError(error.BadResponse, parseResponse(a.allocator(), line));
    }
}
