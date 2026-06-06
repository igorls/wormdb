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

/// Link the QUIC/WebTransport C deps (MsQuic + libwtf) into a module so consumers inherit them, exactly
/// like linkSodium. Uses b.path (relative to THIS package's root) so it resolves when wormdb is consumed
/// as a dependency. Applied only when `-Dquic=true`. NOTE: Linux-oriented. Preconditions: `git submodule
/// update --init` (deps/msquic, deps/libwtf) + a CMake build of MsQuic (which produces the SHARED
/// `bin/Release/libmsquic.so`). The binary then needs libmsquic.so at runtime (set LD_LIBRARY_PATH or an
/// rpath to deps/msquic/build/bin/Release). Build/verify on Linux (see docker/build-linux.sh).
fn linkQuic(b: *std.Build, mod: *std.Build.Module) void {
    // MsQuic's default build is a shared library — link libmsquic.so from its build output dir.
    mod.addLibraryPath(b.path("deps/msquic/build/bin/Release"));
    mod.linkSystemLibrary("msquic", .{});
    mod.addIncludePath(b.path("deps/msquic/src/inc"));
    mod.addIncludePath(b.path("deps/libwtf/include"));
    mod.addIncludePath(b.path("deps/libwtf/build/include")); // cmake-generated wtf_version.h (run `cmake -B build` on libwtf)
    mod.addIncludePath(b.path("deps/libwtf/src"));
    mod.addIncludePath(b.path("deps/libwtf/deps/ls-qpack"));
    mod.addIncludePath(b.path("deps/libwtf/deps/xxhash"));
    mod.addIncludePath(b.path("deps/libwtf/deps/tinycthreads"));
    mod.addIncludePath(b.path("deps/libwtf/deps/verstable"));
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
        "deps/libwtf/deps/xxhash/xxhash.c",
        "deps/libwtf/deps/tinycthreads/tinycthread.c",
        "deps/libwtf/deps/ls-qpack/lsqpack.c",
    };
    for (libwtf_sources) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = &.{ "-std=gnu11", "-DWTF_EXPORTS", "-fno-sanitize=alignment" },
        });
    }
    // The shared libmsquic.so bundles its own TLS (quictls), so no external -lcrypto is needed (the
    // static .a would have required it). libwtf's tinycthread wraps pthread on POSIX.
    mod.linkSystemLibrary("pthread", .{});
}

// This package is the WormDB ENGINE LIBRARY only. It produces the `wormdb` module (consumed by the
// server binary and the domain packages, each in their own repo) plus its unit tests — it does NOT
// build the server exe. The exe is the composition root and lives in `wormdb-server`, which depends
// on this engine + the domain packages. Splitting the exe out of the engine is what lets the domains
// depend on `wormdb` via the package manager without a build-root self-diamond.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    // Build option, exposed to source via @import("build_options"). QUIC's C deps (MsQuic/libwtf) are
    // wired in the server build when enabled — see wormdb-server. The engine only carries the flag +
    // the (comptime-gated) Zig code.
    const enable_quic = b.option(bool, "quic", "Enable QUIC/WebTransport gateway (requires MsQuic)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "quic", enable_quic);
    const build_options_mod = build_options.createModule();

    // MeshGuard library module (embedded mesh networking). b.path resolves against THIS package's root,
    // so it works when wormdb is consumed as a dependency.
    const meshguard_mod = b.createModule(.{
        .root_source_file = b.path("deps/meshguard/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The engine library module — exposed via addModule so the server exe + domain packages consume the
    // real engine types (Store, Ctx, Segment, Domain, …) with `@import("wormdb")`. linkSodium is applied
    // to the module so consumers inherit the libsodium link transitively.
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
    if (enable_quic) linkQuic(b, wormdb_mod); // QUIC C deps inherited by consumers (server exe)

    // Unit tests for the engine.
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
    if (enable_quic) linkQuic(b, test_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
