//! `capsule project` — register, list, retire, and set the profile.

const std = @import("std");
const Io = std.Io;

const api = @import("../../api.zig");
const ids = @import("../../id.zig");
const project_mod = @import("../../project.zig");
const protocol = @import("../../protocol.zig");
const params_mod = @import("../params.zig");
const views = @import("../views.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const verb = request.method["project.".len..];
    const params = params_mod.object(request.params);

    if (std.mem.eql(u8, verb, "list")) {
        return api.writeOk(w, request.id, try views.projectList(d, arena));
    }

    const canonical = params_mod.canonicalPath(arena, params) catch
        return protocol.writeErr(w, request.id, .bad_params, "not a git repository");

    if (std.mem.eql(u8, verb, "add")) {
        const profile = params_mod.stringParam(params, "profile") orelse "default";
        if (!project_mod.validProfile(profile)) {
            return protocol.writeErr(w, request.id, .bad_params, "invalid profile name");
        }
        if (try d.store.findProject(canonical)) |_| {
            return protocol.writeErr(w, request.id, .refused, "already registered");
        }
        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();
        const id = ids.generateNow(d.io);
        try d.store.addProject(id, canonical, profile, now);
        return writeProject(arena, w, request.id, id, canonical, profile);
    }

    const id = (try d.store.findProject(canonical)) orelse
        return protocol.writeErr(w, request.id, .no_project, canonical);

    if (std.mem.eql(u8, verb, "get")) {
        const profile = (try d.store.projectProfile(arena, id)) orelse "default";
        return writeProject(arena, w, request.id, id, canonical, profile);
    }

    if (std.mem.eql(u8, verb, "profile")) {
        const profile = params_mod.stringParam(params, "profile") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no profile given");
        if (!project_mod.validProfile(profile)) {
            return protocol.writeErr(w, request.id, .bad_params, "invalid profile name");
        }
        try d.store.setProjectProfile(id, profile);
        return writeProject(arena, w, request.id, id, canonical, profile);
    }

    if (std.mem.eql(u8, verb, "rm")) {
        const force = switch (params.get("force") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        d.store.removeProject(id, force) catch |e| switch (e) {
            error.HasIssues => return protocol.writeErr(
                w,
                request.id,
                .refused,
                "this project still has issues — pass --force to remove it anyway",
            ),
            else => return e,
        };
        return protocol.writeOk(w, request.id, "{\"removed\":true}");
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}

fn writeProject(
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request_id: u64,
    id: ids.Id,
    canonical: []const u8,
    profile: []const u8,
) !void {
    try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"short\":\"{s}\",\"name\":", .{
        request_id, ids.short(id),
    });
    try std.json.Stringify.encodeJsonString(project_mod.displayName(canonical), .{}, w);
    try w.writeAll(",\"path\":");
    try std.json.Stringify.encodeJsonString(canonical, .{}, w);
    try w.writeAll(",\"profile\":");
    try std.json.Stringify.encodeJsonString(profile, .{}, w);
    try w.writeAll(",\"replica\":");
    try std.json.Stringify.encodeJsonString(try project_mod.replicaName(arena, canonical), .{}, w);
    try w.writeAll("}}\n");
}
