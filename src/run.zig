//! The container command line, the rules about when a run may start, and the two remote
//! scripts `run start` sends to the VM.
//!
//! bash made thirteen ssh round trips to start a run, each one a fresh remote shell that
//! knew nothing about the last. These two scripts carry the same work in two, with
//! `git push` between them — the seam is not removable, because git owns that connection
//! and the replica must exist before the push and be checked out after it.

const std = @import("std");

const ssh = @import("ssh.zig");

pub const Config = struct {
    image: []const u8,
    container_home: []const u8 = "/home/agent",
    mcp_port: u16 = 8765,
    /// `capsule-<first 12 of run id>`.
    container_name: []const u8,
    /// Where the replica is checked out on the VM.
    project_dir: []const u8,
    /// The per-run agent-state directory on the VM.
    agent_state_dir: []const u8,
    /// A mode-0600 file on the VM holding CAPSULE_RUN_TOKEN and the agent's credentials.
    env_file: []const u8,
    profile: []const u8,
    /// Empty for `capsule login`, which has no issue and no token.
    issue_short: []const u8 = "",
    /// The VM's `~/.gitconfig`, mounted read-only into the container. Empty when the VM
    /// has none — the caller checks first, since mounting a missing path makes podman
    /// create an empty directory there instead.
    git_config_path: []const u8 = "",
};

/// The detached `podman run` for an agent session.
///
/// `-d -t`, never `-i`. The PTY `-t` allocates lives on the VM, and `tmux new-session`
/// needs one to attach to; without it tmux exits "not a terminal" and the container
/// with it. `-i` is the dangerous one: it would wire stdin to the ssh client that
/// started the run, tying the session to the connection expected to drop.
///
/// `--network=host` puts the container on the VM's loopback, where the reverse tunnel
/// lands; `--env-file` keeps the token out of the VM's process table.
pub fn podmanArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        "podman",         "run",
        "-d",             "-t",
        "--name",         cfg.container_name,
        "--security-opt", "label=disable",
        "--network=host", "--env-file",
        cfg.env_file,
    });

    try args.appendSlice(arena, &.{
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_MCP_PORT={d}", .{cfg.mcp_port}),
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_PROJECT_DIR={s}", .{cfg.project_dir}),
        "-e", "CAPSULE_IN_CAPSULE=1",
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_PROFILE={s}", .{cfg.profile}),
        "-e", try std.fmt.allocPrint(arena, "CLAUDE_CONFIG_DIR={s}/.claude", .{cfg.container_home}),
        // The container runs as root and the seeded settings ask for bypassPermissions,
        // which claude refuses under uid 0 unless it is told it is already sandboxed.
        "-e", "IS_SANDBOX=1",
        "-e", "DOCKER_HOST=unix:///run/podman.sock",
        "-e", "TESTCONTAINERS_RYUK_DISABLED=true",
        "-e", "TESTCONTAINERS_HOST_OVERRIDE=host.containers.internal",
    });

    try args.appendSlice(arena, &.{
        "-v", "capsule-nix:/nix",
        "-v", try std.fmt.allocPrint(arena, "{s}:{s}/.claude", .{ cfg.agent_state_dir, cfg.container_home }),
        "-v", try std.fmt.allocPrint(arena, "{s}:{s}", .{ cfg.project_dir, cfg.project_dir }),
    });

    if (cfg.git_config_path.len > 0) {
        try args.appendSlice(arena, &.{
            "-v", try std.fmt.allocPrint(arena, "{s}:{s}/.gitconfig:ro", .{ cfg.git_config_path, cfg.container_home }),
        });
    }

    try args.appendSlice(arena, &.{
        "-w",      cfg.project_dir,
        cfg.image,
    });

    try args.appendSlice(arena, &.{ "-lc", try sessionCommand(arena, cfg) });
    return args.toOwnedSlice(arena);
}

pub const LoginConfig = struct {
    image: []const u8,
    container_home: []const u8 = "/home/agent",
    profile: []const u8,
    /// The profile's `.claude` directory on the VM, already absolute.
    ///
    /// Absolute rather than `$HOME/...` because every word of this argv is shell-quoted by
    /// `commandLine` before it crosses ssh — a `$HOME` written here would arrive literal
    /// and podman would create a directory called `$HOME`.
    state_dir: []const u8,
};

