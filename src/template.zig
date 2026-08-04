//! What `capsule env init` scaffolds into a fresh project.
//!
//! bash read these out of `$CAPSULE_SHARE/templates` at run time, which made the command
//! depend on the flake wrapper, the Nix store path and the image layout all agreeing — a
//! mispackaged install failed when a user ran it, not when it was built. They are embedded
//! here instead, the way `seed.zig` embeds the container's hooks.
//!
//! `share/templates/` stays the source of truth: the files are read at compile time, so
//! editing a `packages` list or a justfile is still editing a plain file, and a language
//! that is missing one is a build error rather than a run-time surprise.

const std = @import("std");

/// The placeholder the devshell template carries where the project's name belongs.
pub const name_placeholder = "PROJECT_NAME";

/// The devshell flake every project starts from, marker line included.
pub const devshell_flake = @embedFile("template_devshell_flake");

pub const Lang = struct {
    name: []const u8,
    /// Injected above the flake's marker, in this order.
    packages: []const []const u8,
    /// Written as `justfile`, unless the project already has one.
    justfile: []const u8,
};

/// Every language `env init` knows. Adding one means adding a directory under
/// `share/templates/` and a line here — and then the help, the error message and the
/// dispatch all follow from this array.
pub const langs = [_]Lang{
    .{
        .name = "go",
        .packages = packageList(@embedFile("template_go_packages")),
        .justfile = @embedFile("template_go_justfile"),
    },
    .{
        .name = "zig",
        .packages = packageList(@embedFile("template_zig_packages")),
        .justfile = @embedFile("template_zig_justfile"),
    },
};

/// Splits an embedded `packages` file into names, dropping blank lines — the filter bash
/// spelled `grep -v '^[[:space:]]*$'`. Runs at compile time, so the list costs nothing at
/// run time and cannot fail while a user is waiting on it.
fn packageList(comptime text: []const u8) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const pkg = std.mem.trim(u8, line, " \t\r");
            if (pkg.len == 0) continue;
            out = out ++ [_][]const u8{pkg};
        }
        return out;
    }
}

pub fn find(name: []const u8) ?*const Lang {
    for (&langs) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// The languages on offer, comma-separated, for the message that says one was not found.
pub fn names(arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (&langs, 0..) |*l, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, l.name);
    }
    return out.toOwnedSlice(arena);
}

/// A name is written into a nix string literal and into a shell-free file, so the rule is
/// only that it cannot end the literal or start an interpolation.
///
/// bash substituted it with `sed s/PROJECT_NAME/$name/g` and validated nothing: a `/`
/// broke the sed expression, and a `"` or a `${` produced a `flake.nix` that nix refused
/// to parse — reported as a nix error, several steps from the cause.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        '"', '\\', '$', '\n', '\r', 0 => return false,
        else => {},
    };
    return true;
}

/// The devshell flake with `name` in place of the placeholder.
pub fn renderFlake(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, devshell_flake, name_placeholder, name);
    const out = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, devshell_flake, name_placeholder, name, out);
    return out;
}

const testing = std.testing;

test "every language ships packages and a justfile" {
    for (&langs) |*l| {
        try testing.expect(l.name.len > 0);
        try testing.expect(l.packages.len > 0);
        try testing.expect(l.justfile.len > 0);
    }
}

test "no package list keeps a blank line the shell would have dropped" {
    // The `packages` files end in a newline, so a naive split yields a trailing empty
    // entry — which would be injected into the flake as a bare blank line.
    for (&langs) |*l| {
        for (l.packages) |pkg| {
            try testing.expect(pkg.len > 0);
            try testing.expect(std.mem.trim(u8, pkg, " \t\r").len == pkg.len);
        }
    }
}

test "the languages the shell CLI offered are still offered" {
    try testing.expect(find("zig") != null);
    try testing.expect(find("go") != null);
    try testing.expect(find("rust") == null);
    try testing.expect(find("") == null);
}

test "each language brings just, because its justfile is useless without it" {
    for (&langs) |*l| {
        var has_just = false;
        for (l.packages) |pkg| {
            if (std.mem.eql(u8, pkg, "just")) has_just = true;
        }
        if (!has_just) {
            std.debug.print("language '{s}' seeds a justfile but not just\n", .{l.name});
            return error.JustMissing;
        }
    }
}

test "the embedded flake carries the marker env add needs" {
    const flake = @import("flake.zig");
    try testing.expect(flake.hasMarker(devshell_flake));
    try testing.expect(std.mem.indexOf(u8, devshell_flake, name_placeholder) != null);
}

test "rendering replaces every occurrence of the placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out = try renderFlake(arena.allocator(), "capsule");
    try testing.expect(std.mem.indexOf(u8, out, name_placeholder) == null);
    try testing.expect(std.mem.indexOf(u8, out, "capsule dev shell") != null);

    const flake = @import("flake.zig");
    try testing.expect(flake.hasMarker(out));
}

test "a rendered flake still accepts packages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flake = @import("flake.zig");
    const rendered = try renderFlake(a, "demo");
    const with_pkgs = try flake.inject(a, rendered, find("zig").?.packages);

    for (find("zig").?.packages) |pkg| {
        try testing.expect(flake.present(with_pkgs, pkg));
    }
    // The marker survives, so a later `env add` still has somewhere to insert.
    try testing.expect(flake.hasMarker(with_pkgs));
}

test "names lists every language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const listed = try names(arena.allocator());
    for (&langs) |*l| {
        try testing.expect(std.mem.indexOf(u8, listed, l.name) != null);
    }
}

test "a name that would break the nix expression is refused" {
    try testing.expect(validName("capsule"));
    try testing.expect(validName("my project"));
    try testing.expect(validName("web-api_2"));

    try testing.expect(!validName(""));
    try testing.expect(!validName("a" ** 65));
    try testing.expect(!validName("say \"hi\""));
    try testing.expect(!validName("${pkgs.hello}"));
    try testing.expect(!validName("back\\slash"));
    try testing.expect(!validName("two\nlines"));
}

test "an admitted name renders a description nix can still parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // validName's whole job is that whatever it admits leaves the string literal intact,
    // so the check is on the rendered line rather than on the name.
    for ([_][]const u8{ "a", "my project", "web-api_2", "ünïcode" }) |name| {
        try testing.expect(validName(name));
        const out = try renderFlake(arena.allocator(), name);

        const expected = try std.fmt.allocPrint(
            arena.allocator(),
            "description = \"{s} dev shell\";",
            .{name},
        );
        try testing.expect(std.mem.indexOf(u8, out, expected) != null);
        try testing.expect(std.mem.indexOf(u8, out, "${") == null);
    }
}
