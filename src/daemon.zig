//! The host daemon: the only process that opens the store.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const protocol = @import("protocol.zig");
const store_mod = @import("store.zig");
const paths_mod = @import("paths.zig");
const world_mod = @import("world.zig");
const ssh_mod = @import("ssh.zig");
const http = @import("http.zig");
const project_mod = @import("project.zig");
const ids = @import("id.zig");
const model_mod = @import("model.zig");
const token_mod = @import("token.zig");
const mcp = @import("mcp.zig");
const buffer_mod = @import("buffer.zig");
const memory_mod = @import("memory.zig");

pub const Options = struct {
    socket_path: []const u8,
    db_path: [:0]const u8,
    ssh: ssh_mod.Config,
    /// Seconds, not milliseconds. These facts change on a human timescale and each tick
    /// costs a VM round trip.
    poll_interval_s: u64 = 3,
};

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: Io,
    store: store_mod.Store,
    /// One lock over everything mutable. At one user's scale the contention is nil and
    /// the reasoning is trivial, which is the better trade.
    mutex: Io.Mutex = .init,
    socket_path: []const u8,
    ssh_config: ssh_mod.Config,
    poll_interval_s: u64,
    /// A VM-down world model is a normal state, not an error — the daemon starts before
    /// the VM exists and must survive `capsule vm destroy`. So this begins unreachable
    /// and simply stays that way until a probe succeeds.
    snapshot: world_mod.Snapshot = .{},
    /// The snapshot's strings point into here. Swapped wholesale on each successful tick
    /// so a reader never sees half of one probe and half of the next.
    snapshot_arena: std.heap.ArenaAllocator,
    /// The reverse tunnel, held for as long as the VM is up. Owned here rather than by
    /// `run start`, which exits long before the container it started does.
    tunnel: ?std.process.Child = null,
    /// Read by three threads (accept loop, poller, HTTP) and written by daemon.stop —
    /// atomic so no thread ever reasons from a torn or stale read.
    quit: std.atomic.Value(bool) = .init(false),
    /// False when the loopback endpoint could not be bound.
    http_up: std.atomic.Value(bool) = .init(false),

    /// Opens the store and prepares an idle daemon. Nothing is bound or spawned yet —
    /// that happens in `serve`. The caller owns the result and must `deinit` it.
    pub fn init(gpa: std.mem.Allocator, io: Io, options: Options) !Daemon {
        return .{
            .gpa = gpa,
            .io = io,
            .store = try store_mod.Store.open(options.db_path),
            .socket_path = options.socket_path,
            .ssh_config = options.ssh,
            .poll_interval_s = options.poll_interval_s,
            .snapshot_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Tears down what `init` (and a run of `serve`) built: kills the tunnel if one is
    /// up, closes the store, and frees the snapshot arena.
    pub fn deinit(d: *Daemon) void {
        if (d.tunnel) |*child| child.kill(d.io);
        d.store.close();
        d.snapshot_arena.deinit();
    }

    /// Refreshes the world model until `quit`. Runs on its own thread: a probe takes a VM
    /// round trip and the accept loop must not wait on it.
    fn poll(d: *Daemon) void {
        while (!d.quit.load(.acquire)) {
            var fresh = std.heap.ArenaAllocator.init(d.gpa);
            const snapshot = ssh_mod.probe(
                d.gpa,
                fresh.allocator(),
                d.io,
                d.ssh_config,
                Io.Timestamp.now(d.io, .real).toMilliseconds(),
            );

            d.mutex.lockUncancelable(d.io);
            d.snapshot_arena.deinit();
            d.snapshot_arena = fresh;
            d.snapshot = snapshot;
            d.mutex.unlock(d.io);

            d.reconcileTunnel(snapshot.reachable);
            d.reconcileRuns(snapshot);

            Io.sleep(
                d.io,
                .{ .nanoseconds = @intCast(d.poll_interval_s * std.time.ns_per_s) },
                .awake,
            ) catch return;
        }
    }

    /// Brings the tunnel up when the VM appears and tears it down when the VM goes away.
    fn reconcileTunnel(d: *Daemon, reachable: bool) void {
        if (d.tunnel) |child| {
            if (child.id) |pid| {
                var status: c_int = undefined;
                if (std.c.waitpid(pid, &status, std.c.W.NOHANG) == pid) d.tunnel = null;
            } else d.tunnel = null;
        }

        if (!reachable) {
            if (d.tunnel) |*child| {
                child.kill(d.io);
                d.tunnel = null;
            }
            return;
        }

        if (d.tunnel != null) return;

        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();
        d.tunnel = ssh_mod.startTunnel(arena.allocator(), d.io, d.ssh_config) catch null;
    }

    /// Marks any run whose container has gone as `abandoned` and revokes its token.
    fn reconcileRuns(d: *Daemon, snapshot: world_mod.Snapshot) void {
        if (!snapshot.reachable) return;

        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();

        const gpa = arena.allocator();
        const names = gpa.alloc([]const u8, snapshot.containers.len) catch return;
        for (snapshot.containers, 0..) |container, i| names[i] = container.name;

        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        _ = d.store.reconcileRuns(
            gpa,
            names,
            Io.Timestamp.now(d.io, .real).toMilliseconds(),
        ) catch {};
    }

    fn writeSnapshot(d: *Daemon, arena: std.mem.Allocator, w: *Io.Writer) !void {
        const s = d.snapshot;
        try w.print(
            "{{\"reachable\":{},\"observed_at_ms\":{d},\"uptime_s\":{?d}," ++
                "\"disk_used\":{?d},\"disk_total\":{?d},\"containers\":[",
            .{ s.reachable, s.observed_at_ms, s.uptime_s, s.disk_used, s.disk_total },
        );
        for (s.containers, 0..) |container, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":", .{});
            try std.json.Stringify.encodeJsonString(container.name, .{}, w);
            try w.writeAll(",\"image\":");
            try std.json.Stringify.encodeJsonString(container.image, .{}, w);
            try w.writeAll("}");
        }
        try w.writeAll("],\"branches\":[");
        for (s.branches, 0..) |branch, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"project\":");
            try std.json.Stringify.encodeJsonString(branch.project, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.encodeJsonString(branch.name, .{}, w);
            try w.print(",\"commits\":{d}}}", .{branch.commits});
        }
        try w.writeAll("]}");
        _ = arena;
    }

    /// Binds and serves until `quit`. Cleans the socket up on the way out so the next
    /// start does not have to reason about a leftover it wrote itself.
    pub fn serve(d: *Daemon) !void {
        const lock_fd = try acquireStartLock(d.gpa, d.socket_path);
        defer _ = std.c.close(lock_fd);

        try clearStaleSocket(d.io, d.socket_path);

        const addr = try net.UnixAddress.init(d.socket_path);
        var server = try addr.listen(d.io, .{});
        defer server.deinit(d.io);
        defer Io.Dir.cwd().deleteFile(d.io, d.socket_path) catch {};

        const poller = std.Thread.spawn(.{}, poll, .{d}) catch |err| blk: {
            std.log.warn("world-model poller did not start: {t}", .{err});
            break :blk null;
        };
        defer if (poller) |t| t.join();
        const server_thread = std.Thread.spawn(.{}, serveHttp, .{d}) catch |err| blk: {
            std.log.warn("MCP endpoint thread did not start: {t}", .{err});
            break :blk null;
        };
        defer if (server_thread) |t| t.join();
        defer d.nudgeHttp();
        defer d.quit.store(true, .release);

        while (!d.quit.load(.acquire)) {
            const stream = server.accept(d.io) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            defer stream.close(d.io);
            d.serveConnection(stream) catch {};
        }
    }

    /// Wakes the HTTP thread's blocking accept so it can observe `quit` and exit. Its
    /// connection is closed without a request; the accept loop treats that as routine.
    fn nudgeHttp(d: *Daemon) void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(d.ssh_config.mcp_port) };
        var stream = addr.connect(d.io, .{ .mode = .stream }) catch return;
        stream.close(d.io);
    }

    fn serveConnection(d: *Daemon, stream: net.Stream) !void {
        setSocketTimeouts(stream, 30);

        const read_buf = try d.gpa.alloc(u8, protocol.max_line + 1);
        defer d.gpa.free(read_buf);
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(d.io, read_buf);
        var writer = stream.writer(d.io, &write_buf);
        const w = &writer.interface;

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try protocol.writeErr(w, 0, .too_large, "request line too long");
                    try w.flush();
                    return;
                },
                else => return,
            } orelse return;

            var arena = std.heap.ArenaAllocator.init(d.gpa);
            defer arena.deinit();

            var out: std.ArrayList(u8) = .empty;
            var buffered = std.Io.Writer.Allocating.fromArrayList(arena.allocator(), &out);

            switch (protocol.parseRequest(arena.allocator(), line)) {
                .err => |code| try protocol.writeErr(&buffered.writer, 0, code, @tagName(code)),
                .ok => |request| try d.dispatch(arena.allocator(), &buffered.writer, request),
            }
            try w.writeAll(buffered.written());
            try w.flush();
        }
    }

    /// Bounds how long a stalled peer can hold a connection open: anything in the VM can
    /// reach the MCP port, and one silent connect must not wedge a serial accept loop
    /// forever. Best-effort — a platform refusing the option just keeps today's behaviour.
    fn setSocketTimeouts(stream: net.Stream, seconds: i32) void {
        const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
        const bytes = std.mem.asBytes(&timeout);
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
    }

    /// `capsule project` — register, list, retire, and set the profile.
    fn dispatchProject(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        const verb = request.method["project.".len..];
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };

        if (std.mem.eql(u8, verb, "list")) {
            const rows = try d.store.listProjects(arena);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"short\":\"{s}\",\"name\":", .{ids.short(row.id)});
                try std.json.Stringify.encodeJsonString(project_mod.displayName(row.canonical_path), .{}, w);
                try w.writeAll(",\"path\":");
                try std.json.Stringify.encodeJsonString(row.canonical_path, .{}, w);
                try w.writeAll(",\"profile\":");
                try std.json.Stringify.encodeJsonString(row.profile, .{}, w);
                try w.writeAll(",\"replica\":");
                try std.json.Stringify.encodeJsonString(
                    try project_mod.replicaName(arena, row.canonical_path),
                    .{},
                    w,
                );
                try w.writeAll("}");
            }
            return w.writeAll("]}\n");
        }

        const canonical = d.canonicalPath(arena, params) catch
            return protocol.writeErr(w, request.id, .bad_params, "not a git repository");

        if (std.mem.eql(u8, verb, "add")) {
            const profile = stringParam(params, "profile") orelse "default";
            if (!project_mod.validProfile(profile)) {
                return protocol.writeErr(w, request.id, .bad_params, "invalid profile name");
            }
            if (try d.store.findProject(canonical)) |_| {
                return protocol.writeErr(w, request.id, .refused, "already registered");
            }
            const now = Io.Timestamp.now(d.io, .real).toMilliseconds();
            const id = ids.generateNow(d.io);
            try d.store.addProject(id, canonical, profile, now);
            return d.writeProject(arena, w, request.id, id, canonical, profile);
        }

        const id = (try d.store.findProject(canonical)) orelse
            return protocol.writeErr(w, request.id, .no_project, canonical);

        if (std.mem.eql(u8, verb, "get")) {
            const profile = (try d.store.projectProfile(arena, id)) orelse "default";
            return d.writeProject(arena, w, request.id, id, canonical, profile);
        }

        if (std.mem.eql(u8, verb, "profile")) {
            const profile = stringParam(params, "profile") orelse
                return protocol.writeErr(w, request.id, .bad_params, "no profile given");
            if (!project_mod.validProfile(profile)) {
                return protocol.writeErr(w, request.id, .bad_params, "invalid profile name");
            }
            try d.store.setProjectProfile(id, profile);
            return d.writeProject(arena, w, request.id, id, canonical, profile);
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
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request_id: u64,
        id: ids.Id,
        canonical: []const u8,
        profile: []const u8,
    ) !void {
        _ = d;
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

    /// The caller passes what git said and a cwd that is already physical; joining and
    /// normalising them is `project.resolveGitDir`, which is where the worktree and
    /// bare-repo cases are pinned down.
    fn canonicalPath(d: *Daemon, arena: std.mem.Allocator, params: std.json.ObjectMap) ![]const u8 {
        _ = d;
        const git_dir = stringParam(params, "git_common_dir") orelse return error.NotARepository;
        const cwd = stringParam(params, "cwd") orelse return error.NotARepository;
        return project_mod.resolveGitDir(arena, git_dir, cwd);
    }

    /// `capsule issue` — the human side of the tracker.
    fn dispatchIssue(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        const verb = request.method["issue.".len..];
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };

        const canonical = d.canonicalPath(arena, params) catch
            return protocol.writeErr(w, request.id, .bad_params, "not a git repository");
        const project_id = (try d.store.findProject(canonical)) orelse
            return protocol.writeErr(w, request.id, .no_project, canonical);

        if (std.mem.eql(u8, verb, "new")) {
            const title = stringParam(params, "title") orelse
                return protocol.writeErr(w, request.id, .bad_params, "an issue needs a title");
            if (std.mem.trim(u8, title, " \t\r\n").len == 0) {
                return protocol.writeErr(w, request.id, .bad_params, "an issue needs a title");
            }
            const body = stringParam(params, "body") orelse "";
            const now = Io.Timestamp.now(d.io, .real).toMilliseconds();
            const issue_id = ids.generateNow(d.io);
            const event_id = ids.generateNow(d.io);
            _ = try d.store.createIssue(issue_id, project_id, title, body, .human, event_id, now);
            const row = (try d.store.getIssue(arena, issue_id)).?;
            return d.writeIssue(w, request.id, row);
        }

        if (std.mem.eql(u8, verb, "list")) {
            const state = if (stringParam(params, "state")) |text|
                model_mod.Issue.State.parse(text) orelse
                    return protocol.writeErr(w, request.id, .bad_params, "unknown state")
            else
                null;
            const rows = try d.store.listIssues(arena, project_id, state);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try d.issueObject(w, row);
            }
            return w.writeAll("]}\n");
        }

        if (std.mem.eql(u8, verb, "summary")) {
            const all = try d.store.listIssues(arena, project_id, null);
            var counts = [_]usize{0} ** std.meta.fields(model_mod.Issue.State).len;
            for (all) |row| counts[@intFromEnum(row.state)] += 1;

            const active = try d.store.listMemories(arena, project_id, .active);
            var bodies = try arena.alloc([]const u8, active.len);
            for (active, 0..) |row, i| bodies[i] = row.body;
            const proposals = try d.store.listMemories(arena, project_id, .proposed);

            try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"replica\":", .{request.id});
            try std.json.Stringify.encodeJsonString(
                try project_mod.replicaName(arena, canonical),
                .{},
                w,
            );
            try w.writeAll(",\"issues\":{");
            inline for (std.meta.fields(model_mod.Issue.State), 0..) |field, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\":{d}", .{ field.name, counts[i] });
            }
            try w.print(
                "}},\"memory\":{{\"active\":{d},\"cap\":{d},\"proposed\":{d}," ++
                    "\"tokens\":{d},\"over_budget\":{}}}}}}}\n",
                .{
                    active.len,
                    memory_mod.active_cap,
                    proposals.len,
                    memory_mod.estimateTokens(bodies),
                    memory_mod.overBudget(bodies),
                },
            );
            return;
        }

        if (std.mem.startsWith(u8, verb, "triage.")) {
            return d.dispatchTriage(arena, w, request, project_id, verb);
        }

        const prefix = stringParam(params, "id") orelse
            return protocol.writeErr(w, request.id, .bad_params, "no issue id given");
        const rows = try d.store.listIssues(arena, project_id, null);

        var id_list = try arena.alloc(ids.Id, rows.len);
        for (rows, 0..) |row, i| id_list[i] = row.id;

        const row = switch (ids.resolvePrefix(prefix, id_list)) {
            .resolved => |i| rows[i],
            .ambiguous => return protocol.writeErr(w, request.id, .ambiguous_id, prefix),
            .missing => return protocol.writeErr(w, request.id, .no_issue, prefix),
            .malformed => return protocol.writeErr(w, request.id, .bad_params, "not an issue id"),
        };

        if (std.mem.eql(u8, verb, "get")) {
            return d.writeIssue(w, request.id, row);
        }

        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

        if (std.mem.eql(u8, verb, "edit") or std.mem.eql(u8, verb, "rename")) {
            const title = stringParam(params, "title");
            const body = stringParam(params, "body");
            if (title == null and body == null) {
                return protocol.writeErr(w, request.id, .bad_params, "nothing to change");
            }
            const expected = if (stringParam(params, "last_event_id")) |hex|
                ids.parseHex(hex) catch null
            else
                null;

            d.store.editIssue(ids.generateNow(d.io), row.id, title, body, expected, .human, now) catch |e| switch (e) {
                error.Conflict => return protocol.writeErr(
                    w,
                    request.id,
                    .conflict,
                    "this issue changed while you were editing — re-open it and redo the edit",
                ),
                error.IllegalTransition => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    "this issue is done; merged work is not edited after the fact",
                ),
                else => return e,
            };
            const fresh = (try d.store.getIssue(arena, row.id)).?;
            return d.writeIssue(w, request.id, fresh);
        }

        if (std.mem.eql(u8, verb, "state")) {
            const requested = stringParam(params, "state") orelse
                return protocol.writeErr(w, request.id, .bad_params, "no state given");
            const to = model_mod.Issue.State.parse(requested) orelse
                return protocol.writeErr(w, request.id, .bad_params, "unknown state");

            _ = d.store.appendEvent(
                ids.generateNow(d.io),
                row.id,
                null,
                .{ .kind = .state_changed, .actor = .human, .to = to },
                "",
                now,
            ) catch |e| switch (e) {
                error.IllegalTransition => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    "an issue does not move there by hand — 'run merge' reaches done, " ++
                        "'issue archive' drops it, 'issue triage' accepts a proposal",
                ),
                else => return e,
            };
            const fresh = (try d.store.getIssue(arena, row.id)).?;
            return d.writeIssue(w, request.id, fresh);
        }

        if (std.mem.eql(u8, verb, "merge")) {
            _ = d.store.appendEvent(
                ids.generateNow(d.io),
                row.id,
                null,
                .{ .kind = .merged, .actor = .human },
                stringParam(params, "commit") orelse "",
                now,
            ) catch |e| switch (e) {
                error.IllegalTransition => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    "that issue cannot be merged from its current state",
                ),
                else => return e,
            };
            const fresh = (try d.store.getIssue(arena, row.id)).?;
            return d.writeIssue(w, request.id, fresh);
        }

        if (std.mem.eql(u8, verb, "archive") or std.mem.eql(u8, verb, "reopen")) {
            const archiving = std.mem.eql(u8, verb, "archive");
            const reason = stringParam(params, "reason") orelse "";
            if (archiving and std.mem.trim(u8, reason, " \t\r\n").len == 0) {
                return protocol.writeErr(w, request.id, .bad_params, "archiving needs a reason (-m)");
            }
            _ = d.store.appendEvent(
                ids.generateNow(d.io),
                row.id,
                null,
                .{ .kind = if (archiving) .archived else .reopened, .actor = .human },
                reason,
                now,
            ) catch |e| switch (e) {
                error.IllegalTransition => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    if (archiving)
                        "that issue cannot be archived from its current state"
                    else
                        "only an archived issue can be reopened",
                ),
                else => return e,
            };
            const fresh = (try d.store.getIssue(arena, row.id)).?;
            return d.writeIssue(w, request.id, fresh);
        }

        if (std.mem.eql(u8, verb, "comment")) {
            const text = stringParam(params, "text") orelse
                return protocol.writeErr(w, request.id, .bad_params, "an empty comment says nothing");
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
                return protocol.writeErr(w, request.id, .bad_params, "an empty comment says nothing");
            }
            _ = try d.store.appendEvent(
                ids.generateNow(d.io),
                row.id,
                null,
                .{ .kind = .commented, .actor = .human },
                text,
                now,
            );
            const fresh = (try d.store.getIssue(arena, row.id)).?;
            return d.writeIssue(w, request.id, fresh);
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }

    fn writeIssue(d: *Daemon, w: *Io.Writer, request_id: u64, row: store_mod.Store.IssueRow) !void {
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":", .{request_id});
        try d.issueObject(w, row);
        try w.writeAll("}\n");
    }

    fn issueObject(d: *Daemon, w: *Io.Writer, row: store_mod.Store.IssueRow) !void {
        _ = d;
        try w.print("{{\"short\":\"{s}\",\"id\":\"{s}\",\"state\":\"{s}\",\"title\":", .{
            ids.short(row.id), ids.toHex(row.id), @tagName(row.state),
        });
        try std.json.Stringify.encodeJsonString(row.title, .{}, w);
        try w.writeAll(",\"body\":");
        try std.json.Stringify.encodeJsonString(row.body, .{}, w);
        try w.writeAll(",\"last_event_id\":");
        if (row.last_event_id) |last| {
            try w.print("\"{s}\"", .{ids.toHex(last)});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");
    }

    /// `capsule run` — the lifecycle of a container session.
    fn dispatchRun(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        const verb = request.method["run.".len..];
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };

        const canonical = d.canonicalPath(arena, params) catch
            return protocol.writeErr(w, request.id, .bad_params, "not a git repository");
        const project_id = (try d.store.findProject(canonical)) orelse
            return protocol.writeErr(w, request.id, .no_project, canonical);

        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

        if (std.mem.eql(u8, verb, "list")) {
            const rows = try d.store.listRuns(arena, project_id, 20);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try w.print(
                    "{{\"short\":\"{s}\",\"issue\":\"{s}\",\"state\":\"{s}\"," ++
                        "\"started_at\":{d},\"ended_at\":{?d},\"container\":\"{s}\",\"branch\":",
                    .{
                        ids.short(row.id),   ids.short(row.issue_id),
                        @tagName(row.state), row.started_at,
                        row.ended_at,        try store_mod.containerName(arena, row.id),
                    },
                );
                try std.json.Stringify.encodeJsonString(row.branch, .{}, w);
                try w.writeAll("}");
            }
            return w.writeAll("]}\n");
        }

        if (std.mem.eql(u8, verb, "start")) {
            if (try d.store.activeRunForProject(arena, project_id)) |live| {
                const row = try d.store.getIssue(arena, live.issue_id);
                try w.print(
                    "{{\"id\":{d},\"ok\":false,\"error\":{{\"code\":\"refused\",\"message\":",
                    .{request.id},
                );
                try std.json.Stringify.encodeJsonString(
                    try std.fmt.allocPrint(
                        arena,
                        "a run is already live on this project: {s} \"{s}\" in container {s}",
                        .{
                            ids.short(live.issue_id),
                            if (row) |r| r.title else "(unknown issue)",
                            try store_mod.containerName(arena, live.run_id),
                        },
                    ),
                    .{},
                    w,
                );
                try w.writeAll(",\"hint\":\"capsule run attach\"}}\n");
                return;
            }

            const prefix = stringParam(params, "issue") orelse
                return protocol.writeErr(w, request.id, .bad_params, "no issue given");
            const issues = try d.store.listIssues(arena, project_id, null);
            var id_list = try arena.alloc(ids.Id, issues.len);
            for (issues, 0..) |row, i| id_list[i] = row.id;

            const issue = switch (ids.resolvePrefix(prefix, id_list)) {
                .resolved => |i| issues[i],
                .ambiguous => return protocol.writeErr(w, request.id, .ambiguous_id, prefix),
                .missing => return protocol.writeErr(w, request.id, .no_issue, prefix),
                .malformed => return protocol.writeErr(w, request.id, .bad_params, "not an issue id"),
            };

            const run_id = ids.generateNow(d.io);
            const secret = token_mod.mint(d.io);
            const digest = token_mod.hash(&secret);
            const branch = try std.fmt.allocPrint(arena, "capsule/{s}", .{ids.toHex(issue.id)});

            d.store.startRun(run_id, issue.id, project_id, branch, &digest, ids.generateNow(d.io), now) catch |e| switch (e) {
                error.IllegalTransition => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    "that issue cannot be worked on — it is done or archived",
                ),
                else => return e,
            };

            const profile = (try d.store.projectProfile(arena, project_id)) orelse "default";

            try w.print(
                "{{\"id\":{d},\"ok\":true,\"result\":{{\"run\":\"{s}\",\"issue\":\"{s}\"," ++
                    "\"token\":\"{s}\",\"container\":\"{s}\",\"profile\":",
                .{
                    request.id,
                    ids.toHex(run_id),
                    ids.toHex(issue.id),
                    secret,
                    try store_mod.containerName(arena, run_id),
                },
            );
            try std.json.Stringify.encodeJsonString(profile, .{}, w);
            try w.writeAll(",\"branch\":");
            try std.json.Stringify.encodeJsonString(branch, .{}, w);
            try w.writeAll(",\"title\":");
            try std.json.Stringify.encodeJsonString(issue.title, .{}, w);
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, verb, "end")) {
            const live = (try d.store.activeRunForProject(arena, project_id)) orelse
                return protocol.writeErr(w, request.id, .refused, "no run is live on this project");
            try d.store.finishRun(live.run_id, .ended, now);
            return protocol.writeOk(w, request.id, "{\"ended\":true}");
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }

    /// `POST /mcp` — the agent's only route into the store.
    fn serveMcp(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        head: http.Head,
        body: []const u8,
    ) !void {
        const request = mcp.parseRequest(arena, body) catch {
            var buf: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
            try mcp.writeError(&bw.writer, null, -32700, "parse error");
            return http.writeResponse(w, 200, "application/json", bw.written());
        };

        if (std.mem.eql(u8, request.method, "initialize")) {
            var buf: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
            try mcp.writeInitialize(&bw.writer, request.id, mcp.negotiateVersion(request.params));
            return http.writeResponse(w, 200, "application/json", bw.written());
        }

        if (mcp.isNotification(request)) {
            return http.writeResponse(w, 202, "text/plain", "");
        }

        if (std.mem.eql(u8, request.method, "tools/list")) {
            var buf: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
            try mcp.writeToolList(&bw.writer, request.id);
            return http.writeResponse(w, 200, "application/json", bw.written());
        }

        if (!std.mem.eql(u8, request.method, "tools/call")) {
            var buf: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
            try mcp.writeError(&bw.writer, request.id, -32601, request.method);
            return http.writeResponse(w, 200, "application/json", bw.written());
        }

        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);

        const binding = switch (try d.resolveToken(arena, head.authorization)) {
            .ok => |b| b,
            .absent => return http.writeResponse(w, 401, "text/plain", "no run token\n"),
            .unknown => return http.writeResponse(w, 401, "text/plain", "unknown run token\n"),
        };

        const params = switch (request.params) {
            .object => |o| o,
            else => blk: {
                const e: std.json.ObjectMap = .empty;
                break :blk e;
            },
        };
        const name = stringParam(params, "name") orelse "";
        const args = switch (params.get("arguments") orelse std.json.Value.null) {
            .object => |o| o,
            else => blk: {
                const e: std.json.ObjectMap = .empty;
                break :blk e;
            },
        };

        var buf: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
        try d.callTool(arena, &bw.writer, request.id, binding, name, args);
        return http.writeResponse(w, 200, "application/json", bw.written());
    }

    fn resolveToken(
        d: *Daemon,
        arena: std.mem.Allocator,
        authorization: ?[]const u8,
    ) !token_mod.Resolution(ids.Id) {
        const active = try d.store.activeRuns(arena);
        var bindings = try arena.alloc(token_mod.Binding(ids.Id), active.len);
        var n: usize = 0;
        for (active) |run| {
            if (run.token_hash.len != @sizeOf(token_mod.Hash)) continue;
            var digest: token_mod.Hash = undefined;
            @memcpy(&digest, run.token_hash);
            bindings[n] = .{
                .run_id = run.run_id,
                .issue_id = run.issue_id,
                .project_id = run.project_id,
                .token_hash = digest,
            };
            n += 1;
        }
        return token_mod.resolve(ids.Id, authorization, bindings[0..n]);
    }

    fn callTool(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request_id: ?std.json.Value,
        binding: token_mod.Binding(ids.Id),
        name: []const u8,
        args: std.json.ObjectMap,
    ) !void {
        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

        if (std.mem.eql(u8, name, "get_issue")) {
            const issue = (try d.store.getIssue(arena, binding.issue_id)) orelse
                return mcp.writeToolResult(w, request_id, "this issue no longer exists", true);

            const memories = try d.store.listMemories(arena, binding.project_id, .active);

            var text: std.ArrayList(u8) = .empty;
            var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
            try tw.writer.print("issue {s} [{s}]\n{s}\n", .{
                ids.short(issue.id), @tagName(issue.state), issue.title,
            });
            if (issue.body.len > 0) try tw.writer.print("\n{s}\n", .{issue.body});
            if (memories.len > 0) {
                try tw.writer.print("\n--- project memory ({d}) ---\n", .{memories.len});
                for (memories) |memory| {
                    try tw.writer.print("- {s}\n", .{memory.body});
                }
            }
            return mcp.writeToolResult(w, request_id, tw.written(), false);
        }

        if (std.mem.eql(u8, name, "set_state")) {
            const requested = stringParam(args, "state") orelse
                return mcp.writeToolResult(w, request_id, "which state?", true);
            const to = model_mod.Issue.State.parse(requested) orelse
                return mcp.writeToolResult(w, request_id, "not a state I know", true);

            const comment = stringParam(args, "comment") orelse "";
            if ((to == .blocked or to == .ready_for_review) and
                std.mem.trim(u8, comment, " \t\r\n").len == 0)
            {
                return mcp.writeToolResult(
                    w,
                    request_id,
                    "a comment is required for blocked and ready_for_review — say what you did, " ++
                        "what you did not, and what the next person needs to know",
                    true,
                );
            }

            _ = d.store.appendEvent(
                ids.generateNow(d.io),
                binding.issue_id,
                binding.run_id,
                .{ .kind = .state_changed, .actor = .agent, .to = to },
                comment,
                now,
            ) catch |e| switch (e) {
                error.IllegalTransition => return mcp.writeToolResult(
                    w,
                    request_id,
                    "you cannot move this issue there",
                    true,
                ),
                else => return e,
            };
            if (comment.len > 0) {
                _ = d.store.appendEvent(
                    ids.generateNow(d.io),
                    binding.issue_id,
                    binding.run_id,
                    .{ .kind = .commented, .actor = .agent },
                    comment,
                    now,
                ) catch {};
            }
            return mcp.writeToolResult(w, request_id, requested, false);
        }

        if (std.mem.eql(u8, name, "comment")) {
            const text = stringParam(args, "text") orelse
                return mcp.writeToolResult(w, request_id, "an empty note says nothing", true);
            _ = try d.store.appendEvent(
                ids.generateNow(d.io),
                binding.issue_id,
                binding.run_id,
                .{ .kind = .commented, .actor = .agent },
                text,
                now,
            );
            return mcp.writeToolResult(w, request_id, "noted", false);
        }

        if (std.mem.eql(u8, name, "file_issue")) {
            const title = stringParam(args, "title") orelse
                return mcp.writeToolResult(w, request_id, "a follow-up needs a title", true);
            const body = stringParam(args, "body") orelse "";

            const existing = try d.store.listIssues(arena, binding.project_id, null);
            var similar: std.ArrayList(store_mod.Store.IssueRow) = .empty;
            for (existing) |row| {
                switch (row.state) {
                    .done, .archived, .proposed => continue,
                    else => {},
                }
                if (looksSimilar(title, row.title)) try similar.append(arena, row);
            }

            const new_id = ids.generateNow(d.io);
            _ = try d.store.createIssue(
                new_id,
                binding.project_id,
                title,
                body,
                .agent,
                ids.generateNow(d.io),
                now,
            );

            var text: std.ArrayList(u8) = .empty;
            var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
            try tw.writer.print("filed {s} for triage\n", .{ids.short(new_id)});
            if (similar.items.len > 0) {
                try tw.writer.writeAll("\nthese open issues look similar — if one already covers it, " ++
                    "say so in a comment rather than leaving a duplicate:\n");
                for (similar.items) |row| {
                    try tw.writer.print("  {s} [{s}] {s}\n", .{
                        ids.short(row.id), @tagName(row.state), row.title,
                    });
                }
            }
            return mcp.writeToolResult(w, request_id, tw.written(), false);
        }

        if (std.mem.eql(u8, name, "propose_memory")) {
            const body = stringParam(args, "body") orelse
                return mcp.writeToolResult(w, request_id, "a memory needs a body", true);

            var anchors: std.ArrayList(u8) = .empty;
            if (args.get("anchors")) |value| switch (value) {
                .array => |items| for (items.items) |item| switch (item) {
                    .string => |s| {
                        try anchors.appendSlice(arena, s);
                        try anchors.append(arena, '\n');
                    },
                    else => {},
                },
                else => {},
            };

            try d.store.proposeMemory(
                ids.generateNow(d.io),
                binding.project_id,
                body,
                anchors.items,
                binding.issue_id,
                now,
            );
            return mcp.writeToolResult(
                w,
                request_id,
                "proposed — a human reviews it before it is kept",
                false,
            );
        }

        return mcp.writeToolResult(w, request_id, "no such tool", true);
    }

    /// Triage and memory review share a shape: the daemon renders a buffer, the client
    /// opens it in an editor, the daemon parses what comes back and applies it in one
    /// transaction. Nothing is ever half-applied — half-applied triage has no clean
    /// recovery, so the parse either yields a whole plan or an error the client re-opens
    /// the buffer with.
    fn dispatchTriage(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
        project_id: ids.Id,
        verb: []const u8,
    ) !void {
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };
        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

        if (std.mem.eql(u8, verb, "triage.load")) {
            const proposed = try d.store.listIssues(arena, project_id, .proposed);
            var text: std.ArrayList(u8) = .empty;
            var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
            try tw.writer.writeAll(
                "<!-- capsule triage. verbs: keep | accept | reject -->\n" ++
                    "<!-- edit freely. save to apply. empty file aborts. -->\n" ++
                    "<!-- a deleted line means keep: nothing here is destroyed by omission. -->\n\n",
            );
            for (proposed) |row| {
                try tw.writer.print("## keep {s}  {s}\n", .{ ids.short(row.id), row.title });
                if (row.body.len > 0) try buffer_mod.renderBody(&tw.writer, row.body);
                try tw.writer.writeAll("\n");
            }
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"count\":{d},\"buffer\":", .{
                request.id, proposed.len,
            });
            try std.json.Stringify.encodeJsonString(tw.written(), .{}, w);
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, verb, "triage.apply")) {
            const text = stringParam(params, "buffer") orelse
                return protocol.writeErr(w, request.id, .bad_params, "no buffer");

            const proposed = try d.store.listIssues(arena, project_id, .proposed);
            var expected = try arena.alloc([]const u8, proposed.len);
            for (proposed, 0..) |row, i| expected[i] = try arena.dupe(u8, &ids.short(row.id));

            const verbs = [_][]const u8{ "keep", "accept", "reject" };
            const parsed = try buffer_mod.parse(arena, text, .{ .verbs = &verbs, .expected = expected });
            const entries = switch (parsed) {
                .ok => |e| e,
                .malformed => |err| return protocol.writeErr(
                    w,
                    request.id,
                    .bad_params,
                    try buffer_mod.describe(arena, err),
                ),
            };

            try d.store.begin();
            errdefer d.store.rollback();

            var accepted: usize = 0;
            var rejected: usize = 0;
            for (entries) |entry| {
                const row = findByShort(proposed, entry.id) orelse continue;
                if (std.mem.eql(u8, entry.verb, "accept")) {
                    try d.store.editIssue(ids.generateNow(d.io), row.id, entry.title, entry.body, null, .human, now);
                    _ = try d.store.appendEvent(
                        ids.generateNow(d.io),
                        row.id,
                        null,
                        .{ .kind = .triaged, .actor = .human },
                        "",
                        now,
                    );
                    accepted += 1;
                } else if (std.mem.eql(u8, entry.verb, "reject")) {
                    _ = try d.store.appendEvent(
                        ids.generateNow(d.io),
                        row.id,
                        null,
                        .{ .kind = .archived, .actor = .human },
                        if (entry.body.len > 0) entry.body else "rejected at triage",
                        now,
                    );
                    rejected += 1;
                }
            }
            try d.store.commit();

            return protocol.writeOk(w, request.id, try std.fmt.allocPrint(
                arena,
                "{{\"accepted\":{d},\"rejected\":{d}}}",
                .{ accepted, rejected },
            ));
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }

    fn findByShort(rows: []const store_mod.Store.IssueRow, short: []const u8) ?store_mod.Store.IssueRow {
        for (rows) |row| {
            if (std.mem.eql(u8, &ids.short(row.id), short)) return row;
        }
        return null;
    }

    fn findMemoryByShort(rows: []const store_mod.Store.MemoryRow, short: []const u8) ?store_mod.Store.MemoryRow {
        for (rows) |row| {
            if (std.mem.eql(u8, &ids.short(row.id), short)) return row;
        }
        return null;
    }

    /// One `anchors: <path>` line per anchor, so each parses back unambiguously. The
    /// paths are user-authored file names — content, but content with a fixed shape, so
    /// they stay at column 0 where the reviewer can edit them naturally.
    fn writeAnchorLines(w: *Io.Writer, anchors: []const u8) !void {
        var lines = std.mem.splitScalar(u8, anchors, '\n');
        while (lines.next()) |raw| {
            const anchor = std.mem.trim(u8, raw, " \t\r");
            if (anchor.len > 0) try w.print("anchors: {s}\n", .{anchor});
        }
    }

    const AnchorSplit = struct { anchors: []const u8, body: []const u8 };

    /// The inverse of `writeAnchorLines` plus the render indent: pulls the leading
    /// `anchors:` lines back out of an edited entry body and returns the anchors in
    /// their newline-separated storage shape. Allocates from `arena`.
    fn splitAnchors(arena: std.mem.Allocator, text: []const u8) !AnchorSplit {
        var anchors: std.ArrayList(u8) = .empty;
        var offset: usize = 0;
        while (offset < text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
            const line = std.mem.trim(u8, text[offset..line_end], " \t\r");
            if (!std.mem.startsWith(u8, line, "anchors:")) break;
            const path = std.mem.trim(u8, line["anchors:".len..], " \t");
            if (path.len > 0) {
                if (anchors.items.len > 0) try anchors.append(arena, '\n');
                try anchors.appendSlice(arena, path);
            }
            offset = @min(line_end + 1, text.len);
        }
        return .{
            .anchors = try anchors.toOwnedSlice(arena),
            .body = std.mem.trim(u8, text[offset..], "\r\n"),
        };
    }

    /// `capsule memory` — list, review, and the cap.
    fn dispatchMemory(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        const verb = request.method["memory.".len..];
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };

        const canonical = d.canonicalPath(arena, params) catch
            return protocol.writeErr(w, request.id, .bad_params, "not a git repository");
        const project_id = (try d.store.findProject(canonical)) orelse
            return protocol.writeErr(w, request.id, .no_project, canonical);

        const now = Io.Timestamp.now(d.io, .real).toMilliseconds();

        if (std.mem.eql(u8, verb, "stale")) {
            var gone: std.ArrayList([]const u8) = .empty;
            if (params.get("paths")) |value| switch (value) {
                .array => |items| for (items.items) |item| switch (item) {
                    .string => |s| try gone.append(arena, s),
                    else => {},
                },
                else => {},
            };

            const active = try d.store.listMemories(arena, project_id, .active);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            var n: usize = 0;
            for (active) |row| {
                if (!memory_mod.isSuspect(row.anchors, gone.items)) continue;
                if (n > 0) try w.writeAll(",");
                try w.print("{{\"short\":\"{s}\",\"body\":", .{ids.short(row.id)});
                try std.json.Stringify.encodeJsonString(row.body, .{}, w);
                try w.writeAll(",\"anchors\":");
                try std.json.Stringify.encodeJsonString(std.mem.trim(u8, row.anchors, "\n"), .{}, w);
                try w.writeAll("}");
                n += 1;
            }
            return w.writeAll("]}\n");
        }

        if (std.mem.eql(u8, verb, "list")) {
            const rows = try d.store.listMemories(arena, project_id, null);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"short\":\"{s}\",\"state\":\"{s}\",\"body\":", .{
                    ids.short(row.id), @tagName(row.state),
                });
                try std.json.Stringify.encodeJsonString(row.body, .{}, w);
                try w.writeAll(",\"anchors\":");
                try std.json.Stringify.encodeJsonString(row.anchors, .{}, w);
                try w.writeAll("}");
            }
            return w.writeAll("]}\n");
        }

        if (std.mem.eql(u8, verb, "new")) {
            const body = stringParam(params, "body") orelse
                return protocol.writeErr(w, request.id, .bad_params, "a memory needs a body");

            const active_now: usize = @intCast(try d.store.countActiveMemories(project_id));
            switch (memory_mod.applyCap(active_now, &.{.{ .id = "new", .verb = .activate }})) {
                .refused => return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    try std.fmt.allocPrint(
                        arena,
                        "{d} memories are already active, which is the cap — 'capsule memory review' " ++
                            "and deactivate one in the same pass",
                        .{memory_mod.active_cap},
                    ),
                ),
                .applied => {},
            }

            const id = ids.generateNow(d.io);
            try d.store.proposeMemory(id, project_id, body, stringParam(params, "anchors") orelse "", null, now);
            try d.store.setMemoryState(id, .active, now);
            return protocol.writeOk(w, request.id, "{\"added\":true}");
        }

        if (std.mem.eql(u8, verb, "review.load")) {
            const proposals = try d.store.listMemories(arena, project_id, .proposed);
            const active = try d.store.listMemories(arena, project_id, .active);

            var bodies = try arena.alloc([]const u8, active.len);
            for (active, 0..) |row, i| bodies[i] = row.body;

            var text: std.ArrayList(u8) = .empty;
            var tw = std.Io.Writer.Allocating.fromArrayList(arena, &text);
            try tw.writer.writeAll(
                "<!-- capsule memory review. verbs: keep | activate | discard -->\n" ++
                    "<!-- verbs on active memories: keep | deactivate -->\n",
            );
            try tw.writer.print(
                "<!-- {d}/{d} active, ~{d}k tokens (approx). save to apply. empty file aborts. -->\n\n",
                .{ active.len, memory_mod.active_cap, memory_mod.estimateTokens(bodies) / 1000 },
            );
            for (proposals) |row| {
                try tw.writer.print("## keep {s}\n", .{ids.short(row.id)});
                try writeAnchorLines(&tw.writer, row.anchors);
                try buffer_mod.renderBody(&tw.writer, row.body);
                try tw.writer.writeAll("\n");
            }
            if (active.len > 0) {
                try tw.writer.writeAll("<!-- existing active memories below — deactivate to make room -->\n\n");
                for (active) |row| {
                    try tw.writer.print("## keep {s}\n", .{ids.short(row.id)});
                    try writeAnchorLines(&tw.writer, row.anchors);
                    try buffer_mod.renderBody(&tw.writer, row.body);
                    try tw.writer.writeAll("\n");
                }
            }
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":{{\"proposals\":{d},\"active\":{d},\"buffer\":", .{
                request.id, proposals.len, active.len,
            });
            try std.json.Stringify.encodeJsonString(tw.written(), .{}, w);
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, verb, "review.apply")) {
            const text = stringParam(params, "buffer") orelse
                return protocol.writeErr(w, request.id, .bad_params, "no buffer");

            const all = try d.store.listMemories(arena, project_id, null);
            var expected: std.ArrayList([]const u8) = .empty;
            for (all) |row| switch (row.state) {
                .proposed, .active => try expected.append(arena, try arena.dupe(u8, &ids.short(row.id))),
                .inactive => {},
            };

            const verbs = [_][]const u8{ "keep", "activate", "discard", "deactivate" };
            const parsed = try buffer_mod.parse(arena, text, .{
                .verbs = &verbs,
                .expected = expected.items,
            });
            const entries = switch (parsed) {
                .ok => |e| e,
                .malformed => |err| return protocol.writeErr(
                    w,
                    request.id,
                    .bad_params,
                    try buffer_mod.describe(arena, err),
                ),
            };

            var decisions: std.ArrayList(memory_mod.Decision) = .empty;
            for (entries) |entry| {
                const v = memory_mod.Verb.parse(entry.verb) orelse continue;
                if (v == .keep) continue;
                const row = findMemoryByShort(all, entry.id) orelse continue;
                const complaint: ?[]const u8 = switch (v) {
                    .keep => null,
                    .activate, .discard => if (row.state == .proposed)
                        null
                    else
                        "only applies to a proposal — an active memory takes keep or deactivate",
                    .deactivate => if (row.state == .active)
                        null
                    else
                        "only applies to an active memory — a proposal takes keep, activate or discard",
                };
                if (complaint) |c| {
                    return protocol.writeErr(w, request.id, .refused, try std.fmt.allocPrint(
                        arena,
                        "'{s} {s}': {s}",
                        .{ entry.verb, entry.id, c },
                    ));
                }
                try decisions.append(arena, .{ .id = entry.id, .verb = v });
            }

            const active_now: usize = @intCast(try d.store.countActiveMemories(project_id));
            switch (memory_mod.applyCap(active_now, decisions.items)) {
                .refused => |r| return protocol.writeErr(
                    w,
                    request.id,
                    .refused,
                    try std.fmt.allocPrint(
                        arena,
                        "that would leave {d} active and the cap is {d} — deactivate one in the " ++
                            "same pass, or activate fewer",
                        .{ r.would_be, memory_mod.active_cap },
                    ),
                ),
                .applied => {},
            }

            try d.store.begin();
            errdefer d.store.rollback();

            var changed: usize = 0;
            for (entries) |entry| {
                const v = memory_mod.Verb.parse(entry.verb) orelse continue;
                const row = findMemoryByShort(all, entry.id) orelse continue;

                const edited = try splitAnchors(arena, entry.body);
                if (!std.mem.eql(u8, edited.body, row.body) or
                    !std.mem.eql(u8, edited.anchors, std.mem.trim(u8, row.anchors, "\n")))
                {
                    try d.store.editMemory(row.id, edited.body, edited.anchors, now);
                    changed += 1;
                }

                const next: ?model_mod.Memory.State = switch (v) {
                    .keep => null,
                    .activate => if (row.state == .active) null else .active,
                    .discard, .deactivate => .inactive,
                };
                if (next) |state| {
                    try d.store.setMemoryState(row.id, state, now);
                    changed += 1;
                }
            }
            try d.store.commit();

            return protocol.writeOk(w, request.id, try std.fmt.allocPrint(
                arena,
                "{{\"changed\":{d}}}",
                .{changed},
            ));
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }

    /// What the VM holds for a project that the host may reclaim: `branches` are the
    /// replica branches `vm gc` may delete, `runs` every run directory and container
    /// `run reset` must remove.
    fn dispatchGc(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        const verb = request.method["gc.".len..];
        const empty: std.json.ObjectMap = .empty;
        const params = switch (request.params) {
            .object => |o| o,
            else => empty,
        };
        const canonical = d.canonicalPath(arena, params) catch
            return protocol.writeErr(w, request.id, .bad_params, "not a git repository");
        const project_id = (try d.store.findProject(canonical)) orelse
            return protocol.writeErr(w, request.id, .no_project, canonical);

        if (std.mem.eql(u8, verb, "branches")) {
            const done = try d.store.listIssues(arena, project_id, .done);
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (done, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"capsule/{s}\"", .{ids.toHex(row.id)});
            }
            return w.writeAll("]}\n");
        }

        if (std.mem.eql(u8, verb, "runs")) {
            // Every run, not a page of them: one missed row orphans a seed directory in
            // the VM forever, and `run.list`'s display limit would do exactly that.
            const rows = try d.store.listRuns(arena, project_id, std.math.maxInt(u32));
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
            for (rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"dir\":\"{s}\",\"container\":\"{s}\"}}", .{
                    ids.toHex(row.id)[0..12],
                    try store_mod.containerName(arena, row.id),
                });
            }
            return w.writeAll("]}\n");
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }

    fn serveHttpRequest(d: *Daemon, stream: net.Stream) !void {
        setSocketTimeouts(stream, 30);

        var reader_buf: [4096]u8 = undefined;
        var head_buf: [http.max_head]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(d.io, &reader_buf);
        var writer = stream.writer(d.io, &write_buf);
        const w = &writer.interface;
        defer w.flush() catch {};

        var used: usize = 0;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => return http.writeResponse(w, 413, "text/plain", "header too long\n"),
                else => return,
            };
            if (used + line.len > head_buf.len) {
                return http.writeResponse(w, 413, "text/plain", "head too large\n");
            }
            @memcpy(head_buf[used..][0..line.len], line);
            used += line.len;
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        }

        const head = http.parseHead(head_buf[0..used]) catch
            return http.writeResponse(w, 400, "text/plain", "bad request\n");

        if (head.method == .get and std.mem.eql(u8, head.target, "/ping")) {
            return http.writeResponse(w, 200, "application/json", "{\"ok\":true}");
        }

        if (head.method == .post and std.mem.eql(u8, head.target, "/mcp")) {
            var arena = std.heap.ArenaAllocator.init(d.gpa);
            defer arena.deinit();
            const gpa = arena.allocator();

            var body: std.ArrayList(u8) = .empty;
            try body.appendSlice(gpa, head_buf[head.body_start..used]);
            while (body.items.len < head.content_length) {
                const want = head.content_length - body.items.len;
                const chunk = try gpa.alloc(u8, @min(want, 8192));
                const n = reader.interface.readSliceShort(chunk) catch break;
                if (n == 0) break;
                try body.appendSlice(gpa, chunk[0..n]);
            }
            return d.serveMcp(gpa, w, head, body.items);
        }

        if (head.method == .get and std.mem.eql(u8, head.target, "/status")) {
            var arena = std.heap.ArenaAllocator.init(d.gpa);
            defer arena.deinit();
            return d.serveStatus(arena.allocator(), w, head.authorization);
        }

        return http.writeResponse(w, 404, "text/plain", "not found\n");
    }

    /// Resolves the caller's token to the run it was minted for, and answers with just
    /// enough for a status line: which issue, what state, which branch.
    fn serveStatus(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        authorization: ?[]const u8,
    ) !void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);

        const active = d.store.activeRuns(arena) catch
            return http.writeResponse(w, 500, "text/plain", "store unavailable\n");

        var bindings = try arena.alloc(token_mod.Binding(ids.Id), active.len);
        var n: usize = 0;
        for (active) |run| {
            if (run.token_hash.len != @sizeOf(token_mod.Hash)) continue;
            var digest: token_mod.Hash = undefined;
            @memcpy(&digest, run.token_hash);
            bindings[n] = .{
                .run_id = run.run_id,
                .issue_id = run.issue_id,
                .project_id = run.project_id,
                .token_hash = digest,
            };
            n += 1;
        }

        switch (token_mod.resolve(ids.Id, authorization, bindings[0..n])) {
            .absent => return http.writeResponse(w, 401, "text/plain", "no run token\n"),
            .unknown => return http.writeResponse(w, 401, "text/plain", "unknown run token\n"),
            .ok => |binding| {
                const issue = (d.store.getIssue(arena, binding.issue_id) catch null) orelse
                    return http.writeResponse(w, 404, "text/plain", "no such issue\n");

                var body: std.ArrayList(u8) = .empty;
                var bw = std.Io.Writer.Allocating.fromArrayList(arena, &body);
                try bw.writer.print("{{\"issue\":\"{s}\",\"state\":\"{s}\",\"title\":", .{
                    ids.short(issue.id), @tagName(issue.state),
                });
                try std.json.Stringify.encodeJsonString(issue.title, .{}, &bw.writer);
                try bw.writer.writeAll(",\"branch\":");
                for (active) |run| {
                    if (std.mem.eql(u8, &run.run_id, &binding.run_id)) {
                        try std.json.Stringify.encodeJsonString(run.branch, .{}, &bw.writer);
                        break;
                    }
                } else try bw.writer.writeAll("null");
                try bw.writer.writeAll("}");

                return http.writeResponse(w, 200, "application/json", bw.written());
            },
        }
    }

    fn dispatch(
        d: *Daemon,
        arena: std.mem.Allocator,
        w: *Io.Writer,
        request: protocol.Request,
    ) !void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);

        if (std.mem.eql(u8, request.method, "ping")) {
            return protocol.writeOk(w, request.id, "{\"pong\":true}");
        }

        if (std.mem.eql(u8, request.method, "daemon.status")) {
            var body: std.ArrayList(u8) = .empty;
            var bw = std.Io.Writer.Allocating.fromArrayList(arena, &body);
            try bw.writer.writeAll("{\"socket\":");
            try std.json.Stringify.encodeJsonString(d.socket_path, .{}, &bw.writer);
            try bw.writer.print(",\"projects\":{d},\"endpoint\":\"{s}\"}}", .{
                d.store.countProjects() catch 0,
                if (d.http_up.load(.acquire)) "up" else "down",
            });
            return protocol.writeOk(w, request.id, bw.written());
        }

        if (std.mem.startsWith(u8, request.method, "project.")) {
            return d.dispatchProject(arena, w, request);
        }

        if (std.mem.startsWith(u8, request.method, "run.")) {
            return d.dispatchRun(arena, w, request);
        }

        if (std.mem.startsWith(u8, request.method, "memory.")) {
            return d.dispatchMemory(arena, w, request);
        }

        if (std.mem.startsWith(u8, request.method, "gc.")) {
            return d.dispatchGc(arena, w, request);
        }

        if (std.mem.startsWith(u8, request.method, "issue.")) {
            return d.dispatchIssue(arena, w, request);
        }

        if (std.mem.eql(u8, request.method, "world.get")) {
            try w.print("{{\"id\":{d},\"ok\":true,\"result\":", .{request.id});
            try d.writeSnapshot(arena, w);
            return w.writeAll("}\n");
        }

        if (std.mem.eql(u8, request.method, "daemon.stop")) {
            d.quit.store(true, .release);
            return protocol.writeOk(w, request.id, "{\"stopping\":true}");
        }

        return protocol.writeErr(w, request.id, .unknown_method, request.method);
    }
};

