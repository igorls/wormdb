const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options (exposed to source via @import("build_options")) ---
    const enable_quic = b.option(bool, "quic", "Enable QUIC/WebTransport gateway (requires MsQuic)") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "quic", enable_quic);

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
            .{ .name = "build_options", .module = build_options.createModule() },
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
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wormdb",
        .root_module = exe_mod,
    });
    exe.linkSystemLibrary("sodium");

    // --- QUIC / WebTransport support (opt-in via -Dquic=true) ---
    if (enable_quic) {
        // MsQuic static library (pre-built)
        exe.addObjectFile(.{ .cwd_relative = "deps/msquic/build/bin/Release/libmsquic.a" });

        // MsQuic include path
        exe.addIncludePath(.{ .cwd_relative = "deps/msquic/src/inc" });

        // libwtf include paths
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/include" });
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/src" });
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/ls-qpack" });
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/xxhash" });
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/tinycthreads" });
        exe.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/verstable" });

        // libwtf C sources
        const libwtf_sources = [_][]const u8{
            "deps/libwtf/src/conn.c",
            "deps/libwtf/src/context.c",
            "deps/libwtf/src/datagram.c",
            "deps/libwtf/src/http3.c",
            "deps/libwtf/src/log.c",
            "deps/libwtf/src/qpack.c",
            "deps/libwtf/src/server.c",
            "deps/libwtf/src/session.c",
            "deps/libwtf/src/settings.c",
            "deps/libwtf/src/stream.c",
            "deps/libwtf/src/utils.c",
            "deps/libwtf/src/varint.c",
            // libwtf vendored deps
            "deps/libwtf/deps/xxhash/xxhash.c",
            "deps/libwtf/deps/tinycthreads/tinycthread.c",
            "deps/libwtf/deps/ls-qpack/lsqpack.c",
        };
        for (libwtf_sources) |src| {
            exe.addCSourceFile(.{
                .file = .{ .cwd_relative = src },
                .flags = &.{ "-std=gnu11", "-DWTF_EXPORTS", "-fno-sanitize=alignment" },
            });
        }

        // System libraries needed by MsQuic
        exe.linkSystemLibrary("crypto");
        exe.linkSystemLibrary("pthread");
    }

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
