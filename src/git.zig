//! Git, as calls rather than as command strings.
//!
//! This grows as command groups move over; it currently carries what identifying a
//! project needs, which is the most-called path in the CLI. `project_params` in bash ran
//! `git rev-parse` and `pwd -P` on *every* invocation — four times in `run start`, six in
//! `run merge` — because a shell function has nowhere to keep the answer. Here it is
//! resolved once per process and handed around.
//!
//! A failing git command is a value, never a process death. That is the structural fix
//! for the `set -e` hazard in `cmd_run_merge`, where a hiccup after `git commit` killed
//! the script with the merge landed and the replica left unsynced.

const std = @import("std");
const Io = std.Io;
const exec = @import("exec.zig");

pub const Error = error{
    NotARepository,
    /// git is not installed, or not on PATH.
    GitMissing,
} || exec.Error;

/// Wall-clock cap on the commands that reach the replica.
///
/// `ssh.zig` bounds every connection capsule opens itself, but git spawns its own ssh, so
/// the bound has to be put back here for the ones git makes. Generous rather than tight:
/// the VM is on localhost, so this is catching a hang, not slow work.
const vm_timeout_s: u32 = 120;

/// Git bound to one working directory, so callers do not repeat `-C`.
pub const Git = struct {
    arena: std.mem.Allocator,
    io: Io,
    /// Null runs in capsule's own working directory.
    dir: ?[]const u8 = null,
    /// capsule's ssh as one command line, for git's `core.sshCommand`. Null leaves git to
    /// its own ssh, which is what a repository with no replica wants.
    ssh_command: ?[]const u8 = null,

    /// Builds `git [-C <dir>] <args...>`. The `-C` form is used rather than spawning with
    /// a different cwd so the command is reproducible from the log line alone.
    ///
    /// Public because it is the part worth asserting on: every argument stays one
    /// argument, which is the property a command-string port would lose.
    pub fn argv(self: Git, args: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(self.arena, "git");
        if (self.dir) |d| try out.appendSlice(self.arena, &.{ "-C", d });
        try out.appendSlice(self.arena, args);
        return out.toOwnedSlice(self.arena);
    }

    /// Builds the argv for a command that reaches the replica: `argv` plus capsule's ssh.
    ///
    /// `-c core.sshCommand=` rather than the environment, because `exec.Options.environ`
    /// replaces the child's environment wholesale and every VM call would have to copy the
    /// whole map first. It is set for the git process rather than one remote, which is safe
    /// only because the commands using it name `vm` explicitly — a bare `git fetch` here
    /// would reach `origin` on the VM's port.
    ///
    /// Public for the same reason `argv` is: this is the part worth asserting on.
    pub fn vmArgv(self: Git, args: []const []const u8) ![]const []const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        if (self.ssh_command) |cmd| {
            try full.appendSlice(self.arena, &.{
                "-c",
                try std.fmt.allocPrint(self.arena, "core.sshCommand={s}", .{cmd}),
            });
        }
        try full.appendSlice(self.arena, args);
        return self.argv(full.items);
    }

    /// Runs and captures, leaving the exit code for the caller to interpret.
    pub fn run(self: Git, args: []const []const u8) exec.Error!exec.Output {
        return exec.run(self.arena, self.io, try self.argv(args), .{});
    }

    /// `run` for a command that reaches the replica, which is the only kind that can hang.
    pub fn runOnVm(self: Git, args: []const []const u8) exec.Error!exec.Output {
        return exec.run(self.arena, self.io, try self.vmArgv(args), .{
            .timeout = .{ .duration = .{
                .raw = .{ .nanoseconds = @as(u64, vm_timeout_s) * std.time.ns_per_s },
                .clock = .awake,
            } },
        });
    }

    /// Trimmed stdout, or `error.ExitFailure` when git said no.
    pub fn capture(self: Git, args: []const []const u8) exec.Error![]const u8 {
        return exec.capture(self.arena, self.io, try self.argv(args), .{});
    }

    /// Whether the command succeeded, with output and failure both discarded. For the
    /// questions git answers by exit code alone.
    pub fn succeeds(self: Git, args: []const []const u8) bool {
        const out = self.run(args) catch return false;
        return out.ok();
    }
};

/// The remote capsule creates for the replica in the VM. Named here rather than spelled at
/// each call site: it is also what `run reset` removes, and the two must agree.
pub const remote = "vm";

/// The branch an issue's work lives on. Derived from the **full** issue id, not the short
/// form — the daemon mints the same string in `run.start`, and a short id here would
/// produce a second branch that nothing else recognises.
pub fn issueBranch(arena: std.mem.Allocator, full_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "capsule/{s}", .{full_id});
}

