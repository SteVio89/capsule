//! Every ssh capsule makes: the shared ControlMaster, the reverse tunnel the daemon holds
//! open, the batched probe on the poll timer, and the commands the CLI runs on the VM.
//!
//! One master, one control directory, one place that spells the options. bash kept a second
//! copy of all of this, pointed at a different control directory, so the daemon's warm
//! master sat unused while every CLI ssh paid a fresh ~250ms handshake.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const exec = @import("exec.zig");
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

/// The ssh settings, taken from the one parsed config both the daemon and the CLI load.
/// The whole point of the narrow struct is that this is the only conversion, so the two
/// cannot drift the way `bin/capsule`'s `ssh_opts` drifted from `commonArgs`.
pub fn configFrom(settings: config.Config) Config {
    return .{
        .vm_host = settings.vm_host,
        .vm_port = settings.vm_port,
        .control_dir = settings.control_dir,
        .mcp_port = settings.mcp_port,
        .image = settings.image,
    };
}

/// Options every ssh invocation shares. `%C` hashes the connection tuple into something
/// short — the control socket is itself a unix socket under a 108-byte cap, and a literal
/// user@host:port name blows that on a long TMPDIR.
///
/// With no control directory the multiplexing options are left off entirely rather than
/// pointed at `/cm-%C`: an unconfigured capsule should be slow, not broken.
pub fn commonArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "-o", "StrictHostKeyChecking=accept-new" });
    if (cfg.control_dir.len > 0) {
        try args.appendSlice(arena, &.{
            "-o", "ControlMaster=auto",
            "-o", try std.fmt.allocPrint(arena, "ControlPath={s}/cm-%C", .{cfg.control_dir}),
            "-o", "ControlPersist=10m",
        });
    }
    try args.appendSlice(arena, &.{
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        // Without this a call to a powered-off VM blocks for the OS default, around 75
        // seconds. bash never noticed because it TCP-probed before every ssh; Zig calls
        // ssh directly, so the bound has to live in the options.
        "-o", "ConnectTimeout=10",
        "-p", try std.fmt.allocPrint(arena, "{d}", .{cfg.vm_port}),
    });
    return args.toOwnedSlice(arena);
}

/// `ssh` plus the shared options, ready for a caller to append its own arguments to.
fn baseArgs(arena: std.mem.Allocator, cfg: Config) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, "ssh");
    try args.appendSlice(arena, try commonArgs(arena, cfg));
    return args;
}

/// `ssh -M -N -f`: open the shared master and detach. Everything after this reuses it,
/// which takes a VM round trip from ~250ms to ~10ms. A dashboard polling several facts is
/// unusable without it and fine with it.
pub fn masterArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args = try baseArgs(arena, cfg);
    try args.appendSlice(arena, &.{ "-M", "-N", "-f", cfg.vm_host });
    return args.toOwnedSlice(arena);
}

/// `ssh -O <verb>` against the shared master — `check` to probe it, `exit` to tear it
/// down. The argv is allocated in `arena`, which owns it.
pub fn controlArgs(arena: std.mem.Allocator, cfg: Config, verb: []const u8) ![]const []const u8 {
    var args = try baseArgs(arena, cfg);
    try args.appendSlice(arena, &.{ "-O", verb, cfg.vm_host });
    return args.toOwnedSlice(arena);
}

/// The reverse tunnel gets its own ssh process rather than riding the master with
/// `-O forward`: a master restart silently drops a multiplexed forward, and a tunnel that
/// is quietly gone is worse than one that visibly died.
pub fn tunnelArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args = try baseArgs(arena, cfg);
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

/// The argv for running `remote` on the VM. `remote` is one string, parsed once by the
/// remote login shell — the only place in capsule where a shell string is legitimate, and
/// the reason every value interpolated into one goes through `shellQuote` first.
pub fn execArgs(arena: std.mem.Allocator, cfg: Config, remote: []const u8) ![]const []const u8 {
    var args = try baseArgs(arena, cfg);
    try args.append(arena, cfg.vm_host);
    if (remote.len > 0) try args.append(arena, remote);
    return args.toOwnedSlice(arena);
}

/// The same with `-t`, which allocates a remote tty. Needed by anything that draws:
/// a login shell, `podman exec -it`, an editor on the VM.
/// An empty `remote` means "no command" — a login shell — and the argument is omitted
/// rather than passed as `""`.
///
/// This is not a nicety. `ssh host ""` is ssh being *given* a command to run, which the
/// remote shell executes as nothing and exits from immediately, so `capsule vm ssh` opened
/// a session and closed it in the same breath. bash omitted the argument when it had none;
/// passing an empty string was the port's invention.
pub fn execTtyArgs(arena: std.mem.Allocator, cfg: Config, remote: []const u8) ![]const []const u8 {
    var args = try baseArgs(arena, cfg);
    try args.append(arena, "-t");
    try args.append(arena, cfg.vm_host);
    if (remote.len > 0) try args.append(arena, remote);
    return args.toOwnedSlice(arena);
}