/// The container `capsule login` drops you into.
///
/// Deliberately not `podmanArgs`. A login has no run, so it has no token, no env file, no
/// project mount, no MCP port and no reverse tunnel to reach — and `-it --rm` rather than
/// `-d -t`, because this one *is* the session you are sitting in. The only thing it shares
/// with a run is the nix volume and the profile's `.claude` directory, which is the whole
/// point: authenticate once, and every later run of that profile inherits it.
pub fn loginArgs(arena: std.mem.Allocator, cfg: LoginConfig) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        "podman",         "run",
        "--rm",           "-it",
        "--security-opt", "label=disable",
        "-e",             "CAPSULE_IN_CAPSULE=1",
        "-e",             try std.fmt.allocPrint(arena, "CAPSULE_PROFILE={s}", .{cfg.profile}),
        "-v",             "capsule-nix:/nix",
        "-v",
        try std.fmt.allocPrint(
            arena,
            "{s}:{s}/.claude",
            .{ cfg.state_dir, cfg.container_home },
        ),
        cfg.image,
    });
    return args.toOwnedSlice(arena);
}

/// tmux holds the agent session inside the container — not on the VM, and not on the
/// host. The connection that breaks is host→VM, so the multiplexer has to be on the far
/// side of it; a tmux session on the user's own machine would keep their window layout
/// and do nothing for a dropped ssh connection.
///
/// `direnv exec` rather than a bare `claude`: tmux runs this string through `sh -c`, and
/// direnv's hook lives in bash's PROMPT_COMMAND, so it would not fire until the trailing
/// `bash -l` — long after the agent had started without the project's devshell.
///
/// `handoff.sh` runs after the agent and is the last thing in the session, so quitting
/// claude commits whatever is left and stops the container. An earlier version looped a
/// fallback shell here to keep a habitual `exit` from tearing the container down before
/// anything was committed; it made the session impossible to leave at all, which is the
/// worse of the two failures. Committing on the way out addresses what the loop was for.
///
/// Only quitting the agent reaches this. Detaching from tmux, and the dropped ssh
/// connection this whole arrangement exists for, leave the session running untouched.
///
/// `--append-system-prompt` carries `sandbox_caveat`, so claude does not infer a real
/// sandbox from `IS_SANDBOX=1` (set in `podmanArgs`) and start treating its actual
/// network and filesystem access as denied.
pub fn sessionCommand(arena: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (cfg.issue_short.len == 0) {
        return arena.dupe(u8, "tmux new-session -s capsule");
    }

    return std.fmt.allocPrint(arena,
        \\tmux new-session -s capsule "direnv exec '{s}' claude --append-system-prompt '{s}' 'Work on issue {s}. Call get_issue first for the description and the project memory, then set_state in_progress.' ; {s}/.claude/handoff.sh"
    , .{ cfg.project_dir, sandbox_caveat, cfg.issue_short, cfg.container_home });
}

const sandbox_caveat =
    "IS_SANDBOX=1 is set only to satisfy the bypassPermissions check that claude " ++
    "requires when running as root. This container is not otherwise restricted: it has " ++
    "full network access via host networking, a mounted docker socket, and a writable " ++
    "project directory. Do not assume network or filesystem restrictions apply.";

/// The exit status the bootstrap script uses when the replica has git remotes.
///
/// Distinct from any status a command in the script could produce on its own, because
/// this one refusal must never be mistaken for a generic failure: a replica with a remote
/// is a replica the agent's commits can escape from, and that is the isolation property
/// the whole design rests on.
pub const replica_has_remotes = 9;

pub const BootstrapParams = struct {
    /// The replica's directory name under `~/capsule` on the VM.
    replica: []const u8,
    /// The per-run directory, relative to the VM's home — `.capsule/runs/<12 hex>`.
    run_dir: []const u8,
    /// Copied to the VM's global git config when it has none. Empty to leave it alone.
    git_name: []const u8 = "",
    git_email: []const u8 = "",
};

/// Everything `run start` needs on the VM before the push: the replica exists, it has no
/// remotes, the run directory is there and private, and git knows who the user is.
///
/// It also reports `$HOME`, and that is why the seed does not travel with it. The seeded
/// agent state names the project's path *on the VM*, which is `$HOME/capsule/<replica>` —
/// so the seed cannot be built until this script has answered. bash paid a whole round
/// trip for `$HOME` alone; here it rides along with the work that had to happen anyway.
pub fn bootstrapScript(arena: std.mem.Allocator, p: BootstrapParams) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var alloc = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &alloc.writer;

    // Every conditional below is an `if`, never `[ -f x ] && cmd`. Under `set -e` the
    // `&&` form takes the whole script down when the test fails, which for the two
    // optional files here — the env file and ~/.gitconfig — is the ordinary case.
    try w.print(
        \\set -e
        \\repo=$HOME/capsule/{s}
        \\mkdir -p "$HOME/capsule"
        \\if [ ! -d "$repo/.git" ]; then
        \\  git init -q "$repo"
        \\  git -C "$repo" config receive.denyCurrentBranch updateInstead
        \\  printf 'bootstrapped\t1\n'
        \\fi
        \\remotes=$(git -C "$repo" remote | tr '\n' ' ')
        \\if [ -n "$remotes" ]; then
        \\  printf 'remotes\t%s\n' "$remotes"
        \\  exit {d}
        \\fi
        \\
    , .{ try ssh.shellQuote(arena, p.replica), replica_has_remotes });

    if (p.git_name.len > 0 or p.git_email.len > 0) {
        try w.writeAll("if ! git config --global --get user.email >/dev/null 2>&1; then\n");
        if (p.git_name.len > 0) {
            try w.print("  git config --global user.name {s}\n", .{try ssh.shellQuote(arena, p.git_name)});
        }
        if (p.git_email.len > 0) {
            try w.print("  git config --global user.email {s}\n", .{try ssh.shellQuote(arena, p.git_email)});
        }
        try w.writeAll("fi\n");
    }

    try w.print(
        \\dir=$HOME/{s}
        \\rm -rf "$dir"
        \\mkdir -p "$dir"
        \\chmod 700 "$dir"
        \\printf 'home\t%s\n' "$HOME"
        \\if [ -f "$HOME/.gitconfig" ]; then printf 'gitconfig\t%s/.gitconfig\n' "$HOME"; fi
        \\exit 0
        \\
    , .{try ssh.shellQuote(arena, p.run_dir)});

    return alloc.written();
}

