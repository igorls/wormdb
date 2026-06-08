const std = @import("std");

/// Link platform crypto/system libraries into a module, branching on target OS.
///
/// libsodium is an OPTIONAL accelerator (meshguard#102): it is linked only when
/// `use_libsodium` is set (resolved from `-Dcrypto-backend` / `-Dno-sodium`).
/// Linux uses the vendored shared `deps/lib/libsodium.so`; Windows uses the
/// vendored static `deps/lib/windows-x86_64/libsodium.a`. The std.crypto path
/// (the default off-Linux and whenever sodium is disabled) needs no sodium link.
///
/// Windows always links ws2_32 (Winsock — threadpool server + gateway) and
/// advapi32/bcrypt (CSPRNG backing) regardless of the crypto backend.
fn linkCrypto(b: *std.Build, mod: *std.Build.Module, os_tag: std.Target.Os.Tag, abi: std.Target.Abi, use_libsodium: bool) void {
    if (os_tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("bcrypt", .{});
        if (use_libsodium) {
            mod.addLibraryPath(b.path("deps/lib/windows-x86_64"));
            mod.linkSystemLibrary("sodium", .{ .preferred_link_mode = .static });
        }
    } else if (os_tag == .linux and abi != .android and use_libsodium) {
        mod.addLibraryPath(b.path("deps/lib"));
        mod.linkSystemLibrary("sodium", .{});
    }
}

/// Link the QUIC/WebTransport C deps (MsQuic + libwtf) into a module so consumers inherit them, exactly
/// like linkCrypto. Uses b.path (relative to THIS package's root) so it resolves when wormdb is consumed
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

// This package exports the WormDB ENGINE LIBRARY as the `wormdb` module and also
// builds a basic standalone database executable for local/dev use. Rich domain
// composition binaries can still live in separate repos and depend on this
// engine module; the in-repo exe intentionally wires only the core engine.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;
    const abi = target.result.abi;

    // Build option, exposed to source via @import("build_options"). QUIC's C deps (MsQuic/libwtf) are
    // wired in the server build when enabled — see wormdb-server. The engine only carries the flag +
    // the (comptime-gated) Zig code.
    const enable_quic = b.option(bool, "quic", "Enable QUIC/WebTransport gateway (requires MsQuic)") orelse false;

    // ─── Crypto backend selection (meshguard#102) ───
    // libsodium is an OPTIONAL accelerator (AVX2 ChaCha20-Poly1305 on Linux, used
    // by the embedded meshguard tunnel), not a required dependency. wormdb itself
    // uses std.crypto for SCT auth, so the basic build path needs no libsodium.
    //   auto   → libsodium on Linux desktop (non-Android), std.crypto elsewhere
    //   std    → std.crypto everywhere (no libsodium link)
    //   sodium → force libsodium (link must be available for the target)
    const CryptoBackend = enum { auto, std, sodium };
    const crypto_backend_opt = b.option(CryptoBackend, "crypto-backend", "Crypto backend: auto|std|sodium (default auto)");
    const no_sodium = b.option(bool, "no-sodium", "Alias for -Dcrypto-backend=std") orelse false;
    // Fail fast on contradictory flags rather than silently letting one win.
    if (no_sodium and (crypto_backend_opt orelse .std) == .sodium) {
        std.debug.print("error: -Dno-sodium=true conflicts with -Dcrypto-backend=sodium\n" ++
            "  (-Dno-sodium is an alias for -Dcrypto-backend=std)\n", .{});
        std.process.exit(1);
    }
    const crypto_backend = crypto_backend_opt orelse .auto;
    const auto_libsodium = (os_tag == .linux and abi != .android);
    const use_libsodium = if (no_sodium) false else switch (crypto_backend) {
        .std => false,
        .sodium => true,
        .auto => auto_libsodium,
    };

    const build_options = b.addOptions();
    build_options.addOption(bool, "quic", enable_quic);
    // Consumed by the embedded meshguard source (tunnel.zig/main.zig) so it picks
    // the same backend linkCrypto wires for. Shared with the wormdb module too.
    build_options.addOption(bool, "use_libsodium", use_libsodium);
    const build_options_mod = build_options.createModule();

    // MeshGuard library module (embedded mesh networking). b.path resolves against THIS package's root,
    // so it works when wormdb is consumed as a dependency. meshguard's source reads `build_options` to
    // select its crypto backend — wormdb (which builds meshguard from source) must provide it.
    const meshguard_mod = b.createModule(.{
        .root_source_file = b.path("deps/meshguard/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    meshguard_mod.addImport("build_options", build_options_mod);

    // The engine library module — exposed via addModule so the server exe + domain packages consume the
    // real engine types (Store, Ctx, Segment, Domain, …) with `@import("wormdb")`. linkCrypto is applied
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
    linkCrypto(b, wormdb_mod, os_tag, abi, use_libsodium);
    if (enable_quic) linkQuic(b, wormdb_mod); // QUIC C deps inherited by consumers (server exe)

    // Basic standalone WormDB executable. This is deliberately a small
    // composition root over the engine module (no external domain packages), so
    // `zig build`, `zig build run`, and Dockerfile-based basic usage work from
    // this repository after the core-lib split.
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
    linkCrypto(b, exe_mod, os_tag, abi, use_libsodium);
    if (enable_quic) linkQuic(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "wormdb",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run the basic WormDB server");
    run_step.dependOn(&run_exe.step);

    // Embedding FFI library — a C ABI over the engine for native apps (iOS/Swift,
    // Android/JNI). Single-node, in-process; see src/ffi.zig and ffi/wormdb.h.
    // iOS must static-link (apps cannot dlopen user dylibs); everything else gets
    // a shared library by default.
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wormdb", .module = wormdb_mod },
        },
    });
    linkCrypto(b, ffi_mod, os_tag, abi, use_libsodium);
    if (enable_quic) linkQuic(b, ffi_mod);
    const ffi_lib = b.addLibrary(.{
        .name = "wormdb_ffi",
        .root_module = ffi_mod,
        .linkage = if (os_tag == .ios) .static else .dynamic,
    });
    b.installArtifact(ffi_lib);

    // `zig build ffi` builds ONLY the embedding library. Needed for darwin cross
    // targets (iOS) where the standalone exe can't link libSystem without the SDK,
    // but the static lib compiles fine with `--sysroot $(xcrun --show-sdk-path)`.
    const ffi_step = b.step("ffi", "Build only the embedding FFI library (libwormdb_ffi)");
    ffi_step.dependOn(&b.addInstallArtifact(ffi_lib, .{}).step);

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
    linkCrypto(b, test_mod, os_tag, abi, use_libsodium);
    if (enable_quic) linkQuic(b, test_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const ffi_unit_tests = b.addTest(.{ .root_module = ffi_mod });
    const run_ffi_tests = b.addRunArtifact(ffi_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
}