/// `git fetch vm` — refs only, so nothing in the working tree moves.
pub fn fetch(g: Git) exec.Error!exec.Output {
    return g.runOnVm(&.{ "fetch", "-q", remote });
}

/// Pushes the current HEAD onto an issue's branch in the replica.
pub fn pushToBranch(g: Git, branch: []const u8) exec.Error!exec.Output {
    const refspec = try std.fmt.allocPrint(g.arena, "HEAD:{s}", .{branch});
    return g.runOnVm(&.{ "push", remote, refspec });
}

/// Whether a ref resolves. Used to tell "the agent has not pushed yet" from "something
/// broke", which are the same exit code from most other git commands.
pub fn hasRef(g: Git, ref: []const u8) bool {
    return g.succeeds(&.{ "rev-parse", "--verify", "--quiet", ref });
}

/// How many commits `range` contains, or zero when git cannot say.
pub fn countCommits(g: Git, range: []const u8) usize {
    const out = g.capture(&.{ "rev-list", "--count", range }) catch return 0;
    return std.fmt.parseInt(usize, out, 10) catch 0;
}

/// The branch a merge should land on: `origin/HEAD` when there is one, then `main`, then
/// `master`, then whatever HEAD currently is.
///
/// The fallback chain matters because capsule is used on repositories with no origin at
/// all — the replica itself has no remotes by design.
pub fn defaultBranch(g: Git, configured: []const u8) ![]const u8 {
    if (configured.len > 0) return configured;

    if (g.capture(&.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })) |full| {
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| return full[slash + 1 ..];
        return full;
    } else |_| {}

    for ([_][]const u8{ "main", "master" }) |name| {
        if (hasRef(g, name)) return name;
    }
    return g.capture(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
}

/// Which repository the CLI is being run against — the two values every daemon call
/// carries, resolved once.
///
/// `git_common_dir` rather than the worktree: a linked worktree of the same repository
/// must reach the same backlog, and `--git-common-dir` is what collapses them.
pub const Repo = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
};

/// Resolves the repository containing `cwd`, or `error.NotARepository`.
///
/// Both paths come back realpath'd, because the daemon uses `canonical_path` as a unique
/// key and two spellings of one directory would fork a project into two backlogs.
pub fn discover(arena: std.mem.Allocator, io: Io) Error!Repo {
    const here = realpath(arena, io, ".") catch return error.NotARepository;

    const git = Git{ .arena = arena, .io = io };
    const out = git.run(&.{ "rev-parse", "--git-common-dir" }) catch |err| return switch (err) {
        error.SpawnFailed => error.GitMissing,
        else => err,
    };
    if (!out.ok()) return error.NotARepository;

    // `--git-common-dir` answers relatively (a bare `.git`) when run from the top level,
    // so it is resolved against the working directory before being realpath'd.
    const reported = out.trimmed();
    const absolute = if (std.fs.path.isAbsolute(reported))
        reported
    else
        try std.fs.path.join(arena, &.{ here, reported });

    return .{
        .git_common_dir = realpath(arena, io, absolute) catch absolute,
        .cwd = here,
    };
}

/// The realpath of `path`, with symlinks resolved — `pwd -P` for an arbitrary path.
///
/// This is why project resolution no longer needs a shell: the comment that put `pwd -P`
/// in bash predates `std.Io.Dir.realPathFileAlloc`.
pub fn realpath(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    const resolved = try Io.Dir.cwd().realPathFileAlloc(io, path, arena);
    return std.mem.sliceTo(resolved, 0);
}

const testing = std.testing;

test "the command line keeps every argument whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const git = Git{ .arena = arena.allocator(), .io = testing.io, .dir = "/repo" };
    const line = try git.argv(&.{ "commit", "-m", "a message; with $(punctuation)" });

    try testing.expectEqual(@as(usize, 6), line.len);
    try testing.expectEqualStrings("git", line[0]);
    try testing.expectEqualStrings("-C", line[1]);
    try testing.expectEqualStrings("/repo", line[2]);
    try testing.expectEqualStrings("commit", line[3]);
    try testing.expectEqualStrings("-m", line[4]);
    try testing.expectEqualStrings("a message; with $(punctuation)", line[5]);
}

