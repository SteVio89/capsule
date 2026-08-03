//! What the dashboard shows, as a pure function of the world model.

const std = @import("std");
const screen = @import("screen.zig");
const world = @import("../world.zig");
const model = @import("../model.zig");

const Screen = screen.Screen;
const Style = screen.Style;

/// What the daemon knows about the project the board is pointed at. Null when `capsule
/// board` was run outside a registered project, in which case only the VM panel is shown.
pub const Project = struct {
    name: []const u8 = "",
    /// The project's replica directory name on the VM, which is how its rows in
    /// `Snapshot.branches` are recognised. Empty when the daemon did not say.
    replica: []const u8 = "",
    /// Indexed by `@intFromEnum` of the issue state.
    issues: [7]usize = .{0} ** 7,
    memory_active: usize = 0,
    memory_cap: usize = 40,
    memory_proposed: usize = 0,
    memory_tokens: usize = 0,
    memory_over_budget: bool = false,
};

/// Lays the whole dashboard out into a fresh w-by-h `Screen`. Pure — no terminal, no
/// clock, no socket; `now_ms` comes in so age rendering is testable. The caller owns
/// the returned screen and must `deinit` it with the same `gpa`.
pub fn render(
    gpa: std.mem.Allocator,
    snapshot: world.Snapshot,
    project: ?Project,
    now_ms: i64,
    w: usize,
    h: usize,
) !Screen {
    var s = try Screen.init(gpa, w, h);
    errdefer s.deinit(gpa);

    var y: usize = 0;
    s.write(0, y, "capsule", .{ .bold = true });
    var age_buf: [32]u8 = undefined;
    const age = if (snapshot.observed_at_ms == 0)
        "never polled"
    else
        std.fmt.bufPrint(&age_buf, "{d}s ago", .{
            @max(0, @divTrunc(now_ms -| snapshot.observed_at_ms, 1000)),
        }) catch "?";
    if (w > 20) s.write(w - age.len, y, age, .{ .fg = .dim });
    y += 2;

    y = renderVm(&s, snapshot, y);
    y += 1;
    if (project) |p| {
        y = renderIssues(&s, p, y);
        y += 1;
        y = renderMemory(&s, p, y);
        y += 1;
    }
    y = renderContainers(&s, snapshot, y);
    y += 1;
    y = renderBranches(&s, snapshot, project, y);

    if (h >= 2) s.write(0, h - 1, "q quit   r refresh   p project", .{ .fg = .dim });
    return s;
}

fn renderVm(s: *Screen, snapshot: world.Snapshot, start: usize) usize {
    var y = start;
    s.write(0, y, "VM", .{ .bold = true });
    y += 1;

    if (!snapshot.reachable) {
        s.writeKeyValue(2, y, "state", "unreachable", .{ .fg = .red });
        return y + 1;
    }
    s.writeKeyValue(2, y, "state", "up", .{ .fg = .green });
    y += 1;

    if (snapshot.uptime_s) |up| {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}h {d}m", .{ up / 3600, (up % 3600) / 60 }) catch "?";
        s.writeKeyValue(2, y, "uptime", text, .{});
        y += 1;
    }

    if (snapshot.disk_used) |used| {
        var buf: [64]u8 = undefined;
        const total = snapshot.disk_total orelse 0;
        const pct: u64 = if (total > 0) used * 100 / total else 0;
        const text = std.fmt.bufPrint(&buf, "{d} GB of {d} GB ({d}%)", .{
            used / (1 << 30), total / (1 << 30), pct,
        }) catch "?";
        const style: Style = if (pct >= 90) .{ .fg = .red } else if (pct >= 75) .{ .fg = .yellow } else .{};
        s.writeKeyValue(2, y, "disk", text, style);
        y += 1;
    }
    return y;
}

