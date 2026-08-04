//! Rewriting a devshell `flake.nix` around its package marker.
//!
//! In bash this was three awk programs driven through a `mktemp`-and-move helper. The
//! logic is pure text, so it is pure functions here — which means the properties the shell
//! tests asserted (`test/capsule-test.sh:45-67`) are asserted without a temp file, a
//! working directory, or an awk.
//!
//! The one rule worth stating plainly: a package is matched by **exact equality of the
//! trimmed line**, never by substring or pattern. `python3Packages.foo` and
//! `python3PackagesXfoo` differ, and a regex written the obvious way would confuse them.

const std = @import("std");

/// The line packages are inserted above. Kept as a comment in the file so the flake stays
/// a valid, hand-editable nix expression.
pub const marker = "# devhelper:packages";

/// The whitespace the marker line begins with, so inserted packages line up with it.
/// Empty when the file has no marker.
pub fn indentOf(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        return line[0 .. line.len - trimmed.len];
    }
    return "";
}

pub fn hasMarker(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) return true;
    }
    return false;
}

/// Whether `pkg` is already listed. Exact match on the trimmed line.
pub fn present(text: []const u8, pkg: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), pkg)) return true;
    }
    return false;
}

/// Adds packages immediately above the marker, in the order given, indented to match it.
/// The marker itself survives, because the next `add` needs it.
pub fn inject(arena: std.mem.Allocator, text: []const u8, pkgs: []const []const u8) ![]const u8 {
    const indent = indentOf(text);

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;

        if (std.mem.indexOf(u8, line, marker) != null) {
            for (pkgs) |pkg| {
                try out.appendSlice(arena, indent);
                try out.appendSlice(arena, pkg);
                try out.append(arena, '\n');
            }
        }
        try out.appendSlice(arena, line);
    }
    return out.toOwnedSlice(arena);
}

/// Drops every line whose trimmed text exactly equals one of `pkgs`.
pub fn strip(arena: std.mem.Allocator, text: []const u8, pkgs: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var drop = false;
        for (pkgs) |pkg| {
            if (std.mem.eql(u8, trimmed, pkg)) drop = true;
        }
        if (drop) continue;

        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
    }
    return out.toOwnedSlice(arena);
}

/// The packages to actually add: those not already in the file, with repeats inside one
/// batch collapsed. `capsule env add fd fd` adds `fd` once, and adding it twice on
/// separate invocations is a no-op the second time.
pub fn newPackages(
    arena: std.mem.Allocator,
    text: []const u8,
    requested: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (requested) |pkg| {
        if (pkg.len == 0 or present(text, pkg)) continue;
        var already = false;
        for (out.items) |taken| {
            if (std.mem.eql(u8, taken, pkg)) already = true;
        }
        if (!already) try out.append(arena, pkg);
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

/// The same seed the shell suite used, so the ported assertions are against like for like.
const seed =
    \\{
    \\  outputs = { self, nixpkgs }: {
    \\    devShells.default = pkgs.mkShell {
    \\      packages = with pkgs; [
    \\        # devhelper:packages
    \\      ];
    \\    };
    \\  };
    \\}
;

/// The package names, in order — the Zig equivalent of the suite's `pkg_list`.
fn packageList(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfNone(u8, trimmed, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") != null) continue;
        try names.append(arena, trimmed);
    }
    return std.mem.join(arena, ",", names.items);
}

test "inject adds packages in order and keeps the marker" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const got = try inject(a.allocator(), seed, &.{ "go", "gopls" });
    try testing.expectEqualStrings("go,gopls", try packageList(a.allocator(), got));
    try testing.expect(hasMarker(got));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, marker));
}

test "injected packages take the marker's indentation" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try inject(a.allocator(), seed, &.{"zig"});
    try testing.expect(std.mem.indexOf(u8, got, "\n        zig\n") != null);
}

test "add is idempotent, on repeat invocations and within one batch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var text = try inject(arena, seed, try newPackages(arena, seed, &.{"ripgrep"}));
    text = try inject(arena, text, try newPackages(arena, text, &.{"ripgrep"}));
    try testing.expectEqualStrings("ripgrep", try packageList(arena, text));

    const batch = try newPackages(arena, seed, &.{ "fd", "fd" });
    try testing.expectEqual(@as(usize, 1), batch.len);
}

test "rm drops only the named package" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const filled = try inject(arena, seed, &.{ "go", "gopls", "just" });
    const got = try strip(arena, filled, &.{"gopls"});
    try testing.expectEqualStrings("go,just", try packageList(arena, got));
}

test "rm does not over-match a dot the way a regex would" {
    // `python3Packages.foo` as a pattern matches `python3PackagesXfoo`. Exact equality on
    // the trimmed line is what keeps the two apart, and this is the assertion that pins it.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const filled = try inject(arena, seed, &.{"python3PackagesXfoo"});
    const got = try strip(arena, filled, &.{"python3Packages.foo"});
    try testing.expectEqualStrings("python3PackagesXfoo", try packageList(arena, got));
}

test "removing a package that is not there changes nothing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const filled = try inject(arena, seed, &.{"zig"});
    const got = try strip(arena, filled, &.{"rust"});
    try testing.expectEqualStrings(filled, got);
}

test "presence is exact, never a prefix or a substring" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const filled = try inject(a.allocator(), seed, &.{"ripgrep"});
    try testing.expect(present(filled, "ripgrep"));
    try testing.expect(!present(filled, "rip"));
    try testing.expect(!present(filled, "ripgrepx"));
}

test "a flake with no marker is left alone rather than corrupted" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const plain = "{ outputs = {}; }";
    try testing.expect(!hasMarker(plain));
    try testing.expectEqualStrings("", indentOf(plain));
    try testing.expectEqualStrings(plain, try inject(a.allocator(), plain, &.{"go"}));
}

test "a rewrite round-trips a file it does not change" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Byte-for-byte: no trailing newline gained or lost, no line reflowed.
    try testing.expectEqualStrings(seed, try inject(arena, seed, &.{}));
    try testing.expectEqualStrings(seed, try strip(arena, seed, &.{}));
}