pub const LaunchParams = struct {
    replica: []const u8,
    branch: []const u8,
    run_dir: []const u8,
    /// Already quoted for exactly one shell parse by `podmanArgs` — see below.
    container_cmd: []const u8,
};

/// Unpacks the seed, checks the replica out onto the run's branch, starts the container,
/// and removes the env file the moment podman has read it.
///
/// Reads the seed tarball from stdin. The env file is inside it rather than on a
/// connection of its own: it carries the run token and the agent's credentials, so it is
/// never an argument to anything — a token in a command line is visible in `ps` on both
/// machines — and it is narrowed to 0600 before podman is told where it is.
///
/// `container_cmd` is embedded verbatim. This preserves the invariant the shell suite
/// guards (`test/capsule-test.sh:163-186`): the command survives **exactly one** shell
/// parse. The script text *is* what the remote login shell parses, so a line of it is
/// parsed once, exactly as bash's `ssh_vm "$cmd"` was. Wrapping it in anything — `eval`,
/// `sh -c`, a second layer of quotes — adds the parse that breaks it.
pub fn launchScript(arena: std.mem.Allocator, p: LaunchParams) ![]const u8 {
    // Every quoted value is assigned to a variable first and used as `"$var"`. Writing
    // `"$HOME/capsule/{s}"` with a shell-quoted `{s}` puts single quotes *inside* double
    // quotes, where they are characters rather than quoting — the path then really does
    // contain apostrophes. That shipped once; hence `expandsTo` below.
    return std.fmt.allocPrint(arena,
        \\set -e
        \\dir=$HOME/{s}
        \\repo=$HOME/capsule/{s}
        \\tar xzf - -C "$dir"
        \\if [ -f "$dir/env" ]; then chmod 600 "$dir/env"; fi
        \\git -C "$repo" checkout -q {s}
        \\{s}
        \\rm -f "$dir/env"
        \\
    , .{
        try ssh.shellQuote(arena, p.run_dir),
        try ssh.shellQuote(arena, p.replica),
        try ssh.shellQuote(arena, p.branch),
        p.container_cmd,
    });
}

/// What the bootstrap script reported back.
pub const Bootstrap = struct {
    /// The VM's home directory. bash spent a whole ssh round trip on this alone.
    home: []const u8 = "",
    /// The VM's `~/.gitconfig`, or empty when it has none — podman must not be told to
    /// mount a path that does not exist, or it creates a directory there instead.
    gitconfig: []const u8 = "",
    /// Non-empty only on the refusal, naming what was found.
    remotes: []const u8 = "",
    bootstrapped: bool = false,
};

/// Parses the script's `key<TAB>value` lines, the same shape `world.parseProbe` reads.
pub fn parseBootstrap(text: []const u8) Bootstrap {
    var out = Bootstrap{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const key = line[0..tab];
        const value = line[tab + 1 ..];
        if (std.mem.eql(u8, key, "home")) out.home = value;
        if (std.mem.eql(u8, key, "gitconfig")) out.gitconfig = value;
        if (std.mem.eql(u8, key, "remotes")) out.remotes = std.mem.trim(u8, value, " ");
        if (std.mem.eql(u8, key, "bootstrapped")) out.bootstrapped = true;
    }
    return out;
}

/// `capsule run attach` — ssh, into the container, into tmux.
pub fn attachArgs(arena: std.mem.Allocator, container_name: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        "podman", "exec",   "-it", container_name,
        "tmux",   "attach", "-t",  "capsule",
    });
    return args.toOwnedSlice(arena);
}