/// Issues by state, and the triage count with the command that clears it.
fn renderIssues(s: *Screen, p: Project, start: usize) usize {
    var y = start;
    s.write(0, y, "issues", .{ .bold = true });
    y += 1;

    const labels = [_][]const u8{ "proposed", "open", "in progress", "blocked", "ready", "done", "archived" };
    var any = false;
    for (labels, 0..) |label, i| {
        if (p.issues[i] == 0) continue;
        if (y >= s.h) return y;
        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{p.issues[i]}) catch "?";
        const style: Style = switch (i) {
            3 => .{ .fg = .red },
            4 => .{ .fg = .green },
            else => .{},
        };
        s.writeKeyValue(2, y, label, count, style);
        y += 1;
        any = true;
    }
    if (!any) {
        s.write(2, y, "none yet", .{ .fg = .dim });
        y += 1;
    }
    if (p.issues[0] > 0 and y < s.h) {
        var buf: [64]u8 = undefined;
        const hint = std.fmt.bufPrint(&buf, "{d} awaiting triage — capsule issue triage", .{p.issues[0]}) catch "";
        s.write(2, y, hint, .{ .fg = .yellow });
        y += 1;
    }
    return y;
}

fn renderMemory(s: *Screen, p: Project, start: usize) usize {
    var y = start;
    s.write(0, y, "memory", .{ .bold = true });
    y += 1;

    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}/{d} active", .{ p.memory_active, p.memory_cap }) catch "?";
    const style: Style = if (p.memory_active >= p.memory_cap) .{ .fg = .yellow } else .{};
    s.writeKeyValue(2, y, "active", text, style);
    y += 1;

    if (p.memory_tokens > 0 and y < s.h) {
        var tb: [64]u8 = undefined;
        const tokens = std.fmt.bufPrint(&tb, "~{d} (approx)", .{p.memory_tokens}) catch "?";
        s.writeKeyValue(2, y, "tokens", tokens, if (p.memory_over_budget) .{ .fg = .yellow } else .{});
        y += 1;
    }
    if (p.memory_proposed > 0 and y < s.h) {
        var pb: [64]u8 = undefined;
        const hint = std.fmt.bufPrint(&pb, "{d} proposed — capsule memory review", .{p.memory_proposed}) catch "";
        s.write(2, y, hint, .{ .fg = .yellow });
        y += 1;
    }
    return y;
}

fn renderContainers(s: *Screen, snapshot: world.Snapshot, start: usize) usize {
    var y = start;
    s.write(0, y, "containers", .{ .bold = true });
    y += 1;
    if (snapshot.containers.len == 0) {
        s.write(2, y, "none running", .{ .fg = .dim });
        return y + 1;
    }
    for (snapshot.containers) |container| {
        if (y >= s.h) return y;
        s.write(2, y, container.name, .{ .fg = .cyan });
        s.write(28, y, container.image, .{ .fg = .dim });
        y += 1;
    }
    return y;
}

fn renderBranches(s: *Screen, snapshot: world.Snapshot, project: ?Project, start: usize) usize {
    var y = start;
    s.write(0, y, "branches waiting", .{ .bold = true });
    y += 1;

    var shown: usize = 0;
    var project_shown: usize = 0;
    for (snapshot.branches) |branch| {
        if (branch.commits == 0) continue;
        if (project) |p| {
            if (std.mem.eql(u8, branch.project, p.replica)) project_shown += 1;
        }
        if (y >= s.h) continue;
        var buf: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d} commit{s}", .{
            branch.commits, if (branch.commits == 1) "" else "s",
        }) catch "?";
        s.write(2, y, branch.name, .{ .fg = .yellow });
        s.write(44, y, count, .{});
        y += 1;
        shown += 1;
    }
    if (shown == 0) {
        s.write(2, y, "nothing waiting", .{ .fg = .dim });
        y += 1;
    }

    if (project) |p| {
        const ready = p.issues[@intFromEnum(model.Issue.State.ready_for_review)];
        if (y < s.h and ready > project_shown) {
            var buf: [72]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d} claimed ready with no commits waiting", .{ready - project_shown}) catch "";
            s.write(2, y, text, .{ .fg = .red });
            y += 1;
        } else if (y < s.h and project_shown > ready) {
            var buf: [72]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d} with commits the agent never reported", .{project_shown - ready}) catch "";
            s.write(2, y, text, .{ .fg = .yellow });
            y += 1;
        }
    }
    return y;
}

