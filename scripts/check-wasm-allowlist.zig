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
//! condition and in `A` are walked and checked. Only exact supported predicates (optionally
//! negated once) select a branch. Zig's parser supplies branch spans and import tokens across
//! whitespace and newlines; strings and comments cannot impersonate code. Unknown conditions
//! inspect both branches. Unreadable files, malformed source and computed import paths fail closed.
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

/// Only these exact predicates have a known value on the wasm target. Treat
/// comparisons, compound expressions and unrelated identifiers as unknown.
fn gateNegated(condition: []const u8) ?bool {
    var predicate = std.mem.trim(u8, condition, " \t\r");
    const negated = std.mem.startsWith(u8, predicate, "!");
    if (negated) predicate = std.mem.trimStart(u8, predicate[1..], " \t\r");
    for ([_][]const u8{
        "wasm_target",
        "compat.wasm_target",
        "@import(\"../core/compat.zig\").wasm_target",
    }) |supported| {
        if (std.mem.eql(u8, predicate, supported)) return negated;
    }
    return null;
}

const Import = struct { target: []const u8, at: usize, compiled: bool };

fn nodeSource(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    return tree.source[tree.tokenStart(first) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
}

fn containsNode(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, at: usize) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    return at >= tree.tokenStart(first) and at < tree.tokenStart(last) + tree.tokenSlice(last).len;
}

/// Unknown predicates inspect both branches. AST spans match nested else
/// clauses and ignore strings/comments that happen to contain gate syntax.
fn compiledOnWasm(tree: *const std.zig.Ast, at: usize) bool {
    for (0..tree.nodes.len) |i| {
        const branch = tree.fullIf(@enumFromInt(i)) orelse continue;
        const negated = gateNegated(nodeSource(tree, branch.ast.cond_expr)) orelse continue;
        if (negated and containsNode(tree, branch.ast.then_expr, at)) return false;
        if (!negated) {
            if (branch.ast.else_expr.unwrap()) |else_expr| {
                if (containsNode(tree, else_expr, at)) return false;
            }
        }
    }
    return true;
}

/// Parse whole files so whitespace, newlines and escaped string literals cannot
/// hide imports. A computed import path cannot be resolved here and fails closed.
/// All returned storage belongs to the caller's arena.
fn readImports(allocator: std.mem.Allocator, source: []const u8) ![]Import {
    const terminated = try allocator.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(allocator, terminated, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    for (0..tree.tokens.len) |i| {
        const t: std.zig.Ast.TokenIndex = @intCast(i);
        if (tree.tokenTag(t) != .builtin or !std.mem.eql(u8, tree.tokenSlice(t), "@import")) continue;
        const at = tree.tokenStart(t);
        const compiled = compiledOnWasm(&tree, at);
        if (!compiled) {
            try imports.append(allocator, .{ .target = "", .at = at, .compiled = false });
            continue;
        }
        if (i + 3 >= tree.tokens.len or tree.tokenTag(t + 1) != .l_paren or tree.tokenTag(t + 2) != .string_literal or
            (tree.tokenTag(t + 3) != .r_paren and !(i + 4 < tree.tokens.len and tree.tokenTag(t + 3) == .comma and tree.tokenTag(t + 4) == .r_paren)))
            return error.NonLiteralImport;
        const target = try std.zig.string_literal.parseAlloc(allocator, tree.tokenSlice(t + 2));
        try imports.append(allocator, .{ .target = target, .at = at, .compiled = true });
    }
    return imports.toOwnedSlice(allocator);
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

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const imports = readImports(arena.allocator(), source) catch |err| {
                std.debug.print("check-wasm-allowlist: ERROR cannot inspect {s}: {s}\n", .{ path, @errorName(err) });
                self.failures += 1;
                continue;
            };
            for (imports) |import| {
                if (!import.compiled) {
                    self.gated += 1;
                    continue;
                }
                const line_no = 1 + std.mem.count(u8, source[0..import.at], "\n");
                if (!isFileImport(import.target)) {
                    if (isForbiddenModule(import.target)) self.fail(path, line_no, import.target);
                    continue;
                }
                const resolved = try resolveRelative(self.allocator, path, import.target);
                if (isForbiddenPath(resolved)) {
                    self.fail(path, line_no, resolved);
                    self.allocator.free(resolved);
                    continue;
                }
                if (!self.seen.contains(resolved)) {
                    try self.queue.append(self.allocator, resolved);
                } else self.allocator.free(resolved);
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

fn compiledTargets(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const imports = try readImports(allocator, source);
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    for (imports) |import| {
        if (import.compiled) try targets.append(allocator, import.target);
    }
    return targets.toOwnedSlice(allocator);
}

test "a real gate: the condition and the wasm branch are walked, the cluster branch is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try compiledTargets(arena.allocator(), "const Cluster = if (@import(\"../core/compat.zig\").wasm_target) @import(\"../core/compat.zig\").ClusterStub else @import(\"../cluster/mod.zig\").Cluster;");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    for (got) |t| try std.testing.expectEqualStrings("../core/compat.zig", t);
}

test "a comment mentioning wasm_target gates nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try compiledTargets(arena.allocator(), "const c = @import(\"../cluster/mod.zig\"); // wasm_target");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("../cluster/mod.zig", got[0]);
}

test "an inverted gate compiles the cluster branch on wasm, so it is checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try compiledTargets(arena.allocator(), "const C = if (@import(\"../core/compat.zig\").wasm_target) @import(\"../cluster/x.zig\") else struct {};");
    var saw_cluster = false;
    for (got) |t| saw_cluster = saw_cluster or std.mem.eql(u8, t, "../cluster/x.zig");
    try std.testing.expect(saw_cluster);
}

test "a negated condition swaps the branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try compiledTargets(arena.allocator(), "const C = if (!@import(\"../core/compat.zig\").wasm_target) @import(\"../cluster/x.zig\") else @import(\"stub.zig\");");
    var saw_cluster = false;
    var saw_stub = false;
    for (got) |t| {
        saw_cluster = saw_cluster or std.mem.eql(u8, t, "../cluster/x.zig");
        saw_stub = saw_stub or std.mem.eql(u8, t, "stub.zig");
    }
    try std.testing.expect(!saw_cluster);
    try std.testing.expect(saw_stub);
}

test "unsupported predicates inspect both branches" {
    const predicates = [_][]const u8{
        "compat.wasm_target == false",
        "wasm_target and false",
        "!wasm_target or true",
        "!!wasm_target",
        "not_wasm_target",
        "other.wasm_target",
        "@import(\"../core/compat.zig\").wasm_target == false",
        "@import(\"../other.zig\").wasm_target",
    };
    for (predicates) |predicate| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "const C = if ({s}) @import(\"../cluster/then.zig\") else @import(\"../cluster/else.zig\");", .{predicate});
        defer std.testing.allocator.free(line);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const got = try compiledTargets(arena.allocator(), line);
        var saw_then = false;
        var saw_else = false;
        for (got) |target| {
            saw_then = saw_then or std.mem.eql(u8, target, "../cluster/then.zig");
            saw_else = saw_else or std.mem.eql(u8, target, "../cluster/else.zig");
        }
        try std.testing.expect(saw_then and saw_else);
    }
}

