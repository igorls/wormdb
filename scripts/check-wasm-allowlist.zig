//! Build-time guard for the wasm procedure allowlist.
//!
//! `src/wasm_root.zig` compiles the reduced engine, and `procedures/wasm_registry.zig` names the
//! only procedures it may expose. Those procedures must not reach `cluster` — cluster imports
//! meshguard, whose sockets and locks wasm cannot compile, and that is the whole reason the
//! reduced root exists.
//!
//! Zig cannot inspect another module's import graph at comptime, so this is a build step rather
//! than a language-level check. It reads the allowlisted modules and their `procedures/`
//! dependencies and FAILS THE BUILD if any of them imports cluster, naming the file. It is wired
//! into the wasm ffi step, so the build cannot succeed with a broken allowlist.
//!
//! Run directly: `zig run scripts/check-wasm-allowlist.zig`

const std = @import("std");

/// Files reached from the allowlist, kept explicit so a new entry is a deliberate addition.
/// Each is checked, and any `../cluster` import in one is an error.
const checked = [_][]const u8{
    "src/procedures/transfer.zig",
    "src/procedures/increment.zig",
    "src/procedures/kv_put.zig",
    "src/procedures/kv_get.zig",
    "src/procedures/kv_stats.zig",
    "src/procedures/scan.zig",
    "src/procedures/chat_send.zig",
    "src/procedures/chat_history.zig",
    "src/procedures/vsearch.zig",
    "src/procedures/vsim.zig",
    "src/procedures/vinsert.zig",
    "src/procedures/vstats.zig",
    "src/procedures/vreindex.zig",
    "src/procedures/vrabitq.zig",
    "src/procedures/vdelete.zig",
    "src/procedures/vnsdrop.zig",
    "src/procedures/memory.zig",
    "src/procedures/append_log.zig",
    "src/procedures/context.zig",
    "src/procedures/domain.zig",
    "src/procedures/vector_ops.zig",
    "src/storage/store.zig",
    "src/vector/index.zig",
};

/// The markers that mean "this file pulled the cluster graph in".
/// Only what genuinely drags in sockets or the cluster graph. `server/auth.zig` is pure (no
/// std.posix, no net, no cluster) and is legitimately imported by the reduced root, so naming
/// the whole `../server` directory would be a false positive.
const forbidden = [_][]const u8{
    "@import(\"../cluster",
    "@import(\"../server/tcp.zig",
    "@import(\"../server/epoll.zig",
    "@import(\"../server/gateway.zig",
    "@import(\"../server/uring.zig",
    "@import(\"../server/quic_gateway.zig",
    "@import(\"../server/executor.zig",
    "@import(\"../server/mod.zig",
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var failures: usize = 0;
    for (checked) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(8 << 20)) catch |err| {
            std.debug.print("check-wasm-allowlist: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            failures += 1;
            continue;
        };
        defer allocator.free(source);
        // Line by line, and gate-aware: an import guarded by `wasm_target` is exactly the
        // pattern that makes the reduced root possible, so only an UNGATED one is a violation.
        // That is the case this guard exists to catch — an import added without the gate.
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 0;
        while (lines.next()) |line| {
            line_no += 1;
            if (std.mem.indexOf(u8, line, "wasm_target") != null) continue; // deliberately gated
            for (forbidden) |needle| {
                if (std.mem.indexOf(u8, line, needle) != null) {
                    std.debug.print(
                        "check-wasm-allowlist: ERROR {s}:{d} imports the cluster/server graph ungated ({s}).\n" ++
                            "  Gate it on compat.wasm_target, or keep it out of the wasm allowlist — see docs/wasm.md.\n",
                        .{ path, line_no, needle },
                    );
                    failures += 1;
                }
            }
        }
    }

    if (failures != 0) {
        std.debug.print("check-wasm-allowlist: {d} problem(s); the wasm allowlist is not clean.\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("check-wasm-allowlist: {d} files checked, no cluster/server imports.\n", .{checked.len});
}
