const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MeshGuard library module (embedded mesh networking)
    const meshguard_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../GitHub/zig-meshguard/meshguard/src/lib.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // WormDB library module
    const wormdb_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "meshguard", .module = meshguard_mod },
        },
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wormdb", .module = wormdb_mod },
            .{ .name = "meshguard", .module = meshguard_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wormdb",
        .root_module = exe_mod,
    });
    exe.linkSystemLibrary("sodium");
    b.installArtifact(exe);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "meshguard", .module = meshguard_mod },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.linkSystemLibrary("sodium");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run wormdb");
    run_step.dependOn(&run_cmd.step);
}