/// Creates the control directory if it is missing, `0700` because a control socket lets
/// anyone who can reach it open a session on the VM as you.
///
/// The mode is set through `std.c.chmod` rather than a `std.posix` wrapper: this is
/// best-effort, and several `std.posix` wrappers map errnos to `unreachable`, which is a
/// panic that a `catch` cannot absorb.
pub fn ensureControlDir(arena: std.mem.Allocator, io: Io, cfg: Config) void {
    if (cfg.control_dir.len == 0) return;
    Io.Dir.cwd().createDirPath(io, cfg.control_dir) catch {};

    const path = arena.dupeZ(u8, cfg.control_dir) catch return;
    _ = std.c.chmod(path.ptr, 0o700);
}

/// Whether the shared master is up and answering.
pub fn masterAlive(arena: std.mem.Allocator, io: Io, cfg: Config) bool {
    if (cfg.control_dir.len == 0) return false;
    const argv = controlArgs(arena, cfg, "check") catch return false;
    const out = exec.run(arena, io, argv, .{ .timeout = timeout(5) }) catch return false;
    return out.ok();
}

/// Opens the shared master if nothing is holding it, so the calls after this one cost a
/// round trip rather than a handshake.
///
/// Best-effort by design: `ControlMaster=auto` means every invocation still works if this
/// does nothing at all. It exists so the *first* command in a burst pays the handshake
/// once instead of each command paying its own.
pub fn ensureMaster(arena: std.mem.Allocator, io: Io, cfg: Config) void {
    if (cfg.control_dir.len == 0) return;
    ensureControlDir(arena, io, cfg);
    if (masterAlive(arena, io, cfg)) return;

    const argv = masterArgs(arena, cfg) catch return;
    _ = exec.run(arena, io, argv, .{ .timeout = timeout(20) }) catch {};
}

/// Whether the VM answers, asked without the daemon.
///
/// The daemon's world model is the better answer when it is available — it is refreshed on
/// a timer over a warm master and costs nothing to read. This is the fallback for the
/// commands that need a VM but not a daemon (`vm ssh`, `vm gc`, `image pull`, `login`),
/// which would otherwise be refused for the wrong reason whenever capsuled is down.
///
/// It asks whether ssh works rather than whether the port accepts a connection, which is
/// what bash's `/dev/tcp` probe tested. A VM that accepts TCP but refuses the key is down
/// as far as every caller here is concerned.
pub fn reachable(arena: std.mem.Allocator, io: Io, cfg: Config) bool {
    if (masterAlive(arena, io, cfg)) return true;

    ensureControlDir(arena, io, cfg);
    const argv = execArgs(arena, cfg, "true") catch return false;
    const out = exec.run(arena, io, argv, .{ .timeout = timeout(15) }) catch return false;
    return out.ok();
}

/// Runs `remote` on the VM and captures its output. A non-zero exit is a normal return,
/// as it is for `exec.run` — a remote command failing is data, not a breakage.
pub fn run(
    arena: std.mem.Allocator,
    io: Io,
    cfg: Config,
    remote: []const u8,
    seconds: u32,
) exec.Error!exec.Output {
    ensureControlDir(arena, io, cfg);
    return exec.run(arena, io, try execArgs(arena, cfg, remote), .{
        .timeout = timeout(seconds),
        .stdout_limit = .limited(1 << 22),
        .stderr_limit = .limited(1 << 20),
    });
}

/// Runs `remote` on the VM with the terminal handed over, for a session the user drives.
/// No timeout: the user decides when an interactive session is over.
pub fn interactive(arena: std.mem.Allocator, io: Io, cfg: Config, remote: []const u8) exec.Error!u8 {
    ensureControlDir(arena, io, cfg);
    return exec.interactive(io, try execTtyArgs(arena, cfg, remote), .{});
}

/// Runs `remote` on the VM with `input` as its stdin, capturing what the script printed.
///
/// This is the batched shape: one generated script, one connection, `key<TAB>value` lines
/// back — the pattern `world.probe_script` established for the poller, applied to the work
/// `run start` used to spread across thirteen separate remote shells.
pub fn runWithInput(
    arena: std.mem.Allocator,
    io: Io,
    cfg: Config,
    remote: []const u8,
    input: Io.File,
    seconds: u32,
) exec.Error!exec.Output {
    ensureControlDir(arena, io, cfg);
    return exec.runWithInput(arena, io, try execArgs(arena, cfg, remote), input, .{
        .timeout = timeout(seconds),
        .stdout_limit = .limited(1 << 20),
    });
}

/// Runs output the user should watch scroll by — `podman pull`, `nix-collect-garbage`.
/// Inherits capsule's stdio rather than capturing, so progress appears as it happens.
pub fn stream(arena: std.mem.Allocator, io: Io, cfg: Config, remote: []const u8) exec.Error!u8 {
    ensureControlDir(arena, io, cfg);
    return exec.stream(io, try execArgs(arena, cfg, remote), .{});
}

