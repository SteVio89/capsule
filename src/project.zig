//! Project identity: what makes two directories the same project, and what the replica
//! for one is called.

const std = @import("std");

/// `--git-common-dir` answers relative to the cwd from the repository root (`.git`) and
/// absolutely from inside a worktree. Joining before realpath is what stops those two
/// from resolving to different projects.
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

    return std.fs.path.resolve(arena, &.{joined});
}

/// The replica's directory name on the VM.
pub fn replicaName(arena: std.mem.Allocator, canonical_path: []const u8) ![]const u8 {
    var base = std.fs.path.basename(canonical_path);
    if (std.mem.eql(u8, base, ".git")) {
        base = std.fs.path.basename(std.fs.path.dirname(canonical_path) orelse canonical_path);
    }
    if (base.len == 0) base = "project";

    const digest = std.hash.Wyhash.hash(0, canonical_path);
    return std.fmt.allocPrint(arena, "{s}-{x:0>8}", .{ base, @as(u32, @truncate(digest)) });
}

/// Display name for a project — the basename of its path, which is a perfectly good one.
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

/// A profile's directory: `${XDG_CONFIG_HOME:-$HOME/.config}/capsule/profiles/<name>`.
pub fn profileDir(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(arena, "{s}/capsule/profiles/{s}", .{ x, name });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(arena, "{s}/.config/capsule/profiles/{s}", .{ home, name });
}

/// One preference, from the one-bare-file-per-value layout `capsule login` writes.
///
/// The layout is kept as it is and simply read here, rather than moved into the store: it
/// holds an OAuth token, it is documented as hand-editable, and there is no migration
/// framework to move it with. `fallback` is returned for a missing or empty file, which is
/// what keeps a fresh profile from stopping a run to ask.
pub fn profilePref(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
    name: []const u8,
    fallback: []const u8,
) []const u8 {
    const dir = profileDir(arena, environ, profile) catch return fallback;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return fallback;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16)) catch
        return fallback;

    // Trailing newline: the files are written by shell redirection and read by a shell
    // `$(<file)`, which strips it. A token with a newline welded on authenticates nothing.
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return if (value.len == 0) fallback else value;
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn testEnv(
    arena: std.mem.Allocator,
    pairs: []const [2][]const u8,
) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(arena);
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "a profile directory follows XDG when it is set, and HOME when it is not" {
    var a = testArena();
    defer a.deinit();

    var home = try testEnv(a.allocator(), &.{.{ "HOME", "/home/me" }});
    try testing.expectEqualStrings(
        "/home/me/.config/capsule/profiles/work",
        try profileDir(a.allocator(), &home, "work"),
    );

    var xdg = try testEnv(a.allocator(), &.{ .{ "HOME", "/home/me" }, .{ "XDG_CONFIG_HOME", "/cfg" } });
    try testing.expectEqualStrings(
        "/cfg/capsule/profiles/work",
        try profileDir(a.allocator(), &xdg, "work"),
    );
}

test "a missing preference falls back rather than failing the run" {
    var a = testArena();
    defer a.deinit();

    var env = try testEnv(a.allocator(), &.{.{ "HOME", "/nonexistent-capsule-test" }});
    try testing.expectEqualStrings(
        "dark",
        profilePref(a.allocator(), testing.io, &env, "default", "theme", "dark"),
    );
    try testing.expectEqualStrings(
        "",
        profilePref(a.allocator(), testing.io, &env, "default", "token", ""),
    );
}

test "no HOME and no XDG is a fallback, not an error the caller must handle" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    try testing.expectError(error.NoHome, profileDir(a.allocator(), &env, "work"));
    try testing.expectEqualStrings(
        "vim",
        profilePref(a.allocator(), testing.io, &env, "work", "editor-mode", "vim"),
    );
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
