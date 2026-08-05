//! `capsule run` — the lifecycle of a container session.

const std = @import("std");
const Io = std.Io;

const api = @import("../../api.zig");
const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const store_mod = @import("../../store.zig");
const token_mod = @import("../../token.zig");
const params_mod = @import("../params.zig");
const views = @import("../views.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const verb = request.method["run.".len..];
    const scope = try params_mod.project(d, arena, w, request) orelse return;
    const params = scope.params;
    const project_id = scope.id;

    const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

    if (std.mem.eql(u8, verb, "list")) {
        const rows = try d.store.listRuns(arena, project_id, views.run_list_limit);
        return api.writeOk(w, request.id, try views.runModels(arena, rows));
    }

    if (std.mem.eql(u8, verb, "start")) {
        if (try d.store.activeRunForProject(arena, project_id)) |live| {
            const row = try d.store.getIssue(arena, live.issue_id);
            try w.print(
                "{{\"id\":{d},\"ok\":false,\"error\":{{\"code\":\"refused\",\"message\":",
                .{request.id},
            );
            try std.json.Stringify.encodeJsonString(
                try std.fmt.allocPrint(
                    arena,
                    "a run is already live on this project: {s} \"{s}\" in container {s}",
                    .{
                        ids.short(live.issue_id),
                        if (row) |r| r.title else "(unknown issue)",
                        try store_mod.containerName(arena, live.run_id),
                    },
                ),
                .{},
                w,
            );
            try w.writeAll(",\"hint\":\"capsule run attach\"}}\n");
            return;
        }

        const prefix = params_mod.stringParam(params, "issue") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no issue given");
        const issue = try params_mod.issue(d, arena, w, request, project_id, prefix) orelse return;

        const run_id = ids.generateNow(d.io);
        const secret = token_mod.mint(d.io);
        const digest = token_mod.hash(&secret);
        const branch = try std.fmt.allocPrint(arena, "capsule/{s}", .{ids.toHex(issue.id)});

        d.store.startRun(run_id, issue.id, project_id, branch, &digest, ids.generateNow(d.io), now) catch |e| switch (e) {
            error.IllegalTransition => return protocol.writeErr(
                w,
                request.id,
                .refused,
                "that issue cannot be worked on — it is done or archived",
            ),
            else => return e,
        };

        const profile = (try d.store.projectProfile(arena, project_id)) orelse "default";

        try w.print(
            "{{\"id\":{d},\"ok\":true,\"result\":{{\"run\":\"{s}\",\"issue\":\"{s}\"," ++
                "\"token\":\"{s}\",\"container\":\"{s}\",\"profile\":",
            .{
                request.id,
                ids.toHex(run_id),
                ids.toHex(issue.id),
                secret,
                try store_mod.containerName(arena, run_id),
            },
        );
        try std.json.Stringify.encodeJsonString(profile, .{}, w);
        try w.writeAll(",\"branch\":");
        try std.json.Stringify.encodeJsonString(branch, .{}, w);
        try w.writeAll(",\"title\":");
        try std.json.Stringify.encodeJsonString(issue.title, .{}, w);
        try w.writeAll("}}\n");
        return;
    }

    if (std.mem.eql(u8, verb, "end")) {
        const live = (try d.store.activeRunForProject(arena, project_id)) orelse
            return protocol.writeErr(w, request.id, .refused, "no run is live on this project");
        try d.store.finishRun(live.run_id, .ended, now);
        return protocol.writeOk(w, request.id, "{\"ended\":true}");
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}