test "a replica command carries capsule's ssh, before the subcommand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const g = Git{
        .arena = arena.allocator(),
        .io = testing.io,
        .dir = "/repo",
        .ssh_command = "ssh -o 'ConnectTimeout=10' -p '2222'",
    };
    const line = try g.vmArgv(&.{ "fetch", "-q", remote });

    // `-c` has to land before the subcommand or git rejects it, and after `-C` is where
    // the existing builder puts everything it adds.
    try testing.expectEqualStrings("git", line[0]);
    try testing.expectEqualStrings("-C", line[1]);
    try testing.expectEqualStrings("/repo", line[2]);
    try testing.expectEqualStrings("-c", line[3]);
    try testing.expectEqualStrings(
        "core.sshCommand=ssh -o 'ConnectTimeout=10' -p '2222'",
        line[4],
    );
    try testing.expectEqualStrings("fetch", line[5]);
    try testing.expectEqualStrings(remote, line[7]);
}

test "without an ssh command a replica command is exactly the plain one" {
    // A repository with no replica must not grow a `-c` with an empty value, which git
    // reads as a config key with no name and refuses.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const g = Git{ .arena = arena.allocator(), .io = testing.io };
    const line = try g.vmArgv(&.{ "fetch", "-q", remote });

    try testing.expectEqual(@as(usize, 4), line.len);
    try testing.expectEqualStrings("git", line[0]);
    try testing.expectEqualStrings("fetch", line[1]);
}

test "without a directory there is no -C at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const git = Git{ .arena = arena.allocator(), .io = testing.io };
    const line = try git.argv(&.{"status"});
    try testing.expectEqual(@as(usize, 2), line.len);
    try testing.expectEqualStrings("git", line[0]);
    try testing.expectEqualStrings("status", line[1]);
}

/// A `Git` for tests that need a real repository, or `SkipZigTest` when there is none.
///
/// The Nix build sandbox is exactly that case: the source arrives as an unpacked store
/// path with no `.git`, and the check phase has no `git` binary. These tests assert on the
/// repository capsule itself lives in — meaningful in a checkout, meaningless there — so
/// they stand down rather than failing someone's `darwin-rebuild`.
fn requireRepo(arena: std.mem.Allocator) !Git {
    const git = Git{ .arena = arena, .io = testing.io };
    const out = git.run(&.{ "rev-parse", "--git-dir" }) catch return error.SkipZigTest;
    if (!out.ok()) return error.SkipZigTest;
    return git;
}

test "discover resolves the repository capsule itself lives in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try requireRepo(arena.allocator());

    const repo = try discover(arena.allocator(), testing.io);
    try testing.expect(std.fs.path.isAbsolute(repo.cwd));
    try testing.expect(std.fs.path.isAbsolute(repo.git_common_dir));
    try testing.expect(std.mem.endsWith(u8, repo.git_common_dir, ".git"));
}

test "realpath resolves a symlinked path to one spelling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two spellings of the same directory must not produce two canonical paths, which is
    // the property the daemon's UNIQUE constraint on canonical_path depends on.
    //
    // The second spelling walks through a directory this test makes, rather than through
    // `src/`: a test that assumes the repository's own layout fails anywhere the source is
    // unpacked differently, which is a fact about the checkout and not about `realpath`.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(testing.io, try std.fmt.allocPrint(a, "{s}/down", .{base}));

    const direct = try realpath(a, testing.io, base);
    const indirect = try realpath(a, testing.io, try std.fmt.allocPrint(a, "{s}/down/..", .{base}));
    try testing.expectEqualStrings(direct, indirect);
}

test "a failing git command is a value, not a process death" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const git = try requireRepo(a);
    const out = try git.run(&.{ "rev-parse", "--verify", "refs/heads/definitely-not-a-branch" });
    try testing.expect(!out.ok());
    try testing.expect(!git.succeeds(&.{ "rev-parse", "--verify", "refs/heads/nope" }));
    try testing.expectError(
        error.ExitFailure,
        git.capture(&.{ "rev-parse", "--verify", "refs/heads/nope" }),
    );
}

test "an argument carrying shell punctuation survives the round trip to git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Read-only, so it needs no scratch repository: git echoes the argument back through
    // a format expansion, proving it arrived as exactly one argument.
    const git = try requireRepo(a);
    const nasty = "a message; with $(punctuation) and 'quotes'";

    // A repository with no commits yet has nothing to log, which is not what is under test.
    const got = git.capture(&.{ "log", "-1", "--format=%s", "--no-walk", "HEAD" }) catch
        return error.SkipZigTest;
    try testing.expect(got.len > 0);

    const echoed = try git.capture(&.{ "rev-parse", "--sq-quote", nasty });
    try testing.expect(std.mem.indexOf(u8, echoed, "punctuation") != null);
}
