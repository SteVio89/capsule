//! The world-model poller: one thread, one VM round trip every `poll_interval_s`, and
//! the two reconciliations that follow from what it saw.

const std = @import("std");
const Io = std.Io;

const ssh_mod = @import("../ssh.zig");
const world_mod = @import("../world.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// Refreshes the world model until `quit`. Runs on its own thread: a probe takes a VM
/// round trip and the accept loop must not wait on it.
pub fn poll(d: *Daemon) void {
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

        reconcileTunnel(d, snapshot.reachable);
        reconcileRuns(d, snapshot);

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
    const marked = d.store.reconcileRuns(
        gpa,
        names,
        Io.Timestamp.now(d.io, .real).toMilliseconds(),
    ) catch |err| {
        // Every three seconds, so a permanently broken store is loud. That is the point:
        // it means every run's state is now stale and nothing else will say so.
        std.log.warn("cannot reconcile runs against the VM's containers: {t}", .{err});
        return;
    };
    if (marked > 0) {
        std.log.info("marked {d} run(s) abandoned — their containers are gone", .{marked});
    }
}
