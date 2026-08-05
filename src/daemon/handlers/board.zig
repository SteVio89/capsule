//! `board.get` — one frame of the dashboard: one lock, one instant, one round trip.

const std = @import("std");
const Io = std.Io;

const api = @import("../../api.zig");
const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const store_mod = @import("../../store.zig");
const project_mod = @import("../../project.zig");
const world_mod = @import("../../world.zig");
const params_mod = @import("../params.zig");
const views = @import("../views.zig");

const Daemon = @import("../../daemon.zig").Daemon;

/// Unlike every other project-scoped method this one never refuses. Run `capsule
/// board` in `/tmp` and the VM panel and the project list are still worth drawing;
/// an error there would leave the dashboard with nothing to say at all.
pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const params = params_mod.object(request.params);

    var board = api.Board{
        .world = try views.worldModel(d, arena),
        .projects = try views.projectList(d, arena),
        .project = null,
        .issues = &.{},
        .runs = &.{},
    };

    const canonical = blk: {
        const git_dir = params_mod.stringParam(params, "git_common_dir") orelse break :blk null;
        const cwd = params_mod.stringParam(params, "cwd") orelse break :blk null;
        if (git_dir.len == 0 or cwd.len == 0) break :blk null;
        break :blk project_mod.resolveGitDir(arena, git_dir, cwd) catch null;
    };

    if (canonical) |path| {
        if (try d.store.findProject(path)) |project_id| {
            const summary = try views.summaryFor(d, arena, project_id, path);
            board.project = summary;

            // Every run, because the branch join below needs the run that produced an
            // old issue's branch; only the newest are sent back for display.
            const runs = try d.store.listRuns(arena, project_id, std.math.maxInt(u32));
            board.runs = try views.runModels(arena, runs[0..@min(runs.len, views.run_list_limit)]);
            board.issues = try boardIssues(d, arena, project_id, summary.replica, runs);
        }
    }

    return api.writeOk(w, request.id, board);
}

/// The issue rows the board lists, each joined to what is happening to it.
///
/// Both joins happen here rather than in the board because both need something the
/// board cannot see: the live run comes from the same query `run start` refuses on,
/// so the dashboard and the refusal can never disagree, and the commit count comes
/// from the last VM probe.
fn boardIssues(
    d: *Daemon,
    arena: std.mem.Allocator,
    project_id: ids.Id,
    replica: []const u8,
    runs: []const store_mod.Store.RunRow,
) ![]const api.BoardIssue {
    const rows = try d.store.listIssues(arena, project_id, null);
    const live = try d.store.activeRunForProject(arena, project_id);

    const out = try arena.alloc(api.BoardIssue, rows.len);
    for (rows, out) |row, *o| {
        const short = ids.short(row.id);

        var run: ?[]const u8 = null;
        if (live) |active| {
            if (std.mem.eql(u8, &active.issue_id, &row.id)) {
                const run_short = ids.short(active.run_id);
                run = try arena.dupe(u8, &run_short);
            }
        }

        o.* = .{
            .short = try arena.dupe(u8, &short),
            .state = row.state,
            .title = row.title,
            .created_at = row.created_at,
            .run = run,
            .commits = commitsWaiting(d.snapshot, replica, branchFor(runs, row.id)),
        };
    }
    return out;
}

/// The branch of this issue's most recent run, or null if it never had one. `runs`
/// arrives newest first, so the first match is the one that matters.
fn branchFor(runs: []const store_mod.Store.RunRow, issue_id: ids.Id) ?[]const u8 {
    for (runs) |run| {
        if (std.mem.eql(u8, &run.issue_id, &issue_id)) return run.branch;
    }
    return null;
}

/// Commits waiting on `branch` according to the last probe.
///
/// Null rather than zero when the VM is unreachable or the issue never had a run:
/// "nothing is waiting" and "nobody looked" are different answers, and rendering them
/// alike would report unseen work as finished. Zero is reserved for the case the probe
/// actually answered — the branch is there and has nothing on it.
fn commitsWaiting(snapshot: world_mod.Snapshot, replica: []const u8, branch: ?[]const u8) ?u64 {
    const name = branch orelse return null;
    if (!snapshot.reachable) return null;
    for (snapshot.branches) |b| {
        if (std.mem.eql(u8, b.project, replica) and std.mem.eql(u8, b.name, name)) {
            return b.commits;
        }
    }
    return 0;
}

const testing = std.testing;

fn testId(byte: u8) ids.Id {
    return @splat(byte);
}

test "an issue's branch comes from its newest run, not its first" {
    // `listRuns` returns newest first. An issue re-run after a reset has two branches in
    // the table and only the later one is the branch anything is waiting on.
    const runs = [_]store_mod.Store.RunRow{
        .{
            .id = testId(9),
            .issue_id = testId(1),
            .project_id = testId(0),
            .branch = "capsule/second",
            .state = .active,
            .started_at = 200,
            .ended_at = null,
        },
        .{
            .id = testId(2),
            .issue_id = testId(1),
            .project_id = testId(0),
            .branch = "capsule/first",
            .state = .ended,
            .started_at = 100,
            .ended_at = 150,
        },
    };
    try testing.expectEqualStrings("capsule/second", branchFor(&runs, testId(1)).?);
    try testing.expectEqual(@as(?[]const u8, null), branchFor(&runs, testId(3)));
    try testing.expectEqual(@as(?[]const u8, null), branchFor(&.{}, testId(1)));
}

test "an unreachable VM leaves the commit count unknown rather than zero" {
    const branches = [_]world_mod.Branch{.{ .project = "mine", .name = "capsule/x", .commits = 4 }};

    const down = world_mod.Snapshot{ .reachable = false, .branches = &branches };
    try testing.expectEqual(@as(?u64, null), commitsWaiting(down, "mine", "capsule/x"));

    const up = world_mod.Snapshot{ .reachable = true, .branches = &branches };
    try testing.expectEqual(@as(?u64, 4), commitsWaiting(up, "mine", "capsule/x"));
}

test "an issue that never ran has no branch and so no count" {
    const up = world_mod.Snapshot{ .reachable = true };
    try testing.expectEqual(@as(?u64, null), commitsWaiting(up, "mine", null));
}

test "a branch the probe did not list has nothing waiting on it" {
    // Swept after a merge: the branch is gone from the replica, which is zero waiting and
    // not "unknown" — the probe looked and it was not there.
    const up = world_mod.Snapshot{ .reachable = true, .branches = &.{} };
    try testing.expectEqual(@as(?u64, 0), commitsWaiting(up, "mine", "capsule/x"));
}

test "another project's branch of the same name is not counted as this one's" {
    // Replica names are `<basename>-<hash>`, so two checkouts of the same repository
    // produce identical branch names under different projects.
    const branches = [_]world_mod.Branch{
        .{ .project = "capsule-aaaaaaaa", .name = "capsule/x", .commits = 7 },
        .{ .project = "capsule-bbbbbbbb", .name = "capsule/x", .commits = 2 },
    };
    const up = world_mod.Snapshot{ .reachable = true, .branches = &branches };
    try testing.expectEqual(@as(?u64, 7), commitsWaiting(up, "capsule-aaaaaaaa", "capsule/x"));
    try testing.expectEqual(@as(?u64, 2), commitsWaiting(up, "capsule-bbbbbbbb", "capsule/x"));
    try testing.expectEqual(@as(?u64, 0), commitsWaiting(up, "capsule-cccccccc", "capsule/x"));
}
