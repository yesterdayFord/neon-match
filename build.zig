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

    const bench = b.addExecutable(.{
        .name = "neon-match-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();

    const bench_step = b.step("bench", "Run deterministic benchmark workloads");
    bench_step.dependOn(&run_bench.step);

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

    const journal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/journal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
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
    const run_journal_tests = b.addRunArtifact(journal_tests);
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_journal_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_behavior_tests.step);
}
