//! `capsule issue` — the human side of the tracker, plus the triage queue that the
//! agent fills and a human empties.

const std = @import("std");
const Io = std.Io;

const api = @import("../../api.zig");
const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const store_mod = @import("../../store.zig");
const model_mod = @import("../../model.zig");
const buffer_mod = @import("../../buffer.zig");
const params_mod = @import("../params.zig");
const views = @import("../views.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const verb = request.method["issue.".len..];
    const scope = try params_mod.project(d, arena, w, request) orelse return;
    const params = scope.params;
    const canonical = scope.canonical;
    const project_id = scope.id;

    if (std.mem.eql(u8, verb, "new")) {
        const title = params_mod.stringParam(params, "title") orelse
            return protocol.writeErr(w, request.id, .bad_params, "an issue needs a title");
        if (std.mem.trim(u8, title, " \t\r\n").len == 0) {
            return protocol.writeErr(w, request.id, .bad_params, "an issue needs a title");
        }
        const body = params_mod.stringParam(params, "body") orelse "";
        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();
        const issue_id = ids.generateNow(d.io);
        const event_id = ids.generateNow(d.io);
        _ = try d.store.createIssue(issue_id, project_id, title, body, .human, event_id, now);
        const row = (try d.store.getIssue(arena, issue_id)).?;
        return writeIssue(w, request.id, row);
    }

    if (std.mem.eql(u8, verb, "list")) {
        const state = if (params_mod.stringParam(params, "state")) |text|
            model_mod.Issue.State.parse(text) orelse
                return protocol.writeErr(w, request.id, .bad_params, "unknown state")
        else
            null;
        const rows = try d.store.listIssues(arena, project_id, state);
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
        for (rows, 0..) |row, i| {
            if (i > 0) try w.writeAll(",");
            try issueObject(w, row);
        }
        return w.writeAll("]}\n");
    }

    if (std.mem.eql(u8, verb, "summary")) {
        return api.writeOk(w, request.id, try views.summaryFor(d, arena, project_id, canonical));
    }

    if (std.mem.startsWith(u8, verb, "triage.")) {
        return dispatchTriage(d, arena, w, request, project_id, verb);
    }

    const prefix = params_mod.stringParam(params, "id") orelse
        return protocol.writeErr(w, request.id, .bad_params, "no issue id given");
    const row = try params_mod.issue(d, arena, w, request, project_id, prefix) orelse return;

    if (std.mem.eql(u8, verb, "get")) {
        return writeIssue(w, request.id, row);
    }

    if (std.mem.eql(u8, verb, "events")) {
        const events = try d.store.listEvents(arena, row.id);
        const out = try arena.alloc(api.Event, events.len);
        for (events, out) |e, *o| {
            // `toHex` and `short` hand back fixed arrays by value. Printing one
            // directly is fine, but a struct field outlives this iteration, so each
            // has to be copied into the arena rather than pointed at.
            const hex = ids.toHex(e.id);
            o.* = .{
                .id = try arena.dupe(u8, &hex),
                .kind = e.kind,
                .actor = e.actor,
                .payload = e.payload,
                .created_at = e.created_at,
                .run = if (e.run_id) |r| blk: {
                    const s = ids.short(r);
                    break :blk try arena.dupe(u8, &s);
                } else null,
            };
        }
        // Through `api.writeOk` rather than a hand-written envelope: the result is a
        // list of structs, and every brace this file writes by hand is one no test
        // checks the balance of.
        return api.writeOk(w, request.id, out);
    }

    const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

    if (std.mem.eql(u8, verb, "edit") or std.mem.eql(u8, verb, "rename")) {
        const title = params_mod.stringParam(params, "title");
        const body = params_mod.stringParam(params, "body");
        if (title == null and body == null) {
            return protocol.writeErr(w, request.id, .bad_params, "nothing to change");
        }
        const expected = if (params_mod.stringParam(params, "last_event_id")) |hex|
            ids.parseHex(hex) catch null
        else
            null;

        d.store.editIssue(ids.generateNow(d.io), row.id, title, body, expected, .human, now) catch |e| switch (e) {
            error.Conflict => return protocol.writeErr(
                w,
                request.id,
                .conflict,
                "this issue changed while you were editing — re-open it and redo the edit",
            ),
            error.IllegalTransition => return protocol.writeErr(
                w,
                request.id,
                .refused,
                "this issue is done; merged work is not edited after the fact",
            ),
            else => return e,
        };
        const fresh = (try d.store.getIssue(arena, row.id)).?;
        return writeIssue(w, request.id, fresh);
    }

    if (std.mem.eql(u8, verb, "state")) {
        const requested = params_mod.stringParam(params, "state") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no state given");
        const to = model_mod.Issue.State.parse(requested) orelse
            return protocol.writeErr(w, request.id, .bad_params, "unknown state");

        return appendAndAnswer(
            d,
            arena,
            w,
            request,
            row.id,
            .{ .kind = .state_changed, .actor = .human, .to = to },
            "",
            now,
            "an issue does not move there by hand — 'run merge' reaches done, " ++
                "'issue archive' drops it, 'issue triage' accepts a proposal",
        );
    }

    if (std.mem.eql(u8, verb, "merge")) {
        return appendAndAnswer(
            d,
            arena,
            w,
            request,
            row.id,
            .{ .kind = .merged, .actor = .human },
            params_mod.stringParam(params, "commit") orelse "",
            now,
            "that issue cannot be merged from its current state",
        );
    }

    if (std.mem.eql(u8, verb, "archive") or std.mem.eql(u8, verb, "reopen")) {
        const archiving = std.mem.eql(u8, verb, "archive");
        const reason = params_mod.stringParam(params, "reason") orelse "";
        if (archiving and std.mem.trim(u8, reason, " \t\r\n").len == 0) {
            return protocol.writeErr(w, request.id, .bad_params, "archiving needs a reason (-m)");
        }
        return appendAndAnswer(
            d,
            arena,
            w,
            request,
            row.id,
            .{ .kind = if (archiving) .archived else .reopened, .actor = .human },
            reason,
            now,
            if (archiving)
                "that issue cannot be archived from its current state"
            else
                "only an archived issue can be reopened",
        );
    }

    if (std.mem.eql(u8, verb, "comment")) {
        const text = params_mod.stringParam(params, "text") orelse
            return protocol.writeErr(w, request.id, .bad_params, "an empty comment says nothing");
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            return protocol.writeErr(w, request.id, .bad_params, "an empty comment says nothing");
        }
        return appendAndAnswer(
            d,
            arena,
            w,
            request,
            row.id,
            .{ .kind = .commented, .actor = .human },
            text,
            now,
            "that issue cannot be commented on from its current state",
        );
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}

