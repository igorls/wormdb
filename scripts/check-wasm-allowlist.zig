//! Build-time guard for the wasm procedure allowlist.
//!
//! `src/wasm_root.zig` compiles the reduced engine, and `procedures/wasm_registry.zig` names the
//! only procedures it may expose. Neither may reach `cluster` — cluster imports meshguard, whose
//! sockets and locks wasm cannot compile, and that is the whole reason the reduced root exists.
//!
//! Zig cannot inspect another module's import graph at comptime, so this is a build step rather
//! than a language-level check. It is run by `zig build wasm`/`wasm-smoke`/`ffi` on a wasm target.
//!
//! HOW IT WORKS: it WALKS the import graph from the root rather than checking a hand-written file
//! list. An earlier version listed 23 files by hand; the graph reaches 55, so 32 files — all of
//! `proof/`, `event/`, `protocol/`, `storage/`, `vector/` and `wasm_registry.zig` itself — were
//! never looked at. A list you must remember to extend is a list that goes stale; the walk cannot.
//!
//! THE GATE IS RESPECTED, NOT SKIPPED. The reduced root exists because imports are written as
//! `if (<target>) @import(cluster) else @import(stub)` — e.g. procedures/context.zig:23. An edge on
//! a line mentioning `wasm_target` is NOT traversed, because on this target that branch is not the
//! one compiled. An earlier version skipped any LINE containing `wasm_target`, which had the same
//! effect for the gate but also skipped files entirely; walking and gating per-EDGE is the honest
//! version. An ungated forbidden import is still an error, naming file and line.
//!
//! RUN DIRECTLY: `zig run scripts/check-wasm-allowlist.zig`

const std = @import("std");

/// The root the walk starts from. Every file the wasm target compiles is reachable from here.
const root_file = "src/wasm_root.zig";

/// Import targets that mean "this file pulled the cluster graph in". Only what genuinely drags in
/// sockets or the cluster graph: `server/auth.zig` is pure and is legitimately reached, so naming
/// the whole `../server` directory would be a false positive.
const forbidden = [_][]const u8{
    "../cluster",
    "../server/tcp.zig",
    "../server/epoll.zig",
    "../server/gateway.zig",
    "../server/uring.zig",
    "../server/quic_gateway.zig",
    "../server/executor.zig",
    "../server/mod.zig",
};

/// An import line that mentions this is behind the target gate, so the branch is not compiled on a
/// wasm target and the edge must not be followed.
const gate_marker = "wasm_target";

const Guard = struct {
    allocator: std.mem.Allocator,
    /// Files already walked.
    seen: std.StringHashMap(void),
    /// Files waiting to be walked.
    queue: std.ArrayListUnmanaged([]const u8) = .empty,
    failures: usize,
    /// Gated edges skipped, reported in the summary so a reader can see the gate is recognised.
    gated: usize,

    fn walk(self: *Guard, start: []const u8) !void {
        try self.queue.append(self.allocator, try self.allocator.dupe(u8, start));

        while (self.queue.items.len > 0) {
            const path = self.queue.orderedRemove(0);
            if (self.seen.contains(path)) continue;
            try self.seen.put(path, {});

            const source = std.Io.Dir.cwd().readFileAlloc(
                std.Io.Threaded.global_single_threaded.io(),
                path,
                self.allocator,
                .limited(8 << 20),
            ) catch |err| {
                // FAIL CLOSED. A file we cannot read is a graph we cannot vouch for, so it is a
                // failure rather than a skip — the whole point is that nothing reachable is
                // unchecked. A relative path that resolves to nothing lands here too.
                std.debug.print("check-wasm-allowlist: ERROR cannot read {s}: {s}\n", .{ path, @errorName(err) });
                self.failures += 1;
                continue;
            };
            defer self.allocator.free(source);

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                var from: usize = 0;
                while (nextImport(line, &from)) |target| {
                    const gated = std.mem.indexOf(u8, line, gate_marker) != null;

                    // A forbidden target is a violation only when it is UNGATED.
                    if (isForbidden(target)) {
                        if (gated) {
                            self.gated += 1;
                        } else {
                            std.debug.print(
                                "check-wasm-allowlist: ERROR {s}:{d} imports the cluster/server graph ungated ({s}).\n" ++
                                    "  Gate it on compat.wasm_target, or keep it out of the wasm allowlist — see docs/wasm.md.\n",
                                .{ path, line_no, target },
                            );
                            self.failures += 1;
                        }
                        continue;
                    }

                    // Only a relative path is a file in this tree; `std` and `build_options` are
                    // module names, not files, and must not be queued.
                    if (!isRelativePath(target)) continue;
                    if (gated) {
                        self.gated += 1;
                        continue;
                    }
                    const resolved = try resolveRelative(self.allocator, path, target);
                    if (!self.seen.contains(resolved)) try self.queue.append(self.allocator, resolved);
                }
            }
        }
    }
};

/// Finds the next `@import("<target>")` at or after `*from`, advancing `*from` past it.
/// Returns the target, or null when the line has no further imports.
fn nextImport(line: []const u8, from: *usize) ?[]const u8 {
    const marker = "@import(\"";
    const at = std.mem.indexOfPos(u8, line, from.*, marker) orelse return null;
    const start = at + marker.len;
    const end = std.mem.indexOfPos(u8, line, start, "\"") orelse {
        from.* = line.len;
        return null;
    };
    from.* = end + 1;
    return line[start..end];
}

fn isForbidden(target: []const u8) bool {
    for (forbidden) |needle| {
        if (std.mem.startsWith(u8, target, needle)) return true;
    }
    return false;
}

/// A relative import is a file path in this tree. `std` and `build_options` are module names.
fn isRelativePath(target: []const u8) bool {
    return std.mem.indexOfScalar(u8, target, '/') != null or std.mem.endsWith(u8, target, ".zig");
}

/// Joins an import target onto the importing file's directory and normalises `..`/`.`.
/// Uses resolve() rather than a manual join so `a/../b` cannot produce a path that only LOOKS
/// resolved — a checker fooled by a path is worse than one that reports nothing.
fn resolveRelative(allocator: std.mem.Allocator, importer: []const u8, target: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(importer) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, target });
    defer allocator.free(joined);
    return std.fs.path.resolve(allocator, &.{joined});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var guard = Guard{
        .allocator = allocator,
        .seen = std.StringHashMap(void).init(allocator),
        .failures = 0,
        .gated = 0,
    };

    try guard.walk(root_file);

    if (guard.failures != 0) {
        std.debug.print("check-wasm-allowlist: {d} problem(s); the wasm import graph is not clean.\n", .{guard.failures});
        std.process.exit(1);
    }
    std.debug.print(
        "check-wasm-allowlist: walked {d} files from {s}, no ungated cluster/server imports ({d} gated edges respected).\n",
        .{ guard.seen.count(), root_file, guard.gated },
    );
}
