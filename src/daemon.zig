//! The host daemon: the only process that opens the store.
//!
//! This file is the state and the lifecycle; everything that acts on a `*Daemon` lives
//! beside it under `daemon/`. The handlers import `Daemon` back from here, which is a
//! cycle Zig resolves without complaint because no struct *field* takes part in it.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const ssh_mod = @import("ssh.zig");
const store_mod = @import("store.zig");
const world_mod = @import("world.zig");

const endpoint = @import("daemon/http.zig");
const poller = @import("daemon/poll.zig");
const transport = @import("daemon/transport.zig");

// `refAllDecls` in `root.zig` is shallow: it analyses this file but not the files this
// file imports, so a test under `daemon/` is collected only if listed here. Omitting one
// does not fail — it silently stops running while the summary still says all passed.
test {
    _ = @import("daemon/auth.zig");
    _ = @import("daemon/http.zig");
    _ = @import("daemon/params.zig");
    _ = @import("daemon/poll.zig");
    _ = @import("daemon/router.zig");
    _ = @import("daemon/transport.zig");
    _ = @import("daemon/views.zig");
    _ = @import("daemon/handlers/board.zig");
    _ = @import("daemon/handlers/doctor.zig");
    _ = @import("daemon/handlers/gc.zig");
    _ = @import("daemon/handlers/issue.zig");
    _ = @import("daemon/handlers/mcp.zig");
    _ = @import("daemon/handlers/memory.zig");
    _ = @import("daemon/handlers/project.zig");
    _ = @import("daemon/handlers/run.zig");
}

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

    /// Binds and serves until `quit`. Cleans the socket up on the way out so the next
    /// start does not have to reason about a leftover it wrote itself.
    pub fn serve(d: *Daemon) !void {
        const lock_fd = try transport.acquireStartLock(d.gpa, d.socket_path);
        defer _ = std.c.close(lock_fd);

        try transport.clearStaleSocket(d.io, d.socket_path);

        const addr = try net.UnixAddress.init(d.socket_path);
        var server = try addr.listen(d.io, .{});
        defer server.deinit(d.io);
        defer Io.Dir.cwd().deleteFile(d.io, d.socket_path) catch {};

        const poll_thread = std.Thread.spawn(.{}, poller.poll, .{d}) catch |err| blk: {
            std.log.warn("world-model poller did not start: {t}", .{err});
            break :blk null;
        };
        defer if (poll_thread) |t| t.join();
        const server_thread = std.Thread.spawn(.{}, endpoint.serveHttp, .{d}) catch |err| blk: {
            std.log.warn("MCP endpoint thread did not start: {t}", .{err});
            break :blk null;
        };
        defer if (server_thread) |t| t.join();
        defer transport.nudgeHttp(d);
        defer d.quit.store(true, .release);

        while (!d.quit.load(.acquire)) {
            const stream = server.accept(d.io) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            defer stream.close(d.io);
            transport.serveConnection(d, stream) catch {};
        }
    }
};
