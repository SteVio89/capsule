//! The container command line, and the rules about when a run may start.

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

    try args.appendSlice(arena, &.{ "-lc", try sessionCommand(arena, cfg) });
    return args.toOwnedSlice(arena);
}

/// tmux holds the agent session inside the container — not on the VM, and not on the
/// host. The connection that breaks is host→VM, so the multiplexer has to be on the far
/// side of it; a tmux session on the user's own machine would keep their window layout
/// and do nothing for a dropped ssh connection.
pub fn sessionCommand(arena: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (cfg.issue_short.len == 0) {
        return arena.dupe(u8, "tmux new-session -s capsule");
    }

    return std.fmt.allocPrint(arena,
        \\tmux new-session -s capsule "claude 'Work on issue {s}. Call get_issue first for the description and the project memory, then set_state in_progress.' ; exec bash -l"
    , .{cfg.issue_short});
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

test "the session runs the agent under tmux and falls through to a shell" {
    var a = testArena();
    defer a.deinit();
    const command = try sessionCommand(a.allocator(), example);

    try testing.expect(std.mem.indexOf(u8, command, "tmux new-session") != null);
    try testing.expect(std.mem.indexOf(u8, command, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, command, "get_issue") != null);
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
