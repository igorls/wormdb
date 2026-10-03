//! Build-time guard for the wasm procedure allowlist.
//!
//! `src/wasm_root.zig` compiles the reduced engine, and `procedures/wasm_registry.zig` names the
//! only procedures it may expose. Neither may reach `cluster` — cluster imports meshguard, whose
//! sockets and locks wasm cannot compile, and that is the whole reason the reduced root exists.
//!
//! Zig cannot inspect another module's import graph at comptime, so this is a build step rather
//! than a language-level check. It is run by `zig build wasm`/`wasm-smoke`/`ffi` on a wasm target.
//!
//! HOW IT WORKS: it walks the import graph from the root, so every file the wasm target can reach
//! is checked; nothing depends on a hand-written list.
//!
//! GATES ARE RESPECTED PER EDGE. The reduced root exists because some imports are written
//! `if (@import("../core/compat.zig").wasm_target) A else B` (see procedures/context.zig). On a wasm
//! target `A` is compiled and `B` is not, so imports in `B` are skipped and imports in the
//! condition and in `A` are walked and checked. A negated condition (`if (!…wasm_target)`) swaps
//! the branches. Comments are stripped first, so a comment mentioning `wasm_target` gates nothing.
//! A line that mentions `wasm_target` in any other shape gates nothing either: its imports are all
//! checked, which fails closed.
//!
//! FORBIDDEN TARGETS are matched on the RESOLVED path (so `cluster/mod.zig` from `src/` or
//! `./../cluster/x.zig` can't slip past a string match), plus the `meshguard` module by name.
//!
//! RUN DIRECTLY: `zig run scripts/check-wasm-allowlist.zig`. Its own tests: `zig test scripts/check-wasm-allowlist.zig`.

const std = @import("std");

/// The root the walk starts from. Every file the wasm target compiles is reachable from here.
const root_file = "src/wasm_root.zig";

/// Resolved paths (forward slashes, relative to the repository root) that mean "this file pulled the
/// cluster or socket graph in". `server/auth.zig` is pure and legitimately reached, so the whole
/// `server` directory is not forbidden, only the socket-bearing files.
const forbidden_dirs = [_][]const u8{"src/cluster/"};
const forbidden_files = [_][]const u8{
    "src/server/tcp.zig",
    "src/server/epoll.zig",
    "src/server/gateway.zig",
    "src/server/uring.zig",
    "src/server/quic_gateway.zig",
    "src/server/executor.zig",
    "src/server/mod.zig",
};
/// Named modules (not files) the wasm graph must never import.
const forbidden_modules = [_][]const u8{"meshguard"};

/// The marker a gated condition carries.
const gate_marker = "wasm_target";

/// Removes a `//` comment that isn't inside a string literal.
fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

const Span = struct {
    start: usize,
    end: usize,
    fn contains(self: Span, at: usize) bool {
        return at >= self.start and at < self.end;
    }
};

/// A one-line `if (<cond with wasm_target>) <then> else <else>` expression.
const Gate = struct { cond: Span, then_: Span, else_: Span, negated: bool };

/// Finds the first `if (` whose condition mentions `wasm_target`, with both branches on this line.
fn findGate(code: []const u8) ?Gate {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, code, search, "if (")) |at| {
        search = at + 1;
        // `if` must be a word of its own, not the tail of an identifier.
        if (at > 0 and (std.ascii.isAlphanumeric(code[at - 1]) or code[at - 1] == '_')) continue;
        const open = at + 3;
        const close = matchingParen(code, open) orelse return null;
        const cond = Span{ .start = open + 1, .end = close };
        if (std.mem.indexOf(u8, code[cond.start..cond.end], gate_marker) == null) continue;
        const else_at = std.mem.indexOfPos(u8, code, close, " else ") orelse return null;
        const end = std.mem.indexOfScalarPos(u8, code, else_at, ';') orelse code.len;
        const negated = std.mem.startsWith(u8, std.mem.trimStart(u8, code[cond.start..cond.end], " "), "!");
        return .{ .cond = cond, .then_ = .{ .start = close + 1, .end = else_at }, .else_ = .{ .start = else_at + 6, .end = end }, .negated = negated };
    }
    return null;
}

