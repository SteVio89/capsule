const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });

    const core = b.addModule("capsuled", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite", .module = sqlite.module("sqlite") }},
    });

    const exe = b.addExecutable(.{
        .name = "capsuled",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capsuled", .module = core }},
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
