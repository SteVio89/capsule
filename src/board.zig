//! The dashboard's run loop: poll the daemon, render, paint, read a key, repeat.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const client = @import("client.zig");
const exec = @import("exec.zig");
const world = @import("world.zig");
const model = @import("model.zig");
const term = @import("tui/term.zig");
const board_render = @import("tui/board.zig");
const screen_mod = @import("tui/screen.zig");

/// Redraw cadence. The daemon polls the VM on its own schedule; this only decides how
/// often the picture on screen catches up with it.
const refresh_ms = 1000;

/// The blocking dashboard loop: holds the terminal in raw mode on the alternate screen
/// until the user quits, the tty closes, or the daemon goes away. Returns
/// `error.DaemonNotRunning` or `error.NotATerminal` before touching the terminal, so
/// the caller can print a plain message instead.
pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    /// Pre-encoded `{"git_common_dir":…,"cwd":…}`, or empty when the board was opened
    /// outside a repository. `main.zig` resolves it through `git.discover`; it used to be
    /// bash's job, on the since-corrected belief that 0.16 had no realpath.
    project_params: []const u8,
    /// capsule's own binary as it was invoked, which the action keys re-run. Passed rather
    /// than looked up: 0.16 has no `selfExePath`, and argv[0] is the better answer anyway —
    /// a bare `capsule` re-resolves through `PATH` the way the shell did, while
    /// `./zig-out/bin/capsule` keeps acting on the build you are testing.
    exe_path: []const u8,
) !void {
    _ = client.call(arena, io, socket_path, "ping", "{}") catch return error.DaemonNotRunning;

    var t = term.Term.init() catch return error.NotATerminal;
    try t.enterRaw();
    defer t.leaveRaw();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var previous: ?screen_mod.Screen = null;
    defer if (previous) |*p| p.deinit(gpa);

    // Outside the frame arena on purpose: it is what the selection is made of, and a
    // per-frame allocator would reset it every time the daemon answered.
    var state = board_render.State{};

    while (true) {
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();

        const view = fetch(frame.allocator(), io, socket_path, project_params);

        const size = t.size();
        // The cursor indexes what is drawn, so everything downstream sees the filtered
        // set — otherwise the selection and the screen disagree the moment a filter hides
        // the row it was on.
        const shown = filterIssues(frame.allocator(), view.issues, state.filter);
        state.sync(shown.len, board_render.listHeight(size.h));
        state.syncRuns(view.runs.len, board_render.listHeight(size.h));
        const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

        const selected = state.selected(shown);
        if (selected == null) state.detail = false;

        var current = if (state.detail and selected != null) detail: {
            const issue = selected.?;
            const events = fetchEvents(frame.allocator(), io, socket_path, project_params, issue.short);
            break :detail try board_render.renderDetail(gpa, issue, events, now_ms, size.w, size.h);
        } else try board_render.render(
            gpa,
            view.snapshot,
            view.project,
            shown,
            view.runs,
            state,
            now_ms,
            size.w,
            size.h,
        );
        errdefer current.deinit(gpa);

        try term.paint(t.tty, current, previous, &out, gpa);
        if (previous) |*p| p.deinit(gpa);
        previous = current;

        // An action hands the screen to another program, so the next paint cannot diff
        // against what the dashboard last drew — that memory is stale the moment `capsule
        // issue new` writes a line of its own.
        var acted = false;
        defer if (acted) {
            if (previous) |*p| p.deinit(gpa);
            previous = null;
        };

        var waited: usize = 0;
        while (waited < refresh_ms / 100) : (waited += 1) {
            const key = t.readKey();

            // The detail view claims its keys first, and claims very few: while it is open
            // `q` closes it rather than quitting capsule. Anything that walks the list
            // underneath would move a selection the reader cannot see.
            if (state.detail) {
                switch (key) {
                    .escape => {
                        state.detail = false;
                        break;
                    },
                    .key => |b| switch (b) {
                        'q', 27 => {
                            state.detail = false;
                            break;
                        },
                        3 => return,
                        else => {},
                    },
                    .closed => return,
                    else => {},
                }
                continue;
            }

            // Inside a group the menu owns every letter, because the footer is showing
            // exactly which ones mean something. Letting the list keep `j` and `k` here
            // would move a selection while the reader is looking at a command list.
            if (state.menu.len > 0) {
                switch (key) {
                    .escape => {
                        state.menu = "";
                        break;
                    },
                    .key => |b| {
                        if (b == 3) return;
                        if (b == 27) {
                            state.menu = "";
                            break;
                        }
                        var buf: [32]board_render.Entry = undefined;
                        const entries = board_render.verbEntries(&buf, state.menu);
                        if (board_render.entryFor(entries, b)) |entry| {
                            const group = state.menu;
                            state.menu = "";

                            // A verb the board can answer itself changes the view instead
                            // of running anything — `issue list` would otherwise print a
                            // list onto a screen the dashboard repaints a moment later.
                            if (viewFor(group, entry.verb)) |v| {
                                state.view = v;
                                break;
                            }
                            runEntry(&t, io, frame.allocator(), exe_path, group, entry, selected);
                            acted = true;
                            break;
                        }
                    },
                    .closed => return,
                    else => {},
                }
                continue;
            }

            // `esc` unwinds one step rather than quitting: from a view back to the
            // overview, and from the overview nowhere. Quitting stays on `q` alone, so a
            // reflexive escape can never end the session.
            if (key == .escape and state.view != .overview) {
                state.view = .overview;
                break;
            }

            switch (key) {
                .key => |b| switch (b) {
                    'q', 3 => return,
                    27 => {
                        if (state.view != .overview) {
                            state.view = .overview;
                            break;
                        }
                    },
                    '\r', '\n' => {
                        // The log belongs to an issue. A run has one too, through its
                        // issue, but opening it from here would need a lookup the board
                        // does not have — so the key simply does nothing in the run view
                        // rather than opening the wrong issue's history.
                        if (state.view != .runs) {
                            state.detail = true;
                            break;
                        }
                    },
                    'f' => {
                        if (state.view == .issues) {
                            state.filter = nextFilter(state.filter);
                            break;
                        }
                    },
                    else => {
                        // A group key opens the menu. Checked before the list so a letter
                        // the footer is advertising cannot be swallowed as navigation —
                        // `r` for the run group would otherwise never arrive.
                        var buf: [32]board_render.Entry = undefined;
                        const groups = board_render.groupEntries(&buf);
                        if (board_render.entryFor(groups, b)) |entry| {
                            state.menu = entry.label;
                            break;
                        }
                    },
                },
                .closed => return,
                else => {},
            }

            // Offered to the list last, so a key the menu claims stays the menu's. A key
            // the list takes repaints immediately: waiting out the refresh would make the
            // cursor feel like it was lagging behind the keyboard.
            const moved = switch (state.view) {
                .runs => state.runs.handle(key),
                else => state.issues.handle(key),
            };
            if (moved == .moved) break;
        }
    }
}

