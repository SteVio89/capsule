//! The dashboard's run loop: poll the daemon, render, paint, read a key, repeat.

const std = @import("std");
const Io = std.Io;

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
    /// outside a repository. bash resolves this — it has `pwd -P`, and 0.16's stdlib has
    /// no realpath.
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

    while (true) {
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();

        const snapshot = fetch(frame.allocator(), io, socket_path) catch world.Snapshot{};

        const size = t.size();
        const project = if (project_params.len > 0)
            fetchProject(frame.allocator(), io, socket_path, project_params) catch null
        else
            null;

        var current = try board_render.render(
            gpa,
            snapshot,
            project,
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
            switch (t.readKey()) {
                .key => |key| switch (key) {
                    'q', 3 => return,
                    'r' => break,
                    else => {},
                },
                .timeout => {},
                .closed => return,
            }
        }
    }
}

/// Asks the daemon for the world model and parses it back into a Snapshot.
fn fetch(arena: std.mem.Allocator, io: Io, socket_path: []const u8) !world.Snapshot {
    const response = try client.call(arena, io, socket_path, "world.get", "{}");
    if (!response.ok) return world.Snapshot{};
    return parseSnapshot(arena, response.body);
}

/// Pure: the daemon's JSON in, a Snapshot out. Separated from the socket so the shapes
/// the daemon can return are covered without one.
pub fn parseSnapshot(arena: std.mem.Allocator, body: []const u8) !world.Snapshot {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return world.Snapshot{};
    const object = switch (parsed) {
        .object => |o| o,
        else => return world.Snapshot{},
    };

    var snapshot = world.Snapshot{
        .reachable = boolOf(object.get("reachable")) orelse false,
        .observed_at_ms = intOf(object.get("observed_at_ms")) orelse 0,
        .uptime_s = optionalU64(object.get("uptime_s")),
        .disk_used = optionalU64(object.get("disk_used")),
        .disk_total = optionalU64(object.get("disk_total")),
    };

    if (object.get("containers")) |value| switch (value) {
        .array => |items| {
            var list: std.ArrayList(world.Container) = .empty;
            for (items.items) |item| switch (item) {
                .object => |o| try list.append(arena, .{
                    .name = stringOf(o.get("name")) orelse "",
                    .image = stringOf(o.get("image")) orelse "",
                }),
                else => {},
            };
            snapshot.containers = try list.toOwnedSlice(arena);
        },
        else => {},
    };

    if (object.get("branches")) |value| switch (value) {
        .array => |items| {
            var list: std.ArrayList(world.Branch) = .empty;
            for (items.items) |item| switch (item) {
                .object => |o| try list.append(arena, .{
                    .project = stringOf(o.get("project")) orelse "",
                    .name = stringOf(o.get("name")) orelse "",
                    .commits = optionalU64(o.get("commits")) orelse 0,
                }),
                else => {},
            };
            snapshot.branches = try list.toOwnedSlice(arena);
        },
        else => {},
    };

    return snapshot;
}

fn boolOf(value: ?std.json.Value) ?bool {
    return switch (value orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn intOf(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const i = intOf(value) orelse return null;
    return if (i < 0) null else @intCast(i);
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "a full snapshot round-trips from the daemon's json" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const s = try parseSnapshot(a.allocator(),
        \\{"reachable":true,"observed_at_ms":1234,"uptime_s":90,"disk_used":10,"disk_total":80,
        \\ "containers":[{"name":"c1","image":"i1"}],
        \\ "branches":[{"project":"p","name":"capsule/x","commits":3}]}
    );
    try testing.expect(s.reachable);
    try testing.expectEqual(@as(i64, 1234), s.observed_at_ms);
    try testing.expectEqual(@as(u64, 90), s.uptime_s.?);
    try testing.expectEqualStrings("c1", s.containers[0].name);
    try testing.expectEqualStrings("capsule/x", s.branches[0].name);
    try testing.expectEqual(@as(u64, 3), s.branches[0].commits);
}

test "an unreachable snapshot carries nulls, not zeros" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const s = try parseSnapshot(a.allocator(),
        \\{"reachable":false,"observed_at_ms":0,"uptime_s":null,"disk_used":null,
        \\ "disk_total":null,"containers":[],"branches":[]}
    );
    try testing.expect(!s.reachable);
    try testing.expectEqual(@as(?u64, null), s.uptime_s);
    try testing.expectEqual(@as(usize, 0), s.containers.len);
}

test "garbage from the daemon renders as unreachable rather than crashing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    for ([_][]const u8{ "", "null", "[]", "\"x\"", "{", "{\"reachable\":\"yes\"}" }) |body| {
        const s = try parseSnapshot(a.allocator(), body);
        try testing.expect(!s.reachable);
    }
}

