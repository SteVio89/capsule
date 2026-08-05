//! What the dashboard shows, as a pure function of the world model.

const std = @import("std");
const screen = @import("screen.zig");
const list_mod = @import("list.zig");
const api = @import("../api.zig");
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

/// What the board remembers between frames.
///
/// `render` is a pure snapshot-to-Screen function and the tests depend on that, so the
/// cursor cannot live inside it — the daemon is polled and a new frame arrives every
/// second, which would reset the selection under the user's hand. It lives here instead
/// and is threaded through, leaving `render` pure and the selection stable.
pub const State = struct {
    issues: list_mod.List = .{},

    /// Re-applies the list's invariants against however many issues this frame brought.
    /// Called before rendering because the count changes underneath the cursor whenever
    /// an agent files something or a merge completes.
    pub fn sync(self: *State, count: usize, height: usize) void {
        self.issues.len = count;
        self.issues.height = height;
        self.issues.clamp();
    }

    /// The issue the cursor is on, or null when there are none.
    pub fn selected(self: State, issues: []const api.BoardIssue) ?api.BoardIssue {
        if (issues.len == 0 or self.issues.cursor >= issues.len) return null;
        return issues[self.issues.cursor];
    }
};

/// Lays the whole dashboard out into a fresh w-by-h `Screen`. Pure — no terminal, no
/// clock, no socket; `now_ms` comes in so age rendering is testable, and `state` comes in
/// so the selection survives a frame. The caller owns the returned screen and must
/// `deinit` it with the same `gpa`.
pub fn render(
    gpa: std.mem.Allocator,
    snapshot: world.Snapshot,
    project: ?Project,
    issues: []const api.BoardIssue,
    state: State,
    now_ms: i64,
    w: usize,
    h: usize,
) !Screen {
    var s = try Screen.init(gpa, w, h);
    errdefer s.deinit(gpa);

    // Against a local copy, so `render` stays pure and cannot be handed a state whose
    // `len` still says zero — which would draw an empty list over a full backlog. The
    // caller syncs too, because its key handling needs the cursor clamped before the
    // next frame; doing it in both places is what makes neither depend on the other.
    var view = state;
    view.sync(issues.len, listHeight(project != null, h));

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

    // The issue list is the board, so it gets whatever height is left after the panels
    // that frame it — and it is drawn before them, because a list that shrinks to nothing
    // on a short terminal is the one thing here that must not happen.
    if (project != null or issues.len > 0) {
        y = renderIssueList(&s, issues, view, y, listHeight(project != null, h));
        y += 1;
    }
    if (project) |p| {
        y = renderMemory(&s, p, y);
        y += 1;
    }
    y = renderContainers(&s, snapshot, y);
    y += 1;
    y = renderBranches(&s, snapshot, project, y);

    if (h >= 2) s.write(0, h - 1, "q quit   r refresh   ↑↓ select", .{ .fg = .dim });
    return s;
}