/// Appends an event, then answers with the issue as it now stands.
///
/// `refused` is the message for an `IllegalTransition` — the one failure a caller has
/// anything to say about, because which transition was attempted, and why it is not
/// allowed, differ per verb.
fn appendAndAnswer(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
    issue_id: ids.Id,
    event: model_mod.Event,
    payload: []const u8,
    now: i64,
    refused: []const u8,
) !void {
    _ = d.store.appendEvent(
        ids.generateNow(d.io),
        issue_id,
        null,
        event,
        payload,
        now,
    ) catch |e| switch (e) {
        error.IllegalTransition => return protocol.writeErr(w, request.id, .refused, refused),
        else => return e,
    };
    const fresh = (try d.store.getIssue(arena, issue_id)).?;
    return writeIssue(w, request.id, fresh);
}

fn writeIssue(w: *Io.Writer, request_id: u64, row: store_mod.Store.IssueRow) !void {
    try w.print("{{\"id\":{d},\"ok\":true,\"result\":", .{request_id});
    try issueObject(w, row);
    try w.writeAll("}\n");
}

fn issueObject(w: *Io.Writer, row: store_mod.Store.IssueRow) !void {
    try w.print("{{\"short\":\"{s}\",\"id\":\"{s}\",\"state\":\"{s}\",\"title\":", .{
        ids.short(row.id), ids.toHex(row.id), @tagName(row.state),
    });
    try std.json.Stringify.encodeJsonString(row.title, .{}, w);
    try w.writeAll(",\"body\":");
    try std.json.Stringify.encodeJsonString(row.body, .{}, w);
    try w.writeAll(",\"last_event_id\":");
    if (row.last_event_id) |last| {
        try w.print("\"{s}\"", .{ids.toHex(last)});
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"created_at\":{d}}}", .{row.created_at});
}

