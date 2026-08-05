//! What the dashboard shows, as a pure function of the world model.

const std = @import("std");
const screen = @import("screen.zig");
const list_mod = @import("list.zig");
const api = @import("../api.zig");
const world = @import("../world.zig");
const model = @import("../model.zig");
const cli = @import("../cli.zig");

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
/// Which main view is on screen.
///
/// The board opens on `overview` — what is true right now, at a glance — and a command
/// switches it. `issue list` is not a panel that is always there taking space; it is a
/// view you ask for, the same way you would have typed the command.
pub const View = enum { overview, issues };

pub const State = struct {
    view: View = .overview,
    /// Which state the issue view is showing, or null for all of them.
    filter: ?model.Issue.State = null,
    issues: list_mod.List = .{},
    /// Whether the event log for the selected issue is open. The board otherwise reports
    /// that an issue is blocked without ever saying who blocked it or why — the log has
    /// been written since the first commit and read by nothing.
    detail: bool = false,
    /// The command group the reader has opened, or empty at the top level. A slice of a
    /// `menu_groups` literal, so it outlives any frame.
    menu: []const u8 = "",

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
    view.sync(issues.len, listHeight(h));

    var y: usize = 0;
    s.write(0, y, "capsule", .{ .bold = true });
    if (view.view == .issues) {
        // Named here rather than in the menu line, which has no room for it once eight
        // group labels are on it. A filter you cannot see is a list that looks incomplete.
        var head: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&head, "issues · {s}", .{filterLabel(view.filter)}) catch "issues";
        s.write(8, y, text, .{ .fg = .cyan });
    }

    var age_buf: [32]u8 = undefined;
    const age = if (snapshot.observed_at_ms == 0)
        "never polled"
    else
        std.fmt.bufPrint(&age_buf, "{d}s ago", .{
            @max(0, @divTrunc(now_ms -| snapshot.observed_at_ms, 1000)),
        }) catch "?";
    if (w > 20) s.write(w - age.len, y, age, .{ .fg = .dim });
    y += 2;

    switch (view.view) {
        // The list gets the whole screen when it *is* the screen: two rows of chrome
        // above and the menu below, rather than the leftovers of five panels.
        .issues => _ = renderIssueList(&s, issues, view, y, listHeight(h)),
        .overview => renderOverview(&s, snapshot, project, issues, y, h),
    }

    if (h >= 2) renderMenu(&s, view, h - 1);
    return s;
}

/// What is true right now, at a glance: the VM, what is running, what is waiting on you.
///
/// Deliberately **not** the issue list. A list of every issue is a thing you go and look
/// at; an overview is a thing you glance at, and a panel that grows without bound is the
/// opposite of a glance. What appears here is only what would make you act.
fn renderOverview(
    s: *Screen,
    snapshot: world.Snapshot,
    project: ?Project,
    issues: []const api.BoardIssue,
    start: usize,
    h: usize,
) void {
    var y = renderVm(s, snapshot, start);
    y += 1;

    if (project) |p| {
        y = renderPending(s, p, issues, y);
        y += 1;
        y = renderMemory(s, p, y);
        y += 1;
    }
    y = renderContainers(s, snapshot, y);
    y += 1;
    _ = renderBranches(s, snapshot, project, y);
    _ = h;
}

/// The counts that mean someone has to do something, and the running work.
///
/// `done` and `archived` are absent on purpose: they are the states that need nothing from
/// you, and an overview that lists them buries the four that do.
fn renderPending(s: *Screen, p: Project, issues: []const api.BoardIssue, start: usize) usize {
    var y = start;
    s.write(0, y, "issues", .{ .bold = true });
    y += 1;

    const wanted = [_]model.Issue.State{ .proposed, .in_progress, .blocked, .ready_for_review };
    var any = false;
    for (wanted) |state| {
        const n = p.issues[@intFromEnum(state)];
        if (n == 0 or y >= s.h) continue;
        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
        s.writeKeyValue(2, y, stateLabel(state), count, .{ .fg = stateColour(state) });
        y += 1;
        any = true;
    }
    if (!any and y < s.h) {
        s.write(2, y, "nothing waiting on you", .{ .fg = .dim });
        y += 1;
    }

    // Named, not counted: which issue an agent is on is the one thing here you might act
    // on immediately, and a number cannot be attached to.
    for (issues) |issue| {
        if (issue.run == null or y >= s.h) continue;
        s.write(2, y, "●", .{ .fg = .green });
        s.write(4, y, issue.short, .{});
        s.write(14, y, truncate(issue.title, s.w -| 16).text, .{ .fg = .dim });
        y += 1;
    }
    return y;
}