/// One frame's worth of daemon state, in the shapes the renderer takes.
pub const Frame = struct {
    snapshot: world.Snapshot = .{},
    /// Null outside a registered project, when the VM panel is all there is to draw.
    project: ?board_render.Project = null,
    /// The navigable issue list and the run history. Carried here from the moment the
    /// wire gained them; the panels that show them land with the selectable list.
    issues: []const api.BoardIssue = &.{},
    runs: []const api.Run = &.{},
};

/// One `board.get` per tick.
///
/// This used to be two calls — `world.get` and `issue.summary` — which arrived at
/// different instants, so the VM panel could show a container the issue panel had no run
/// for. One call under one lock means whatever the frame says was all true at once.
///
/// Never fails: a daemon that is down, refusing, or talking nonsense yields the default
/// frame, which draws as "unreachable". Refusing to render is the one thing a dashboard
/// must not do when the news is bad.
fn fetch(
    arena: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    params: []const u8,
) Frame {
    const request = if (params.len > 0) params else "{}";
    const response = client.call(arena, io, socket_path, api.board_get.name, request) catch
        return .{};
    if (!response.ok) return .{};
    return parseFrame(arena, response.body);
}

/// Hands the terminal back, runs a capsule command on it, then restores the dashboard.
///
/// The board acts by invoking the CLI it ships beside, rather than reimplementing anything
/// against the daemon. `run start` alone is two batched ssh scripts, a seed tarball and a
/// git push — none of which the daemon can do — and `issue new` wants `$EDITOR`. One
/// implementation of every action, already exercised against a real VM.
///
/// Failures are swallowed on purpose: the command printed its own complaint on the
/// terminal it was handed, and the dashboard's job is to come back either way.
fn shellOut(t: *term.Term, io: Io, argv: []const []const u8) void {
    t.leaveRaw();
    defer t.enterRaw() catch {};
    _ = exec.interactive(io, argv, .{}) catch {};
}

