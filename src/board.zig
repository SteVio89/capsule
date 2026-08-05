//! The dashboard's run loop: poll the daemon, render, paint, read a key, repeat.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const client = @import("client.zig");
const world = @import("world.zig");
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
        state.sync(view.issues.len, board_render.listHeight(view.project != null, size.h));

        var current = try board_render.render(
            gpa,
            view.snapshot,
            view.project,
            view.issues,
            state,
            Io.Timestamp.now(io, .real).toMilliseconds(),
            size.w,
            size.h,
        );
        errdefer current.deinit(gpa);

        try term.paint(t.tty, current, previous, &out, gpa);
        if (previous) |*p| p.deinit(gpa);
        previous = current;

        var waited: usize = 0;
        while (waited < refresh_ms / 100) : (waited += 1) {
            const key = t.readKey();
            switch (key) {
                .key => |b| switch (b) {
                    'q', 3 => return,
                    'r' => break,
                    else => {},
                },
                .closed => return,
                else => {},
            }

            // Offered to the list after the board's own keys, so `q` stays quit rather
            // than becoming whatever a list might one day want it for. A key the list
            // takes repaints immediately: waiting out the refresh would make the cursor
            // feel like it was lagging behind the keyboard.
            if (state.issues.handle(key) == .moved) break;
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

test "a frame from the daemon draws without a terminal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const f = parseFrame(a.allocator(), full_frame);
    var drawn = try board_render.render(testing.allocator, f.snapshot, f.project, f.issues, .{}, 2000, 80, 24);
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