/// Whether an issue belongs in the view under `filter`.
pub fn matches(issue: api.BoardIssue, filter: ?model.Issue.State) bool {
    const want = filter orelse return true;
    return issue.state == want;
}

/// The filters the issue view offers, in the order their keys are claimed. Null is "all".
pub const filters = [_]?model.Issue.State{
    null,     .proposed,         .open, .in_progress,
    .blocked, .ready_for_review, .done, .archived,
};

/// The menu line: where the reader is, and every key available from there.
///
/// Always drawn, never a mode the reader has to remember being in. The whole point of
/// deriving keys from `cli.zig` is that nothing here has to be memorised — a command you
/// can reach is a command you can see, and it is spelled the way you would have typed it.
fn renderMenu(s: *Screen, state: State, y: usize) void {
    var buf: [32]Entry = undefined;
    const entries = if (state.menu.len == 0) groupEntries(&buf) else verbEntries(&buf, state.menu);

    // The hint is placed first and kept: it is the only thing here that says how to get
    // back, and the eight group labels alone are 69 columns — on an 80-column terminal
    // something must give, and it must not be the way out. The keys truncate instead,
    // which costs nothing, because pressing one is how you discover it anyway.
    const hint = if (state.menu.len > 0)
        "esc back"
    else if (state.view != .overview)
        "f filter   esc overview"
    else
        "q quit";

    const hint_w = screen.displayWidth(hint);
    const limit = if (s.w > hint_w + 2) s.w - hint_w - 2 else 0;
    if (limit > 0) s.write(s.w - hint_w, y, hint, .{ .fg = .dim });

    var x: usize = 0;
    if (state.menu.len > 0) {
        // The group name in normal weight against dim keys: which mode you are in is the
        // one thing that must not be as quiet as the list of ways out of it.
        s.write(x, y, state.menu, .{ .bold = true });
        x += screen.displayWidth(state.menu) + 2;
    }

    for (entries) |entry| {
        const width = 2 + screen.displayWidth(entry.label) + 2;
        if (x + width > limit) break;
        s.write(x, y, &[_]u8{entry.key}, .{ .fg = .cyan });
        s.write(x + 2, y, entry.label, .{ .fg = .dim });
        x += width;
    }
}

/// What the current filter is called, including when there isn't one.
pub fn filterLabel(filter: ?model.Issue.State) []const u8 {
    return if (filter) |state| stateLabel(state) else "all";
}

/// The command groups the menu offers, in the order they claim their keys.
///
/// Deliberately **not** `cli.commands`' declaration order, which exists for the help text:
/// that order reaches `image` before `issue` and would hand `i` to the command you run
/// once a month instead of the one you run all day. The membership still comes from the
/// table, so a new group appears here by being added there.
pub const menu_groups = [_][]const u8{
    "issue", "run", "vm", "project", "memory", "env", "image", "daemon",
};

/// Keys the dashboard keeps for itself, so the menu never steals one.
const reserved_keys = "qjkgG";

/// One entry in the menu: the key that triggers it, and what it is.
pub const Entry = struct {
    key: u8,
    /// What the reader sees — a group name at the top level, a verb inside one.
    label: []const u8,
    /// Empty at the top level, where choosing an entry opens a group rather than running
    /// anything.
    verb: []const u8 = "",
    /// `cli.Command.args`, which is how the dispatcher knows whether this verb wants the
    /// selected issue or a line of text.
    args: []const u8 = "",
};

