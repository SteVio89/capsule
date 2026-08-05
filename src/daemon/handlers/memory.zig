//! `capsule memory` — list, review, and the cap.

const std = @import("std");
const Io = std.Io;

const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const store_mod = @import("../../store.zig");
const memory_mod = @import("../../memory.zig");
const buffer_mod = @import("../../buffer.zig");
const model_mod = @import("../../model.zig");
const params_mod = @import("../params.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const verb = request.method["memory.".len..];
    const scope = try params_mod.project(d, arena, w, request) orelse return;
    const params = scope.params;
    const project_id = scope.id;

    const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

    if (std.mem.eql(u8, verb, "stale")) {
        var gone: std.ArrayList([]const u8) = .empty;
        if (params.get("paths")) |value| switch (value) {
            .array => |items| for (items.items) |item| switch (item) {
                .string => |s| try gone.append(arena, s),
                else => {},
            },
            else => {},
        };

        const active = try d.store.listMemories(arena, project_id, .active);
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
        var n: usize = 0;
        for (active) |row| {
            if (!memory_mod.isSuspect(row.anchors, gone.items)) continue;
            if (n > 0) try w.writeAll(",");
            try w.print("{{\"short\":\"{s}\",\"body\":", .{ids.short(row.id)});
            try std.json.Stringify.encodeJsonString(row.body, .{}, w);
            try w.writeAll(",\"anchors\":");
            try std.json.Stringify.encodeJsonString(std.mem.trim(u8, row.anchors, "\n"), .{}, w);
            try w.writeAll("}");
            n += 1;
        }
        return w.writeAll("]}\n");
    }

    if (std.mem.eql(u8, verb, "list")) {
        const rows = try d.store.listMemories(arena, project_id, null);
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
        for (rows, 0..) |row, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"short\":\"{s}\",\"state\":\"{s}\",\"body\":", .{
                ids.short(row.id), @tagName(row.state),
            });
            try std.json.Stringify.encodeJsonString(row.body, .{}, w);
            try w.writeAll(",\"anchors\":");
            try std.json.Stringify.encodeJsonString(row.anchors, .{}, w);
            try w.writeAll("}");
        }
        return w.writeAll("]}\n");
    }

    if (std.mem.eql(u8, verb, "new")) {
        const body = params_mod.stringParam(params, "body") orelse
            return protocol.writeErr(w, request.id, .bad_params, "a memory needs a body");

        const active_now: usize = @intCast(try d.store.countActiveMemories(project_id));
        switch (memory_mod.applyCap(active_now, &.{.{ .id = "new", .verb = .activate }})) {
            .refused => return protocol.writeErr(
                w,
                request.id,
                .refused,
                try std.fmt.allocPrint(
                    arena,
                    "{d} memories are already active, which is the cap — 'capsule memory review' " ++
                        "and deactivate one in the same pass",
                    .{memory_mod.active_cap},
                ),
            ),
            .applied => {},
        }

        const id = ids.generateNow(d.io);
        try d.store.proposeMemory(id, project_id, body, params_mod.stringParam(params, "anchors") orelse "", null, now);
        try d.store.setMemoryState(id, .active, now);
        return protocol.writeOk(w, request.id, "{\"added\":true}");
    }

    if (std.mem.eql(u8, verb, "review.load")) {
        const proposals = try d.store.listMemories(arena, project_id, .proposed);
        const active = try d.store.listMemories(arena, project_id, .active);

        var bodies = try arena.alloc([]const u8, active.len);
        for (active, 0..) |row, i| bodies[i] = row.body;

        var text: std.ArrayList(u8) = .empty;
        var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
        try tw.writer.writeAll(
            "<!-- capsule memory review. verbs: keep | activate | discard -->\n" ++
                "<!-- verbs on active memories: keep | deactivate -->\n",
        );
        try tw.writer.print(
            "<!-- {d}/{d} active, ~{d}k tokens (approx). save to apply. empty file aborts. -->\n\n",
            .{ active.len, memory_mod.active_cap, memory_mod.estimateTokens(bodies) / 1000 },
        );
        for (proposals) |row| {
            try tw.writer.print("## keep {s}\n", .{ids.short(row.id)});
            try writeAnchorLines(&tw.writer, row.anchors);
            try buffer_mod.renderBody(&tw.writer, row.body);
            try tw.writer.writeAll("\n");
        }
        if (active.len > 0) {
            try tw.writer.writeAll("<!-- existing active memories below — deactivate to make room -->\n\n");
            for (active) |row| {
                try tw.writer.print("## keep {s}\n", .{ids.short(row.id)});
                try writeAnchorLines(&tw.writer, row.anchors);
                try buffer_mod.renderBody(&tw.writer, row.body);
                try tw.writer.writeAll("\n");
            }
        }
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"proposals\":{d},\"active\":{d},\"buffer\":", .{
            request.id, proposals.len, active.len,
        });
        try std.json.Stringify.encodeJsonString(tw.written(), .{}, w);
        try w.writeAll("}}\n");
        return;
    }

    if (std.mem.eql(u8, verb, "review.apply")) {
        const text = params_mod.stringParam(params, "buffer") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no buffer");

        const all = try d.store.listMemories(arena, project_id, null);
        var expected: std.ArrayList([]const u8) = .empty;
        for (all) |row| switch (row.state) {
            .proposed, .active => try expected.append(arena, try arena.dupe(u8, &ids.short(row.id))),
            .inactive => {},
        };

        const verbs = [_][]const u8{ "keep", "activate", "discard", "deactivate" };
        const parsed = try buffer_mod.parse(arena, text, .{
            .verbs = &verbs,
            .expected = expected.items,
        });
        const entries = switch (parsed) {
            .ok => |e| e,
            .malformed => |err| return protocol.writeErr(
                w,
                request.id,
                .bad_params,
                try buffer_mod.describe(arena, err),
            ),
        };

        var decisions: std.ArrayList(memory_mod.Decision) = .empty;
        for (entries) |entry| {
            const v = memory_mod.Verb.parse(entry.verb) orelse continue;
            if (v == .keep) continue;
            const row = findMemoryByShort(all, entry.id) orelse continue;
            const complaint: ?[]const u8 = switch (v) {
                .keep => null,
                .activate, .discard => if (row.state == .proposed)
                    null
                else
                    "only applies to a proposal — an active memory takes keep or deactivate",
                .deactivate => if (row.state == .active)
                    null
                else
                    "only applies to an active memory — a proposal takes keep, activate or discard",
            };
            if (complaint) |c| {
                return protocol.writeErr(w, request.id, .refused, try std.fmt.allocPrint(
                    arena,
                    "'{s} {s}': {s}",
                    .{ entry.verb, entry.id, c },
                ));
            }
            try decisions.append(arena, .{ .id = entry.id, .verb = v });
        }

        const active_now: usize = @intCast(try d.store.countActiveMemories(project_id));
        switch (memory_mod.applyCap(active_now, decisions.items)) {
            .refused => |r| return protocol.writeErr(
                w,
                request.id,
                .refused,
                try std.fmt.allocPrint(
                    arena,
                    "that would leave {d} active and the cap is {d} — deactivate one in the " ++
                        "same pass, or activate fewer",
                    .{ r.would_be, memory_mod.active_cap },
                ),
            ),
            .applied => {},
        }

        try d.store.begin();
        errdefer d.store.rollback();

        var changed: usize = 0;
        for (entries) |entry| {
            const v = memory_mod.Verb.parse(entry.verb) orelse continue;
            const row = findMemoryByShort(all, entry.id) orelse continue;

            const edited = try splitAnchors(arena, entry.body);
            if (!std.mem.eql(u8, edited.body, row.body) or
                !std.mem.eql(u8, edited.anchors, std.mem.trim(u8, row.anchors, "\n")))
            {
                try d.store.editMemory(row.id, edited.body, edited.anchors, now);
                changed += 1;
            }

            const next: ?model_mod.Memory.State = switch (v) {
                .keep => null,
                .activate => if (row.state == .active) null else .active,
                .discard, .deactivate => .inactive,
            };
            if (next) |state| {
                try d.store.setMemoryState(row.id, state, now);
                changed += 1;
            }
        }
        try d.store.commit();

        return protocol.writeOk(w, request.id, try std.fmt.allocPrint(
            arena,
            "{{\"changed\":{d}}}",
            .{changed},
        ));
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}

