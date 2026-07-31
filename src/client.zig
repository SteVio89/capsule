//! The other side of the socket: one request, one response, exit.
//!
//! Used by `bin/capsule` for anything structured, and by the board on its poll timer.
//! Deliberately not a session — there is nothing to keep open between two lines of JSON.

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
    var stream = addr.connect(io) catch return error.DaemonNotRunning;
    defer stream.close(io);

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
    // Typed, not an anonymous literal: an anon struct would be stringified as itself
    // rather than coerced to a Value, and the map's internals are not serializable.
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
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
