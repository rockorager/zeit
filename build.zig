const std = @import("std");

/// Allow the full zeit API to be usable at build time
pub const api = @import("src/zeit.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zeit", .{
        .root_source_file = b.path("src/zeit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zeit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const gen_step = b.step("generate", "Update timezone names");
    const gen = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const fmt = b.addFmt(
        .{ .paths = &.{"src/location.zig"} },
    );
    const gen_run = b.addRunArtifact(gen);
    fmt.step.dependOn(&gen_run.step);
    gen_step.dependOn(&fmt.step);

    // Docs
    {
        const docs_step = b.step("docs", "Build the zeit docs");
        const docs_obj = b.addObject(.{
            .name = "zeit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zeit.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const docs = docs_obj.getEmittedDocs();
        docs_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = docs,
            .install_dir = .prefix,
            .install_subdir = "docs",
        }).step);
    }
}
