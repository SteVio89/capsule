//! The agent-facing tool surface: MCP method routing, the run-token check every
//! call passes through, and the tools themselves.

const std = @import("std");
const Io = std.Io;

const ids = @import("../../id.zig");
const http = @import("../../http.zig");
const mcp = @import("../../mcp.zig");
const model_mod = @import("../../model.zig");
const token_mod = @import("../../token.zig");
const store_mod = @import("../../store.zig");
const auth = @import("../auth.zig");
const params_mod = @import("../params.zig");

const Daemon = @import("../../daemon.zig").Daemon;

/// `POST /mcp` — the agent's only route into the store.
pub fn serve(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    head: http.Head,
    body: []const u8,
) !void {
    const request = mcp.parseRequest(arena, body) catch {
        var buf: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
        try mcp.writeError(&bw.writer, null, -32700, "parse error");
        return http.writeResponse(w, 200, "application/json", bw.written());
    };

    if (std.mem.eql(u8, request.method, "initialize")) {
        var buf: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
        try mcp.writeInitialize(&bw.writer, request.id, mcp.negotiateVersion(request.params));
        return http.writeResponse(w, 200, "application/json", bw.written());
    }

    if (mcp.isNotification(request)) {
        return http.writeResponse(w, 202, "text/plain", "");
    }

    if (std.mem.eql(u8, request.method, "tools/list")) {
        var buf: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
        try mcp.writeToolList(&bw.writer, request.id);
        return http.writeResponse(w, 200, "application/json", bw.written());
    }

    if (!std.mem.eql(u8, request.method, "tools/call")) {
        var buf: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
        try mcp.writeError(&bw.writer, request.id, -32601, request.method);
        return http.writeResponse(w, 200, "application/json", bw.written());
    }

    d.mutex.lockUncancelable(d.io);
    defer d.mutex.unlock(d.io);

    const binding = switch (try auth.resolveToken(d, arena, head.authorization)) {
        .ok => |b| b,
        .absent => return http.writeResponse(w, 401, "text/plain", "no run token\n"),
        .unknown => return http.writeResponse(w, 401, "text/plain", "unknown run token\n"),
    };

    const params = switch (request.params) {
        .object => |o| o,
        else => blk: {
            const e: std.json.ObjectMap = .empty;
            break :blk e;
        },
    };
    const name = params_mod.stringParam(params, "name") orelse "";
    const args = switch (params.get("arguments") orelse std.json.Value.null) {
        .object => |o| o,
        else => blk: {
            const e: std.json.ObjectMap = .empty;
            break :blk e;
        },
    };

    var buf: std.ArrayList(u8) = .empty;
    var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    try callTool(d, arena, &bw.writer, request.id, binding, name, args);
    return http.writeResponse(w, 200, "application/json", bw.written());
}