/// Runs the command a menu entry names, filling in whatever its arguments ask for.
///
/// `cli.Command.args` is the help text's own spelling — `"<title>"`, `"[issue-id]"` — and
/// it is the only place that records what a verb wants. Reading it here means the menu
/// learns a new command's shape from the same line that documents it, rather than from a
/// second table that would drift.
///
/// One `leaveRaw`/`enterRaw` around the prompt *and* the command: separating them flickers
/// the alternate screen in and out between typing a title and the editor appearing, which
/// reads as a glitch rather than a step.
fn runEntry(
    t: *term.Term,
    io: Io,
    arena: std.mem.Allocator,
    exe_path: []const u8,
    group: []const u8,
    entry: board_render.Entry,
    selected: ?api.BoardIssue,
) void {
    t.leaveRaw();
    defer t.enterRaw() catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ exe_path, group, entry.verb }) catch return;

    // The id first, then the title, which is the order every such command spells them in.
    if (std.mem.indexOf(u8, entry.args, "id") != null) {
        if (selected) |issue| argv.append(arena, issue.short) catch return;
    }
    if (std.mem.indexOf(u8, entry.args, "title") != null) {
        const title = askLine(arena, io, "title (empty to cancel): ") orelse return;
        argv.append(arena, title) catch return;
    }

    _ = exec.interactive(io, argv.items, .{}) catch {};

    // Without this the dashboard repaints over the output within milliseconds, which is
    // why every command that only prints — `vm status`, `run list`, `project list` —
    // appeared to do nothing at all. A command the board runs is a command you must be
    // able to read the answer to.
    waitForKey(io, "\n[any key]");
}

/// Blocks until one byte arrives on the terminal. Silent on failure: the caller has
/// already run the command, and a prompt that cannot be shown is not worth an error.
fn waitForKey(io: Io, note: []const u8) void {
    const tty = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return;
    defer tty.close(io);

    var out: [64]u8 = undefined;
    var writer = tty.writer(io, &out);
    writer.interface.writeAll(note) catch {};
    writer.interface.flush() catch {};

    var buf: [8]u8 = undefined;
    var reader = tty.readerStreaming(io, &buf);
    _ = reader.interface.takeByte() catch {};
}

/// The view a verb opens instead of shelling out.
///
/// `issue list` is the board's own main view: shelling out would print a list and hand
/// back a screen the dashboard immediately paints over. Verbs with no view here still run
/// as commands, which is the right default — the board should not grow a second, worse
/// implementation of `run list` just to avoid a subprocess.
fn viewFor(group: []const u8, verb: []const u8) ?board_render.View {
    if (std.mem.eql(u8, group, "issue") and std.mem.eql(u8, verb, "list")) return .issues;
    if (std.mem.eql(u8, group, "run") and std.mem.eql(u8, verb, "list")) return .runs;
    return null;
}

