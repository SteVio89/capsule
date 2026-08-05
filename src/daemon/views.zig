//! The wire shapes more than one handler builds. Each of these has two callers — a
//! command and the board — and the point of having one copy is that the two can never
//! report different numbers for the same project.

const std = @import("std");

const api = @import("../api.zig");
const ids = @import("../id.zig");
const memory_mod = @import("../memory.zig");
const model_mod = @import("../model.zig");
const project_mod = @import("../project.zig");
const store_mod = @import("../store.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// The poller's snapshot as the wire shape. `world.Snapshot` and `api.World` carry
/// the same facts but are separate types on purpose — one is what a probe observed,
/// the other is what the protocol promises — so the arrays are copied, not cast.
pub fn worldModel(d: *Daemon, arena: std.mem.Allocator) !api.World {
    const s = d.snapshot;

    const containers = try arena.alloc(api.Container, s.containers.len);
    for (s.containers, containers) |from, *to| {
        to.* = .{ .name = from.name, .image = from.image };
    }
    const branches = try arena.alloc(api.Branch, s.branches.len);
    for (s.branches, branches) |from, *to| {
        to.* = .{ .project = from.project, .name = from.name, .commits = from.commits };
    }

    return .{
        .reachable = s.reachable,
        .observed_at_ms = s.observed_at_ms,
        .uptime_s = s.uptime_s,
        .disk_used = s.disk_used,
        .disk_total = s.disk_total,
        .image_digest = s.image_digest,
        .containers = containers,
        .branches = branches,
    };
}

/// Every registered project. Shared by `project.list` and `board.get` so the picker
/// and the dashboard cannot show different sets.
pub fn projectList(d: *Daemon, arena: std.mem.Allocator) ![]const api.Project {
    const rows = try d.store.listProjects(arena);
    const out = try arena.alloc(api.Project, rows.len);
    for (rows, out) |row, *o| {
        // `short` hands back a fixed array by value; a struct field outlives this
        // iteration, so it has to be copied rather than pointed at.
        const short = ids.short(row.id);
        o.* = .{
            .short = try arena.dupe(u8, &short),
            .name = project_mod.displayName(row.canonical_path),
            .path = row.canonical_path,
            .profile = row.profile,
            .replica = try project_mod.replicaName(arena, row.canonical_path),
        };
    }
    return out;
}

/// The project's counts and memory pressure. Shared by `issue.summary` and
/// `board.get`: two writers of the same numbers is two chances to disagree.
pub fn summaryFor(
    d: *Daemon,
    arena: std.mem.Allocator,
    project_id: ids.Id,
    canonical: []const u8,
) !api.Summary {
    const rows = try d.store.listIssues(arena, project_id, null);
    var tally = [_]usize{0} ** std.meta.fields(model_mod.Issue.State).len;
    for (rows) |row| tally[@intFromEnum(row.state)] += 1;

    // Copying by field name rather than by position: a state added to the enum and
    // not to `IssueCounts` fails to compile here instead of reporting zero forever.
    var counts = api.IssueCounts{};
    inline for (std.meta.fields(model_mod.Issue.State), 0..) |field, i| {
        @field(counts, field.name) = tally[i];
    }

    const active = try d.store.listMemories(arena, project_id, .active);
    const bodies = try arena.alloc([]const u8, active.len);
    for (active, bodies) |row, *body| body.* = row.body;
    const proposals = try d.store.listMemories(arena, project_id, .proposed);

    return .{
        .replica = try project_mod.replicaName(arena, canonical),
        .issues = counts,
        .memory = .{
            .active = active.len,
            .cap = memory_mod.active_cap,
            .proposed = proposals.len,
            .tokens = memory_mod.estimateTokens(bodies),
            .over_budget = memory_mod.overBudget(bodies),
        },
    };
}

/// How many runs `run.list` and the board's history pane show. Runs accumulate
/// forever; a dashboard that scrolls back to the first one is not a dashboard.
pub const run_list_limit = 20;

pub fn runModels(arena: std.mem.Allocator, rows: []const store_mod.Store.RunRow) ![]const api.Run {
    const out = try arena.alloc(api.Run, rows.len);
    for (rows, out) |row, *o| {
        const short = ids.short(row.id);
        const issue = ids.short(row.issue_id);
        o.* = .{
            .short = try arena.dupe(u8, &short),
            .issue = try arena.dupe(u8, &issue),
            .state = row.state,
            .started_at = row.started_at,
            .ended_at = row.ended_at,
            .container = try store_mod.containerName(arena, row.id),
            .branch = row.branch,
        };
    }
    return out;
}
