const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linux = b.addModule("linux", .{ .root_source_file = b.path("src/linux.zig") });

    const tests = b.addTest(.{ .name = "linux-zig", .root_module = b.createModule(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "linux", .module = linux }},
    }) });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    b.step("test", "run the unit tests").dependOn(&run_tests.step);
    b.step("test-build", "build the unit tests without running them").dependOn(&tests.step);
}