fn findMemoryByShort(rows: []const store_mod.Store.MemoryRow, short: []const u8) ?store_mod.Store.MemoryRow {
    for (rows) |row| {
        if (std.mem.eql(u8, &ids.short(row.id), short)) return row;
    }
    return null;
}

/// One `anchors: <path>` line per anchor, so each parses back unambiguously. The
/// paths are user-authored file names — content, but content with a fixed shape, so
/// they stay at column 0 where the reviewer can edit them naturally.
fn writeAnchorLines(w: *Io.Writer, anchors: []const u8) !void {
    var lines = std.mem.splitScalar(u8, anchors, '\n');
    while (lines.next()) |raw| {
        const anchor = std.mem.trim(u8, raw, " \t\r");
        if (anchor.len > 0) try w.print("anchors: {s}\n", .{anchor});
    }
}

const AnchorSplit = struct { anchors: []const u8, body: []const u8 };

/// The inverse of `writeAnchorLines` plus the render indent: pulls the leading
/// `anchors:` lines back out of an edited entry body and returns the anchors in
/// their newline-separated storage shape. Allocates from `arena`.
fn splitAnchors(arena: std.mem.Allocator, text: []const u8) !AnchorSplit {
    var anchors: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (offset < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[offset..line_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "anchors:")) break;
        const path = std.mem.trim(u8, line["anchors:".len..], " \t");
        if (path.len > 0) {
            if (anchors.items.len > 0) try anchors.append(arena, '\n');
            try anchors.appendSlice(arena, path);
        }
        offset = @min(line_end + 1, text.len);
    }
    return .{
        .anchors = try anchors.toOwnedSlice(arena),
        .body = std.mem.trim(u8, text[offset..], "\r\n"),
    };
}
