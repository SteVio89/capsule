//! The container command line, and the rules about when a run may start.
//!
//! Everything here is a pure function returning a string or a decision, because this is
//! the one part of capsule that cannot be exercised without a VM: podman, ssh and the
//! replica are all on the far side of a machine boundary. Pushing the decisions into
//! testable functions leaves only plumbing for the host to prove.

const std = @import("std");

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
};

/// The detached `podman run` for an agent session.
///
/// Detached, not `-it`: with an attached container over ssh, a dropped connection —
/// a sleeping laptop, flapping wifi — kills the agent mid-task and strands uncommitted
/// work. Detached, the agent keeps going and `run attach` reconnects.
///
/// The token arrives via `--env-file`, never `-e`: an `-e` would put it in the VM's
/// process table for anyone running `ps`, and in the shell history of the ssh command.
pub fn podmanArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        "podman",           "run",
        "-d",               "--name",
        cfg.container_name, "--security-opt",
        "label=disable",
        // The container shares the VM's network namespace, so it sees the loopback the
        // daemon's reverse tunnel lands on. This is what makes the MCP endpoint reachable
        // without anything being bound on a real interface.
           "--network=host",
        "--env-file",       cfg.env_file,
    });

    try args.appendSlice(arena, &.{
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_MCP_PORT={d}", .{cfg.mcp_port}),
        // Hooks gate on this, and it is deliberately absent from a login container.
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_PROJECT_DIR={s}", .{cfg.project_dir}),
        "-e", "CAPSULE_IN_CAPSULE=1",
        "-e", try std.fmt.allocPrint(arena, "CAPSULE_PROFILE={s}", .{cfg.profile}),
        // The seeded tree (settings.json, .claude.json with the MCP server) mounts at
        // ~/.claude, but Claude Code looks for .claude.json at the *config dir* — by
        // default the home root, where the mount does not put it. Without this, the MCP
        // server entry is simply never read and the agent has no tools.
        "-e", try std.fmt.allocPrint(arena, "CLAUDE_CONFIG_DIR={s}/.claude", .{cfg.container_home}),
        "-e", "DOCKER_HOST=unix:///run/podman.sock",
        "-e", "TESTCONTAINERS_RYUK_DISABLED=true",
        "-e", "TESTCONTAINERS_HOST_OVERRIDE=host.containers.internal",
    });

    try args.appendSlice(arena, &.{
        "-v",      "capsule-nix:/nix",
        "-v",      try std.fmt.allocPrint(arena, "{s}:{s}/.claude", .{ cfg.agent_state_dir, cfg.container_home }),
        "-v",      try std.fmt.allocPrint(arena, "{s}:{s}", .{ cfg.project_dir, cfg.project_dir }),
        "-w",      cfg.project_dir,
        cfg.image,
    });

    // The image's entrypoint is `bash -l`, so what follows is its argument.
    try args.appendSlice(arena, &.{ "-lc", try sessionCommand(arena, cfg) });
    return args.toOwnedSlice(arena);
}

/// tmux holds the agent session inside the container — not on the VM, and not on the
/// host. The connection that breaks is host→VM, so the multiplexer has to be on the far
/// side of it; a tmux session on the user's own machine would keep their window layout
/// and do nothing for a dropped ssh connection.
///
/// The container must exit when tmux does. Otherwise "the container is gone" never
/// becomes true and no run ever reaches a terminal state.
pub fn sessionCommand(arena: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (cfg.issue_short.len == 0) {
        // `capsule login`: a shell to authenticate in, no issue, no token, no run record.
        return arena.dupe(u8, "tmux new-session -s capsule");
    }

    // Claude Code is launched directly with an opening instruction rather than dropped
    // into a shell the user then types into. The instruction names the issue and says to
    // call get_issue; it does not paste the body, so later edits are visible and the tool
    // has a reason to be called.
    //
    // On exit it falls through to a shell rather than tearing the container down —
    // sessions frequently need a manual follow-up.
    return std.fmt.allocPrint(arena,
        \\tmux new-session -s capsule "claude 'Work on issue {s}. Call get_issue first for the description and the project memory, then set_state in_progress.' ; exec bash -l"
    , .{cfg.issue_short});
}

/// `capsule run attach` — ssh, into the container, into tmux.
///
/// This and the one-run-per-project refusal only work together: without it, refusing a
/// second run would lock the user out of their own session after a disconnect.
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
///
/// The account token is not run-scoped and any process in the container can read the
/// environment — including anything the agent runs. That is true of a credentials file
/// too, so this is no worse than the status quo, but it does mean the agent holds the
/// user's account for the run's duration. The container-in-VM-on-a-replica boundary is
/// what contains it; there is no point adding a deny rule over an empty directory.
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
///
/// Single quotes, with embedded single quotes broken out — the only form with no escape
/// characters to reason about inside.
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
pub fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |word, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, try shellQuote(arena, word));
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- tests

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

test "the container is detached, named, and on the host network" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));

    try testing.expect(std.mem.indexOf(u8, line, " -d ") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--name capsule-019fb1ce23cd") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--network=host") != null);
    // -it would tie the agent's life to the ssh connection, which is the thing that breaks.
    try testing.expect(std.mem.indexOf(u8, line, " -it ") == null);
}

test "the token goes in through an env-file and never on the command line" {
    var a = testArena();
    defer a.deinit();
    const line = try joined(a.allocator(), try podmanArgs(a.allocator(), example));

    try testing.expect(std.mem.indexOf(u8, line, "--env-file") != null);
    // Anything on this command line is visible in the VM's process table and in history.
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
    // Per run, because several projects share a profile: a run token written into a
    // shared ~/.claude is overwritten by the next run in that profile, and an agent
    // authenticated as someone else's run is the worst failure this design can produce.
    try testing.expect(std.mem.indexOf(u8, line, "runs/019fb1ce/claude:/home/agent/.claude") != null);
}

test "the session runs the agent under tmux and falls through to a shell" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);

    try testing.expect(std.mem.indexOf(u8, command, "tmux new-session") != null);
    try testing.expect(std.mem.indexOf(u8, command, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, command, "get_issue") != null);
    // A follow-up shell rather than tearing the container down on agent exit.
    try testing.expect(std.mem.indexOf(u8, command, "exec bash -l") != null);
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
    // Identity-mapped, which is why direnv has to whitelist both /home and /var/home.
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
    // The ones that would otherwise be interpreted by the remote shell.
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
    // It contains both single and double quotes, which is exactly what breaks naive
    // escaping on the way through ssh.
    const argv = try podmanArgs(a.allocator(), example);
    const line = try commandLine(a.allocator(), argv);
    try testing.expect(std.mem.indexOf(u8, line, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, line, "'\\''") != null);
}