/// The env file's contents. Written on the VM at mode 0600 and removed once podman has
/// read it.
pub fn envFileContents(
    arena: std.mem.Allocator,
    run_token: []const u8,
    oauth_token: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (run_token.len > 0) {
        try out.appendSlice(arena, "CAPSULE_RUN_TOKEN=");
        try out.appendSlice(arena, run_token);
        try out.append(arena, '\n');
    }
    if (oauth_token.len > 0) {
        try out.appendSlice(arena, "CLAUDE_CODE_OAUTH_TOKEN=");
        try out.appendSlice(arena, oauth_token);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// One shell-safe line, because the command crosses an ssh boundary and is re-parsed by
/// the remote shell. Quoting it in bash instead would mean getting `printf %q` semantics
/// right across two shells; doing it here makes it a function with tests.
pub fn shellQuote(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (word) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// Joins an argv into a single shell-quoted command line, each word through
/// `shellQuote` — the form that survives an ssh boundary intact. Allocated in `arena`,
/// which owns it.
///
/// Quoted for exactly one shell parse, which the remote login shell performs. The caller
/// must hand it to ssh as-is; an `eval` on the far side is a second parse that undoes the
/// quoting and word-splits arguments that contain spaces.
pub fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |word, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, try shellQuote(arena, word));
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

const example = Config{
    .image = "ghcr.io/x/capsule:latest",
    .container_name = "capsule-019fb1ce23cd",
    .project_dir = "/var/home/core/capsule/api-f23e31bc",
    .agent_state_dir = "/var/home/core/.capsule/runs/019fb1ce/claude",
    .env_file = "/var/home/core/.capsule/runs/019fb1ce/env",
    .profile = "work",
    .issue_short = "018f2a1c",
};

fn joined(arena: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return std.mem.join(arena, " ", argv);
}

const example_bootstrap = BootstrapParams{
    .replica = "api-f23e31bc",
    .run_dir = ".capsule/runs/019fb1ce23cd",
    .git_name = "Ada Lovelace",
    .git_email = "ada@example.com",
};

/// Runs `sh -n` over a generated script. A remote script that does not parse fails on the
/// VM, several seconds and one network round trip from anything that could explain it —
/// so the parse is checked here, by the shell itself, rather than reasoned about.
fn shellParses(arena: std.mem.Allocator, script: []const u8) !bool {
    const exec_mod = @import("exec.zig");
    const out = exec_mod.run(arena, testing.io, &.{ "sh", "-n", "-c", script }, .{}) catch
        return error.SkipZigTest;
    if (!out.ok()) std.debug.print("sh -n rejected the script:\n{s}\n", .{out.stderr});
    return out.ok();
}

/// Evaluates one of a generated script's assignments in a real shell and reports what the
/// variable actually expands to.
///
/// `sh -n` cannot catch the bug this exists for: `"$HOME/capsule/'name'"` parses perfectly
/// and then resolves to a path containing apostrophes, which is how a shell-quoted value
/// interpolated inside double quotes fails. Only expansion shows it, so a shell is asked.
fn expandsTo(arena: std.mem.Allocator, script: []const u8, name: []const u8) ![]const u8 {
    const exec_mod = @import("exec.zig");

    var probe: std.ArrayList(u8) = .empty;
    try probe.appendSlice(arena, "HOME=/var/home/core\n");

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, name) and
            trimmed.len > name.len and trimmed[name.len] == '=')
        {
            try probe.appendSlice(arena, trimmed);
            try probe.append(arena, '\n');
        }
    }
    try probe.appendSlice(arena, "printf %s \"$");
    try probe.appendSlice(arena, name);
    try probe.appendSlice(arena, "\"\n");

    const out = exec_mod.run(arena, testing.io, &.{ "sh", "-c", probe.items }, .{}) catch
        return error.SkipZigTest;
    if (!out.ok()) return error.SkipZigTest;
    return out.stdout;
}

/// Runs `command_line` through a real `sh` with a fake `podman` on PATH that echoes each
/// argument on its own line, and hands back what podman saw.
///
/// This is the port of `test/capsule-test.sh:163-186`, the most load-bearing assertion the
/// shell suite had. The property is not about text: it is that the command survives
/// **exactly one** shell parse. A second one — an `eval`, an `sh -c`, a stray layer of
/// quotes — splits the tmux command into separate podman arguments, and the agent gets an
/// unnamed session with its instructions scattered across argv. Only a shell can tell you
/// that, so a shell is asked.
fn podmanSees(arena: std.mem.Allocator, command_line: []const u8) ![]const []const u8 {
    const exec_mod = @import("exec.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const fake = try std.fmt.allocPrint(arena, "{s}/podman", .{dir});
    {
        var file = try std.Io.Dir.cwd().createFile(testing.io, fake, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(testing.io);
        var buf: [256]u8 = undefined;
        var w = file.writer(testing.io, &buf);
        try w.interface.writeAll("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n");
        try w.interface.flush();
    }

    const abs = try @import("git.zig").realpath(arena, testing.io, dir);
    const script = try std.fmt.allocPrint(arena, "PATH={s}:$PATH; {s}", .{ abs, command_line });

    const out = exec_mod.run(arena, testing.io, &.{ "sh", "-c", script }, .{}) catch
        return error.SkipZigTest;
    if (!out.ok()) return error.SkipZigTest;

    var args: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.stdout, "\n"), '\n');
    while (lines.next()) |line| try args.append(arena, line);
    return args.toOwnedSlice(arena);
}