/// The first character of `label` nobody has claimed, else its next free one.
///
/// Collisions are the rule rather than the exception — `vm` alone has status, ssh, start
/// and stop all wanting `s`. Rather than hand-maintain a key table that would drift from
/// `cli.zig`, the key is derived and then **shown next to its label**, so the reader never
/// has to guess which of four commands won `s`.
fn claimKey(label: []const u8, taken: *[256]bool) ?u8 {
    for (label) |c| {
        if (std.ascii.isAlphabetic(c) and !taken[c]) {
            taken[c] = true;
            return c;
        }
    }
    // Nothing in the word was free, so fall back to any letter at all rather than leaving
    // the command unreachable from the board.
    for ('a'..'z' + 1) |c| {
        if (!taken[c]) {
            taken[c] = true;
            return @intCast(c);
        }
    }
    return null;
}

/// The top-level menu: one entry per group, written into `buf`.
///
/// Takes a buffer rather than an allocator so `render` can build the menu without one and
/// stay a pure function of its arguments, which is what makes every test here run without
/// a terminal or a heap.
pub fn groupEntries(buf: []Entry) []const Entry {
    var taken = [_]bool{false} ** 256;
    for (reserved_keys) |c| taken[c] = true;

    var n: usize = 0;
    for (menu_groups) |group| {
        if (n == buf.len) break;
        if (!groupExists(group)) continue;
        const key = claimKey(group, &taken) orelse continue;
        buf[n] = .{ .key = key, .label = group };
        n += 1;
    }
    return buf[0..n];
}

/// One group's menu: one entry per verb, in the order `cli.zig` declares them.
pub fn verbEntries(buf: []Entry, group: []const u8) []const Entry {
    var taken = [_]bool{false} ** 256;
    var n: usize = 0;

    for (cli.commands) |command| {
        if (n == buf.len) break;
        if (command.isBare() or !std.mem.eql(u8, command.group, group)) continue;
        // The table lists some verbs twice (once in the fallback set), and a second entry
        // would silently claim a second key for the same command.
        if (containsVerb(buf[0..n], command.verb)) continue;

        const key = claimKey(command.verb, &taken) orelse continue;
        buf[n] = .{
            .key = key,
            .label = command.verb,
            .verb = command.verb,
            .args = command.args,
        };
        n += 1;
    }
    return buf[0..n];
}

fn containsVerb(entries: []const Entry, verb: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.verb, verb)) return true;
    }
    return false;
}

fn groupExists(group: []const u8) bool {
    for (cli.commands) |command| {
        if (!command.isBare() and std.mem.eql(u8, command.group, group)) return true;
    }
    return false;
}

/// The entry `key` selects, or null when nothing does.
pub fn entryFor(entries: []const Entry, key: u8) ?Entry {
    for (entries) |e| {
        if (e.key == key) return e;
    }
    return null;
}

/// One issue and its event log, filling the screen.
///
/// Full-screen rather than a split pane: on the 80x24 this is used at, a split leaves both
/// halves too narrow to read, and the log is what you came for once you have chosen a row.
pub fn renderDetail(
    gpa: std.mem.Allocator,
    issue: api.BoardIssue,
    events: []const api.Event,
    now_ms: i64,
    w: usize,
    h: usize,
) !Screen {
    var s = try Screen.init(gpa, w, h);
    errdefer s.deinit(gpa);

    var y: usize = 0;
    s.write(0, y, issue.short, .{ .bold = true });
    s.write(10, y, stateLabel(issue.state), .{ .fg = stateColour(issue.state) });
    y += 1;
    if (y < h) {
        s.write(0, y, truncate(issue.title, w).text, .{});
        y += 2;
    }

    if (y < h) {
        s.write(0, y, "log", .{ .bold = true });
        y += 1;
    }
    if (events.len == 0) {
        if (y < h) s.write(2, y, "no events", .{ .fg = .dim });
        return s;
    }

    // Oldest first, and the tail is what matters, so a log longer than the screen drops
    // its beginning rather than its end.
    const start = if (events.len > h -| y) events.len - (h -| y) else 0;
    for (events[start..]) |event| {
        if (y >= h) break;
        renderEventRow(&s, event, now_ms, y);
        y += 1;
    }
    return s;
}