const testing = std.testing;

/// Asserts on what a person would see, rather than on a cell array.
fn expectRowContains(s: Screen, y: usize, needle: []const u8) !void {
    const text = try s.rowText(testing.allocator, y);
    defer testing.allocator.free(text);
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("row {d} is \"{s}\", expected it to contain \"{s}\"\n", .{ y, text, needle });
        return error.RowMismatch;
    }
}

fn findRow(s: Screen, needle: []const u8) !?usize {
    for (0..s.h) |y| {
        const text = try s.rowText(testing.allocator, y);
        defer testing.allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return y;
    }
    return null;
}

test "an unreachable VM says so and shows no figures" {
    var s = try render(testing.allocator, .{}, null, 1000, 80, 24);
    defer s.deinit(testing.allocator);

    try expectRowContains(s, 0, "capsule");
    try expectRowContains(s, 0, "never polled");
    try testing.expect((try findRow(s, "unreachable")) != null);
    try testing.expect((try findRow(s, "uptime")) == null);
    try testing.expect((try findRow(s, "disk")) == null);
}

test "a healthy VM shows uptime, disk, containers and branches" {
    const snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 9_000,
        .uptime_s = 3600 * 5 + 60 * 7,
        .disk_used = 20 * (1 << 30),
        .disk_total = 80 * (1 << 30),
        .containers = &.{.{ .name = "capsule-018f2a1c", .image = "ghcr.io/x/capsule:latest" }},
        .branches = &.{
            .{ .project = "p", .name = "capsule/018f2a1c", .commits = 3 },
            .{ .project = "p", .name = "capsule/018f2a3d", .commits = 0 },
        },
    };
    var s = try render(testing.allocator, snapshot, null, 12_000, 80, 24);
    defer s.deinit(testing.allocator);

    try expectRowContains(s, 0, "3s ago");
    try testing.expect((try findRow(s, "5h 7m")) != null);
    try testing.expect((try findRow(s, "20 GB of 80 GB (25%)")) != null);
    try testing.expect((try findRow(s, "capsule-018f2a1c")) != null);

    try testing.expect((try findRow(s, "capsule/018f2a1c")) != null);
    try testing.expect((try findRow(s, "capsule/018f2a3d")) == null);
    try testing.expect((try findRow(s, "3 commits")) != null);
}

test "one commit is not pluralised" {
    const snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 1,
        .branches = &.{.{ .project = "p", .name = "capsule/x", .commits = 1 }},
    };
    var s = try render(testing.allocator, snapshot, null, 1, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "1 commit")) != null);
    try testing.expect((try findRow(s, "1 commits")) == null);
}

test "empty sections say so rather than leaving a gap" {
    const snapshot = world.Snapshot{ .reachable = true, .observed_at_ms = 1 };
    var s = try render(testing.allocator, snapshot, null, 1, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "none running")) != null);
    try testing.expect((try findRow(s, "nothing waiting")) != null);
}

test "a nearly full disk is flagged" {
    var snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 1,
        .disk_used = 76 * (1 << 30),
        .disk_total = 80 * (1 << 30),
    };
    var s = try render(testing.allocator, snapshot, null, 1, 80, 24);
    defer s.deinit(testing.allocator);
    const y = (try findRow(s, "95%")).?;
    try testing.expectEqual(screen.Color.red, s.row(y)[12].style.fg);

    snapshot.disk_used = 10 * (1 << 30);
    var ok = try render(testing.allocator, snapshot, null, 1, 80, 24);
    defer ok.deinit(testing.allocator);
    const oy = (try findRow(ok, "12%")).?;
    try testing.expectEqual(screen.Color.default, ok.row(oy)[12].style.fg);
}

