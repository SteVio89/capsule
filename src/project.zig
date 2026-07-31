//! Project identity: what makes two directories the same project, and what the replica
//! for one is called.
//!
//! Keyed on `git rev-parse --git-common-dir`, realpath'd.
//!
//! Not `--show-toplevel`, which returns the *worktree* — two worktrees of one repository
//! would silently fork into separate backlogs. Not the raw cwd string either, because
//! macOS hands out `/Users/...` and `/private/var/...` for the same directory.
//!
//! Registration is explicit and is the barrier: a directory is not a capsule project
//! until `capsule project add` has been run in it. No scanning, no adoption on first use.

const std = @import("std");

/// `--git-common-dir` answers relative to the cwd from the repository root (`.git`) and
/// absolutely from inside a worktree. Joining before realpath is what stops those two
/// from resolving to different projects.
///
/// Pure, and it does not resolve symlinks: Zig 0.16's standard library has no realpath.
/// The caller passes a `cwd` that is already physical (`pwd -P` in bash), which is what
/// makes macOS's `/var` and `/private/var` land on one project.
pub fn resolveGitDir(
    arena: std.mem.Allocator,
    git_common_dir: []const u8,
    cwd: []const u8,
) ![]const u8 {
    const trimmed = std.mem.trim(u8, git_common_dir, " \t\r\n");
    if (trimmed.len == 0) return error.NotARepository;

    const joined = if (std.fs.path.isAbsolute(trimmed))
        try arena.dupe(u8, trimmed)
    else
        try std.fs.path.join(arena, &.{ cwd, trimmed });

    // `.` is what a bare repository reports, and resolves to the repository itself.
    return std.fs.path.resolve(arena, &.{joined});
}

/// The replica's directory name on the VM.
///
/// The basename alone is not enough: two projects called `api` under different parents
/// would land on the same replica and quietly share a working tree. The suffix is derived
/// from the same canonical path the store keys on, so the two can never disagree.
pub fn replicaName(arena: std.mem.Allocator, canonical_path: []const u8) ![]const u8 {
    var base = std.fs.path.basename(canonical_path);
    // The canonical path is the git dir, so it usually ends in `/.git`; the interesting
    // name is the directory above it.
    if (std.mem.eql(u8, base, ".git")) {
        base = std.fs.path.basename(std.fs.path.dirname(canonical_path) orelse canonical_path);
    }
    if (base.len == 0) base = "project";

    const digest = std.hash.Wyhash.hash(0, canonical_path);
    return std.fmt.allocPrint(arena, "{s}-{x:0>8}", .{ base, @as(u32, @truncate(digest)) });
}

/// Display name for a project — the basename of its path, which is a perfectly good one.
/// There is deliberately no `projects.alias` column to keep in sync with it.
pub fn displayName(canonical_path: []const u8) []const u8 {
    var base = std.fs.path.basename(canonical_path);
    if (std.mem.eql(u8, base, ".git")) {
        base = std.fs.path.basename(std.fs.path.dirname(canonical_path) orelse canonical_path);
    }
    return if (base.len == 0) "project" else base;
}

/// Profiles name directories and get interpolated into remote shell commands, so the set
/// of legal characters is deliberately small.
pub fn validProfile(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "a relative .git is resolved against the cwd it was reported from" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "/home/me/code/api/.git",
        try resolveGitDir(a.allocator(), ".git", "/home/me/code/api"),
    );
}

test "a worktree reports an absolute common dir, and it wins" {
    var a = testArena();
    defer a.deinit();
    // The whole point: both the main checkout and a worktree of it resolve to one path,
    // so they share a backlog instead of forking into two.
    const from_main = try resolveGitDir(a.allocator(), ".git", "/home/me/code/api");
    const from_worktree = try resolveGitDir(
        a.allocator(),
        "/home/me/code/api/.git",
        "/home/me/code/api-feature",
    );
    try testing.expectEqualStrings(from_main, from_worktree);
}

test "a bare repository reports dot" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "/srv/git/api.git",
        try resolveGitDir(a.allocator(), ".", "/srv/git/api.git"),
    );
}

test "trailing whitespace from git is trimmed" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "/home/me/api/.git",
        try resolveGitDir(a.allocator(), ".git\n", "/home/me/api"),
    );
}

test "no output at all is not a repository" {
    var a = testArena();
    defer a.deinit();
    try testing.expectError(error.NotARepository, resolveGitDir(a.allocator(), "", "/tmp"));
    try testing.expectError(error.NotARepository, resolveGitDir(a.allocator(), "  \n", "/tmp"));
}

test "traversal in the reported path is normalised away" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "/home/me/other/.git",
        try resolveGitDir(a.allocator(), "../other/.git", "/home/me/api"),
    );
}

test "same-named projects under different parents get different replicas" {
    var a = testArena();
    defer a.deinit();
    const one = try replicaName(a.allocator(), "/home/me/work/api/.git");
    const two = try replicaName(a.allocator(), "/home/me/personal/api/.git");

    try testing.expect(std.mem.startsWith(u8, one, "api-"));
    try testing.expect(std.mem.startsWith(u8, two, "api-"));
    try testing.expect(!std.mem.eql(u8, one, two));
}

test "a replica name is stable across calls" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        try replicaName(a.allocator(), "/home/me/code/api/.git"),
        try replicaName(a.allocator(), "/home/me/code/api/.git"),
    );
}

test "a bare repo's replica keeps its own name" {
    var a = testArena();
    defer a.deinit();
    const name = try replicaName(a.allocator(), "/srv/git/api.git");
    try testing.expect(std.mem.startsWith(u8, name, "api.git-"));
}

test "the display name is the directory, not the dot-git" {
    try testing.expectEqualStrings("api", displayName("/home/me/code/api/.git"));
    try testing.expectEqualStrings("api.git", displayName("/srv/git/api.git"));
}

test "profile names are restricted" {
    try testing.expect(validProfile("default"));
    try testing.expect(validProfile("work-2"));
    try testing.expect(validProfile("A_b"));
    try testing.expect(!validProfile(""));
    try testing.expect(!validProfile("has space"));
    try testing.expect(!validProfile("../escape"));
    try testing.expect(!validProfile("semi;colon"));
    try testing.expect(!validProfile("x" ** 65));
}