/// The issues the current filter admits, in the frame's arena.
///
/// Filtering here rather than in `render` keeps one truth: the cursor indexes what is on
/// screen, so a selection can never point at a row the filter has hidden.
fn filterIssues(
    arena: std.mem.Allocator,
    issues: []const api.BoardIssue,
    filter: ?model.Issue.State,
) []const api.BoardIssue {
    if (filter == null) return issues;

    var out: std.ArrayList(api.BoardIssue) = .empty;
    for (issues) |issue| {
        if (board_render.matches(issue, filter)) out.append(arena, issue) catch return issues;
    }
    return out.toOwnedSlice(arena) catch issues;
}

/// The next filter in `board_render.filters`, wrapping.
fn nextFilter(current: ?model.Issue.State) ?model.Issue.State {
    for (board_render.filters, 0..) |f, i| {
        const same = (f == null and current == null) or
            (f != null and current != null and f.? == current.?);
        if (same) return board_render.filters[(i + 1) % board_render.filters.len];
    }
    return null;
}

/// Asks for one line on the restored terminal. Null when the reader cancelled with an
/// empty line, which is the only way out of a prompt that has already taken the screen.
fn askLine(arena: std.mem.Allocator, io: Io, question: []const u8) ?[]const u8 {
    const tty = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return null;
    defer tty.close(io);

    var out: [256]u8 = undefined;
    var writer = tty.writer(io, &out);
    writer.interface.writeAll(question) catch return null;
    writer.interface.flush() catch return null;

    var buf: [4096]u8 = undefined;
    var reader = tty.readerStreaming(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return null;

    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;
    return arena.dupe(u8, trimmed) catch null;
}

/// The selected issue's event log, or empty on any failure.
///
/// Fetched only while the detail view is open, rather than for every issue on every tick:
/// the log is unbounded and the board polls once a second.
fn fetchEvents(
    arena: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    project_params: []const u8,
    short: []const u8,
) []const api.Event {
    const params = withId(arena, project_params, short) orelse return &.{};
    const response = client.call(arena, io, socket_path, api.issue_events.name, params) catch
        return &.{};
    if (!response.ok) return &.{};
    return api.parseResult(api.issue_events, arena, response.body) catch &.{};
}

/// `{"git_common_dir":…,"cwd":…}` with an `"id"` added.
///
/// Spliced rather than re-encoded because `run` is handed the repo fields already encoded
/// and never sees them apart. The input is capsule's own output, so its last byte is the
/// closing brace; anything else returns null rather than producing malformed JSON. `short`
/// is a hex id from the daemon, so it needs no escaping.
fn withId(arena: std.mem.Allocator, project_params: []const u8, short: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, project_params, " \t\r\n");
    if (!std.mem.endsWith(u8, trimmed, "}") or trimmed.len < 2) return null;
    for (short) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.allocPrint(arena, "{s},\"id\":\"{s}\"}}", .{ trimmed[0 .. trimmed.len - 1], short }) catch null;
}

