//! A hand-rolled HTTP/1.1 server, about as small as one can be and still be correct.

const std = @import("std");

/// Generous for a header block, and a hard stop for anything that is not one. The body
/// limit is separate, since MCP requests carry real JSON.
pub const max_head = 8 * 1024;
pub const max_body = 1 << 20;

pub const Method = enum { get, post, other };

pub const Head = struct {
    method: Method,
    target: []const u8,
    /// The value of the bearer token header, if the caller sent one. The run token
    /// arrives here and is what tells the daemon which issue the caller is working on.
    authorization: ?[]const u8 = null,
    content_length: usize = 0,
    /// Byte offset in the buffer where the body begins.
    body_start: usize,
};

pub const ParseError = error{
    Incomplete,
    Malformed,
    TooLarge,
    UnsupportedVersion,
};

/// Returns `Incomplete` when the terminating blank line has not arrived yet, which is the
/// caller's cue to read more rather than to fail.
pub fn parseHead(bytes: []const u8) ParseError!Head {
    if (bytes.len > max_head) return error.TooLarge;

    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        const lf_end = std.mem.indexOf(u8, bytes, "\n\n") orelse return error.Incomplete;
        return parseLines(bytes[0..lf_end], lf_end + 2);
    };
    return parseLines(bytes[0..end], end + 4);
}

fn parseLines(head: []const u8, body_start: usize) ParseError!Head {
    var lines = std.mem.splitAny(u8, head, "\n");

    const request_line = std.mem.trimEnd(u8, lines.next() orelse return error.Malformed, "\r");
    var parts = std.mem.splitScalar(u8, request_line, ' ');

    const method_text = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (target.len == 0) return error.Malformed;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.UnsupportedVersion;

    var result = Head{
        .method = if (std.ascii.eqlIgnoreCase(method_text, "GET"))
            .get
        else if (std.ascii.eqlIgnoreCase(method_text, "POST"))
            .post
        else
            .other,
        .target = target,
        .body_start = body_start,
    };

    var saw_content_length = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.Malformed;

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (saw_content_length) return error.Malformed;
            saw_content_length = true;
            const n = std.fmt.parseInt(usize, value, 10) catch return error.Malformed;
            if (n > max_body) return error.TooLarge;
            result.content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            result.authorization = if (std.ascii.startsWithIgnoreCase(value, "bearer "))
                std.mem.trim(u8, value[7..], " ")
            else
                value;
        }
    }

    return result;
}

/// Writes a complete HTTP/1.1 response — status line, headers, body — with
/// `connection: close`, since every caller makes one request and goes away.
pub fn writeResponse(w: *std.Io.Writer, status: u16, content_type: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    try w.print("content-type: {s}\r\n", .{content_type});
    try w.print("content-length: {d}\r\n", .{body.len});
    try w.writeAll("connection: close\r\n\r\n");
    try w.writeAll(body);
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        else => "Error",
    };
}

const testing = std.testing;

test "a minimal GET parses" {
    const head = try parseHead("GET /ping HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expectEqual(Method.get, head.method);
    try testing.expectEqualStrings("/ping", head.target);
    try testing.expectEqual(@as(usize, 0), head.content_length);
    try testing.expectEqual(@as(?[]const u8, null), head.authorization);
}

test "a POST with a body reports where the body starts" {
    const raw = "POST /mcp HTTP/1.1\r\ncontent-length: 9\r\n\r\n{\"a\":123}";
    const head = try parseHead(raw);
    try testing.expectEqual(Method.post, head.method);
    try testing.expectEqual(@as(usize, 9), head.content_length);
    try testing.expectEqualStrings("{\"a\":123}", raw[head.body_start..]);
}

test "the bearer token is extracted, with or without the scheme" {
    const with = try parseHead("GET /status HTTP/1.1\r\nauthorization: Bearer abc123\r\n\r\n");
    try testing.expectEqualStrings("abc123", with.authorization.?);

    const bare = try parseHead("GET /status HTTP/1.1\r\nauthorization: abc123\r\n\r\n");
    try testing.expectEqualStrings("abc123", bare.authorization.?);

    const cased = try parseHead("GET /status HTTP/1.1\r\nAUTHORIZATION: BEARER abc123\r\n\r\n");
    try testing.expectEqualStrings("abc123", cased.authorization.?);
}

test "a truncated head asks for more rather than failing" {
    try testing.expectError(error.Incomplete, parseHead("GET /ping HTTP/1.1\r\nhost: x"));
    try testing.expectError(error.Incomplete, parseHead(""));
    try testing.expectError(error.Incomplete, parseHead("GET /ping HTTP/1.1\r\n"));
}

test "malformed request lines are rejected" {
    try testing.expectError(error.Malformed, parseHead("GET\r\n\r\n"));
    try testing.expectError(error.Malformed, parseHead("GET /ping\r\n\r\n"));
    try testing.expectError(error.UnsupportedVersion, parseHead("GET /ping HTTP/2\r\n\r\n"));
    try testing.expectError(error.Malformed, parseHead("GET /ping HTTP/1.1\r\nnocolon\r\n\r\n"));
}

test "an absurd content-length is refused, not trusted" {
    try testing.expectError(
        error.TooLarge,
        parseHead("POST /mcp HTTP/1.1\r\ncontent-length: 999999999\r\n\r\n"),
    );
    try testing.expectError(
        error.Malformed,
        parseHead("POST /mcp HTTP/1.1\r\ncontent-length: abc\r\n\r\n"),
    );
}

test "an over-long head is refused before it is parsed" {
    const big = "GET /" ++ "x" ** (max_head + 16);
    try testing.expectError(error.TooLarge, parseHead(big));
}

test "bare LF separators are accepted" {
    const head = try parseHead("GET /ping HTTP/1.1\nhost: localhost\n\n");
    try testing.expectEqualStrings("/ping", head.target);
}

test "an unknown method is classified rather than rejected" {
    const head = try parseHead("DELETE /x HTTP/1.1\r\n\r\n");
    try testing.expectEqual(Method.other, head.method);
}

test "transfer-encoding and duplicate content-lengths are refused" {
    try testing.expectError(
        error.Malformed,
        parseHead("POST /mcp HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n"),
    );
    try testing.expectError(
        error.Malformed,
        parseHead("POST /mcp HTTP/1.1\r\ncontent-length: 5\r\ncontent-length: 9\r\n\r\n"),
    );
}

test "a response is well-formed and self-describing" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeResponse(&w, 200, "application/json", "{\"ok\":true}");
    const out = w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "content-length: 11\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n{\"ok\":true}"));
}
