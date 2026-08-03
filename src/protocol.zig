//! The CLI/TUI ↔ daemon wire format: one JSON object per line, request and response.

const std = @import("std");

/// A line longer than this is refused rather than buffered. It is a backstop against a
/// runaway client, not a meaningful limit on content — so it must clear the largest
/// legitimate payload: the editor accepts buffers up to 1 MiB, JSON escaping can double
/// that, and triage/review responses carry many bodies in one line. Anything holding a
/// buffer of this size takes it from an allocator, never the stack.
pub const max_line = 1 << 22;

/// Closed set, because bash branches on it. `hint` is what the CLI prints verbatim —
/// keeping the remedy next to the code is what stops "run capsule daemon start" from
/// being spelled six different ways across the bash.
pub const Code = enum {
    bad_json,
    missing_method,
    unknown_method,
    bad_params,
    too_large,
    no_project,
    no_issue,
    ambiguous_id,
    conflict,
    refused,
    internal,

    /// The remedy the CLI prints verbatim under the error, or null when there is no
    /// one-line fix. Static strings — nothing to free.
    pub fn hint(code: Code) ?[]const u8 {
        return switch (code) {
            .no_project => "capsule project add",
            .no_issue => "capsule issue list",
            .ambiguous_id => "use more characters of the id",
            else => null,
        };
    }
};

pub const Request = struct {
    id: u64,
    method: []const u8,
    /// Left as a `Value` so each method parses its own shape. A method that wants a typed
    /// struct re-parses this; a method with no arguments ignores it.
    params: std.json.Value,
};

pub const ParseResult = union(enum) {
    ok: Request,
    /// The id could not be recovered, so a reply cannot be correlated. The daemon answers
    /// with id 0 and closes.
    err: Code,
};

/// Pure: bytes in, request or error code out. The allocator owns the parsed tree, which
/// is why the daemon runs an arena per request and drops it after the response flushes.
pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseResult {
    if (line.len > max_line) return .{ .err = .too_large };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch
        return .{ .err = .bad_json };

    const object = switch (parsed) {
        .object => |o| o,
        else => return .{ .err = .bad_json },
    };

    const method = switch (object.get("method") orelse return .{ .err = .missing_method }) {
        .string => |s| s,
        else => return .{ .err = .missing_method },
    };
    if (method.len == 0) return .{ .err = .missing_method };

    const id: u64 = switch (object.get("id") orelse std.json.Value{ .integer = 0 }) {
        .integer => |i| if (i < 0) return .{ .err = .bad_json } else @intCast(i),
        else => return .{ .err = .bad_json },
    };

    return .{ .ok = .{
        .id = id,
        .method = method,
        .params = object.get("params") orelse .null,
    } };
}

/// Writes one response line, newline included. `result_json` is already-encoded JSON so
/// each method can stream its own shape without a common result type.
pub fn writeOk(w: *std.Io.Writer, id: u64, result_json: []const u8) !void {
    try w.print("{{\"id\":{d},\"ok\":true,\"result\":{s}}}\n", .{ id, result_json });
}

/// Writes one error line, newline included. The message is JSON-escaped here, and the
/// code's hint (if any) rides along so the remedy is never spelled by the caller.
pub fn writeErr(w: *std.Io.Writer, id: u64, code: Code, message: []const u8) !void {
    try w.print("{{\"id\":{d},\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":", .{
        id, @tagName(code),
    });
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    if (code.hint()) |h| {
        try w.writeAll(",\"hint\":");
        try std.json.Stringify.encodeJsonString(h, .{}, w);
    }
    try w.writeAll("}}\n");
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, line: []const u8) ParseResult {
    return parseRequest(arena, line);
}

test "a well-formed request round-trips its fields" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const got = parse(a.allocator(),
        \\{"id":7,"method":"issue.list","params":{"state":"open"}}
    );
    try testing.expectEqual(@as(u64, 7), got.ok.id);
    try testing.expectEqualStrings("issue.list", got.ok.method);
    try testing.expectEqualStrings("open", got.ok.params.object.get("state").?.string);
}

test "id is optional and params default to null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const got = parse(a.allocator(),
        \\{"method":"ping"}
    );
    try testing.expectEqual(@as(u64, 0), got.ok.id);
    try testing.expectEqual(std.json.Value.null, got.ok.params);
}

test "malformed input is rejected by code, never by crashing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const cases = [_]struct { line: []const u8, code: Code }{
        .{ .line = "", .code = .bad_json },
        .{ .line = "not json", .code = .bad_json },
        .{ .line = "[1,2,3]", .code = .bad_json },
        .{ .line = "\"a string\"", .code = .bad_json },
        .{ .line = "{\"method\":\"ping\"", .code = .bad_json },
        .{ .line = "{}", .code = .missing_method },
        .{ .line = "{\"method\":42}", .code = .missing_method },
        .{ .line = "{\"method\":\"\"}", .code = .missing_method },
        .{ .line = "{\"id\":\"x\",\"method\":\"ping\"}", .code = .bad_json },
        .{ .line = "{\"id\":-1,\"method\":\"ping\"}", .code = .bad_json },
    };
    for (cases) |c| {
        try testing.expectEqual(c.code, parse(a.allocator(), c.line).err);
    }
}

test "an over-long line is refused before it is parsed" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const big = try a.allocator().alloc(u8, max_line + 1);
    @memset(big, 'x');
    try testing.expectEqual(Code.too_large, parse(a.allocator(), big).err);
}

test "trailing content after the object is not silently accepted" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqual(Code.bad_json, parse(a.allocator(),
        \\{"method":"ping"} {"method":"other"}
    ).err);
}

test "writeOk emits one line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeOk(&w, 3, "{\"pong\":true}");
    try testing.expectEqualStrings(
        "{\"id\":3,\"ok\":true,\"result\":{\"pong\":true}}\n",
        w.buffered(),
    );
}

test "writeErr carries the code, the message, and the remedy when there is one" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeErr(&w, 1, .no_project, "not a registered project");
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":false,\"error\":{\"code\":\"no_project\"," ++
            "\"message\":\"not a registered project\",\"hint\":\"capsule project add\"}}\n",
        w.buffered(),
    );
}

test "writeErr escapes a message that would otherwise break the line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeErr(&w, 1, .internal, "broke \"here\"\nand here");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "\n"));
}
