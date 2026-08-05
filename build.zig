const std = @import("std");

/// The one version. `build.zig.zon` is where a release bumps it; everything that prints
/// a version reads it from here so a bump cannot land in one place and not the other.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });

    const core = b.addModule("capsule", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite", .module = sqlite.module("sqlite") }},
    });

    // The shipped example config is the compatibility contract for the config parser, so
    // it is embedded and asserted on rather than duplicated into a test fixture that
    // could drift from the file users actually copy.
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    core.addOptions("build_options", options);

    core.addAnonymousImport("config_example", .{ .root_source_file = b.path("config.example") });

    // Embedded only so a test can assert the flake declares the same version this binary
    // prints. Nothing reads it at run time.
    core.addAnonymousImport("flake_nix", .{ .root_source_file = b.path("flake.nix") });

    // `env init`'s scaffolding. Embedded rather than read from CAPSULE_SHARE at run time,
    // so a language that lost a file breaks the build instead of the user's first command.
    // @embedFile cannot reach outside the module root, which is what these names are for.
    const templates = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "template_butane", .path = "share/fcos.bu.tmpl" },
        .{ .name = "template_devshell_flake", .path = "share/templates/devshell-flake.nix" },
        .{ .name = "template_go_packages", .path = "share/templates/go/packages" },
        .{ .name = "template_go_justfile", .path = "share/templates/go/justfile" },
        .{ .name = "template_zig_packages", .path = "share/templates/zig/packages" },
        .{ .name = "template_zig_justfile", .path = "share/templates/zig/justfile" },
    };
    for (templates) |t| {
        core.addAnonymousImport(t.name, .{ .root_source_file = b.path(t.path) });
    }

    const exe = b.addExecutable(.{
        .name = "capsule",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capsule", .module = core }},
        }),
    });
    b.installArtifact(exe);

    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};

    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ core, exe.root_module }) |m| {
        const t = b.addTest(.{ .root_module = m, .filters = filters });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