test "a cramped terminal renders without crashing or overflowing" {
    const snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 1,
        .uptime_s = 100,
        .containers = &.{
            .{ .name = "a-very-long-container-name-indeed", .image = "some/very/long/image:tag" },
        },
        .branches = &.{.{ .project = "p", .name = "capsule/aaaaaaaa", .commits = 2 }},
    };
    for ([_]usize{ 1, 5, 20, 40 }) |w| {
        for ([_]usize{ 1, 2, 6, 24 }) |h| {
            var s = try render(testing.allocator, snapshot, null, 1, w, h);
            defer s.deinit(testing.allocator);
            try testing.expectEqual(w * h, s.cells.len);
        }
    }
}

test "issues by state, with triage named as a command and never as an action" {
    const p = Project{
        .issues = .{ 2, 3, 1, 1, 4, 7, 0 },
        .memory_active = 12,
        .memory_proposed = 0,
    };
    var s = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, p, 1, 100, 40);
    defer s.deinit(testing.allocator);

    try testing.expect((try findRow(s, "proposed")) != null);
    try testing.expect((try findRow(s, "ready")) != null);
    try testing.expect((try findRow(s, "2 awaiting triage — capsule issue triage")) != null);
    try testing.expect((try findRow(s, "archived")) == null);
}

test "the memory panel shows the cap and warns at it" {
    const under = Project{ .memory_active = 12, .memory_cap = 40, .memory_tokens = 900 };
    var a = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, under, 1, 100, 40);
    defer a.deinit(testing.allocator);
    const row = (try findRow(a, "12/40 active")).?;
    try testing.expectEqual(screen.Color.default, a.row(row)[12].style.fg);

    const at_cap = Project{ .memory_active = 40, .memory_cap = 40, .memory_proposed = 3 };
    var b = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, at_cap, 1, 100, 40);
    defer b.deinit(testing.allocator);
    const capped = (try findRow(b, "40/40 active")).?;
    try testing.expectEqual(screen.Color.yellow, b.row(capped)[12].style.fg);
    try testing.expect((try findRow(b, "3 proposed — capsule memory review")) != null);
}

test "the token estimate is labelled approximate" {
    const p = Project{ .memory_active = 40, .memory_tokens = 3400, .memory_over_budget = true };
    var s = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, p, 1, 100, 40);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "~3400 (approx)")) != null);
}

test "a claim with no commits is called out, and so is the reverse" {
    const claimed = Project{ .issues = .{ 0, 0, 0, 0, 2, 0, 0 } };
    var a = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, claimed, 1, 100, 40);
    defer a.deinit(testing.allocator);
    try testing.expect((try findRow(a, "2 claimed ready with no commits waiting")) != null);

    const snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 1,
        .branches = &.{
            .{ .project = "p", .name = "capsule/a", .commits = 3 },
            .{ .project = "p", .name = "capsule/b", .commits = 1 },
        },
    };
    const silent = Project{ .replica = "p", .issues = .{ 0, 0, 2, 0, 0, 0, 0 } }; // in progress, none ready
    var b = try render(testing.allocator, snapshot, silent, 1, 100, 40);
    defer b.deinit(testing.allocator);
    try testing.expect((try findRow(b, "2 with commits the agent never reported")) != null);
}

test "another project's waiting branches do not contradict this project's claims" {
    const snapshot = world.Snapshot{
        .reachable = true,
        .observed_at_ms = 1,
        .branches = &.{
            .{ .project = "other", .name = "capsule/a", .commits = 3 },
            .{ .project = "other", .name = "capsule/b", .commits = 1 },
        },
    };
    const idle = Project{ .replica = "mine", .issues = .{0} ** 7 };
    var s = try render(testing.allocator, snapshot, idle, 1, 100, 40);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "never reported")) == null);
    try testing.expect((try findRow(s, "claimed ready")) == null);
    try testing.expect((try findRow(s, "capsule/a")) != null);
}

test "without a project the board still renders the VM alone" {
    var s = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, null, 1, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "issues")) == null);
    try testing.expect((try findRow(s, "memory")) == null);
    try testing.expect((try findRow(s, "state")) != null);
}
