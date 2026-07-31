const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core is its own module so `zig build test` exercises it directly and main.zig
    // stays argv marshalling. Everything worth testing — event replay, buffer parsing,
    // prefix resolution, the socket envelope — lives behind here as a pure function.
    const core = b.addModule("capsuled", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Explicit, not inherited from linkSystemLibrary below. The root module's
        // link_libc is what selects the start code: without it Zig uses its own `_start`
        // and never calls __libc_start_main, so glibc's TLS is never set up — and then
        // the first library call that touches a pthread mutex faults. libsqlite3 does
        // that inside sqlite3_initialize, before it looks at a single argument.
        .link_libc = true,
    });
    // System sqlite, not a vendored amalgamation and not a package dependency: a
    // build.zig.zon dependency would force a fixed-output derivation with a hash to
    // maintain, in a project whose packaging is otherwise four lines of `cp`.
    core.linkSystemLibrary("sqlite3", .{});
    // Two binds that need SQLITE_TRANSIENT, a sentinel Zig cannot construct. See the file.
    core.addCSourceFile(.{ .file = b.path("src/sqlite_shim.c") });

    const exe = b.addExecutable(.{
        .name = "capsuled",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "capsuled", .module = core }},
        }),
    });
    b.installArtifact(exe);

    // A test binary covers one module, so both need their own.
    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};

    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ core, exe.root_module }) |m| {
        const t = b.addTest(.{ .root_module = m, .filters = filters });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