test "malformed entries inside the arrays are skipped, not fatal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const s = try parseSnapshot(a.allocator(),
        \\{"reachable":true,"observed_at_ms":1,"containers":["nope",{"name":"ok","image":"i"}],
        \\ "branches":[42,{"project":"p","name":"b","commits":1}]}
    );
    try testing.expectEqual(@as(usize, 1), s.containers.len);
    try testing.expectEqualStrings("ok", s.containers[0].name);
    try testing.expectEqual(@as(usize, 1), s.branches.len);
}

test "a snapshot from the daemon draws without a terminal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const s = try parseSnapshot(a.allocator(),
        \\{"reachable":true,"observed_at_ms":1000,"uptime_s":60,"containers":[],"branches":[]}
    );
    var drawn = try board_render.render(testing.allocator, s, null, 2000, 80, 24);
    defer drawn.deinit(testing.allocator);
    const first = try drawn.rowText(testing.allocator, 0);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "capsule") != null);
}

/// Asks the daemon for the project's counts. Everything the board needs about a project
/// in one call — the board polls on a timer, and a call per state would multiply that.
fn fetchProject(
    arena: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    params: []const u8,
) !?board_render.Project {
    const response = try client.call(arena, io, socket_path, "issue.summary", params);
    if (!response.ok) return null;
    return parseProject(arena, response.body);
}

/// Pure, so the shapes the daemon can return are covered without a socket.
pub fn parseProject(arena: std.mem.Allocator, body: []const u8) !?board_render.Project {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const object = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    var out = board_render.Project{};
    out.replica = stringOf(object.get("replica")) orelse "";

    if (object.get("issues")) |value| switch (value) {
        .object => |counts| {
            const names = [_][]const u8{
                "proposed", "open", "in_progress", "blocked", "ready_for_review", "done", "archived",
            };
            for (names, 0..) |name, i| out.issues[i] = optionalUsize(counts.get(name)) orelse 0;
        },
        else => {},
    };

    if (object.get("memory")) |value| switch (value) {
        .object => |memory| {
            out.memory_active = optionalUsize(memory.get("active")) orelse 0;
            out.memory_cap = optionalUsize(memory.get("cap")) orelse 40;
            out.memory_proposed = optionalUsize(memory.get("proposed")) orelse 0;
            out.memory_tokens = optionalUsize(memory.get("tokens")) orelse 0;
            out.memory_over_budget = boolOf(memory.get("over_budget")) orelse false;
        },
        else => {},
    };

    return out;
}

fn optionalUsize(value: ?std.json.Value) ?usize {
    const i = intOf(value) orelse return null;
    return if (i < 0) null else @intCast(i);
}

test "a project summary parses into the board's shape" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const p = (try parseProject(a.allocator(),
        \\{"issues":{"proposed":2,"open":3,"in_progress":1,"blocked":0,
        \\ "ready_for_review":4,"done":7,"archived":1},
        \\ "memory":{"active":40,"cap":40,"proposed":2,"tokens":2100,"over_budget":false}}
    )).?;
    try testing.expectEqual(@as(usize, 2), p.issues[0]);
    try testing.expectEqual(@as(usize, 4), p.issues[4]);
    try testing.expectEqual(@as(usize, 40), p.memory_active);
    try testing.expectEqual(@as(usize, 2), p.memory_proposed);
    try testing.expect(!p.memory_over_budget);
}

test "a malformed summary leaves the board showing the VM alone" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    for ([_][]const u8{ "", "null", "[]", "{" }) |body| {
        try testing.expectEqual(@as(?board_render.Project, null), try parseProject(a.allocator(), body));
    }
}

test "a summary missing sections still renders" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const p = (try parseProject(a.allocator(), "{}")).?;
    try testing.expectEqual(@as(usize, 0), p.issues[0]);
    try testing.expectEqual(@as(usize, 40), p.memory_cap);
}