/// Pure: the daemon's JSON in, the renderer's shapes out. Separated from the socket so
/// every shape the daemon can return is covered without one.
pub fn parseFrame(arena: std.mem.Allocator, body: []const u8) Frame {
    const parsed = api.parseResult(api.board_get, arena, body) catch return .{};

    const containers = arena.alloc(world.Container, parsed.world.containers.len) catch return .{};
    for (parsed.world.containers, containers) |from, *to| {
        to.* = .{ .name = from.name, .image = from.image };
    }
    const branches = arena.alloc(world.Branch, parsed.world.branches.len) catch return .{};
    for (parsed.world.branches, branches) |from, *to| {
        to.* = .{ .project = from.project, .name = from.name, .commits = from.commits };
    }

    var frame = Frame{
        .snapshot = .{
            .reachable = parsed.world.reachable,
            .observed_at_ms = parsed.world.observed_at_ms,
            .uptime_s = parsed.world.uptime_s,
            .disk_used = parsed.world.disk_used,
            .disk_total = parsed.world.disk_total,
            .image_digest = parsed.world.image_digest,
            .containers = containers,
            .branches = branches,
        },
        .issues = parsed.issues,
        .runs = parsed.runs,
    };

    if (parsed.project) |summary| {
        var project = board_render.Project{ .replica = summary.replica };
        // By field name, in enum order: the renderer indexes `issues` by the state's tag,
        // so a state added to the enum and not to the panel would shift every count.
        inline for (@typeInfo(api.IssueCounts).@"struct".fields, 0..) |field, i| {
            project.issues[i] = @field(summary.issues, field.name);
        }
        project.memory_active = summary.memory.active;
        project.memory_cap = summary.memory.cap;
        project.memory_proposed = summary.memory.proposed;
        project.memory_tokens = summary.memory.tokens;
        project.memory_over_budget = summary.memory.over_budget;
        frame.project = project;
    }

    return frame;
}

const testing = std.testing;

/// A complete `board.get` result, which is what the daemon actually sends: every field
/// present, because both sides are the same binary and the encoder omits nothing.
const full_frame =
    \\{"world":{"reachable":true,"observed_at_ms":1234,"uptime_s":90,"disk_used":10,
    \\ "disk_total":80,"image_digest":"sha256:beef",
    \\ "containers":[{"name":"c1","image":"i1"}],
    \\ "branches":[{"project":"p","name":"capsule/x","commits":3}]},
    \\ "projects":[{"short":"abc12345","name":"capsule","path":"/p/.git",
    \\ "profile":"default","replica":"capsule-abc12345"}],
    \\ "project":{"replica":"capsule-abc12345",
    \\ "issues":{"proposed":2,"open":3,"in_progress":1,"blocked":0,
    \\ "ready_for_review":4,"done":7,"archived":1},
    \\ "memory":{"active":40,"cap":40,"proposed":2,"tokens":2100,"over_budget":false}},
    \\ "issues":[{"short":"3f2a1b9c","state":"in_progress","title":"live","created_at":10,
    \\ "run":"019fb1ce","commits":3}],
    \\ "runs":[{"short":"019fb1ce","issue":"3f2a1b9c","state":"active","started_at":1,
    \\ "ended_at":null,"container":"capsule-019fb1ce23cd","branch":"capsule/x"}]}
;

test "a full frame round-trips from the daemon's json" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const f = parseFrame(a.allocator(), full_frame);
    try testing.expect(f.snapshot.reachable);
    try testing.expectEqual(@as(i64, 1234), f.snapshot.observed_at_ms);
    try testing.expectEqual(@as(u64, 90), f.snapshot.uptime_s.?);
    try testing.expectEqualStrings("sha256:beef", f.snapshot.image_digest.?);
    try testing.expectEqualStrings("c1", f.snapshot.containers[0].name);
    try testing.expectEqualStrings("capsule/x", f.snapshot.branches[0].name);
    try testing.expectEqual(@as(u64, 3), f.snapshot.branches[0].commits);

    const p = f.project.?;
    try testing.expectEqualStrings("capsule-abc12345", p.replica);
    try testing.expectEqual(@as(usize, 2), p.issues[0]);
    try testing.expectEqual(@as(usize, 4), p.issues[4]);
    try testing.expectEqual(@as(usize, 40), p.memory_active);
    try testing.expectEqual(@as(usize, 2), p.memory_proposed);
    try testing.expect(!p.memory_over_budget);

    try testing.expectEqual(@as(usize, 1), f.issues.len);
    try testing.expectEqualStrings("019fb1ce", f.issues[0].run.?);
    try testing.expectEqual(@as(usize, 1), f.runs.len);
}