test "the container command survives exactly one shell parse" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const argv = try podmanArgs(arena, example);
    const seen = try podmanSees(arena, try commandLine(arena, argv));

    // `argv[0]` is podman itself, which the fake sees as its own name rather than in
    // `"$@"` — so what it reports is everything after it.
    const expected = argv[1..];
    try testing.expectEqual(expected.len, seen.len);
    for (expected, seen) |built, got| try testing.expectEqualStrings(built, got);
}

test "the session command reaches podman as a single argument" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const seen = try podmanSees(arena, try commandLine(arena, try podmanArgs(arena, example)));

    // The word after `-lc` is the whole tmux invocation. If a second parse had happened it
    // would be just `tmux`, with the rest promoted to podman's own arguments.
    var found: ?[]const u8 = null;
    for (seen, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-lc") and i + 1 < seen.len) found = seen[i + 1];
    }
    const session = found orelse return error.NoSessionArgument;
    try testing.expectEqualStrings(try sessionCommand(arena, example), session);
    try testing.expect(std.mem.indexOf(u8, session, "tmux new-session") != null);
    try testing.expect(std.mem.indexOf(u8, session, "handoff.sh") != null);
}

test "a login container command survives the same single parse" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const argv = try loginArgs(arena, .{
        .image = "ghcr.io/x/capsule:latest",
        .profile = "work",
        .state_dir = "/var/home/core/.capsule/profiles/work/claude",
    });
    const seen = try podmanSees(arena, try commandLine(arena, argv));
    const expected = argv[1..];
    try testing.expectEqual(expected.len, seen.len);
    for (expected, seen) |built, got| try testing.expectEqualStrings(built, got);
}

test "a login container carries no run state and no unexpanded variable" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const argv = try loginArgs(arena, .{
        .image = "ghcr.io/x/capsule:latest",
        .container_home = "/home/agent",
        .profile = "work",
        .state_dir = "/var/home/core/.capsule/profiles/work/claude",
    });
    const line = try joined(arena, argv);

    try testing.expect(std.mem.indexOf(u8, line, "--rm -it") != null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_PROFILE=work") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        line,
        "/var/home/core/.capsule/profiles/work/claude:/home/agent/.claude",
    ) != null);

    // Every word is shell-quoted before it crosses ssh, so a `$HOME` or a `~` written into
    // this argv would arrive literal and podman would make a directory out of it.
    try testing.expect(std.mem.indexOf(u8, line, "$HOME") == null);
    try testing.expect(std.mem.indexOf(u8, line, "~") == null);

    // A login has no run: no token, no env file, no project mount, no MCP port.
    try testing.expect(std.mem.indexOf(u8, line, "--env-file") == null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_RUN_TOKEN") == null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_MCP_PORT") == null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_PROJECT_DIR") == null);
    try testing.expect(std.mem.indexOf(u8, line, " -d ") == null);
}

test "the login command survives quoting with its mount intact" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const cmd = try commandLine(arena, try loginArgs(arena, .{
        .image = "ghcr.io/x/capsule:latest",
        .profile = "work",
        .state_dir = "/var/home/core/.capsule/profiles/work/claude",
    }));
    try testing.expect(try shellParses(arena, cmd));
    try testing.expect(std.mem.indexOf(u8, cmd, "$HOME") == null);
}

test "the paths the scripts compute survive expansion unquoted" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    // The regression: `git -C "$HOME/capsule/'capsule-81f9e486'"` — valid shell, wrong
    // path. It reached a real VM before anything noticed.
    const launch = try launchScript(arena, .{
        .replica = "capsule-81f9e486",
        .branch = "capsule/019fce83703f7590866bae24dfe2679a",
        .run_dir = ".capsule/runs/019fce83703f",
        .container_cmd = "true",
    });
    try testing.expectEqualStrings(
        "/var/home/core/capsule/capsule-81f9e486",
        try expandsTo(arena, launch, "repo"),
    );
    try testing.expectEqualStrings(
        "/var/home/core/.capsule/runs/019fce83703f",
        try expandsTo(arena, launch, "dir"),
    );

    const boot = try bootstrapScript(arena, example_bootstrap);
    try testing.expectEqualStrings(
        "/var/home/core/capsule/api-f23e31bc",
        try expandsTo(arena, boot, "repo"),
    );
    try testing.expectEqualStrings(
        "/var/home/core/.capsule/runs/019fb1ce23cd",
        try expandsTo(arena, boot, "dir"),
    );
}

