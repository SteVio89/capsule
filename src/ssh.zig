//! The daemon's ssh: the ControlMaster it owns, the reverse tunnel it holds open, and the
//! one batched probe it runs on a timer.

const std = @import("std");
const world = @import("world.zig");

pub const Config = struct {
    /// `user@host`, validated by bash before it ever reaches here.
    vm_host: []const u8,
    vm_port: u16 = 2222,
    control_dir: []const u8,
    /// One shared port for every run. The token disambiguates callers, so there is no
    /// per-run port and no registry to keep.
    mcp_port: u16 = 8765,
    image: []const u8 = "",
};

/// Options every ssh invocation shares. `%C` hashes the connection tuple into something
/// short — the control socket is itself a unix socket under a 108-byte cap, and a literal
/// user@host:port name blows that on a long TMPDIR.
pub fn commonArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ControlMaster=auto",
        "-o", try std.fmt.allocPrint(arena, "ControlPath={s}/cm-%C", .{cfg.control_dir}),
        "-o", "ControlPersist=10m",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-p", try std.fmt.allocPrint(arena, "{d}", .{cfg.vm_port}),
    });
    return args.toOwnedSlice(arena);
}

/// `ssh -M -N -f`: open the shared master and detach. Everything after this reuses it,
/// which takes a VM round trip from ~250ms to ~10ms. A dashboard polling several facts is
/// unusable without it and fine with it.
pub fn masterArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, "ssh");
    try args.appendSlice(arena, try commonArgs(arena, cfg));
    try args.appendSlice(arena, &.{ "-M", "-N", "-f", cfg.vm_host });
    return args.toOwnedSlice(arena);
}

/// `ssh -O <verb>` against the shared master — `check` to probe it, `exit` to tear it
/// down. The argv is allocated in `arena`, which owns it.
pub fn controlArgs(arena: std.mem.Allocator, cfg: Config, verb: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, "ssh");
    try args.appendSlice(arena, try commonArgs(arena, cfg));
    try args.appendSlice(arena, &.{ "-O", verb, cfg.vm_host });
    return args.toOwnedSlice(arena);
}

/// The reverse tunnel gets its own ssh process rather than riding the master with
/// `-O forward`: a master restart silently drops a multiplexed forward, and a tunnel that
/// is quietly gone is worse than one that visibly died.
pub fn tunnelArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, "ssh");
    try args.appendSlice(arena, try commonArgs(arena, cfg));
    try args.appendSlice(arena, &.{
        "-o",        "ExitOnForwardFailure=yes",
        "-N",        "-T",
        "-R",
        try std.fmt.allocPrint(
            arena,
            "127.0.0.1:{d}:localhost:{d}",
            .{ cfg.mcp_port, cfg.mcp_port },
        ),
        cfg.vm_host,
    });
    return args.toOwnedSlice(arena);
}

/// Starts the reverse tunnel as a detached child and hands back the handle.
pub fn startTunnel(arena: std.mem.Allocator, io: std.Io, cfg: Config) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = try tunnelArgs(arena, cfg),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Wraps `text` in single quotes for a POSIX shell, escaping embedded single quotes.
pub fn shellQuote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// One call per tick, not one per fact. Returns the arena-allocated ssh argv.
pub fn probeArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, "ssh");
    try args.appendSlice(arena, try commonArgs(arena, cfg));
    const image = if (cfg.image.len == 0) "none" else cfg.image;
    try args.appendSlice(arena, &.{
        cfg.vm_host,
        try std.fmt.allocPrint(
            arena,
            "CAPSULE_IMAGE={s}\n{s}",
            .{ try shellQuote(arena, image), world.probe_script },
        ),
    });
    return args.toOwnedSlice(arena);
}

/// Runs the probe and parses it. A failure of any kind — VM down, ssh refused, timeout —
/// is an unreachable snapshot, not an error: a VM-down world model is a normal state and
/// the daemon must keep serving through it.
pub fn probe(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    now_ms: i64,
) world.Snapshot {
    const argv = probeArgs(arena, cfg) catch return .{};

    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 10 * std.time.ns_per_s }, .clock = .awake } },
    }) catch return .{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return .{},
        else => return .{},
    }

    const copy = arena.dupe(u8, result.stdout) catch return .{};
    return world.parseProbe(arena, copy, now_ms) catch .{};
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn joined(arena: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return std.mem.join(arena, " ", argv);
}

const test_cfg = Config{
    .vm_host = "core@localhost",
    .vm_port = 2222,
    .control_dir = "/run/user/1000/capsule",
    .mcp_port = 8765,
    .image = "ghcr.io/x/capsule:latest",
};

test "every invocation multiplexes over the same control path" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try commonArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, line, "ControlMaster=auto") != null);
    try testing.expect(std.mem.indexOf(u8, line, "ControlPath=/run/user/1000/capsule/cm-%C") != null);
    try testing.expect(std.mem.indexOf(u8, line, "ControlPersist=10m") != null);
    try testing.expect(std.mem.indexOf(u8, line, "-p 2222") != null);
}

test "the master is the only invocation that passes -M" {
    var a = testArena();
    defer a.deinit();
    const master = try joined(a.allocator(), try masterArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, master, " -M ") != null);

    const probe_line = try joined(a.allocator(), try probeArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, probe_line, " -M ") == null);
}

test "the tunnel binds the VM's loopback and never every interface" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try tunnelArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, line, "127.0.0.1:8765:localhost:8765") != null);
    try testing.expect(std.mem.indexOf(u8, line, "0.0.0.0") == null);
    try testing.expect(std.mem.indexOf(u8, line, "GatewayPorts") == null);
}

test "the tunnel refuses to sit there having failed to forward" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try tunnelArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, line, "ExitOnForwardFailure=yes") != null);
}

test "control verbs address the same master" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try controlArgs(a.allocator(), test_cfg, "check"));
    try testing.expect(std.mem.indexOf(u8, line, "-O check") != null);
    try testing.expect(std.mem.indexOf(u8, line, "core@localhost") != null);
}

test "the probe carries the image so the digest can be compared" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try probeArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_IMAGE='ghcr.io/x/capsule:latest'") != null);
}

test "the probe script itself travels in the remote command" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try probeArgs(a.allocator(), test_cfg));
    try testing.expect(std.mem.indexOf(u8, line, "sh -s") == null);
    try testing.expect(std.mem.indexOf(u8, line, world.probe_script) != null);
}

test "an unconfigured image still produces a runnable probe" {
    var a = testArena();
    defer a.deinit();
    var bare = test_cfg;
    bare.image = "";
    const line = try joined(a.allocator(), try probeArgs(a.allocator(), bare));
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_IMAGE='none'") != null);
}

test "a hostile image name cannot break out of its quoting" {
    var a = testArena();
    defer a.deinit();
    const quoted = try shellQuote(a.allocator(), "im'age; rm -rf /");
    try testing.expectEqualStrings("'im'\\''age; rm -rf /'", quoted);
}