/// Triage and memory review share a shape: the daemon renders a buffer, the client
/// opens it in an editor, the daemon parses what comes back and applies it in one
/// transaction. Nothing is ever half-applied — half-applied triage has no clean
/// recovery, so the parse either yields a whole plan or an error the client re-opens
/// the buffer with.
fn dispatchTriage(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
    project_id: ids.Id,
    verb: []const u8,
) !void {
    const params = params_mod.object(request.params);
    const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

    if (std.mem.eql(u8, verb, "triage.load")) {
        const proposed = try d.store.listIssues(arena, project_id, .proposed);
        var text: std.ArrayList(u8) = .empty;
        var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
        try tw.writer.writeAll(
            "<!-- capsule triage. verbs: keep | accept | reject -->\n" ++
                "<!-- edit freely. save to apply. empty file aborts. -->\n" ++
                "<!-- a deleted line means keep: nothing here is destroyed by omission. -->\n\n",
        );
        for (proposed) |row| {
            try tw.writer.print("## keep {s}  {s}\n", .{ ids.short(row.id), row.title });
            if (row.body.len > 0) try buffer_mod.renderBody(&tw.writer, row.body);
            try tw.writer.writeAll("\n");
        }
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"count\":{d},\"buffer\":", .{
            request.id, proposed.len,
        });
        try std.json.Stringify.encodeJsonString(tw.written(), .{}, w);
        try w.writeAll("}}\n");
        return;
    }

    if (std.mem.eql(u8, verb, "triage.apply")) {
        const text = params_mod.stringParam(params, "buffer") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no buffer");

        const proposed = try d.store.listIssues(arena, project_id, .proposed);
        var expected = try arena.alloc([]const u8, proposed.len);
        for (proposed, 0..) |row, i| expected[i] = try arena.dupe(u8, &ids.short(row.id));

        const verbs = [_][]const u8{ "keep", "accept", "reject" };
        const parsed = try buffer_mod.parse(arena, text, .{ .verbs = &verbs, .expected = expected });
        const entries = switch (parsed) {
            .ok => |e| e,
            .malformed => |err| return protocol.writeErr(
                w,
                request.id,
                .bad_params,
                try buffer_mod.describe(arena, err),
            ),
        };

        try d.store.begin();
        errdefer d.store.rollback();

        var accepted: usize = 0;
        var rejected: usize = 0;
        for (entries) |entry| {
            const row = findByShort(proposed, entry.id) orelse continue;
            if (std.mem.eql(u8, entry.verb, "accept")) {
                try d.store.editIssue(ids.generateNow(d.io), row.id, entry.title, entry.body, null, .human, now);
                _ = try d.store.appendEvent(
                    ids.generateNow(d.io),
                    row.id,
                    null,
                    .{ .kind = .triaged, .actor = .human },
                    "",
                    now,
                );
                accepted += 1;
            } else if (std.mem.eql(u8, entry.verb, "reject")) {
                _ = try d.store.appendEvent(
                    ids.generateNow(d.io),
                    row.id,
                    null,
                    .{ .kind = .archived, .actor = .human },
                    if (entry.body.len > 0) entry.body else "rejected at triage",
                    now,
                );
                rejected += 1;
            }
        }
        try d.store.commit();

        return protocol.writeOk(w, request.id, try std.fmt.allocPrint(
            arena,
            "{{\"accepted\":{d},\"rejected\":{d}}}",
            .{ accepted, rejected },
        ));
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}

fn findByShort(rows: []const store_mod.Store.IssueRow, short: []const u8) ?store_mod.Store.IssueRow {
    for (rows) |row| {
        if (std.mem.eql(u8, &ids.short(row.id), short)) return row;
    }
    return null;
}