/// How many issue rows the list gets on a terminal `h` rows tall.
///
/// Public because the caller needs it *before* `render`: the cursor is clamped against the
/// viewport height, and a height the list only discovers while drawing is one the cursor
/// can already have walked off the end of.
///
/// Approximate by construction. The panels around the list are variable-length, so this
/// reserves a fixed budget rather than measuring — measuring would mean rendering twice.
/// Reserving slightly too much costs one row; too little pushes the panels below off the
/// bottom, which is worse. `renderIssueList` still stops at the screen edge regardless.
pub fn listHeight(has_project: bool, h: usize) usize {
    const chrome: usize = if (has_project) 15 else 11;
    if (h <= chrome) return 1;
    return h - chrome;
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

/// The issue list — the thing the board is for.
///
/// This replaced a panel of seven counters. The counters were not wrong, they were
/// unusable: "3 open" cannot be selected, opened, or acted on, and the titles that would
/// tell you *which* three were only ever in SQLite. A row per issue is what makes the id
/// something you never have to type.
fn renderIssueList(
    s: *Screen,
    issues: []const api.BoardIssue,
    state: State,
    start: usize,
    height: usize,
) usize {
    var y = start;
    s.write(0, y, "issues", .{ .bold = true });

    var head: [32]u8 = undefined;
    if (issues.len > 0) {
        const count = std.fmt.bufPrint(&head, "{d}", .{issues.len}) catch "?";
        if (s.w > 12) s.write(8, y, count, .{ .fg = .dim });
    }
    y += 1;

    if (issues.len == 0) {
        if (y < s.h) s.write(2, y, "none yet — 'capsule issue new <title>'", .{ .fg = .dim });
        return y + 1;
    }

    const limit = start + 1 + height;
    const range = state.issues.visible();
    for (range.start..range.end) |i| {
        if (y >= limit or y >= s.h) break;
        renderIssueRow(s, issues[i], state.issues.styleFor(i, .{}), y);
        y += 1;
    }

    // Said only when it is true, and it is the one fact the viewport hides.
    if (range.end < issues.len and y < s.h) {
        var buf: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&buf, "{d} more below", .{issues.len - range.end}) catch "more";
        s.write(2, y, more, .{ .fg = .dim });
        y += 1;
    }

    // Counted from the rows rather than from the summary's `proposed` tally: the list is
    // what is on screen, so a hint derived from it cannot disagree with what you can see.
    // Named as the command that clears it — the board reports, the CLI acts.
    var proposed: usize = 0;
    for (issues) |issue| {
        if (issue.state == .proposed) proposed += 1;
    }
    if (proposed > 0 and y < s.h) {
        var buf: [64]u8 = undefined;
        const hint = std.fmt.bufPrint(&buf, "{d} awaiting triage — capsule issue triage", .{proposed}) catch "";
        s.write(2, y, hint, .{ .fg = .cyan });
        y += 1;
    }
    return y;
}

fn renderIssueRow(s: *Screen, issue: api.BoardIssue, base: Style, y: usize) void {
    // The selected row is reverse video across its whole width, so the blank between
    // columns has to carry the style too — otherwise the highlight comes out striped.
    if (base.reverse) {
        for (s.row(y)) |*cell| cell.* = .{ .ch = ' ', .style = base };
    }

    // A live run is the one thing worth a mark in the margin: `in_progress` alone means
    // both "an agent is working" and "an agent stopped and nobody noticed".
    if (issue.run != null) s.write(0, y, "●", withFg(base, .green));
    s.write(2, y, issue.short, base);

    const label = stateLabel(issue.state);
    s.write(12, y, label, withFg(base, stateColour(issue.state)));

    const title_x = 24;
    if (s.w > title_x + 4) {
        // Reserve the right-hand column so a long title cannot run into the commit count.
        const commits_room: usize = if (issue.commits) |c| if (c > 0) 12 else 0 else 0;
        const room = s.w - title_x - commits_room;
        const title = truncate(issue.title, room);
        s.write(title_x, y, title.text, base);
        if (title.cut) {
            s.write(title_x + screen.displayWidth(title.text), y, "…", withFg(base, .dim));
        }
    }

    if (issue.commits) |c| {
        if (c > 0 and s.w > 14) {
            var buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d} commit{s}", .{ c, if (c == 1) "" else "s" }) catch "?";
            if (s.w > text.len) s.write(s.w - text.len, y, text, withFg(base, .cyan));
        }
    }
}

/// A style with a different foreground, keeping whatever else the base carries.
///
/// A selected row is reverse video, and reverse swaps foreground and background — so a
/// colour set on top of it still reads, while replacing the style outright would drop the
/// highlight for that one column.
fn withFg(base: Style, fg: screen.Color) Style {
    var out = base;
    out.fg = fg;
    return out;
}

fn stateLabel(state: model.Issue.State) []const u8 {
    return switch (state) {
        .proposed => "proposed",
        .open => "open",
        .in_progress => "running",
        .blocked => "blocked",
        .ready_for_review => "ready",
        .done => "done",
        .archived => "archived",
    };
}

fn stateColour(state: model.Issue.State) screen.Color {
    return switch (state) {
        .blocked => .red,
        .ready_for_review => .green,
        .in_progress => .yellow,
        .proposed => .cyan,
        .done, .archived => .dim,
        .open => .default,
    };
}