/// The index of the `)` matching the `(` at `open`, skipping string literals.
fn matchingParen(code: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = open;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Whether an import at `at` is compiled on a wasm target, given the line's gate (if any).
fn compiledOnWasm(gate: ?Gate, at: usize) bool {
    const g = gate orelse return true;
    if (g.then_.contains(at)) return !g.negated;
    if (g.else_.contains(at)) return g.negated;
    return true; // the condition itself, or anything outside the gated expression
}

const Import = struct { target: []const u8, at: usize };

/// Finds the next `@import("<target>")` at or after `*from`, advancing `*from` past it.
fn nextImport(code: []const u8, from: *usize) ?Import {
    const marker = "@import(\"";
    const at = std.mem.indexOfPos(u8, code, from.*, marker) orelse return null;
    const start = at + marker.len;
    const end = std.mem.indexOfScalarPos(u8, code, start, '"') orelse {
        from.* = code.len;
        return null;
    };
    from.* = end + 1;
    return .{ .target = code[start..end], .at = at };
}

/// A relative import is a file path in this tree; `std`, `builtin` and `build_options` are module names.
fn isFileImport(target: []const u8) bool {
    return std.mem.indexOfScalar(u8, target, '/') != null or std.mem.endsWith(u8, target, ".zig");
}

/// Joins an import target onto the importing file's directory, normalises it, and uses forward slashes.
fn resolveRelative(allocator: std.mem.Allocator, importer: []const u8, target: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(importer) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, target });
    defer allocator.free(joined);
    const slashed = try toSlashes(allocator, joined);
    defer allocator.free(slashed);
    return std.fs.path.resolvePosix(allocator, &.{slashed});
}

fn toSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn isForbiddenPath(resolved: []const u8) bool {
    for (forbidden_dirs) |dir| if (std.mem.startsWith(u8, resolved, dir)) return true;
    for (forbidden_files) |file| if (std.mem.eql(u8, resolved, file)) return true;
    return false;
}

fn isForbiddenModule(name: []const u8) bool {
    for (forbidden_modules) |module| if (std.mem.eql(u8, name, module)) return true;
    return false;
}

const Guard = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMap(void),
    queue: std.ArrayListUnmanaged([]const u8) = .empty,
    failures: usize = 0,
    /// Edges skipped because they sit in the branch a wasm target doesn't compile.
    gated: usize = 0,

    fn fail(self: *Guard, path: []const u8, line_no: usize, target: []const u8) void {
        std.debug.print(
            "check-wasm-allowlist: ERROR {s}:{d} imports the cluster/server graph on the wasm target ({s}).\n" ++
                "  Put it in the non-wasm branch of an `if (…wasm_target) … else …` gate, or keep it out of the wasm allowlist; see docs/wasm.md.\n",
            .{ path, line_no, target },
        );
        self.failures += 1;
    }

    fn walk(self: *Guard, start: []const u8) !void {
        try self.queue.append(self.allocator, try self.allocator.dupe(u8, start));
        while (self.queue.items.len > 0) {
            const path = self.queue.orderedRemove(0);
            if (self.seen.contains(path)) continue;
            try self.seen.put(path, {});

            const source = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, self.allocator, .limited(8 << 20)) catch |err| {
                // FAIL CLOSED: a file we can't read is a graph we can't vouch for.
                std.debug.print("check-wasm-allowlist: ERROR cannot read {s}: {s}\n", .{ path, @errorName(err) });
                self.failures += 1;
                continue;
            };
            defer self.allocator.free(source);

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |raw| {
                line_no += 1;
                const code = stripComment(raw);
                const gate = findGate(code);
                var from: usize = 0;
                while (nextImport(code, &from)) |import| {
                    if (!compiledOnWasm(gate, import.at)) {
                        self.gated += 1;
                        continue;
                    }
                    if (!isFileImport(import.target)) {
                        if (isForbiddenModule(import.target)) self.fail(path, line_no, import.target);
                        continue;
                    }
                    const resolved = try resolveRelative(self.allocator, path, import.target);
                    if (isForbiddenPath(resolved)) {
                        self.fail(path, line_no, resolved);
                        continue;
                    }
                    if (!self.seen.contains(resolved)) try self.queue.append(self.allocator, resolved);
                }
            }
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var guard = Guard{ .allocator = allocator, .seen = std.StringHashMap(void).init(allocator) };
    try guard.walk(root_file);
    if (guard.failures != 0) {
        std.debug.print("check-wasm-allowlist: {d} problem(s); the wasm import graph is not clean.\n", .{guard.failures});
        std.process.exit(1);
    }
    std.debug.print(
        "check-wasm-allowlist: walked {d} files from {s}, no cluster/server imports on the wasm target ({d} gated edges skipped).\n",
        .{ guard.seen.count(), root_file, guard.gated },
    );
}