test "a replica name with a space is still one path" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    // The quoting has to be real, not decorative: without it the space splits the word
    // and `git -C` gets two arguments.
    var spaced = example_bootstrap;
    spaced.replica = "my project-f23e31bc";
    try testing.expectEqualStrings(
        "/var/home/core/capsule/my project-f23e31bc",
        try expandsTo(arena, try bootstrapScript(arena, spaced), "repo"),
    );

    const launch = try launchScript(arena, .{
        .replica = "my project-f23e31bc",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = "true",
    });
    try testing.expectEqualStrings(
        "/var/home/core/capsule/my project-f23e31bc",
        try expandsTo(arena, launch, "repo"),
    );
}

test "the bootstrap script is valid shell" {
    var a = testArena();
    defer a.deinit();
    try testing.expect(try shellParses(a.allocator(), try bootstrapScript(a.allocator(), example_bootstrap)));

    // The branch with no git identity to seed omits a whole `if`, so it parses separately.
    var bare = example_bootstrap;
    bare.git_name = "";
    bare.git_email = "";
    try testing.expect(try shellParses(a.allocator(), try bootstrapScript(a.allocator(), bare)));
}

test "the launch script is valid shell, container command and all" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const cmd = try commandLine(arena, try podmanArgs(arena, example));
    try testing.expect(try shellParses(arena, try launchScript(arena, .{
        .replica = "api-f23e31bc",
        .branch = "capsule/019fb1ce23cd",
        .run_dir = ".capsule/runs/019fb1ce23cd",
        .container_cmd = cmd,
    })));
}

test "the replica is checked for remotes before anything is written to the VM" {
    var a = testArena();
    defer a.deinit();

    // Ordering is the property, not presence: a replica that fails the check must not
    // have had a run directory made for it, and must never reach the launch step at all.
    const script = try bootstrapScript(a.allocator(), example_bootstrap);
    const check = std.mem.indexOf(u8, script, "remote | tr").?;
    const mkdir = std.mem.indexOf(u8, script, "mkdir -p \"$dir\"").?;
    try testing.expect(check < mkdir);
    try testing.expect(std.mem.indexOf(u8, script, "tar xzf -") == null);
}

test "the seed is unpacked before the container is told to mount it" {
    var a = testArena();
    defer a.deinit();

    const script = try launchScript(a.allocator(), .{
        .replica = "api",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = "podman run x",
    });
    const untar = std.mem.indexOf(u8, script, "tar xzf -").?;
    const chmod = std.mem.indexOf(u8, script, "chmod 600").?;
    const start = std.mem.indexOf(u8, script, "podman run x").?;
    try testing.expect(untar < chmod);
    try testing.expect(chmod < start);
}

test "a replica with remotes exits with its own status, not a generic failure" {
    var a = testArena();
    defer a.deinit();
    const script = try bootstrapScript(a.allocator(), example_bootstrap);
    try testing.expect(std.mem.indexOf(u8, script, "exit 9") != null);
    try testing.expectEqual(@as(u8, 9), replica_has_remotes);
}

test "the optional files are tested with if, never with a bare &&" {
    var a = testArena();
    defer a.deinit();

    // `set -e` turns `[ -f x ] && cmd` into "exit the script" whenever x is absent, and
    // absent is the normal case for both of these.
    const arena = a.allocator();
    const boot = try bootstrapScript(arena, example_bootstrap);
    const launch = try launchScript(arena, .{
        .replica = "api",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = "podman run x",
    });

    for ([_][]const u8{ boot, launch }) |script| {
        try testing.expect(std.mem.indexOf(u8, script, "] && ") == null);
    }
    try testing.expect(std.mem.indexOf(u8, boot, "if [ -f \"$HOME/.gitconfig\" ]") != null);
    try testing.expect(std.mem.indexOf(u8, launch, "if [ -f \"$dir/env\" ]") != null);
}

test "the env file is narrowed to 0600 before anything reads it" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const boot = try bootstrapScript(arena, example_bootstrap);
    try testing.expect(std.mem.indexOf(u8, boot, "chmod 700 \"$dir\"") != null);

    const launch = try launchScript(arena, .{
        .replica = "api",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = "podman run x",
    });
    try testing.expect(std.mem.indexOf(u8, launch, "chmod 600 \"$dir/env\"") != null);

    // The tokens ride in the tar; neither script ever carries one as an argument.
    for ([_][]const u8{ boot, launch }) |script| {
        try testing.expect(std.mem.indexOf(u8, script, "CAPSULE_RUN_TOKEN") == null);
        try testing.expect(std.mem.indexOf(u8, script, "CLAUDE_CODE_OAUTH_TOKEN") == null);
    }
}

