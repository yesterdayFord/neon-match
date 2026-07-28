const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "neon-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run neon-match");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/engine_behavior.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine", .module = engine_module },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_main_tests = b.addRunArtifact(main_tests);
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const replay_basic = b.addRunArtifact(exe);
    replay_basic.setStdIn(.{ .lazy_path = b.path("tests/fixtures/basic.commands") });
    replay_basic.expectStdOutEqual(@embedFile("tests/fixtures/basic.stdout"));

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_behavior_tests.step);
    test_step.dependOn(&replay_basic.step);
}