// ── Tests: `zig test scripts/check-wasm-allowlist.zig` ───────────────────────────────────────────

fn compiledTargets(line: []const u8, buf: *[4][]const u8) [][]const u8 {
    const code = stripComment(line);
    const gate = findGate(code);
    var n: usize = 0;
    var from: usize = 0;
    while (nextImport(code, &from)) |import| {
        if (compiledOnWasm(gate, import.at)) {
            buf[n] = import.target;
            n += 1;
        }
    }
    return buf[0..n];
}

test "a real gate: the condition and the wasm branch are walked, the cluster branch is skipped" {
    var buf: [4][]const u8 = undefined;
    const got = compiledTargets("const Cluster = if (@import(\"../core/compat.zig\").wasm_target) @import(\"../core/compat.zig\").ClusterStub else @import(\"../cluster/mod.zig\").Cluster;", &buf);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    for (got) |t| try std.testing.expectEqualStrings("../core/compat.zig", t);
}

test "a comment mentioning wasm_target gates nothing" {
    var buf: [4][]const u8 = undefined;
    const got = compiledTargets("const c = @import(\"../cluster/mod.zig\"); // wasm_target", &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("../cluster/mod.zig", got[0]);
}

test "an inverted gate compiles the cluster branch on wasm, so it is checked" {
    var buf: [4][]const u8 = undefined;
    const got = compiledTargets("const C = if (@import(\"../core/compat.zig\").wasm_target) @import(\"../cluster/x.zig\") else struct {};", &buf);
    var saw_cluster = false;
    for (got) |t| saw_cluster = saw_cluster or std.mem.eql(u8, t, "../cluster/x.zig");
    try std.testing.expect(saw_cluster);
}

test "a negated condition swaps the branches" {
    var buf: [4][]const u8 = undefined;
    const got = compiledTargets("const C = if (!@import(\"../core/compat.zig\").wasm_target) @import(\"../cluster/x.zig\") else @import(\"stub.zig\");", &buf);
    var saw_cluster = false;
    var saw_stub = false;
    for (got) |t| {
        saw_cluster = saw_cluster or std.mem.eql(u8, t, "../cluster/x.zig");
        saw_stub = saw_stub or std.mem.eql(u8, t, "stub.zig");
    }
    try std.testing.expect(!saw_cluster);
    try std.testing.expect(saw_stub);
}

test "forbidden targets match on the resolved path, not the spelling" {
    const a = std.testing.allocator;
    const r1 = try resolveRelative(a, "src/procedures/x.zig", "./../cluster/node.zig");
    defer a.free(r1);
    try std.testing.expect(isForbiddenPath(r1));
    const r2 = try resolveRelative(a, "src/x.zig", "cluster/mod.zig");
    defer a.free(r2);
    try std.testing.expect(isForbiddenPath(r2));
    const r3 = try resolveRelative(a, "src/procedures/x.zig", "../server/auth.zig");
    defer a.free(r3);
    try std.testing.expect(!isForbiddenPath(r3));
    try std.testing.expect(isForbiddenModule("meshguard"));
    try std.testing.expect(!isForbiddenModule("std"));
}
