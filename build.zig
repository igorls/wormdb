const std = @import("std");

/// Link libsodium into a module, branching on target OS.
///
/// Linux uses the vendored shared `deps/lib/libsodium.so`. Windows (gnu/MinGW
/// ABI) links the vendored static `deps/lib/windows-x86_64/libsodium.a` and the
/// system libraries libsodium's Windows backend needs (advapi32/bcrypt for the
/// CSPRNG) plus ws2_32 for Winsock, which the threadpool server and gateway use.
fn linkSodium(b: *std.Build, mod: *std.Build.Module, is_windows: bool) void {
    if (is_windows) {
        mod.addLibraryPath(b.path("deps/lib/windows-x86_64"));
        mod.linkSystemLibrary("sodium", .{ .preferred_link_mode = .static });
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("bcrypt", .{});
        mod.linkSystemLibrary("ws2_32", .{});
    } else {
        mod.addLibraryPath(b.path("deps/lib"));
        mod.linkSystemLibrary("sodium", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    // --- Build options (exposed to source via @import("build_options")) ---
    const enable_quic = b.option(bool, "quic", "Enable QUIC/WebTransport gateway (requires MsQuic)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "quic", enable_quic);
    // Create the build_options module ONCE and share it across all modules below. Creating it
    // per-module would yield distinct module instances that conflict once they're composed
    // together (e.g. main importing the engine via the named `wormdb` module).
    const build_options_mod = build_options.createModule();

    // MeshGuard library module (embedded mesh networking). Use b.path (relative to THIS
    // package's root) not .cwd_relative, so wormdb resolves correctly when consumed as a
    // dependency from another package (e.g. wormdb-domain-atomicassets).
    const meshguard_mod = b.createModule(.{
        .root_source_file = b.path("deps/meshguard/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // WormDB library module — exposed via addModule so downstream packages (domain
    // extensions in their own repos, e.g. wormdb-domain-atomicassets) can consume the real
    // engine types (Store, Ctx, Segment, Domain, …) with `@import("wormdb")`. linkSodium is
    // applied to the module itself so consumers inherit the libsodium link transitively.
    const wormdb_mod = b.addModule("wormdb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "meshguard", .module = meshguard_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    linkSodium(b, wormdb_mod, is_windows);

    // Main executable. Domain packages live in their own repos and are wired in at src/<name>
    // (a symlink to the package's src/, like deps/meshguard). main.zig imports the domain's
    // manifest as a plain file within this module, so the domain shares the exe's `wormdb`
    // import (the same engine module instance — its manifest types match exactly). main.zig
    // registers each manifest's procedures at startup.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wormdb", .module = wormdb_mod },
            .{ .name = "meshguard", .module = meshguard_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // In Zig 0.16, link* / addInclude / addCSource are on Module, not Step.Compile
    linkSodium(b, exe_mod, is_windows);

    const exe = b.addExecutable(.{
        .name = "wormdb",
        .root_module = exe_mod,
    });

    // --- QUIC / WebTransport support (opt-in via -Dquic=true) ---
    if (enable_quic) {
        // MsQuic static library (pre-built)
        exe_mod.addObjectFile(.{ .cwd_relative = "deps/msquic/build/bin/Release/libmsquic.a" });

        // MsQuic include path
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/msquic/src/inc" });

        // libwtf include paths
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/include" });
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/src" });
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/ls-qpack" });
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/xxhash" });
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/tinycthreads" });
        exe_mod.addIncludePath(.{ .cwd_relative = "deps/libwtf/deps/verstable" });

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
            exe_mod.addCSourceFile(.{
                .file = .{ .cwd_relative = src },
                .flags = &.{ "-std=gnu11", "-DWTF_EXPORTS", "-fno-sanitize=alignment" },
            });
        }

        // System libraries needed by MsQuic
        exe_mod.linkSystemLibrary("crypto", .{});
        exe_mod.linkSystemLibrary("pthread", .{});
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
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    linkSodium(b, test_mod, is_windows);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

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