test "supported named predicates retain branch selection" {
    for ([_][]const u8{ "wasm_target", "compat.wasm_target" }) |predicate| {
        for ([_]bool{ false, true }) |negated| {
            const line = try std.fmt.allocPrint(std.testing.allocator, "const C = if ( {s}{s} ) @import(\"then.zig\") else @import(\"else.zig\");", .{ if (negated) @as([]const u8, "!") else "", predicate });
            defer std.testing.allocator.free(line);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const got = try compiledTargets(arena.allocator(), line);
            try std.testing.expectEqual(@as(usize, 1), got.len);
            try std.testing.expectEqualStrings(if (negated) "else.zig" else "then.zig", got[0]);
        }
    }
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

test "nested branches cannot impersonate the outer else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "const C = if (compat.wasm_target) (if (false) struct {} else @import(\"../cluster/node.zig\")) else struct {};",
        "const C = if (wasm_target) if (false) struct {} else @import(\"../cluster/node.zig\") else struct {};",
        "const C = if (wasm_target) struct { const label = \" else \"; const c = @import(\"../cluster/node.zig\"); } else struct {};",
    }) |source| {
        const got = try compiledTargets(a, source);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("../cluster/node.zig", got[0]);
    }
}

test "imports are tokenized across formatting and escaped paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "const c = @import( \"../cluster/mod.zig\");",
        "const c = @import(\n // comment\n \"../cluster/mod.zig\"\n);",
        "const c = @import(\"../cluster/mod.zig\",);",
        "const c = @import(\"../clu\\x73ter/mod.zig\");",
    }) |source| {
        const got = try compiledTargets(arena.allocator(), source);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("../cluster/mod.zig", got[0]);
    }
}

test "multiline gates and fake code in comments and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try compiledTargets(arena.allocator(),
        \\const text = "if (wasm_target) Stub else @import(\"../cluster/fake.zig\")";
        \\// @import("../cluster/comment.zig")
        \\const c = if (wasm_target)
        \\    @import("stub.zig")
        \\else
        \\    @import("../cluster/mod.zig");
    );
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("stub.zig", got[0]);
}

test "malformed source and computed import paths fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidZigSource, readImports(a, "const c = @import(\"std\""));
    try std.testing.expectError(error.NonLiteralImport, readImports(a, "const c = @import(\"../cluster/\" ++ \"mod.zig\");"));
}