fn callTool(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request_id: ?std.json.Value,
    binding: token_mod.Binding(ids.Id),
    name: []const u8,
    args: std.json.ObjectMap,
) !void {
    const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

    if (std.mem.eql(u8, name, "get_issue")) {
        const issue = (try d.store.getIssue(arena, binding.issue_id)) orelse
            return mcp.writeToolResult(w, request_id, "this issue no longer exists", true);

        const memories = try d.store.listMemories(arena, binding.project_id, .active);

        var text: std.ArrayList(u8) = .empty;
        var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
        try tw.writer.print("issue {s} [{s}]\n{s}\n", .{
            ids.short(issue.id), @tagName(issue.state), issue.title,
        });
        if (issue.body.len > 0) try tw.writer.print("\n{s}\n", .{issue.body});
        if (memories.len > 0) {
            try tw.writer.print("\n--- project memory ({d}) ---\n", .{memories.len});
            for (memories) |memory| {
                try tw.writer.print("- {s}\n", .{memory.body});
            }
        }
        return mcp.writeToolResult(w, request_id, tw.written(), false);
    }

    if (std.mem.eql(u8, name, "set_state")) {
        const requested = params_mod.stringParam(args, "state") orelse
            return mcp.writeToolResult(w, request_id, "which state?", true);
        const to = model_mod.Issue.State.parse(requested) orelse
            return mcp.writeToolResult(w, request_id, "not a state I know", true);

        const comment = params_mod.stringParam(args, "comment") orelse "";
        if ((to == .blocked or to == .ready_for_review) and
            std.mem.trim(u8, comment, " \t\r\n").len == 0)
        {
            return mcp.writeToolResult(
                w,
                request_id,
                "a comment is required for blocked and ready_for_review — say what you did, " ++
                    "what you did not, and what the next person needs to know",
                true,
            );
        }

        _ = d.store.appendEvent(
            ids.generateNow(d.io),
            binding.issue_id,
            binding.run_id,
            .{ .kind = .state_changed, .actor = .agent, .to = to },
            comment,
            now,
        ) catch |e| switch (e) {
            error.IllegalTransition => return mcp.writeToolResult(
                w,
                request_id,
                "you cannot move this issue there",
                true,
            ),
            else => return e,
        };
        if (comment.len > 0) {
            // The text is already the `state_changed` event's payload, so what a failure
            // here loses is the separate entry in the comment stream, not the note
            // itself. Not worth failing the call the agent already completed — but it is
            // a write that vanished, so it does not get to vanish quietly too.
            _ = d.store.appendEvent(
                ids.generateNow(d.io),
                binding.issue_id,
                binding.run_id,
                .{ .kind = .commented, .actor = .agent },
                comment,
                now,
            ) catch |err| std.log.warn(
                "the state change was recorded but its comment event was not: {t}",
                .{err},
            );
        }
        return mcp.writeToolResult(w, request_id, requested, false);
    }

    if (std.mem.eql(u8, name, "comment")) {
        const text = params_mod.stringParam(args, "text") orelse
            return mcp.writeToolResult(w, request_id, "an empty note says nothing", true);
        _ = try d.store.appendEvent(
            ids.generateNow(d.io),
            binding.issue_id,
            binding.run_id,
            .{ .kind = .commented, .actor = .agent },
            text,
            now,
        );
        return mcp.writeToolResult(w, request_id, "noted", false);
    }

    if (std.mem.eql(u8, name, "file_issue")) {
        const title = params_mod.stringParam(args, "title") orelse
            return mcp.writeToolResult(w, request_id, "a follow-up needs a title", true);
        const body = params_mod.stringParam(args, "body") orelse "";

        const existing = try d.store.listIssues(arena, binding.project_id, null);
        var similar: std.ArrayList(store_mod.Store.IssueRow) = .empty;
        for (existing) |row| {
            switch (row.state) {
                .done, .archived, .proposed => continue,
                else => {},
            }
            if (looksSimilar(title, row.title)) try similar.append(arena, row);
        }

        const new_id = ids.generateNow(d.io);
        _ = try d.store.createIssue(
            new_id,
            binding.project_id,
            title,
            body,
            .agent,
            ids.generateNow(d.io),
            now,
        );

        var text: std.ArrayList(u8) = .empty;
        var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
        try tw.writer.print("filed {s} for triage\n", .{ids.short(new_id)});
        if (similar.items.len > 0) {
            try tw.writer.writeAll("\nthese open issues look similar — if one already covers it, " ++
                "say so in a comment rather than leaving a duplicate:\n");
            for (similar.items) |row| {
                try tw.writer.print("  {s} [{s}] {s}\n", .{
                    ids.short(row.id), @tagName(row.state), row.title,
                });
            }
        }
        return mcp.writeToolResult(w, request_id, tw.written(), false);
    }

    if (std.mem.eql(u8, name, "propose_memory")) {
        const body = params_mod.stringParam(args, "body") orelse
            return mcp.writeToolResult(w, request_id, "a memory needs a body", true);

        var anchors: std.ArrayList(u8) = .empty;
        if (args.get("anchors")) |value| switch (value) {
            .array => |items| for (items.items) |item| switch (item) {
                .string => |s| {
                    try anchors.appendSlice(arena, s);
                    try anchors.append(arena, '\n');
                },
                else => {},
            },
            else => {},
        };

        try d.store.proposeMemory(
            ids.generateNow(d.io),
            binding.project_id,
            body,
            anchors.items,
            binding.issue_id,
            now,
        );
        return mcp.writeToolResult(
            w,
            request_id,
            "proposed — a human reviews it before it is kept",
            false,
        );
    }

    return mcp.writeToolResult(w, request_id, "no such tool", true);
}

/// Deliberately crude: shared significant words, not edit distance or embeddings. The
/// answer only has to be good enough to make an agent look twice before duplicating, and
/// anything cleverer would be a retrieval layer nobody asked for.
fn looksSimilar(a: []const u8, b: []const u8) bool {
    var shared: usize = 0;
    var words = std.mem.tokenizeAny(u8, a, " \t\n-_/.,:;()[]");
    while (words.next()) |word| {
        if (word.len < 4) continue;
        if (std.ascii.indexOfIgnoreCase(b, word) != null) shared += 1;
        if (shared >= 2) return true;
    }
    return false;
}