fn renderEventRow(s: *Screen, event: api.Event, now_ms: i64, y: usize) void {
    var age_buf: [24]u8 = undefined;
    const age = relativeAge(&age_buf, now_ms - event.created_at);
    s.write(0, y, age, .{ .fg = .dim });

    // The actor is the fact a reader cannot reconstruct: the same kind of event means
    // something different when an agent wrote it inside a run than when you typed it.
    const actor: []const u8 = switch (event.actor) {
        .human => "you",
        .agent => "agent",
    };
    s.write(8, y, actor, .{ .fg = if (event.actor == .agent) .cyan else .default });

    s.write(16, y, @tagName(event.kind), .{});

    if (event.payload.len > 0 and s.w > 34) {
        const text = truncate(firstLine(event.payload), s.w - 34);
        s.write(34, y, text.text, .{ .fg = .dim });
        if (text.cut) s.write(34 + screen.displayWidth(text.text), y, "…", .{ .fg = .dim });
    }
}

/// The first line of a payload. A comment is free text and its later lines would overwrite
/// whatever the renderer drew next.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

/// A coarse "how long ago", written into `buf`. Coarse on purpose: the log is read to
/// understand a sequence, and a wall-clock timestamp makes that arithmetic the reader's job.
fn relativeAge(buf: []u8, delta_ms: i64) []const u8 {
    const s = @max(0, @divTrunc(delta_ms, 1000));
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s, 3600)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(s, 86400)}) catch "?";
}

/// How many issue rows the issue view has room for on a terminal `h` rows tall.
///
/// Five rows go elsewhere: the title and its blank line above, the menu below, and one
/// more for the "N more below" line — which without that reservation is written straight
/// onto the menu row and vanishes, hiding the one fact a viewport cannot show by itself.
///
/// Public because the caller needs it *before* `render`: the cursor is clamped against the
/// viewport height, and a height the list only discovers while drawing is one the cursor
/// can already have walked off the end of.
pub fn listHeight(h: usize) usize {
    return h -| 5;
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

/// A replica directory name as the project it belongs to.
///
/// The VM names replicas `capsule-<short>`, which is the id you would have to look up.
/// Stripping the prefix leaves the short id, which is at least the thing printed beside
/// every issue.
fn projectLabel(replica: []const u8) []const u8 {
    const prefix = "capsule-";
    if (std.mem.startsWith(u8, replica, prefix)) return replica[prefix.len..];
    return replica;
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

        // The VM holds every project's replicas, so this list is not only yours. Naming
        // the project and dimming the rest is the difference between "seven branches are
        // waiting" and "seven of my branches are waiting" — the second was never true.
        const mine = if (project) |p| std.mem.eql(u8, branch.project, p.replica) else false;
        const style: Style = if (mine) .{ .fg = .yellow } else .{ .fg = .dim };

        s.write(2, y, truncate(projectLabel(branch.project), 12).text, style);
        s.write(16, y, branch.name, style);
        s.write(48, y, count, style);
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

/// The issue view, which is where the list lives. Forced here rather than taken from the
/// caller because these tests are about the list; the overview has its own below.
fn renderSample(state: State, w: usize, h: usize) !Screen {
    var s = state;
    s.view = .issues;
    return render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{ .memory_active = 12 },
        &sample_issues,
        s,
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
        .{ .view = .issues },
        1,
        100,
        40,
    );
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "capsule issue new")) != null);
}

test "a viewport smaller than the backlog says how much it is hiding" {
    // A short terminal, which is the only way the viewport is ever smaller in practice.
    var s = try renderSample(.{}, 100, 7);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "2 more below")) != null);
}