/// `text` cut to fit `columns`, and whether anything was cut.
///
/// By display width, not bytes: `Screen.write` already stops at the screen edge, but a
/// title cut there gives no sign it was cut and would run into the commit count to its
/// right. The last column is left for the ellipsis the caller writes.
const Truncated = struct { text: []const u8, cut: bool };

fn truncate(text: []const u8, columns: usize) Truncated {
    if (columns == 0) return .{ .text = "", .cut = text.len > 0 };
    if (screen.displayWidth(text) <= columns) return .{ .text = text, .cut = false };
    if (columns == 1) return .{ .text = "", .cut = true };

    var used: usize = 0;
    var end: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const w = screen.width(cp);
        if (used + w > columns - 1) break;
        used += w;
        end = iter.i;
    }
    return .{ .text = text[0..end], .cut = true };
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
    var s = try render(testing.allocator, .{}, null, &.{}, .{}, 1000, 80, 24);
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
    var s = try render(testing.allocator, snapshot, null, &.{}, .{}, 12_000, 80, 24);
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
    var s = try render(testing.allocator, snapshot, null, &.{}, .{}, 1, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "1 commit")) != null);
    try testing.expect((try findRow(s, "1 commits")) == null);
}

test "empty sections say so rather than leaving a gap" {
    const snapshot = world.Snapshot{ .reachable = true, .observed_at_ms = 1 };
    var s = try render(testing.allocator, snapshot, null, &.{}, .{}, 1, 80, 24);
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
    var s = try render(testing.allocator, snapshot, null, &.{}, .{}, 1, 80, 24);
    defer s.deinit(testing.allocator);
    const y = (try findRow(s, "95%")).?;
    try testing.expectEqual(screen.Color.red, s.row(y)[12].style.fg);

    snapshot.disk_used = 10 * (1 << 30);
    var ok = try render(testing.allocator, snapshot, null, &.{}, .{}, 1, 80, 24);
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
            var s = try render(testing.allocator, snapshot, null, &.{}, .{}, 1, w, h);
            defer s.deinit(testing.allocator);
            try testing.expectEqual(w * h, s.cells.len);
        }
    }
}

/// A handful of issues in the states that read differently on the board.
const sample_issues = [_]api.BoardIssue{
    .{ .short = "3f2a1b9c", .state = .in_progress, .title = "make the board useful", .created_at = 1, .run = "019fb1ce", .commits = 4 },
    .{ .short = "b8e01d77", .state = .ready_for_review, .title = "split zig and bash", .created_at = 2, .run = null, .commits = 7 },
    .{ .short = "9c4a2f01", .state = .open, .title = "port vm start", .created_at = 3, .run = null, .commits = null },
    .{ .short = "55aa10ff", .state = .proposed, .title = "agent: add wcwidth", .created_at = 4, .run = null, .commits = 0 },
};

fn renderSample(state: State, w: usize, h: usize) !Screen {
    return render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{ .memory_active = 12 },
        &sample_issues,
        state,
        1,
        w,
        h,
    );
}

test "every issue is a row, with its id, state and title" {
    var s = try renderSample(.{}, 100, 40);
    defer s.deinit(testing.allocator);

    // The counters this replaced could say "3 open" and never which three.
    try testing.expect((try findRow(s, "3f2a1b9c")) != null);
    try testing.expect((try findRow(s, "make the board useful")) != null);
    try testing.expect((try findRow(s, "running")) != null);
    try testing.expect((try findRow(s, "ready")) != null);
    try testing.expect((try findRow(s, "4 commits")) != null);
}

test "triage is named as a command and never as an action" {
    var s = try renderSample(.{}, 100, 40);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "1 awaiting triage — capsule issue triage")) != null);
}

test "the selected row is the only one drawn reversed" {
    var state = State{};
    state.sync(sample_issues.len, 10);
    state.issues.moveTo(1);

    var s = try renderSample(state, 100, 40);
    defer s.deinit(testing.allocator);

    const selected = (try findRow(s, "b8e01d77")).?;
    const other = (try findRow(s, "3f2a1b9c")).?;
    try testing.expect(s.row(selected)[0].style.reverse);
    try testing.expect(!s.row(other)[0].style.reverse);

    // Across the whole width, not just where the text is: a highlight that stops at the
    // last character reads as a stripe rather than a selection.
    for (s.row(selected)) |cell| try testing.expect(cell.style.reverse);
}