fn timeout(seconds: u32) Io.Timeout {
    return .{ .duration = .{
        .raw = .{ .nanoseconds = @as(u64, seconds) * std.time.ns_per_s },
        .clock = .awake,
    } };
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
    var args = try baseArgs(arena, cfg);
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
        .timeout = timeout(10),
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

test "the CLI and the daemon build the same options from one config" {
    var a = testArena();
    defer a.deinit();

    // The regression this pins: two control directories, so the daemon's warm master was
    // never the one the CLI reused.
    const settings = config.Config{
        .vm_host = "core@localhost",
        .vm_port = 2222,
        .control_dir = "/run/user/1000/capsule",
        .mcp_port = 8765,
        .image = "ghcr.io/x/capsule:latest",
    };
    const derived = configFrom(settings);
    try testing.expectEqualStrings(test_cfg.control_dir, derived.control_dir);

    const probe_line = try joined(a.allocator(), try probeArgs(a.allocator(), derived));
    const exec_line = try joined(a.allocator(), try execArgs(a.allocator(), derived, "uptime -p"));
    const path = "ControlPath=/run/user/1000/capsule/cm-%C";
    try testing.expect(std.mem.indexOf(u8, probe_line, path) != null);
    try testing.expect(std.mem.indexOf(u8, exec_line, path) != null);
}

test "the remote command is one argument, so the remote shell parses it once" {
    var a = testArena();
    defer a.deinit();

    // This is the argv-count property `test/capsule-test.sh:163-186` guards on the far
    // side: the container command must survive exactly one shell parse. If the command
    // were split across arguments here, ssh would rejoin it and a second parse would eat
    // the quoting.
    const remote = "podman run --rm -e T='a b' img sh -c 'echo hi'";
    const argv = try execArgs(a.allocator(), test_cfg, remote);
    try testing.expectEqualStrings(remote, argv[argv.len - 1]);
    try testing.expectEqualStrings(test_cfg.vm_host, argv[argv.len - 2]);
}

test "no remote command means no argument, not an empty one" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    // `ssh host ""` hands ssh a command to run. The remote shell runs nothing and exits,
    // so `capsule vm ssh` opened a login shell and closed it in the same breath.
    const tty = try execTtyArgs(arena, test_cfg, "");
    try testing.expectEqualStrings(test_cfg.vm_host, tty[tty.len - 1]);

    const plain = try execArgs(arena, test_cfg, "");
    try testing.expectEqualStrings(test_cfg.vm_host, plain[plain.len - 1]);

    // With a command it is the last word, and the host is the one before it.
    const with = try execTtyArgs(arena, test_cfg, "uptime -p");
    try testing.expectEqualStrings("uptime -p", with[with.len - 1]);
    try testing.expectEqualStrings(test_cfg.vm_host, with[with.len - 2]);
}

test "only the interactive form asks for a remote tty" {
    var a = testArena();
    defer a.deinit();
    const plain = try joined(a.allocator(), try execArgs(a.allocator(), test_cfg, "true"));
    const tty = try joined(a.allocator(), try execTtyArgs(a.allocator(), test_cfg, "true"));
    try testing.expect(std.mem.indexOf(u8, plain, " -t ") == null);
    try testing.expect(std.mem.indexOf(u8, tty, " -t ") != null);
}

test "without a control directory ssh still runs, just unmultiplexed" {
    var a = testArena();
    defer a.deinit();

    // A config that failed to resolve must not produce `ControlPath=/cm-%C`, which ssh
    // would try to create at the filesystem root on every single call.
    var bare = test_cfg;
    bare.control_dir = "";
    const line = try joined(a.allocator(), try execArgs(a.allocator(), bare, "true"));
    try testing.expect(std.mem.indexOf(u8, line, "ControlPath") == null);
    try testing.expect(std.mem.indexOf(u8, line, "ControlMaster") == null);
    try testing.expect(std.mem.indexOf(u8, line, "StrictHostKeyChecking=accept-new") != null);
    try testing.expect(std.mem.indexOf(u8, line, "-p 2222") != null);
}

test "every form that reaches the VM carries the shared options" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const lines = [_][]const u8{
        try joined(arena, try execArgs(arena, test_cfg, "true")),
        try joined(arena, try execTtyArgs(arena, test_cfg, "true")),
        try joined(arena, try probeArgs(arena, test_cfg)),
        try joined(arena, try masterArgs(arena, test_cfg)),
        try joined(arena, try controlArgs(arena, test_cfg, "check")),
        try joined(arena, try tunnelArgs(arena, test_cfg)),
    };
    for (lines) |line| {
        try testing.expect(std.mem.startsWith(u8, line, "ssh "));
        try testing.expect(std.mem.indexOf(u8, line, "ControlPath=/run/user/1000/capsule/cm-%C") != null);
        try testing.expect(std.mem.indexOf(u8, line, "-p 2222") != null);
    }
}

test "a hostile image name cannot break out of its quoting" {
    var a = testArena();
    defer a.deinit();
    const quoted = try shellQuote(a.allocator(), "im'age; rm -rf /");
    try testing.expectEqualStrings("'im'\\''age; rm -rf /'", quoted);
}