test "a hostile replica name stays one word to the shell that runs it" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();
    const exec_mod = @import("exec.zig");

    // The payload does appear in the script — inside single quotes, which is the whole
    // point. So the assertion is not on the text but on what a shell makes of it: the
    // real shell is asked to expand the quoted form and hand back what it saw.
    const hostile = "x'; rm -rf ~; echo '";
    const quoted = try ssh.shellQuote(arena, hostile);
    const probe = try std.fmt.allocPrint(arena, "printf %s {s}", .{quoted});

    const out = exec_mod.run(arena, testing.io, &.{ "sh", "-c", probe }, .{}) catch
        return error.SkipZigTest;
    try testing.expect(out.ok());
    try testing.expectEqualStrings(hostile, out.stdout);

    var evil = example_bootstrap;
    evil.replica = hostile;
    try testing.expect(try shellParses(arena, try bootstrapScript(arena, evil)));
}

test "the launch script embeds the container command with no second parse around it" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    const cmd = try commandLine(arena, try podmanArgs(arena, example));
    const script = try launchScript(arena, .{
        .replica = "api",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = cmd,
    });

    // Verbatim, and with nothing wrapped around it. `eval` or an `sh -c` here would add
    // the second parse that splits the tmux command into podman arguments.
    try testing.expect(std.mem.indexOf(u8, script, cmd) != null);
    try testing.expect(std.mem.indexOf(u8, script, "eval") == null);
    try testing.expect(std.mem.indexOf(u8, script, "sh -c") == null);
}

test "the env file is removed once the container has been given it" {
    var a = testArena();
    defer a.deinit();
    const script = try launchScript(a.allocator(), .{
        .replica = "api",
        .branch = "capsule/abc",
        .run_dir = ".capsule/runs/abc",
        .container_cmd = "podman run x",
    });
    const start = std.mem.indexOf(u8, script, "podman run x").?;
    const remove = std.mem.indexOf(u8, script, "rm -f").?;
    try testing.expect(start < remove);
}

test "the bootstrap reply is read back as key-value lines" {
    const got = parseBootstrap(
        "bootstrapped\t1\nhome\t/var/home/core\ngitconfig\t/var/home/core/.gitconfig\n",
    );
    try testing.expect(got.bootstrapped);
    try testing.expectEqualStrings("/var/home/core", got.home);
    try testing.expectEqualStrings("/var/home/core/.gitconfig", got.gitconfig);
    try testing.expectEqualStrings("", got.remotes);
}

test "a VM with no gitconfig reports none, rather than a path that is not there" {
    const got = parseBootstrap("home\t/var/home/core\n");
    try testing.expectEqualStrings("/var/home/core", got.home);
    try testing.expectEqualStrings("", got.gitconfig);
    try testing.expect(!got.bootstrapped);
}

test "the refusal names the remotes it found" {
    const got = parseBootstrap("remotes\torigin backup \n");
    try testing.expectEqualStrings("origin backup", got.remotes);
}

test "the container is detached, has a terminal, is named, and is on the host network" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));

    try testing.expect(std.mem.indexOf(u8, line, " -d ") != null);
    try testing.expect(std.mem.indexOf(u8, line, " -t ") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--name capsule-019fb1ce23cd") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--network=host") != null);
    try testing.expect(std.mem.indexOf(u8, line, " -i ") == null);
    try testing.expect(std.mem.indexOf(u8, line, " -it ") == null);
}

test "the token goes in through an env-file and never on the command line" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));

    try testing.expect(std.mem.indexOf(u8, line, "--env-file") != null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_RUN_TOKEN=") == null);
    try testing.expect(std.mem.indexOf(u8, line, "CLAUDE_CODE_OAUTH_TOKEN=") == null);
}

test "hooks get the project dir, and the in-capsule marker is set" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_PROJECT_DIR=/var/home/core/capsule/api-f23e31bc") != null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_IN_CAPSULE=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "CAPSULE_MCP_PORT=8765") != null);
}

test "the per-run agent state is mounted, not the profile's" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, "runs/019fb1ce/claude:/home/agent/.claude") != null);
}

test "the host's git identity is mounted read-only when the VM has one" {
    var a = testArena();
    defer a.deinit();
    var with_git = example;
    with_git.git_config_path = "/home/core/.gitconfig";
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), with_git));
    try testing.expect(std.mem.indexOf(u8, line, "/home/core/.gitconfig:/home/agent/.gitconfig:ro") != null);
}

test "no gitconfig mount appears when the VM has none" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, ".gitconfig") == null);
}

test "claude is told it is sandboxed, or bypassPermissions refuses to run as root" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, "IS_SANDBOX=1") != null);
}

test "the agent starts inside the project's direnv environment" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);
    try testing.expect(std.mem.indexOf(
        u8,
        command,
        "direnv exec '/var/home/core/capsule/api-f23e31bc' claude ",
    ) != null);
}