test "a live run is marked, and a stalled one is not" {
    var s = try renderSample(.{}, 100, 40);
    defer s.deinit(testing.allocator);

    // `in_progress` alone cannot tell "an agent is working" from "an agent stopped".
    const live = (try findRow(s, "3f2a1b9c")).?;
    const idle = (try findRow(s, "9c4a2f01")).?;
    try testing.expectEqual(@as(u21, '●'), s.row(live)[0].ch);
    try testing.expectEqual(@as(u21, ' '), s.row(idle)[0].ch);
}

test "an empty backlog says what to type instead of drawing a blank pane" {
    var s = try render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{},
        &.{},
        .{},
        1,
        100,
        40,
    );
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "capsule issue new")) != null);
}

test "a viewport smaller than the backlog says how much it is hiding" {
    // A short terminal, which is the only way the viewport is ever smaller in practice.
    var s = try renderSample(.{}, 100, 17);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "2 more below")) != null);
}

test "a title too wide for its column is cut with an ellipsis" {
    const long = [_]api.BoardIssue{.{
        .short = "aaaaaaaa",
        .state = .open,
        .title = "a title far longer than the column it has been given to live in",
        .created_at = 1,
        .run = null,
        .commits = 9,
    }};
    var s = try render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{},
        &long,
        .{},
        1,
        60,
        40,
    );
    defer s.deinit(testing.allocator);

    const y = (try findRow(s, "aaaaaaaa")).?;
    const text = try s.rowText(testing.allocator, y);
    defer testing.allocator.free(text);

    // Cut, marked as cut, and still clear of the commit count on the right.
    try testing.expect(std.mem.indexOf(u8, text, "…") != null);
    try testing.expect(std.mem.indexOf(u8, text, "9 commits") != null);
    try testing.expect(std.mem.indexOf(u8, text, "live in") == null);
}

test "the memory panel shows the cap and warns at it" {
    const under = Project{ .memory_active = 12, .memory_cap = 40, .memory_tokens = 900 };
    var a = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, under, &.{}, .{}, 1, 100, 40);
    defer a.deinit(testing.allocator);
    const row = (try findRow(a, "12/40 active")).?;
    try testing.expectEqual(screen.Color.default, a.row(row)[12].style.fg);

    const at_cap = Project{ .memory_active = 40, .memory_cap = 40, .memory_proposed = 3 };
    var b = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, at_cap, &.{}, .{}, 1, 100, 40);
    defer b.deinit(testing.allocator);
    const capped = (try findRow(b, "40/40 active")).?;
    try testing.expectEqual(screen.Color.yellow, b.row(capped)[12].style.fg);
    try testing.expect((try findRow(b, "3 proposed — capsule memory review")) != null);
}

test "the token estimate is labelled approximate" {
    const p = Project{ .memory_active = 40, .memory_tokens = 3400, .memory_over_budget = true };
    var s = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, p, &.{}, .{}, 1, 100, 40);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "~3400 (approx)")) != null);
}

test "a claim with no commits is called out, and so is the reverse" {
    const claimed = Project{ .issues = .{ 0, 0, 0, 0, 2, 0, 0 } };
    var a = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, claimed, &.{}, .{}, 1, 100, 40);
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
    var b = try render(testing.allocator, snapshot, silent, &.{}, .{}, 1, 100, 40);
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
    var s = try render(testing.allocator, snapshot, idle, &.{}, .{}, 1, 100, 40);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "never reported")) == null);
    try testing.expect((try findRow(s, "claimed ready")) == null);
    try testing.expect((try findRow(s, "capsule/a")) != null);
}

test "without a project the board still renders the VM alone" {
    var s = try render(testing.allocator, .{ .reachable = true, .observed_at_ms = 1 }, null, &.{}, .{}, 1, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "issues")) == null);
    try testing.expect((try findRow(s, "memory")) == null);
    try testing.expect((try findRow(s, "state")) != null);
}