/// The loopback HTTP endpoint the container reaches through the reverse tunnel.
fn serveHttp(d: *Daemon) void {
    const addr: net.IpAddress = .{ .ip4 = .loopback(d.ssh_config.mcp_port) };
    var server = addr.listen(d.io, .{ .reuse_address = true }) catch |err| {
        std.log.warn("cannot bind 127.0.0.1:{d}: {t} — the MCP endpoint is down", .{
            d.ssh_config.mcp_port, err,
        });
        return;
    };
    defer server.deinit(d.io);
    d.http_up.store(true, .release);
    defer d.http_up.store(false, .release);

    while (!d.quit.load(.acquire)) {
        const stream = server.accept(d.io) catch continue;
        defer stream.close(d.io);
        if (d.quit.load(.acquire)) break;
        d.serveHttpRequest(stream) catch {};
    }
}

/// Takes the exclusive start lock at `<socket>.lock`, or fails with `AlreadyRunning`.
fn acquireStartLock(gpa: std.mem.Allocator, socket_path: []const u8) !std.posix.fd_t {
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{socket_path});
    defer gpa.free(lock_path);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        lock_path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
        0o600,
    );
    errdefer _ = std.c.close(fd);
    if (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) return error.AlreadyRunning;
    return fd;
}

/// A socket file left by a daemon that died is indistinguishable from one a live daemon
/// is listening on — until you try to talk to it. Ask first: if something answers, this
/// is a second daemon and it must not start. If nothing does, the file is debris.
fn clearStaleSocket(io: Io, path: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return,
    };

    if (stat.kind != .unix_domain_socket) {
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    }

    const addr = try net.UnixAddress.init(path);
    if (addr.connect(io)) |stream| {
        var s = stream;
        s.close(io);
        return error.AlreadyRunning;
    } else |_| {
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

const testing = std.testing;

test "a socket path over the kernel limit is rejected before binding" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const long = "x" ** (net.UnixAddress.max_len + 1);
    try testing.expectError(error.NameTooLong, net.UnixAddress.init(long));
}

fn stringParam(params: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (params.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Deliberately crude: shared significant words, not edit distance or embeddings. The
/// answer only has to be good enough to make an agent look twice before duplicating, and
/// anything cleverer would be a retrieval layer nobody asked for.
fn looksSimilar(a: []const u8, b: []const u8) bool {
    var shared: usize = 0;
    var words = std.mem.tokenizeAny(u8, a, " \t\n-_/.,:;()[]");
    while (words.next()) |word| {
        if (word.len < 4) continue;
        if (std.ascii.indexOfIgnoreCase(b, word) != null) shared += 1;
        if (shared >= 2) return true;
    }
    return false;
}