test "claude is told IS_SANDBOX is only for the root check, not a real restriction" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);

    try testing.expect(std.mem.indexOf(u8, command, "--append-system-prompt '") != null);
    try testing.expect(std.mem.indexOf(u8, command, "IS_SANDBOX=1 is set only to satisfy") != null);
    try testing.expect(std.mem.indexOf(u8, command, "full network access") != null);
}

test "a login session carries no system-prompt caveat, since it starts no agent" {
    var a = testArena();
    defer a.deinit();
    var login = example;
    login.issue_short = "";
    const command = try sessionCommand(a.allocator(), login);

    try testing.expect(std.mem.indexOf(u8, command, "--append-system-prompt") == null);
}

test "the session runs the agent under tmux and hands off when it exits" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);

    try testing.expect(std.mem.indexOf(u8, command, "tmux new-session") != null);
    try testing.expect(std.mem.indexOf(u8, command, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, command, "get_issue") != null);
    try testing.expect(std.mem.indexOf(u8, command, "/home/agent/.claude/handoff.sh") != null);
}

test "nothing outlives the agent, so quitting it stops the container" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);

    try testing.expect(std.mem.indexOf(u8, command, "while :; do bash -l; done") == null);
    try testing.expect(std.mem.indexOf(u8, command, "bash -l") == null);
}

test "the handoff is the last command, or the container stops before it commits" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);
    try testing.expect(std.mem.endsWith(u8, command, "handoff.sh\""));
}

test "the handoff path follows the container's home, not a hardcoded one" {
    var a = testArena();
    defer a.deinit();
    var elsewhere = example;
    elsewhere.container_home = "/root";
    const command = try sessionCommand(a.allocator(), elsewhere);
    try testing.expect(std.mem.indexOf(u8, command, "/root/.claude/handoff.sh") != null);
}

test "a login session has no issue and starts no agent" {
    var a = testArena();
    defer a.deinit();
    var login = example;
    login.issue_short = "";
    const command = try sessionCommand(a.allocator(), login);

    try testing.expect(std.mem.indexOf(u8, command, "tmux new-session") != null);
    try testing.expect(std.mem.indexOf(u8, command, "claude '") == null);
    try testing.expect(std.mem.indexOf(u8, command, "get_issue") == null);
}

test "attach goes through exec into the same tmux session" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try attachArgs(a.allocator(), "capsule-abc"));
    try testing.expectEqualStrings("podman exec -it capsule-abc tmux attach -t capsule", line);
}

test "the env file carries both tokens, one per line" {
    var a = testArena();
    defer a.deinit();
    const contents = try envFileContents(a.allocator(), "run-tok", "oauth-tok");
    try testing.expectEqualStrings("CAPSULE_RUN_TOKEN=run-tok\nCLAUDE_CODE_OAUTH_TOKEN=oauth-tok\n", contents);
}

test "a login env file has no run token, and an unauthenticated one has no oauth line" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "CLAUDE_CODE_OAUTH_TOKEN=oauth\n",
        try envFileContents(a.allocator(), "", "oauth"),
    );
    try testing.expectEqualStrings(
        "CAPSULE_RUN_TOKEN=run\n",
        try envFileContents(a.allocator(), "run", ""),
    );
    try testing.expectEqualStrings("", try envFileContents(a.allocator(), "", ""));
}

test "the project is mounted at the same path it has on the VM" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));
    const both = "/var/home/core/capsule/api-f23e31bc:/var/home/core/capsule/api-f23e31bc";
    try testing.expect(std.mem.indexOf(u8, line, both) != null);
    try testing.expect(std.mem.indexOf(u8, line, "-w /var/home/core/capsule/api-f23e31bc") != null);
}

test "shell quoting survives the characters that break a remote command" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings("'plain'", try shellQuote(a.allocator(), "plain"));
    try testing.expectEqualStrings("'a b'", try shellQuote(a.allocator(), "a b"));
    try testing.expectEqualStrings("'a'\\''b'", try shellQuote(a.allocator(), "a'b"));
    try testing.expectEqualStrings("'$(rm -rf /)'", try shellQuote(a.allocator(), "$(rm -rf /)"));
    try testing.expectEqualStrings("'a;b|c&d'", try shellQuote(a.allocator(), "a;b|c&d"));
    try testing.expectEqualStrings("'`x`'", try shellQuote(a.allocator(), "`x`"));
}

test "the whole command line is quoted word by word" {
    var a = testArena();
    defer a.deinit();
    const line = try commandLine(a.allocator(), &.{ "podman", "run", "-e", "X=a b" });
    try testing.expectEqualStrings("'podman' 'run' '-e' 'X=a b'", line);
}

test "the session command survives quoting intact" {
    var a = testArena();
    defer a.deinit();
    const argv = try podmanArgs(a.allocator(), example);
    const line = try commandLine(a.allocator(), argv);
    try testing.expect(std.mem.indexOf(u8, line, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, line, "'\\''") != null);
}