test "every group and verb gets a distinct key" {
    var buf: [32]Entry = undefined;
    const groups = groupEntries(&buf);
    try testing.expectEqual(menu_groups.len, groups.len);

    var seen = [_]bool{false} ** 256;
    for (groups) |g| {
        try testing.expect(!seen[g.key]);
        seen[g.key] = true;
        // A key the dashboard needs for itself would be unreachable from the menu.
        try testing.expect(std.mem.indexOfScalar(u8, reserved_keys, g.key) == null);
    }

    // Per group, including the three where a naive first-letter scheme collapses: `vm`
    // has status, ssh, start and stop all wanting `s`.
    for (menu_groups) |group| {
        var vbuf: [32]Entry = undefined;
        const verbs = verbEntries(&vbuf, group);
        try testing.expect(verbs.len > 0);

        var vseen = [_]bool{false} ** 256;
        for (verbs) |v| {
            try testing.expect(!vseen[v.key]);
            vseen[v.key] = true;
        }
    }
}

test "the daily-driver groups keep their obvious letters" {
    var buf: [32]Entry = undefined;
    const groups = groupEntries(&buf);

    // `cli.commands` declares image before issue, so its order would hand `i` to the
    // command you run once a month. `menu_groups` exists to stop that.
    try testing.expectEqual(@as(?u8, 'i'), keyOf(groups, "issue"));
    try testing.expectEqual(@as(?u8, 'r'), keyOf(groups, "run"));
    try testing.expectEqual(@as(?u8, 'v'), keyOf(groups, "vm"));
    try testing.expectEqual(@as(?u8, 'p'), keyOf(groups, "project"));
}

test "a verb carries the argument spelling the dispatcher reads" {
    var buf: [32]Entry = undefined;
    const verbs = verbEntries(&buf, "issue");

    // The menu asks `cli.zig` what a command wants rather than keeping a second list.
    for (verbs) |v| {
        if (std.mem.eql(u8, v.verb, "new")) {
            try testing.expect(std.mem.indexOf(u8, v.args, "title") != null);
            return;
        }
    }
    try testing.expect(false);
}

/// The menu line of a board in `state`, which is always the last row.
fn menuLine(state: State) ![]u8 {
    var s = try render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{},
        &sample_issues,
        state,
        1,
        100,
        40,
    );
    defer s.deinit(testing.allocator);
    return s.rowText(testing.allocator, 39);
}

test "the menu always says where you are and every way out of it" {
    // The overview offers the groups, and the only key that ends the session.
    const overview = try menuLine(.{});
    defer testing.allocator.free(overview);
    try testing.expect(std.mem.indexOf(u8, overview, "issue") != null);
    try testing.expect(std.mem.indexOf(u8, overview, "run") != null);
    try testing.expect(std.mem.indexOf(u8, overview, "q quit") != null);

    // A view offers its filter and a way back — never `q quit`, which from here would
    // close the board when the reader meant to close the view.
    const issues = try menuLine(.{ .view = .issues });
    defer testing.allocator.free(issues);
    try testing.expect(std.mem.indexOf(u8, issues, "f filter") != null);
    try testing.expect(std.mem.indexOf(u8, issues, "esc overview") != null);
    try testing.expect(std.mem.indexOf(u8, issues, "q quit") == null);

    // An open group names itself, so the letters below it are never anonymous.
    const inside = try menuLine(.{ .menu = "vm" });
    defer testing.allocator.free(inside);
    try testing.expect(std.mem.indexOf(u8, inside, "vm") != null);
    try testing.expect(std.mem.indexOf(u8, inside, "ssh") != null);
    try testing.expect(std.mem.indexOf(u8, inside, "esc back") != null);
}

test "a filter narrows the view to one state, and names which" {
    // In the header, where there is room: the menu line is eight group labels wide.
    var s = try renderSample(.{ .view = .issues, .filter = .blocked }, 100, 40);
    defer s.deinit(testing.allocator);
    const head = try s.rowText(testing.allocator, 0);
    defer testing.allocator.free(head);
    try testing.expect(std.mem.indexOf(u8, head, "issues · blocked") != null);

    var unfiltered = try renderSample(.{ .view = .issues }, 100, 40);
    defer unfiltered.deinit(testing.allocator);
    const all = try unfiltered.rowText(testing.allocator, 0);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "issues · all") != null);

    // The filter is what the caller applies to the slice; the renderer only reports it.
    try testing.expect(matches(sample_issues[0], null));
    try testing.expect(matches(sample_issues[0], .in_progress));
    try testing.expect(!matches(sample_issues[0], .blocked));
}