test "an unreachable frame carries nulls, not zeros" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const f = parseFrame(a.allocator(),
        \\{"world":{"reachable":false,"observed_at_ms":0,"uptime_s":null,"disk_used":null,
        \\ "disk_total":null,"image_digest":null,"containers":[],"branches":[]},
        \\ "projects":[],"project":null,"issues":[],"runs":[]}
    );
    try testing.expect(!f.snapshot.reachable);
    try testing.expectEqual(@as(?u64, null), f.snapshot.uptime_s);
    try testing.expectEqual(@as(usize, 0), f.snapshot.containers.len);
    try testing.expectEqual(@as(?board_render.Project, null), f.project);
}

test "garbage from the daemon renders as unreachable rather than crashing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    for ([_][]const u8{
        "",
        "null",
        "[]",
        "\"x\"",
        "{",
        "{}",
        "{\"world\":{\"reachable\":\"yes\"}}",
        // A frame that parses down to the last field and then lies about a type: the
        // whole frame is discarded rather than half-rendered.
        \\{"world":{"reachable":true,"observed_at_ms":1,"uptime_s":null,"disk_used":null,
        \\ "disk_total":null,"image_digest":null,"containers":[],"branches":[]},
        \\ "projects":[],"project":null,"issues":[],"runs":"nope"}
        ,
    }) |body| {
        const f = parseFrame(a.allocator(), body);
        try testing.expect(!f.snapshot.reachable);
        try testing.expectEqual(@as(?board_render.Project, null), f.project);
    }
}

test "an unknown state in the issue list is refused, not rendered as `open`" {
    // The wire carries the state as an enum tag. A daemon a version ahead could send one
    // this build has no name for, and quietly mapping it to `open` would put work that is
    // blocked into the column that means nothing is wrong.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const f = parseFrame(a.allocator(),
        \\{"world":{"reachable":true,"observed_at_ms":1,"uptime_s":null,"disk_used":null,
        \\ "disk_total":null,"image_digest":null,"containers":[],"branches":[]},
        \\ "projects":[],"project":null,
        \\ "issues":[{"short":"a","state":"from_the_future","title":"t","created_at":1,
        \\ "run":null,"commits":null}],"runs":[]}
    );
    try testing.expect(!f.snapshot.reachable);
}

test "the events request carries the repo fields plus the id" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const params = withId(arena, "{\"git_common_dir\":\"/p/.git\",\"cwd\":\"/p\"}", "3f2a1b9c").?;
    try testing.expectEqualStrings(
        "{\"git_common_dir\":\"/p/.git\",\"cwd\":\"/p\",\"id\":\"3f2a1b9c\"}",
        params,
    );

    // It parses as the daemon's own parameter type, which is the only check that matters.
    const parsed = try std.json.parseFromSlice(api.IdParams, testing.allocator, params, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("3f2a1b9c", parsed.value.id);

    // Splicing into something that is not an object would produce malformed JSON, and an
    // id that is not hex could carry a quote into it. Both refuse rather than build it.
    try testing.expectEqual(@as(?[]const u8, null), withId(arena, "", "3f2a1b9c"));
    try testing.expectEqual(@as(?[]const u8, null), withId(arena, "not json", "3f2a1b9c"));
    try testing.expectEqual(@as(?[]const u8, null), withId(arena, "{}", "\",\"x\":\""));
}

test "a frame from the daemon draws without a terminal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const f = parseFrame(a.allocator(), full_frame);
    var drawn = try board_render.render(testing.allocator, f.snapshot, f.project, f.issues, f.runs, .{}, 2000, 80, 24);
    defer drawn.deinit(testing.allocator);
    const first = try drawn.rowText(testing.allocator, 0);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "capsule") != null);
}

test "the panel's count array and the wire's count struct stay the same length" {
    // `parseFrame` copies one into the other by position. If a state is added to
    // `IssueCounts` and the panel's fixed array is not grown, this is where it stops.
    const counts = @typeInfo(api.IssueCounts).@"struct".fields.len;
    const panel = @typeInfo(@FieldType(board_render.Project, "issues")).array.len;
    try testing.expectEqual(counts, panel);
}
