//! The loopback HTTP endpoint the container reaches through the reverse tunnel. Only
//! `/ping` and `/mcp` are served; the MCP method routing itself is `handlers/mcp.zig`.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const auth = @import("auth.zig");
const http = @import("../http.zig");
const ids = @import("../id.zig");
const token_mod = @import("../token.zig");
const mcp_handler = @import("handlers/mcp.zig");
const transport = @import("transport.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// The loopback HTTP endpoint the container reaches through the reverse tunnel.
pub fn serveHttp(d: *Daemon) void {
    const addr: net.IpAddress = .{ .ip4 = .loopback(d.ssh_config.mcp_port) };
    var server = addr.listen(d.io, .{ .reuse_address = true }) catch |err| {
        std.log.warn("cannot bind 127.0.0.1:{d}: {t} — the MCP endpoint is down", .{
            d.ssh_config.mcp_port, err,
        });
        return;
    };
    defer server.deinit(d.io);
    d.http_up.store(true, .release);
    defer d.http_up.store(false, .release);

    while (!d.quit.load(.acquire)) {
        const stream = server.accept(d.io) catch continue;
        defer stream.close(d.io);
        if (d.quit.load(.acquire)) break;
        serveHttpRequest(d, stream) catch {};
    }
}

fn serveHttpRequest(d: *Daemon, stream: net.Stream) !void {
    transport.setSocketTimeouts(stream, 30);

    var reader_buf: [4096]u8 = undefined;
    var head_buf: [http.max_head]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(d.io, &reader_buf);
    var writer = stream.writer(d.io, &write_buf);
    const w = &writer.interface;
    defer w.flush() catch {};

    var used: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return http.writeResponse(w, 413, "text/plain", "header too long\n"),
            else => return,
        };
        if (used + line.len > head_buf.len) {
            return http.writeResponse(w, 413, "text/plain", "head too large\n");
        }
        @memcpy(head_buf[used..][0..line.len], line);
        used += line.len;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }

    const head = http.parseHead(head_buf[0..used]) catch
        return http.writeResponse(w, 400, "text/plain", "bad request\n");

    if (head.method == .get and std.mem.eql(u8, head.target, "/ping")) {
        return http.writeResponse(w, 200, "application/json", "{\"ok\":true}");
    }

    if (head.method == .post and std.mem.eql(u8, head.target, "/mcp")) {
        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();
        const gpa = arena.allocator();

        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(gpa, head_buf[head.body_start..used]);
        while (body.items.len < head.content_length) {
            const want = head.content_length - body.items.len;
            const chunk = try gpa.alloc(u8, @min(want, 8192));
            const n = reader.interface.readSliceShort(chunk) catch break;
            if (n == 0) break;
            try body.appendSlice(gpa, chunk[0..n]);
        }
        // The loop breaks on a short read as well as on a full one, so reaching here
        // says nothing about completeness. Handing a truncated body to the JSON parser
        // gets a parse error blamed on the agent's request rather than on the transport.
        if (body.items.len < head.content_length) {
            return http.writeResponse(w, 400, "text/plain", "request body ended early\n");
        }
        return mcp_handler.serve(d, gpa, w, head, body.items);
    }

    if (head.method == .get and std.mem.eql(u8, head.target, "/status")) {
        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();
        return serveStatus(d, arena.allocator(), w, head.authorization);
    }

    return http.writeResponse(w, 404, "text/plain", "not found\n");
}

/// Resolves the caller's token to the run it was minted for, and answers with just
/// enough for a status line: which issue, what state, which branch.
fn serveStatus(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    authorization: ?[]const u8,
) !void {
    d.mutex.lockUncancelable(d.io);
    defer d.mutex.unlock(d.io);

    const active = d.store.activeRuns(arena) catch
        return http.writeResponse(w, 500, "text/plain", "store unavailable\n");

    switch (token_mod.resolve(ids.Id, authorization, try auth.bindingsFor(arena, active))) {
        .absent => return http.writeResponse(w, 401, "text/plain", "no run token\n"),
        .unknown => return http.writeResponse(w, 401, "text/plain", "unknown run token\n"),
        .ok => |binding| {
            const issue = (d.store.getIssue(arena, binding.issue_id) catch null) orelse
                return http.writeResponse(w, 404, "text/plain", "no such issue\n");

            var body: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &body);
            try bw.writer.print("{{\"issue\":\"{s}\",\"state\":\"{s}\",\"title\":", .{
                ids.short(issue.id), @tagName(issue.state),
            });
            try std.json.Stringify.encodeJsonString(issue.title, .{}, &bw.writer);
            try bw.writer.writeAll(",\"branch\":");
            for (active) |run| {
                if (std.mem.eql(u8, &run.run_id, &binding.run_id)) {
                    try std.json.Stringify.encodeJsonString(run.branch, .{}, &bw.writer);
                    break;
                }
            } else try bw.writer.writeAll("null");
            try bw.writer.writeAll("}");

            return http.writeResponse(w, 200, "application/json", bw.written());
        },
    }
}