test "the overview shows what needs you, and not the whole backlog" {
    var s = try render(
        testing.allocator,
        .{ .reachable = true, .observed_at_ms = 1 },
        Project{ .issues = .{ 2, 3, 1, 0, 4, 7, 1 }, .memory_active = 12 },
        &sample_issues,
        .{},
        1,
        100,
        40,
    );
    defer s.deinit(testing.allocator);

    // The four states that mean someone must act, named; done and archived absent.
    try testing.expect((try findRow(s, "proposed")) != null);
    try testing.expect((try findRow(s, "ready")) != null);
    try testing.expect((try findRow(s, "done")) == null);
    try testing.expect((try findRow(s, "archived")) == null);

    // The running issue by name — a count cannot be acted on, and this can.
    try testing.expect((try findRow(s, "3f2a1b9c")) != null);

    // But not the backlog: an issue with nobody on it belongs in the issue view.
    try testing.expect((try findRow(s, "9c4a2f01")) == null);
}

fn keyOf(entries: []const Entry, label: []const u8) ?u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.label, label)) return e.key;
    }
    return null;
}

const sample_events = [_]api.Event{
    .{ .id = "e1", .kind = .created, .actor = .human, .payload = "", .created_at = 0, .run = null },
    .{ .id = "e2", .kind = .commented, .actor = .agent, .payload = "found the cause\nsecond line", .created_at = 60_000, .run = "019fb1ce" },
    .{ .id = "e3", .kind = .state_changed, .actor = .agent, .payload = "needs a decision", .created_at = 120_000, .run = "019fb1ce" },
};

test "the log names who acted, not only what happened" {
    var s = try renderDetail(testing.allocator, sample_issues[0], &sample_events, 180_000, 80, 24);
    defer s.deinit(testing.allocator);

    // The board could always say an issue was blocked. It could never say by whom.
    try testing.expect((try findRow(s, "3f2a1b9c")) != null);
    try testing.expect((try findRow(s, "make the board useful")) != null);
    const blocked = (try findRow(s, "state_changed")).?;
    const text = try s.rowText(testing.allocator, blocked);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "agent") != null);
    try testing.expect(std.mem.indexOf(u8, text, "needs a decision") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1m") != null);
}

test "a multi-line payload cannot overwrite the row beneath it" {
    var s = try renderDetail(testing.allocator, sample_issues[0], &sample_events, 180_000, 80, 24);
    defer s.deinit(testing.allocator);

    try testing.expect((try findRow(s, "found the cause")) != null);
    try testing.expect((try findRow(s, "second line")) == null);
}

test "a log longer than the screen keeps its end, not its beginning" {
    var many: [40]api.Event = undefined;
    for (&many, 0..) |*e, i| {
        e.* = .{
            .id = "x",
            .kind = if (i == 39) .merged else .commented,
            .actor = .human,
            .payload = if (i == 0) "the very first" else "later",
            .created_at = @intCast(i),
            .run = null,
        };
    }

    var s = try renderDetail(testing.allocator, sample_issues[0], &many, 1000, 80, 24);
    defer s.deinit(testing.allocator);

    // What just happened is why you opened the log; what happened first is history.
    try testing.expect((try findRow(s, "merged")) != null);
    try testing.expect((try findRow(s, "the very first")) == null);
}

test "an issue with no events says so rather than drawing an empty pane" {
    var s = try renderDetail(testing.allocator, sample_issues[0], &.{}, 1000, 80, 24);
    defer s.deinit(testing.allocator);
    try testing.expect((try findRow(s, "no events")) != null);
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
        .{ .view = .issues },
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
    // By panel content, not by heading: the footer names every action key, so "memory"
    // and "issues" both appear there whatever the panels above do.
    try testing.expect((try findRow(s, "capsule issue new")) == null);
    try testing.expect((try findRow(s, "/40 active")) == null);
    try testing.expect((try findRow(s, "state")) != null);
}
