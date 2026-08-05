//! What every handler does before it can start: read the params, resolve the project the
//! call is about, and — where a verb takes one — resolve the issue id.
//!
//! `project` and `issue` answer null once they have already written the refusal. That is
//! deliberate: each has two or three distinct failures needing different codes and
//! different messages, and no caller has anything to add to any of them.

const std = @import("std");
const Io = std.Io;

const ids = @import("../id.zig");
const project_mod = @import("../project.zig");
const protocol = @import("../protocol.zig");
const store_mod = @import("../store.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// The request's params as an object. Anything else — including nothing — reads as empty,
/// so a handler's own "an issue needs a title" wins over a generic complaint about shape.
pub fn object(value: std.json.Value) std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => .empty,
    };
}

pub const Project = struct {
    id: ids.Id,
    canonical: []const u8,
    params: std.json.ObjectMap,
};

/// The project this request is about, or null once the refusal has been written.
pub fn project(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !?Project {
    const params = object(request.params);
    const canonical = canonicalPath(arena, params) catch {
        try protocol.writeErr(w, request.id, .bad_params, "not a git repository");
        return null;
    };
    const id = (try d.store.findProject(canonical)) orelse {
        try protocol.writeErr(w, request.id, .no_project, canonical);
        return null;
    };
    return .{ .id = id, .canonical = canonical, .params = params };
}

/// The issue `prefix` names, or null once the refusal has been written. Ids resolve by
/// unique prefix, as git resolves a short SHA.
pub fn issue(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
    project_id: ids.Id,
    prefix: []const u8,
) !?store_mod.Store.IssueRow {
    const id_list = try d.store.listIssueIds(arena, project_id);
    switch (ids.resolvePrefix(prefix, id_list)) {
        .resolved => |i| return (try d.store.getIssue(arena, id_list[i])).?,
        .ambiguous => try protocol.writeErr(w, request.id, .ambiguous_id, prefix),
        .missing => try protocol.writeErr(w, request.id, .no_issue, prefix),
        .malformed => try protocol.writeErr(w, request.id, .bad_params, "not an issue id"),
    }
    return null;
}

pub fn stringParam(params: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (params.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The caller passes what git said and a cwd that is already physical; joining and
/// normalising them is `project.resolveGitDir`, which is where the worktree and
/// bare-repo cases are pinned down.
pub fn canonicalPath(arena: std.mem.Allocator, params: std.json.ObjectMap) ![]const u8 {
    const git_dir = stringParam(params, "git_common_dir") orelse return error.NotARepository;
    const cwd = stringParam(params, "cwd") orelse return error.NotARepository;
    return project_mod.resolveGitDir(arena, git_dir, cwd);
}
