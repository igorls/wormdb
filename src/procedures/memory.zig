//! Agent-memory procedures — in-database primitives for building AI
//! memory systems on top of WormDB.
//!
//! Each `mem_add` call atomically writes a doc, its metadata, and its
//! embedding — plus publishing an "added" event — in one EXEC round-trip.
//! Queries join vector similarity with the stored doc/metadata in-process,
//! so clients never re-fetch docs to enrich search results.
//!
//! ── Key layout ──────────────────────────────────────────────────────
//!   mem:<ns>:<id>             doc body (WORM by default)
//!   mem:<ns>:<id>:meta        metadata JSON (mutable; raw passthrough)
//!   vec:mem:<ns>:<id>         embedding (raw f32 bytes)
//!   bq:vec:mem:<ns>:<id>      BQ companion (written by applyVinsert)
//!   __meta:mem:<ns>:config    {"embedder_id":"...","metric":"...","decay_tau_hours":168,"vector_only":false,"created_at":N}
//!
//! ── Procedure surface ───────────────────────────────────────────────
//!   mem_init         <ns> <embedder_id> <metric> [<decay_tau_hours>] [vector_only=true]
//!   mem_add          <ns> <doc_id> <text> <embedding> [<meta_json>] [<worm>] [<embedder_id>]
//!   mem_add          <ns> <doc_id> <embedding> [<meta_json>] [<worm>] [<embedder_id>]  (vector_only)
//!   mem_meta_set     <ns> <doc_id> <meta_json>
//!   mem_bulk_add     <ns> <count> [<id> <embedding> <meta_json>]×N
//!   mem_get          <ns> <doc_id>
//!   mem_query        <ns> <embedding> <k> [<lambda>] [<min_score>] [<snippet_chars>] [<decay_tau_hours>] [<filter>]
//!   mem_range        <ns> <since_ms> <until_ms> [<limit>] [<filter>]
//!   mem_stats        <ns>
//!   mem_verify       <ns>
//!   mem_drop         <ns>
//!   mem_reset_index  <ns> <new_embedder_id>
//!   mem_capabilities
//!
//! ── Design notes ────────────────────────────────────────────────────
//! * Chunking lives on the client. `mem_add` indexes one chunk; clients
//!   that think in sessions call `mem_add` N times with derived ids.
//! * `mem_init` is optional/lazy: the metric defaults to cosine on first
//!   add. Calling mem_init up front lets you pre-declare for fail-fast.
//! * Embedder identity is captured in config for reporting and (when the
//!   caller passes the optional `embedder_id` arg to `mem_add`) enforced
//!   server-side: a mismatch between asserted and configured embedder
//!   rejects the call before any state changes. Same-dim model swaps —
//!   the failure mode dim-freeze can't catch — are caught here when the
//!   client asserts. Use `mem_reset_index` to switch a namespace to a
//!   new embedder; it drops vec/BQ/HNSW state but preserves doc bodies.
//! * mem_query skips the BQ prefilter — HNSW is eagerly created by
//!   mem_init, so cold-start (post-restart until vreindex) is the only
//!   HNSW-absent case, and brute-force is the simpler fallback there.
//! * mem_query filters are parsed by predicate.zig and evaluated before
//!   top-K admission, either during HNSW refine or the brute-force scan.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const predicate = @import("predicate.zig");
const vector_ops = @import("vector_ops.zig");
const distance = @import("../vector/distance.zig");
const topk_mod = @import("../vector/topk.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const metric_mod = @import("../vector/metric.zig");
const IndexModule = @import("../vector/index.zig");
const Store = @import("../storage/store.zig").Store;
const Command = @import("../core/types.zig").Command;
const auth = @import("../server/auth.zig");

const Metric = metric_mod.Metric;

// ╔═══════════════════════════════════════════════════╗
// ║  Constants                                         ║
// ╚═══════════════════════════════════════════════════╝

const MAX_NS_LEN: usize = 64;
const MAX_DOC_ID_LEN: usize = 256;
const MAX_EMBEDDER_ID_LEN: usize = 128;
const MAX_TOP_K: usize = 100;
const DEFAULT_RANGE_LIMIT: usize = 100;
const MAX_RANGE_LIMIT: usize = 10_000;
const MAX_BULK_ADD: usize = 10_000;
const DEFAULT_SNIPPET_CHARS: i64 = 512;
const DEFAULT_DECAY_TAU_HOURS: f32 = 168.0;
const HNSW_EF_SEARCH_FACTOR: usize = 10;
const MAX_VERIFY_ORPHANS: usize = 100;

// ╔═══════════════════════════════════════════════════╗
// ║  Input validation                                  ║
// ╚═══════════════════════════════════════════════════╝

/// Allow alphanumeric plus `- _ . /` — enough for model names like
/// `sentence-transformers/all-MiniLM-L6-v2` and slug-style namespace
/// names. Reject `:` so key construction can't collide with segment
/// separators. Reject controls and `"` / `\` so JSON serialization of
/// these values into config is safe without escape logic.
fn isSafeToken(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '/';
}

fn validateNs(ns: []const u8) bool {
    if (ns.len == 0 or ns.len > MAX_NS_LEN) return false;
    for (ns) |c| if (!isSafeToken(c)) return false;
    return true;
}

fn validateDocId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_DOC_ID_LEN) return false;
    for (id) |c| if (!isSafeToken(c)) return false;
    return true;
}

fn validateEmbedderId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_EMBEDDER_ID_LEN) return false;
    for (id) |c| if (!isSafeToken(c)) return false;
    return true;
}

// ╔═══════════════════════════════════════════════════╗
// ║  JSON helpers                                      ║
// ╚═══════════════════════════════════════════════════╝

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try list.appendSlice(alloc, "\\u00");
                    const hex = "0123456789abcdef";
                    try list.append(alloc, hex[c >> 4]);
                    try list.append(alloc, hex[c & 0x0f]);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
}

fn writeUsize(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(alloc, s);
}

fn writeU64(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, n: u64) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(alloc, s);
}

/// Extract a string field value from our own config JSON. Relies on the
/// format we generate: `"<field>":"<value>"` with values that passed
/// validateEmbedderId / known metric names, so no escape handling needed.
/// Returns null if the field isn't present.
fn extractConfigField(json: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start + needle.len;
    const tail = json[value_start..];
    const end = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..end];
}

fn configVectorOnly(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"vector_only\":true") != null;
}

fn extractConfigFloat(json: []const u8, field: []const u8) ?f32 {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start + needle.len;
    const tail = json[value_start..];
    var end: usize = 0;
    while (end < tail.len and tail[end] != ',' and tail[end] != '}') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, tail[0..end]) catch null;
}

fn parseDecayTauHours(raw: []const u8) ?f32 {
    const tau = std.fmt.parseFloat(f32, raw) catch return null;
    if (!std.math.isFinite(tau) or tau <= 0.0) return null;
    return tau;
}

fn extractConfigBool(json: []const u8, field: []const u8) ?bool {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var tail = json[start + needle.len ..];
    while (tail.len > 0 and (tail[0] == ' ' or tail[0] == '\t')) tail = tail[1..];
    if (std.mem.startsWith(u8, tail, "true")) return true;
    if (std.mem.startsWith(u8, tail, "false")) return false;
    return null;
}

fn parseMemInitVectorOnlyFlag(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "vector_only") or
        std.mem.eql(u8, raw, "vector_only=true") or
        std.mem.eql(u8, raw, "vector_only=1") or
        std.mem.eql(u8, raw, "true") or
        std.mem.eql(u8, raw, "1"))
    {
        return true;
    }
    if (std.mem.eql(u8, raw, "vector_only=false") or
        std.mem.eql(u8, raw, "vector_only=0") or
        std.mem.eql(u8, raw, "false") or
        std.mem.eql(u8, raw, "0"))
    {
        return false;
    }
    return null;
}

fn isVectorOnlyConfig(cfg: ?[]const u8) bool {
    return if (cfg) |bytes| extractConfigBool(bytes, "vector_only") orelse false else false;
}

// A trailing mem_query option is a filter predicate when it carries the
// `filter=` prefix; otherwise it is parsed as a bare decay_tau_hours value.
fn argLooksLikeFilter(raw: []const u8) bool {
    const pfx = "filter=";
    if (raw.len < pfx.len) return false;
    for (pfx, 0..) |c, i| {
        if (std.ascii.toLower(raw[i]) != c) return false;
    }
    return true;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Distance + decay shared with vsearch              ║
// ╚═══════════════════════════════════════════════════╝

inline fn applyDecay(raw_sim: f32, timestamp: u64, decay: f32, now_ms: u64, decay_tau_hours: f32) f32 {
    if (decay <= 0.0) return raw_sim;
    const age_ms = if (now_ms > timestamp) now_ms - timestamp else 0;
    const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
    const recency = @exp(-age_hours / decay_tau_hours);
    return (1.0 - decay) * raw_sim + decay * recency;
}

inline fn computeExactSim(metric: Metric, q: []align(1) const f32, v: []align(1) const f32) f32 {
    return switch (metric) {
        .cosine => distance.cosine(q, v),
        .dot => distance.dot(q, v),
        .l2 => blk: {
            const d = distance.l2Squared(q, v);
            break :blk 1.0 / (1.0 + d);
        },
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_capabilities                                  ║
// ╚═══════════════════════════════════════════════════╝

pub fn memCapabilities(ctx: *Ctx) anyerror!Ctx.Result {
    const json =
        \\{"name":"wormdb-agent-memory","version":"1",
        \\"retrieval_unit":"chunk",
        \\"temporal_decay":true,
        \\"bulk_add":true,
        \\"vector_only":true,
        \\"verbatim":true,
        \\"local":true,
        \\"structured_facts":false,
        \\"metadata_update":true,
        \\"health_verify":true,
        \\"metrics":["cosine","dot","l2"]}
    ;
    return ctx.value(json);
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_init                                          ║
// ╚═══════════════════════════════════════════════════╝

pub fn memInit(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse
        return ctx.err("mem_init requires: <ns> <embedder_id> <metric> [<decay_tau_hours>]");
    const embedder_id = ctx.arg(1) orelse
        return ctx.err("mem_init requires: <ns> <embedder_id> <metric> [<decay_tau_hours>]");
    const metric_str = ctx.arg(2) orelse
        return ctx.err("mem_init requires: <ns> <embedder_id> <metric> [<decay_tau_hours>]");

    if (!validateNs(ns))
        return ctx.err("mem_init: ns must be 1..64 bytes, chars in [A-Za-z0-9._/-]");
    ctx.requireNamespace(ns, .write) catch return ctx.err("permission denied");
    if (!validateEmbedderId(embedder_id))
        return ctx.err("mem_init: embedder_id must be 1..128 bytes, chars in [A-Za-z0-9._/-]");
    const metric = Metric.fromStr(metric_str) orelse
        return ctx.err("mem_init: unknown metric (cosine|dot|l2)");
    // Options after <metric> may appear in any order: a positive float sets
    // decay_tau_hours, a vector_only=true|false flag sets vector-only mode.
    var vector_only = false;
    var decay_tau_hours: f32 = DEFAULT_DECAY_TAU_HOURS;
    var decay_tau_provided = false;
    var opt_i: usize = 3;
    while (opt_i < ctx.argCount()) : (opt_i += 1) {
        const opt = ctx.arg(opt_i).?;
        if (parseMemInitVectorOnlyFlag(opt)) |v| {
            vector_only = v;
        } else if (parseDecayTauHours(opt)) |tau| {
            decay_tau_hours = tau;
            decay_tau_provided = true;
        } else {
            return ctx.err("mem_init: unknown option (expected <decay_tau_hours> or vector_only=true|false)");
        }
    }

    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);

    // ── Idempotent-if-matching check ────────────────────────────
    // The shard lock is released by setDurable's internal dance,
    // so only the read is protected here. Concurrent inits with
    // matching inputs converge to the same final config.
    const existing = try ctx.getCopy(config_key);
    if (existing) |cfg| {
        const cfg_embedder = extractConfigField(cfg, "embedder_id") orelse "";
        const cfg_metric = extractConfigField(cfg, "metric") orelse "";
        if (!std.mem.eql(u8, cfg_embedder, embedder_id))
            return ctx.err("mem_init: embedder_id differs from existing namespace config");
        if (!std.mem.eql(u8, cfg_metric, metric.name()))
            return ctx.err("mem_init: metric differs from existing namespace config");
        const cfg_vector_only = extractConfigBool(cfg, "vector_only") orelse false;
        if (cfg_vector_only != vector_only)
            return ctx.err("mem_init: vector_only differs from existing namespace config");
        if (!decay_tau_provided) return ctx.ok();
        const cfg_tau = extractConfigFloat(cfg, "decay_tau_hours") orelse DEFAULT_DECAY_TAU_HOURS;
        if (@abs(cfg_tau - decay_tau_hours) < 0.0001) return ctx.ok();
    }

    // ── Freeze the vector namespace with the declared metric ────
    // This is what makes mem_init fail-fast useful: without it, the
    // metric freezes only on the first mem_add. With it, a second
    // mem_init with a different metric errors immediately.
    if (ctx.vector_registry) |reg| {
        const vec_ns = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
        defer ctx.allocator.free(vec_ns);
        _ = reg.getOrCreate(vec_ns, metric) catch |e| {
            return ctx.err(ctx.fmt("mem_init: registry error: {s}", .{@errorName(e)}));
        };
    }

    // ── Build + persist the config JSON ─────────────────────────
    var cfg: std.ArrayListUnmanaged(u8) = .empty;
    defer cfg.deinit(ctx.allocator);
    try cfg.appendSlice(ctx.allocator, "{\"embedder_id\":\"");
    try cfg.appendSlice(ctx.allocator, embedder_id);
    try cfg.appendSlice(ctx.allocator, "\",\"metric\":\"");
    try cfg.appendSlice(ctx.allocator, metric.name());
    try cfg.appendSlice(ctx.allocator, "\",\"decay_tau_hours\":");
    var tau_buf: [32]u8 = undefined;
    const tau_str = std.fmt.bufPrint(&tau_buf, "{d}", .{decay_tau_hours}) catch "168";
    try cfg.appendSlice(ctx.allocator, tau_str);
    try cfg.appendSlice(ctx.allocator, ",\"vector_only\":");
    try cfg.appendSlice(ctx.allocator, if (vector_only) "true" else "false");
    try cfg.appendSlice(ctx.allocator, ",\"created_at\":");
    try writeU64(&cfg, ctx.allocator, ctx.timestamp());
    try cfg.append(ctx.allocator, '}');

    try ctx.setDurable(config_key, cfg.items);
    return ctx.ok();
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_add                                           ║
// ╚═══════════════════════════════════════════════════╝

pub fn memAdd(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "mem_add requires: <ns> <doc_id> <text> <embedding> [<meta_json>] [<worm>] [<embedder_id>]";
    const ns = ctx.arg(0) orelse return ctx.err(usage);
    const doc_id = ctx.arg(1) orelse return ctx.err(usage);

    if (!validateNs(ns))
        return ctx.err("mem_add: invalid ns");
    ctx.requireNamespace(ns, .write) catch return ctx.err("permission denied");
    if (!validateDocId(doc_id))
        return ctx.err("mem_add: invalid doc_id");

    // ── Pick metric from config (default cosine if no init) and
    //    optionally enforce embedder match. Read config once.
    const cfg_bytes: ?[]const u8 = blk: {
        const cfg_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
        defer ctx.allocator.free(cfg_key);
        break :blk try ctx.getCopy(cfg_key);
    };

    const metric: Metric = blk: {
        if (cfg_bytes) |cfg| {
            if (extractConfigField(cfg, "metric")) |m_str| {
                if (Metric.fromStr(m_str)) |m| break :blk m;
            }
        }
        break :blk .cosine;
    };

    const vector_only = isVectorOnlyConfig(cfg_bytes);
    const text: []const u8 = if (vector_only) "" else ctx.arg(2) orelse return ctx.err(usage);
    const embedding = if (vector_only)
        ctx.arg(2) orelse return ctx.err("mem_add vector_only requires: <ns> <doc_id> <embedding> [<meta_json>] [<worm>] [<embedder_id>]")
    else
        ctx.arg(3) orelse return ctx.err(usage);
    const meta_json: []const u8 = if (vector_only) ctx.arg(3) orelse "" else ctx.arg(4) orelse "";
    const is_worm = if (if (vector_only) ctx.arg(4) else ctx.arg(5)) |w| !std.mem.eql(u8, w, "0") else true;
    const embedder_id_arg: ?[]const u8 = if (vector_only) ctx.arg(5) else ctx.arg(6);

    if (vector_only and distance.bytesToF32(embedding) == null) {
        if (ctx.arg(3)) |maybe_embedding| {
            if (distance.bytesToF32(maybe_embedding) != null) {
                return ctx.err("mem_add: vector_only namespace uses <ns> <doc_id> <embedding> [<meta_json>] [<worm>] [<embedder_id>] (no text arg)");
            }
        }
    }

    if (embedder_id_arg) |req_emb| {
        if (!validateEmbedderId(req_emb))
            return ctx.err("mem_add: invalid embedder_id");
    }

    // Embedder enforcement: only when caller asserts an id AND the
    // namespace has an existing config. Lazy-init namespaces (no
    // config yet) accept the add — first mem_init declares the
    // embedder, and future asserted adds will be checked.
    if (embedder_id_arg) |req_emb| {
        if (cfg_bytes) |cfg| {
            if (extractConfigField(cfg, "embedder_id")) |cfg_emb| {
                if (!std.mem.eql(u8, cfg_emb, req_emb)) {
                    return ctx.err(ctx.fmt(
                        "mem_add: embedder mismatch (config={s}, requested={s})",
                        .{ cfg_emb, req_emb },
                    ));
                }
            }
        }
    }

    // ── Build derived keys ──────────────────────────────────────
    const doc_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}", .{ ns, doc_id });
    defer ctx.allocator.free(doc_key);
    const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
    defer ctx.allocator.free(meta_key);
    const vec_key = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:{s}", .{ ns, doc_id });
    defer ctx.allocator.free(vec_key);
    const vec_namespace = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_namespace);
    const channel = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:added", .{ns});
    defer ctx.allocator.free(channel);

    // ── Vector first: applyVinsert runs all pre-checks (dim +
    //    metric freeze). A failure here writes nothing; the doc
    //    and meta paths below are only reached on success. This
    //    is the correctness-over-speed ordering — under WORM the
    //    doc_key write would otherwise become a permanent orphan
    //    if the vector insert failed after it.
    vector_ops.applyVinsert(
        ctx.store,
        ctx.cluster,
        ctx.event_bus,
        ctx.vector_registry,
        ctx.allocator,
        .{
            .key = vec_key,
            .vector = embedding,
            .worm = is_worm,
            .namespace = vec_namespace,
            .metric = metric,
            .timestamp = ctx.timestamp(),
            .replicate = true,
        },
    ) catch |err| {
        return switch (err) {
            error.InvalidVectorBytes => ctx.err("mem_add: embedding must be non-empty f32 bytes (len multiple of 4)"),
            error.WormViolation => ctx.err("mem_add: doc_id already exists (WORM; drop namespace to replace)"),
            error.DimensionMismatch => ctx.err("mem_add: embedding dim does not match the namespace"),
            else => ctx.err(ctx.fmt("mem_add: vector insert failed: {s}", .{@errorName(err)})),
        };
    };

    // ── Doc body ────────────────────────────────────────────────
    if (!vector_only) {
        if (is_worm) {
            ctx.setDurableWorm(doc_key, text) catch |err| switch (err) {
                error.WormViolation => {
                    // Vector was already applied — it now has no doc body.
                    // Surface a clear message; operator can mem_drop to recover.
                    return ctx.err("mem_add: doc_id already exists (WORM) — vector written but doc body refused; consider mem_drop");
                },
                else => return ctx.err(ctx.fmt("mem_add: doc write failed: {s}", .{@errorName(err)})),
            };
        } else {
            ctx.setDurable(doc_key, text) catch |err| {
                return ctx.err(ctx.fmt("mem_add: doc write failed: {s}", .{@errorName(err)}));
            };
        }
    }

    // ── Metadata (always mutable) ───────────────────────────────
    if (meta_json.len > 0) {
        ctx.setDurable(meta_key, meta_json) catch |err| {
            return ctx.err(ctx.fmt("mem_add: meta write failed: {s}", .{@errorName(err)}));
        };
    }

    // ── Publish to namespace channel ────────────────────────────
    ctx.publish(channel, doc_id);
    return ctx.ok();
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_meta_set                                      ║
// ╚═══════════════════════════════════════════════════╝

pub fn memMetaSet(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "mem_meta_set requires: <ns> <doc_id> <meta_json>";
    const ns = ctx.arg(0) orelse return ctx.err(usage);
    const doc_id = ctx.arg(1) orelse return ctx.err(usage);
    const meta_json = ctx.arg(2) orelse return ctx.err(usage);

    if (!validateNs(ns)) return ctx.err("mem_meta_set: invalid ns");
    if (!validateDocId(doc_id)) return ctx.err("mem_meta_set: invalid doc_id");
    ctx.requireNamespace(ns, .write) catch return ctx.err("permission denied");

    const doc_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}", .{ ns, doc_id });
    defer ctx.allocator.free(doc_key);
    const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
    defer ctx.allocator.free(meta_key);

    if ((try ctx.getCopy(doc_key)) == null) {
        return ctx.err("mem_meta_set: doc_id not found");
    }

    ctx.setDurable(meta_key, meta_json) catch |err| {
        return ctx.err(ctx.fmt("mem_meta_set: meta write failed: {s}", .{@errorName(err)}));
    };
    return ctx.ok();
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_bulk_add                                      ║
// ╚═══════════════════════════════════════════════════╝

const BulkMetaWrite = struct {
    key: []const u8,
    value: []const u8,
};

pub fn memBulkAdd(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "mem_bulk_add requires: <ns> <count> [<id> <embedding> <meta_json>]×N";
    const ns = ctx.arg(0) orelse return ctx.err(usage);
    const count = ctx.argInt(usize, 1) orelse return ctx.err("mem_bulk_add: count must be an integer");

    if (!validateNs(ns)) return ctx.err("mem_bulk_add: invalid ns");
    ctx.requireNamespace(ns, .write) catch return ctx.err("permission denied");
    if (count > MAX_BULK_ADD)
        return ctx.err(ctx.fmt("mem_bulk_add: count must be <= {d}", .{MAX_BULK_ADD}));

    const expected_args = 2 + count * 3;
    if (ctx.argCount() != expected_args)
        return ctx.err(usage);
    if (count == 0) return ctx.ok();

    const cfg_bytes: ?[]const u8 = blk: {
        const cfg_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
        defer ctx.allocator.free(cfg_key);
        break :blk try ctx.getCopy(cfg_key);
    };

    const metric: Metric = blk: {
        if (cfg_bytes) |cfg| {
            if (extractConfigField(cfg, "metric")) |m_str| {
                if (Metric.fromStr(m_str)) |m| break :blk m;
            }
        }
        break :blk .cosine;
    };

    const vec_namespace = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_namespace);
    const channel = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:added.bulk", .{ns});
    defer ctx.allocator.free(channel);

    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_namespace)) |ns_idx| {
            if (ns_idx.metric != metric)
                return ctx.err("mem_bulk_add: metric differs from existing vector namespace");
        }
    }

    const items = try ctx.allocator.alloc(Command.VbulkinsertParams.BulkItem, count);
    const metas = try ctx.allocator.alloc(BulkMetaWrite, count);
    const ids = try ctx.allocator.alloc([]const u8, count);

    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer seen.deinit();

    var expected_dim: ?usize = null;
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_namespace)) |ns_idx| {
            expected_dim = ns_idx.expectedDim();
        }
    }

    var batch_dim: ?usize = null;
    const now_ms = ctx.timestamp();

    for (0..count) |i| {
        const base = 2 + i * 3;
        const doc_id = ctx.arg(base).?;
        const embedding = ctx.arg(base + 1).?;
        const meta_json = ctx.arg(base + 2).?;

        if (!validateDocId(doc_id))
            return ctx.err("mem_bulk_add: invalid doc_id");
        const seen_gop = try seen.getOrPut(doc_id);
        if (seen_gop.found_existing)
            return ctx.err("mem_bulk_add: duplicate doc_id in batch");

        const vec = distance.bytesToF32(embedding) orelse
            return ctx.err("mem_bulk_add: embedding must be non-empty f32 bytes (len multiple of 4)");
        if (batch_dim) |d| {
            if (vec.len != d) return ctx.err("mem_bulk_add: all embeddings in a batch must have the same dimension");
        } else {
            batch_dim = vec.len;
        }
        if (expected_dim) |d| {
            if (vec.len != d) return ctx.err("mem_bulk_add: embedding dim does not match the namespace");
        }

        const vec_key = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:{s}", .{ ns, doc_id });
        const bq_key = try std.fmt.allocPrint(ctx.allocator, "bq:vec:mem:{s}:{s}", .{ ns, doc_id });
        defer ctx.allocator.free(bq_key);
        if ((try ctx.getCopy(vec_key)) != null or (try ctx.getCopy(bq_key)) != null)
            return ctx.err("mem_bulk_add: doc_id already has vector state");

        const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
        items[i] = .{ .key = vec_key, .vector = embedding, .timestamp = now_ms };
        metas[i] = .{ .key = meta_key, .value = meta_json };
        ids[i] = doc_id;
    }

    vector_ops.applyVbulkinsert(
        ctx.store,
        ctx.cluster,
        ctx.event_bus,
        ctx.vector_registry,
        ctx.allocator,
        vec_namespace,
        metric,
        true,
        false,
        items,
        true,
    ) catch |err| {
        return switch (err) {
            error.KeyMissingNamespace => ctx.err("mem_bulk_add: internal vector key outside namespace"),
        };
    };

    for (metas) |m| {
        if (m.value.len > 0) {
            ctx.setDurable(m.key, m.value) catch |err| {
                return ctx.err(ctx.fmt("mem_bulk_add: meta write failed: {s}", .{@errorName(err)}));
            };
        }
    }

    var event_json: std.ArrayListUnmanaged(u8) = .empty;
    defer event_json.deinit(ctx.allocator);
    try event_json.append(ctx.allocator, '[');
    for (ids, 0..) |id, i| {
        if (i > 0) try event_json.append(ctx.allocator, ',');
        try event_json.append(ctx.allocator, '"');
        try appendJsonEscaped(&event_json, ctx.allocator, id);
        try event_json.append(ctx.allocator, '"');
    }
    try event_json.append(ctx.allocator, ']');
    ctx.publish(channel, event_json.items);

    return ctx.ok();
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_get                                           ║
// ╚═══════════════════════════════════════════════════╝

pub fn memGet(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse return ctx.err("mem_get requires: <ns> <doc_id>");
    const doc_id = ctx.arg(1) orelse return ctx.err("mem_get requires: <ns> <doc_id>");

    if (!validateNs(ns)) return ctx.err("mem_get: invalid ns");
    ctx.requireNamespace(ns, .read) catch return ctx.err("permission denied");
    if (!validateDocId(doc_id)) return ctx.err("mem_get: invalid doc_id");

    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);
    const cfg_bytes = try ctx.getCopy(config_key);
    if (isVectorOnlyConfig(cfg_bytes)) {
        return ctx.err("mem_get: namespace is vector_only");
    }

    const doc_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}", .{ ns, doc_id });
    defer ctx.allocator.free(doc_key);
    const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
    defer ctx.allocator.free(meta_key);

    // Acquire both shards in deterministic order; read atomically.
    ctx.lockKeys2(doc_key, meta_key);
    const doc_slice = ctx.get(doc_key) orelse return ctx.err("mem_get: doc_id not found");
    const doc_copy = try ctx.allocator.dupe(u8, doc_slice);
    const ts = ctx.getTimestamp(doc_key) orelse 0;
    const meta_slice = ctx.get(meta_key);
    const meta_copy: ?[]u8 = if (meta_slice) |m| try ctx.allocator.dupe(u8, m) else null;

    // Build JSON. meta is inserted raw — it was stored as-is from the
    // client, and re-escaping would double-encode. Garbage in, garbage out.
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"id\":\"");
    try appendJsonEscaped(&json, ctx.allocator, doc_id);
    try json.appendSlice(ctx.allocator, "\",\"text\":\"");
    try appendJsonEscaped(&json, ctx.allocator, doc_copy);
    try json.appendSlice(ctx.allocator, "\",\"meta\":");
    if (meta_copy) |m| {
        try json.appendSlice(ctx.allocator, m);
    } else {
        try json.appendSlice(ctx.allocator, "null");
    }
    try json.appendSlice(ctx.allocator, ",\"ts\":");
    try writeU64(&json, ctx.allocator, ts);
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_query                                         ║
// ╚═══════════════════════════════════════════════════╝

const QueryCandidate = struct {
    key: []const u8, // arena-owned — `vec:mem:<ns>:<id>`
    score: f32,
    timestamp: u64,
};

fn candidateScore(c: QueryCandidate) f32 {
    return c.score;
}

const TopKCandidate = topk_mod.TopK(QueryCandidate, candidateScore);

const BruteScanCtx = struct {
    query_vec: []align(1) const f32,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
};

fn docIdFromVecKey(vec_key: []const u8, vec_prefix: []const u8) ?[]const u8 {
    if (vec_key.len <= vec_prefix.len) return null;
    if (!std.mem.startsWith(u8, vec_key, vec_prefix)) return null;
    return vec_key[vec_prefix.len..];
}

fn candidateMatchesFilter(
    ctx: *Ctx,
    pred: ?*const predicate.Predicate,
    ns: []const u8,
    vec_prefix: []const u8,
    vec_key: []const u8,
    timestamp: u64,
) !bool {
    const p = pred orelse return true;
    const doc_id = docIdFromVecKey(vec_key, vec_prefix) orelse return false;
    const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
    defer ctx.allocator.free(meta_key);
    const meta_bytes = try ctx.getCopy(meta_key);
    return p.matches(meta_bytes, timestamp);
}

fn onBruteMatch(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *BruteScanCtx = @ptrCast(@alignCast(raw_ctx));
    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != sc.query_vec.len) return .cont;

    const raw_sim = computeExactSim(sc.metric, sc.query_vec, vec);
    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

    if (score <= sc.heap.thresholdScore()) return .cont;

    const key_copy = sc.allocator.dupe(u8, key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

/// HNSW dispatch mirrors vsearch.zig's `runHnswDispatch`. Kept as a
/// private helper here to avoid a shared dependency cycle; if mem_query
/// and vsearch grow together, the next refactor is a `vector/search.zig`
/// module that both call into.
fn runHnswDispatch(
    ctx: *Ctx,
    ns: []const u8,
    ns_idx: *IndexModule.NamespaceIndex,
    query_vec: []align(1) const f32,
    top_k: usize,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    filter: ?*const predicate.Predicate,
    heap: *TopKCandidate,
) !bool {
    const stage1_size = top_k * HNSW_EF_SEARCH_FACTOR;
    const raw_buf = try ctx.allocator.alloc(IndexModule.IndexSearchResult, stage1_size);
    const hnsw_scratch = try ctx.allocator.alloc(hnsw_mod.SearchResult, stage1_size);
    const ef = stage1_size;

    const n_stage1 = blk: {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();
        if (ns_idx.len() == 0) break :blk @as(usize, 0);
        break :blk try ns_idx.searchLocked(query_vec, stage1_size, ef, raw_buf, hnsw_scratch);
    };

    if (n_stage1 == 0) return false;

    const vec_prefix = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_prefix);

    const stage1_keys = try ctx.allocator.alloc([]u8, n_stage1);
    const stage1_ts = try ctx.allocator.alloc(u64, n_stage1);
    {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();
        for (raw_buf[0..n_stage1], 0..) |r, i| {
            stage1_keys[i] = try ctx.allocator.dupe(u8, r.key);
            stage1_ts[i] = r.timestamp;
        }
    }

    for (0..n_stage1) |i| {
        if (!try candidateMatchesFilter(ctx, filter, ns, vec_prefix, stage1_keys[i], stage1_ts[i])) continue;

        const vec_bytes = (try ctx.getCopy(stage1_keys[i])) orelse continue;
        const vec = distance.bytesToF32(vec_bytes) orelse continue;
        if (vec.len != query_vec.len) continue;

        const raw_sim = computeExactSim(metric, query_vec, vec);
        const score = applyDecay(raw_sim, stage1_ts[i], decay, now_ms, decay_tau_hours);
        heap.push(.{ .key = stage1_keys[i], .score = score, .timestamp = stage1_ts[i] });
    }

    return true;
}

fn runFilteredBruteScan(
    ctx: *Ctx,
    ns: []const u8,
    vec_namespace: []const u8,
    query_vec: []align(1) const f32,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    filter: *const predicate.Predicate,
    heap: *TopKCandidate,
) !void {
    const results = try ctx.scan(vec_namespace, 0);
    for (results) |r| {
        const vec = distance.bytesToF32(r.value) orelse continue;
        if (vec.len != query_vec.len) continue;
        if (!try candidateMatchesFilter(ctx, filter, ns, vec_namespace, r.key, r.timestamp)) continue;

        const raw_sim = computeExactSim(metric, query_vec, vec);
        const score = applyDecay(raw_sim, r.timestamp, decay, now_ms, decay_tau_hours);
        if (score <= heap.thresholdScore()) continue;
        heap.push(.{ .key = r.key, .score = score, .timestamp = r.timestamp });
    }
}

pub fn memQuery(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse
        return ctx.err("mem_query requires: <ns> <embedding> <k> [<lambda>] [<min_score>] [<snippet_chars>] [<decay_tau_hours>]");
    const embedding = ctx.arg(1) orelse
        return ctx.err("mem_query requires: <ns> <embedding> <k> [<lambda>] [<min_score>] [<snippet_chars>] [<decay_tau_hours>]");
    const top_k_raw = ctx.argInt(usize, 2) orelse
        return ctx.err("mem_query: k must be a positive integer");

    if (!validateNs(ns)) return ctx.err("mem_query: invalid ns");
    ctx.requireNamespace(ns, .read) catch return ctx.err("permission denied");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, MAX_TOP_K);

    var decay: f32 = 0.0;
    if (ctx.arg(3)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    var min_score: f32 = -std.math.inf(f32);
    if (ctx.arg(4)) |m| {
        min_score = std.fmt.parseFloat(f32, m) catch -std.math.inf(f32);
    }

    // snippet_chars: positive = cap; 0 = full text; negative = omit doc.
    var snippet_chars: i64 = DEFAULT_SNIPPET_CHARS;
    if (ctx.arg(5)) |s| {
        snippet_chars = std.fmt.parseInt(i64, s, 10) catch DEFAULT_SNIPPET_CHARS;
    }

    // Trailing options (args 6 and 7), in any order: a `filter=...` predicate
    // and/or a bare decay_tau_hours value. The `filter=` prefix disambiguates.
    var parsed_filter: ?predicate.Predicate = null;
    defer if (parsed_filter) |*p| p.deinit();
    var decay_tau_override: ?f32 = null;
    {
        var opt_i: usize = 6;
        while (opt_i <= 7) : (opt_i += 1) {
            const raw = ctx.arg(opt_i) orelse continue;
            if (raw.len == 0) continue;
            if (argLooksLikeFilter(raw)) {
                if (parsed_filter != null) return ctx.err("mem_query: filter specified more than once");
                parsed_filter = predicate.parse(ctx.allocator, raw) catch
                    return ctx.err("mem_query: invalid filter predicate");
            } else {
                decay_tau_override = parseDecayTauHours(raw) orelse
                    return ctx.err("mem_query: decay_tau_hours must be positive");
            }
        }
    }
    const filter_ptr: ?*const predicate.Predicate = if (parsed_filter) |*p| p else null;

    const query_vec = distance.bytesToF32(embedding) orelse
        return ctx.err("mem_query: embedding must be non-empty f32 bytes (len multiple of 4)");

    const cfg_bytes: ?[]const u8 = blk: {
        const cfg_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
        defer ctx.allocator.free(cfg_key);
        break :blk try ctx.getCopy(cfg_key);
    };

    // Resolve metric: config metric wins; default cosine.
    const metric: Metric = blk: {
        const cfg = cfg_bytes orelse break :blk .cosine;
        const m_str = extractConfigField(cfg, "metric") orelse break :blk .cosine;
        break :blk Metric.fromStr(m_str) orelse .cosine;
    };
    const vector_only = isVectorOnlyConfig(cfg_bytes);

    const configured_decay_tau_hours: f32 = blk: {
        const cfg = cfg_bytes orelse break :blk DEFAULT_DECAY_TAU_HOURS;
        break :blk extractConfigFloat(cfg, "decay_tau_hours") orelse DEFAULT_DECAY_TAU_HOURS;
    };
    const decay_tau_hours = decay_tau_override orelse configured_decay_tau_hours;

    const vec_namespace = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_namespace);

    const final_buf = try ctx.allocator.alloc(QueryCandidate, top_k);
    var final_heap = TopKCandidate.init(final_buf);

    const now_ms = ctx.timestamp();

    // ── Stage 1: HNSW if available ──────────────────────────────
    var used_hnsw = false;
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_namespace)) |ns_idx| {
            if (ns_idx.metric == metric and ns_idx.len() > 0) {
                used_hnsw = try runHnswDispatch(
                    ctx,
                    ns,
                    ns_idx,
                    query_vec,
                    top_k,
                    metric,
                    decay,
                    decay_tau_hours,
                    now_ms,
                    filter_ptr,
                    &final_heap,
                );
            }
        }
    }

    // ── Fallback: brute-force prefix scan ───────────────────────
    // Triggered on cold-start (post-restart before vreindex) or when
    // no index has ever been created for this namespace.
    if (!used_hnsw) {
        if (filter_ptr) |filter| {
            try runFilteredBruteScan(ctx, ns, vec_namespace, query_vec, metric, decay, decay_tau_hours, now_ms, filter, &final_heap);
        } else {
            var brute_sc = BruteScanCtx{
                .query_vec = query_vec,
                .metric = metric,
                .decay = decay,
                .decay_tau_hours = decay_tau_hours,
                .now_ms = now_ms,
                .heap = &final_heap,
                .allocator = ctx.allocator,
                .oom = false,
            };
            ctx.scanCallback(vec_namespace, @ptrCast(&brute_sc), onBruteMatch);
            if (brute_sc.oom) return ctx.err("mem_query: out of memory during brute-force scan");
        }
    }

    // ── Enrich results with doc + meta lookups ──────────────────
    const ns_prefix = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(ns_prefix);

    const results = final_heap.sortedDesc();

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.append(ctx.allocator, '[');

    var emitted: usize = 0;
    for (results) |r| {
        if (r.score < min_score) continue;

        // Strip "vec:mem:<ns>:" prefix to recover the doc_id.
        if (r.key.len <= ns_prefix.len) continue;
        if (!std.mem.startsWith(u8, r.key, ns_prefix)) continue;
        const doc_id = r.key[ns_prefix.len..];

        const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, doc_id });
        defer ctx.allocator.free(meta_key);

        const meta_bytes = try ctx.getCopy(meta_key);

        if (emitted > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"id\":\"");
        try appendJsonEscaped(&json, ctx.allocator, doc_id);
        try json.appendSlice(ctx.allocator, "\",\"score\":");
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score}) catch "0";
        try json.appendSlice(ctx.allocator, score_str);
        try json.appendSlice(ctx.allocator, ",\"ts\":");
        try writeU64(&json, ctx.allocator, r.timestamp);

        // Doc text (subject to snippet_chars).
        if (!vector_only and snippet_chars >= 0) {
            const doc_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}", .{ ns, doc_id });
            defer ctx.allocator.free(doc_key);
            const doc_bytes = try ctx.getCopy(doc_key); // may be null if vec was orphaned

            try json.appendSlice(ctx.allocator, ",\"doc\":");
            if (doc_bytes) |d| {
                try json.append(ctx.allocator, '"');
                const max_len: usize = if (snippet_chars == 0) d.len else @min(d.len, @as(usize, @intCast(snippet_chars)));
                try appendJsonEscaped(&json, ctx.allocator, d[0..max_len]);
                try json.append(ctx.allocator, '"');
            } else {
                try json.appendSlice(ctx.allocator, "null");
            }
        }

        // Metadata — passthrough raw JSON (client-supplied).
        try json.appendSlice(ctx.allocator, ",\"meta\":");
        if (meta_bytes) |m| {
            try json.appendSlice(ctx.allocator, m);
        } else {
            try json.appendSlice(ctx.allocator, "null");
        }

        try json.append(ctx.allocator, '}');
        emitted += 1;
    }
    try json.append(ctx.allocator, ']');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_range                                         ║
// ╚═══════════════════════════════════════════════════╝

const RangeItem = struct {
    id: []u8,
    timestamp: u64,
};

const RangeScanCtx = struct {
    prefix_len: usize,
    since_ms: u64,
    until_ms: u64,
    items: std.ArrayListUnmanaged(RangeItem),
    allocator: std.mem.Allocator,
    oom: bool,
};

fn rangeItemLessThan(_: void, a: RangeItem, b: RangeItem) bool {
    if (a.timestamp == b.timestamp) return std.mem.lessThan(u8, a.id, b.id);
    return a.timestamp < b.timestamp;
}

fn onRangeDoc(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = value;
    _ = is_worm;
    const sc: *RangeScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (timestamp < sc.since_ms or timestamp > sc.until_ms) return .cont;
    if (key.len <= sc.prefix_len) return .cont;

    const id = key[sc.prefix_len..];
    // `mem:<ns>:` also contains metadata keys (`<id>:meta`). Stored memory
    // doc ids cannot contain ':', so any colon-bearing suffix is not a doc.
    if (std.mem.indexOfScalar(u8, id, ':') != null) return .cont;

    const id_copy = sc.allocator.dupe(u8, id) catch {
        sc.oom = true;
        return .stop;
    };
    sc.items.append(sc.allocator, .{ .id = id_copy, .timestamp = timestamp }) catch {
        sc.allocator.free(id_copy);
        sc.oom = true;
        return .stop;
    };
    return .cont;
}

pub fn memRange(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "mem_range requires: <ns> <since_ms> <until_ms> [<limit>] [<filter>]";
    const ns = ctx.arg(0) orelse return ctx.err(usage);
    const since_ms = ctx.argInt(u64, 1) orelse return ctx.err("mem_range: since_ms must be an integer");
    const until_ms = ctx.argInt(u64, 2) orelse return ctx.err("mem_range: until_ms must be an integer");

    if (!validateNs(ns)) return ctx.err("mem_range: invalid ns");
    ctx.requireNamespace(ns, .read) catch return ctx.err("permission denied");
    if (since_ms > until_ms) return ctx.err("mem_range: since_ms must be <= until_ms");

    var limit: usize = DEFAULT_RANGE_LIMIT;
    if (ctx.arg(3)) |raw_limit| {
        limit = std.fmt.parseInt(usize, raw_limit, 10) catch
            return ctx.err("mem_range: limit must be a non-negative integer");
        if (limit > MAX_RANGE_LIMIT) {
            return ctx.err(ctx.fmt("mem_range: limit must be <= {d}", .{MAX_RANGE_LIMIT}));
        }
    }

    var parsed_filter: ?predicate.Predicate = null;
    defer if (parsed_filter) |*p| p.deinit();
    const filter: ?*const predicate.Predicate = if (ctx.arg(4)) |raw| blk: {
        parsed_filter = predicate.parse(ctx.allocator, raw) catch
            return ctx.err("mem_range: invalid filter predicate");
        break :blk &parsed_filter.?;
    } else null;

    const doc_prefix = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:", .{ns});
    defer ctx.allocator.free(doc_prefix);

    var scan_ctx = RangeScanCtx{
        .prefix_len = doc_prefix.len,
        .since_ms = since_ms,
        .until_ms = until_ms,
        .items = .empty,
        .allocator = ctx.allocator,
        .oom = false,
    };
    defer {
        for (scan_ctx.items.items) |item| scan_ctx.allocator.free(item.id);
        scan_ctx.items.deinit(scan_ctx.allocator);
    }

    ctx.scanCallback(doc_prefix, @ptrCast(&scan_ctx), onRangeDoc);
    if (scan_ctx.oom) return ctx.err("mem_range: out of memory during scan");

    std.sort.heap(RangeItem, scan_ctx.items.items, {}, rangeItemLessThan);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.append(ctx.allocator, '[');

    var emitted: usize = 0;
    for (scan_ctx.items.items) |item| {
        if (limit > 0 and emitted >= limit) break;
        const meta_key = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:{s}:meta", .{ ns, item.id });
        defer ctx.allocator.free(meta_key);
        const meta = try ctx.getCopy(meta_key);
        if (filter) |pred| {
            if (!pred.matches(meta, item.timestamp)) continue;
        }

        if (emitted > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"id\":\"");
        try appendJsonEscaped(&json, ctx.allocator, item.id);
        try json.appendSlice(ctx.allocator, "\",\"ts\":");
        try writeU64(&json, ctx.allocator, item.timestamp);
        try json.appendSlice(ctx.allocator, ",\"meta\":");

        if (meta) |bytes| {
            try json.appendSlice(ctx.allocator, bytes);
        } else {
            try json.appendSlice(ctx.allocator, "null");
        }

        try json.append(ctx.allocator, '}');
        emitted += 1;
    }
    try json.append(ctx.allocator, ']');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_stats                                         ║
// ╚═══════════════════════════════════════════════════╝

pub fn memStats(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse return ctx.err("mem_stats requires: <ns>");
    if (!validateNs(ns)) return ctx.err("mem_stats: invalid ns");
    ctx.requireNamespace(ns, .read) catch return ctx.err("permission denied");

    const vec_namespace = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_namespace);
    const doc_prefix = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:", .{ns});
    defer ctx.allocator.free(doc_prefix);
    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);

    // Counts: `mem:<ns>:` covers both docs and :meta entries, so divide
    // by two on average. Simpler to report the raw prefix count and let
    // the client interpret — call it `doc_keys`.
    const doc_keys = ctx.countKeys(doc_prefix);
    const vec_count = ctx.countKeys(vec_namespace);

    const config_bytes = try ctx.getCopy(config_key);

    // Dimension — derive from first vec (matches vstats).
    var dimensions: usize = 0;
    const first_vec = try ctx.scan(vec_namespace, 1);
    if (first_vec.len > 0) {
        if (distance.bytesToF32(first_vec[0].value)) |vec| {
            dimensions = vec.len;
        }
    }

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try appendJsonEscaped(&json, ctx.allocator, ns);
    try json.appendSlice(ctx.allocator, "\",\"vectors\":");
    try writeUsize(&json, ctx.allocator, vec_count);
    try json.appendSlice(ctx.allocator, ",\"doc_keys\":");
    try writeUsize(&json, ctx.allocator, doc_keys);
    try json.appendSlice(ctx.allocator, ",\"dimensions\":");
    try writeUsize(&json, ctx.allocator, dimensions);

    try json.appendSlice(ctx.allocator, ",\"config\":");
    if (config_bytes) |cfg| {
        try json.appendSlice(ctx.allocator, cfg);
    } else {
        try json.appendSlice(ctx.allocator, "null");
    }

    // HNSW block.
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_namespace)) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();

            try json.appendSlice(ctx.allocator, ",\"hnsw\":{\"metric\":\"");
            try json.appendSlice(ctx.allocator, ns_idx.metric.name());
            try json.appendSlice(ctx.allocator, "\",\"nodes\":");
            try writeUsize(&json, ctx.allocator, ns_idx.len());
            try json.appendSlice(ctx.allocator, ",\"live\":");
            try writeUsize(&json, ctx.allocator, ns_idx.liveCount());
            try json.appendSlice(ctx.allocator, ",\"tombstones\":");
            try writeUsize(&json, ctx.allocator, ns_idx.tombstone_count);
            try json.append(ctx.allocator, '}');
        }
    }

    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_verify                                        ║
// ╚═══════════════════════════════════════════════════╝

const VerifyKind = enum { doc, vector, bq };

const VerifyIdSet = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(void),
    count: usize = 0,

    fn init(allocator: std.mem.Allocator) VerifyIdSet {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *VerifyIdSet) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.deinit();
    }

    fn add(self: *VerifyIdSet, id: []const u8) !void {
        if (self.map.contains(id)) return;
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        try self.map.put(id_copy, {});
        self.count += 1;
    }

    fn has(self: *const VerifyIdSet, id: []const u8) bool {
        return self.map.contains(id);
    }
};

const VerifyCollectCtx = struct {
    prefix: []const u8,
    kind: VerifyKind,
    ids: *VerifyIdSet,
    oom: bool = false,
};

fn collectVerifyId(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = value;
    _ = timestamp;
    _ = is_worm;

    const vc: *VerifyCollectCtx = @ptrCast(@alignCast(raw_ctx));
    if (key.len < vc.prefix.len) return .cont;
    const id = key[vc.prefix.len..];

    // `mem:<ns>:` includes both docs and metadata sidecars. Doc IDs cannot
    // contain `:`, so a `:meta` suffix is the metadata key, not a document.
    if (vc.kind == .doc and std.mem.endsWith(u8, id, ":meta")) return .cont;

    vc.ids.add(id) catch {
        vc.oom = true;
        return .stop;
    };
    return .cont;
}

fn appendDiffArray(
    json: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    source: *const VerifyIdSet,
    missing_from: *const VerifyIdSet,
    limit: usize,
) !bool {
    var emitted: usize = 0;
    var truncated = false;
    try json.append(allocator, '[');
    var it = source.map.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (missing_from.has(id)) continue;
        if (emitted == limit) {
            truncated = true;
            continue;
        }
        if (emitted > 0) try json.append(allocator, ',');
        try json.append(allocator, '"');
        try appendJsonEscaped(json, allocator, id);
        try json.append(allocator, '"');
        emitted += 1;
    }
    try json.append(allocator, ']');
    return truncated;
}

fn collectVerifySet(ctx: *Ctx, prefix: []const u8, kind: VerifyKind, ids: *VerifyIdSet) !void {
    var collector = VerifyCollectCtx{
        .prefix = prefix,
        .kind = kind,
        .ids = ids,
    };
    ctx.scanCallback(prefix, @ptrCast(&collector), collectVerifyId);
    if (collector.oom) return error.OutOfMemory;
}

pub fn memVerify(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse return ctx.err("mem_verify requires: <ns>");
    if (!validateNs(ns)) return ctx.err("mem_verify: invalid ns");
    ctx.requireNamespace(ns, .read) catch return ctx.err("permission denied");

    const doc_prefix = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:", .{ns});
    defer ctx.allocator.free(doc_prefix);
    const vec_prefix = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_prefix);
    const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "bq:vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(bq_prefix);
    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);

    var doc_ids = VerifyIdSet.init(ctx.allocator);
    defer doc_ids.deinit();
    var vec_ids = VerifyIdSet.init(ctx.allocator);
    defer vec_ids.deinit();
    var bq_ids = VerifyIdSet.init(ctx.allocator);
    defer bq_ids.deinit();

    collectVerifySet(ctx, doc_prefix, .doc, &doc_ids) catch {
        return ctx.err("mem_verify: out of memory collecting doc ids");
    };
    collectVerifySet(ctx, vec_prefix, .vector, &vec_ids) catch {
        return ctx.err("mem_verify: out of memory collecting vector ids");
    };
    collectVerifySet(ctx, bq_prefix, .bq, &bq_ids) catch {
        return ctx.err("mem_verify: out of memory collecting bq ids");
    };

    const config_bytes = try ctx.getCopy(config_key);
    const vector_only = if (config_bytes) |cfg| configVectorOnly(cfg) else false;

    var hnsw_node_count: usize = 0;
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_prefix)) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            hnsw_node_count = ns_idx.len();
        }
    }

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try appendJsonEscaped(&json, ctx.allocator, ns);
    try json.appendSlice(ctx.allocator, "\",\"doc_count\":");
    try writeUsize(&json, ctx.allocator, doc_ids.count);
    try json.appendSlice(ctx.allocator, ",\"vector_count\":");
    try writeUsize(&json, ctx.allocator, vec_ids.count);
    try json.appendSlice(ctx.allocator, ",\"bq_count\":");
    try writeUsize(&json, ctx.allocator, bq_ids.count);
    try json.appendSlice(ctx.allocator, ",\"hnsw_node_count\":");
    try writeUsize(&json, ctx.allocator, hnsw_node_count);
    try json.appendSlice(ctx.allocator, ",\"orphan_limit\":");
    try writeUsize(&json, ctx.allocator, MAX_VERIFY_ORPHANS);

    try json.appendSlice(ctx.allocator, ",\"orphan_vectors\":");
    const orphan_vectors_truncated = try appendDiffArray(&json, ctx.allocator, &vec_ids, &doc_ids, MAX_VERIFY_ORPHANS);

    try json.appendSlice(ctx.allocator, ",\"orphan_docs\":");
    const orphan_docs_truncated = if (vector_only) blk: {
        try json.appendSlice(ctx.allocator, "[]");
        break :blk false;
    } else try appendDiffArray(&json, ctx.allocator, &doc_ids, &vec_ids, MAX_VERIFY_ORPHANS);

    try json.appendSlice(ctx.allocator, ",\"missing_bq\":");
    const missing_bq_truncated = try appendDiffArray(&json, ctx.allocator, &vec_ids, &bq_ids, MAX_VERIFY_ORPHANS);

    try json.appendSlice(ctx.allocator, ",\"orphan_vectors_truncated\":");
    try json.appendSlice(ctx.allocator, if (orphan_vectors_truncated) "true" else "false");
    try json.appendSlice(ctx.allocator, ",\"orphan_docs_truncated\":");
    try json.appendSlice(ctx.allocator, if (orphan_docs_truncated) "true" else "false");
    try json.appendSlice(ctx.allocator, ",\"missing_bq_truncated\":");
    try json.appendSlice(ctx.allocator, if (missing_bq_truncated) "true" else "false");
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_drop                                          ║
// ╚═══════════════════════════════════════════════════╝

const DropCtx = struct {
    keys: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,
    oom: bool,
};

fn collectDropKey(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = value;
    _ = timestamp;
    _ = is_worm;
    const sc: *DropCtx = @ptrCast(@alignCast(raw_ctx));
    const k = sc.allocator.dupe(u8, key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.keys.append(sc.allocator, k) catch {
        sc.allocator.free(k);
        sc.oom = true;
        return .stop;
    };
    return .cont;
}

pub fn memDrop(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse return ctx.err("mem_drop requires: <ns>");
    if (!validateNs(ns)) return ctx.err("mem_drop: invalid ns");
    ctx.requireNamespace(ns, .delete) catch return ctx.err("permission denied");

    const mem_prefix = try std.fmt.allocPrint(ctx.allocator, "mem:{s}:", .{ns});
    defer ctx.allocator.free(mem_prefix);
    const vec_prefix = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_prefix);
    const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "bq:vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(bq_prefix);
    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);

    // ── Drop the HNSW index ─────────────────────────────────────
    var index_dropped = false;
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_prefix) != null) {
            reg.remove(vec_prefix);
            index_dropped = true;
        }
    }

    // ── Collect + delete under each prefix ──────────────────────
    var total_deleted: usize = 0;
    var skipped_worm: usize = 0;
    var errors: usize = 0;

    const prefixes = [_][]const u8{ mem_prefix, vec_prefix, bq_prefix };
    for (prefixes) |prefix| {
        var collector = DropCtx{
            .keys = .empty,
            .allocator = ctx.allocator,
            .oom = false,
        };
        defer {
            for (collector.keys.items) |k| collector.allocator.free(k);
            collector.keys.deinit(collector.allocator);
        }
        ctx.scanCallback(prefix, @ptrCast(&collector), collectDropKey);
        if (collector.oom) return ctx.err("mem_drop: out of memory collecting keys");

        for (collector.keys.items) |k| {
            ctx.deleteDurable(k) catch |e| switch (e) {
                error.WormViolation => skipped_worm += 1,
                else => errors += 1,
            };
        }
        total_deleted += collector.keys.items.len - skipped_worm - errors;
    }

    // ── Config key (store.delete is idempotent for missing keys) ──
    ctx.deleteDurable(config_key) catch |e| switch (e) {
        error.WormViolation => skipped_worm += 1,
        else => errors += 1,
    };

    // ── Response ────────────────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try appendJsonEscaped(&json, ctx.allocator, ns);
    try json.appendSlice(ctx.allocator, "\",\"index_dropped\":");
    try json.appendSlice(ctx.allocator, if (index_dropped) "true" else "false");
    try json.appendSlice(ctx.allocator, ",\"deleted\":");
    try writeUsize(&json, ctx.allocator, total_deleted);
    try json.appendSlice(ctx.allocator, ",\"skipped_worm\":");
    try writeUsize(&json, ctx.allocator, skipped_worm);
    try json.appendSlice(ctx.allocator, ",\"errors\":");
    try writeUsize(&json, ctx.allocator, errors);
    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

// ╔═══════════════════════════════════════════════════╗
// ║  mem_reset_index                                   ║
// ╚═══════════════════════════════════════════════════╝

/// Drop the HNSW + BQ + raw-vector state for a namespace and rewrite
/// the config with a new embedder_id. Preserves `mem:<ns>:<id>` doc
/// bodies and `:meta` blobs — BentoKit-style sidecar callers hold the
/// canonical row in SQLite, re-embed against the new model, and call
/// `mem_add` again to repopulate.
///
/// The metric is preserved from the existing config: changing metric
/// requires `mem_drop` + fresh `mem_init`.
pub fn memResetIndex(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse
        return ctx.err("mem_reset_index requires: <ns> <new_embedder_id>");
    const new_embedder_id = ctx.arg(1) orelse
        return ctx.err("mem_reset_index requires: <ns> <new_embedder_id>");

    if (!validateNs(ns)) return ctx.err("mem_reset_index: invalid ns");
    ctx.requireNamespace(ns, .delete) catch return ctx.err("permission denied");
    if (!validateEmbedderId(new_embedder_id))
        return ctx.err("mem_reset_index: invalid embedder_id");

    const config_key = try std.fmt.allocPrint(ctx.allocator, "__meta:mem:{s}:config", .{ns});
    defer ctx.allocator.free(config_key);

    const existing = (try ctx.getCopy(config_key)) orelse
        return ctx.err("mem_reset_index: namespace has no config — call mem_init first");
    const cfg_metric_str = extractConfigField(existing, "metric") orelse
        return ctx.err("mem_reset_index: existing config missing metric field");
    const metric = Metric.fromStr(cfg_metric_str) orelse
        return ctx.err("mem_reset_index: existing config has unknown metric");
    const vector_only = extractConfigBool(existing, "vector_only") orelse false;

    const vec_prefix = try std.fmt.allocPrint(ctx.allocator, "vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(vec_prefix);
    const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "bq:vec:mem:{s}:", .{ns});
    defer ctx.allocator.free(bq_prefix);

    // ── Delete vec:* and bq:* keys first; only after all succeed do
    //    we drop HNSW state and rewrite the config. The all-or-nothing
    //    discipline matters: if any vec key survives a half-applied
    //    reset (most commonly a WORM-protected key), the namespace
    //    would end up with old vectors under a new embedder_id —
    //    silent mixed-embedder corruption, the exact failure this
    //    proc exists to prevent. On any failure we leave HNSW intact
    //    and config untouched so the caller can inspect, then
    //    `mem_drop` if they need a clean slate.
    var vectors_dropped: usize = 0;
    var skipped_worm: usize = 0;
    var errors: usize = 0;

    const prefixes = [_][]const u8{ vec_prefix, bq_prefix };
    for (prefixes, 0..) |prefix, prefix_idx| {
        var collector = DropCtx{
            .keys = .empty,
            .allocator = ctx.allocator,
            .oom = false,
        };
        defer {
            for (collector.keys.items) |k| collector.allocator.free(k);
            collector.keys.deinit(collector.allocator);
        }
        ctx.scanCallback(prefix, @ptrCast(&collector), collectDropKey);
        if (collector.oom)
            return ctx.err("mem_reset_index: out of memory collecting keys");

        for (collector.keys.items) |k| {
            ctx.deleteDurable(k) catch |e| switch (e) {
                error.WormViolation => {
                    skipped_worm += 1;
                    continue;
                },
                else => {
                    errors += 1;
                    continue;
                },
            };
            // Only count the vec:* prefix (prefix_idx 0) toward the
            // "needs re-ingest" tally — bq:* are derivatives.
            if (prefix_idx == 0) vectors_dropped += 1;
        }
    }

    // ── Abort if any deletion failed — config and HNSW must stay in
    //    their pre-reset state so the namespace remains coherent.
    if (skipped_worm > 0 or errors > 0) {
        return ctx.err(ctx.fmt(
            "mem_reset_index: aborted; {d} vec/bq key(s) blocked by WORM and {d} other error(s) — config and HNSW left intact. Use mem_drop if you need a hard reset.",
            .{ skipped_worm, errors },
        ));
    }

    // ── Clear the HNSW index in-place. Using clearLocked rather than
    //    NamespaceRegistry.remove avoids a use-after-free against any
    //    concurrent caller that resolved the namespace pointer before
    //    we ran (e.g. mem_query holding ns_idx through stage-2 refine).
    //    The pointer stays valid; the caller observes an empty index.
    if (ctx.vector_registry) |reg| {
        if (reg.get(vec_prefix)) |ns_idx| {
            ns_idx.lock.lock();
            defer ns_idx.lock.unlock();
            ns_idx.clearLocked();
        }
    }

    // ── Rewrite config with new embedder_id, preserving metric ──
    var cfg: std.ArrayListUnmanaged(u8) = .empty;
    defer cfg.deinit(ctx.allocator);
    try cfg.appendSlice(ctx.allocator, "{\"embedder_id\":\"");
    try cfg.appendSlice(ctx.allocator, new_embedder_id);
    try cfg.appendSlice(ctx.allocator, "\",\"metric\":\"");
    try cfg.appendSlice(ctx.allocator, metric.name());
    try cfg.appendSlice(ctx.allocator, "\",\"vector_only\":");
    try cfg.appendSlice(ctx.allocator, if (vector_only) "true" else "false");
    try cfg.appendSlice(ctx.allocator, ",\"created_at\":");
    try writeU64(&cfg, ctx.allocator, ctx.timestamp());
    try cfg.append(ctx.allocator, '}');
    try ctx.setDurable(config_key, cfg.items);

    // ── Response ────────────────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try appendJsonEscaped(&json, ctx.allocator, ns);
    try json.appendSlice(ctx.allocator, "\",\"embedder_id\":\"");
    try appendJsonEscaped(&json, ctx.allocator, new_embedder_id);
    try json.appendSlice(ctx.allocator, "\",\"metric\":\"");
    try json.appendSlice(ctx.allocator, metric.name());
    try json.appendSlice(ctx.allocator, "\",\"vector_only\":");
    try json.appendSlice(ctx.allocator, if (vector_only) "true" else "false");
    try json.appendSlice(ctx.allocator, ",\"vectors_to_reingest\":");
    try writeUsize(&json, ctx.allocator, vectors_dropped);
    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

test {
    std.testing.refAllDecls(@This());
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests — pure helpers                              ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;

test "validateNs accepts safe tokens" {
    try testing.expect(validateNs("articles"));
    try testing.expect(validateNs("user_memories"));
    try testing.expect(validateNs("ns-1"));
    try testing.expect(validateNs("a.b.c"));
    try testing.expect(validateNs("sessions/demo"));
}

test "validateNs rejects empty, too-long, colons, and control chars" {
    try testing.expect(!validateNs(""));
    const too_long = "a" ** (MAX_NS_LEN + 1);
    try testing.expect(!validateNs(too_long));
    try testing.expect(!validateNs("has:colon"));
    try testing.expect(!validateNs("has space"));
    try testing.expect(!validateNs("has\"quote"));
    try testing.expect(!validateNs("has\nnewline"));
}

test "validateDocId mirrors ns rules but with longer cap" {
    try testing.expect(validateDocId("doc-001"));
    try testing.expect(validateDocId("session/42/chunk-3"));
    try testing.expect(!validateDocId(""));
    try testing.expect(!validateDocId("has:colon"));
}

test "validateEmbedderId accepts common model names" {
    try testing.expect(validateEmbedderId("text-embedding-3-large"));
    try testing.expect(validateEmbedderId("sentence-transformers/all-MiniLM-L6-v2"));
    try testing.expect(validateEmbedderId("bge-m3.v1"));
    try testing.expect(!validateEmbedderId(""));
    try testing.expect(!validateEmbedderId("has:colon"));
}

test "extractConfigField pulls string field from our own JSON layout" {
    const cfg = "{\"embedder_id\":\"bge-m3\",\"metric\":\"cosine\",\"created_at\":12345}";
    try testing.expectEqualStrings("bge-m3", extractConfigField(cfg, "embedder_id").?);
    try testing.expectEqualStrings("cosine", extractConfigField(cfg, "metric").?);
    try testing.expect(extractConfigField(cfg, "missing") == null);
}

test "extractConfigFloat pulls numeric field from our own JSON layout" {
    const cfg = "{\"embedder_id\":\"bge-m3\",\"metric\":\"cosine\",\"decay_tau_hours\":24,\"created_at\":12345}";
    try testing.expectApproxEqAbs(@as(f32, 24.0), extractConfigFloat(cfg, "decay_tau_hours").?, 0.001);
    try testing.expect(extractConfigFloat(cfg, "missing") == null);
}

test "extractConfigBool pulls boolean fields from config JSON" {
    const cfg = "{\"embedder_id\":\"bge-m3\",\"metric\":\"cosine\",\"vector_only\":true,\"created_at\":12345}";
    try testing.expectEqual(true, extractConfigBool(cfg, "vector_only").?);
    try testing.expect(extractConfigBool(cfg, "missing") == null);
}

test "parseMemInitVectorOnlyFlag accepts explicit true and false forms" {
    try testing.expectEqual(true, parseMemInitVectorOnlyFlag("vector_only=true").?);
    try testing.expectEqual(true, parseMemInitVectorOnlyFlag("vector_only").?);
    try testing.expectEqual(false, parseMemInitVectorOnlyFlag("vector_only=false").?);
    try testing.expect(parseMemInitVectorOnlyFlag("decay_tau_hours=24") == null);
}

test "appendJsonEscaped handles quotes, backslashes, and control chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendJsonEscaped(&buf, testing.allocator, "hello\"world\\and\nnewline\t");
    try testing.expectEqualStrings("hello\\\"world\\\\and\\nnewline\\t", buf.items);
}

test "applyDecay: lambda=0 is a no-op" {
    const s = applyDecay(0.8, 1000, 0.0, 2000, DEFAULT_DECAY_TAU_HOURS);
    try testing.expectApproxEqAbs(@as(f32, 0.8), s, 1e-6);
}

test "applyDecay: lambda=1 returns pure recency in [0,1]" {
    const now: u64 = 10_000_000_000; // ~116 days in ms
    const ts: u64 = now; // zero age
    const s = applyDecay(0.5, ts, 1.0, now, DEFAULT_DECAY_TAU_HOURS);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s, 1e-6);

    // 116 days at a 1-week time constant → exp(-~16.5) ≈ 7e-8 ≪ 0.01
    const s_old = applyDecay(0.5, 0, 1.0, now, DEFAULT_DECAY_TAU_HOURS);
    try testing.expect(s_old < 0.01);

    // One time-constant (168 h) → exp(-1) ≈ 0.368
    const one_tau_ms: u64 = 168 * 3_600_000;
    const s_tau = applyDecay(0.5, 0, 1.0, one_tau_ms, DEFAULT_DECAY_TAU_HOURS);
    try testing.expectApproxEqAbs(@as(f32, 0.3679), s_tau, 0.001);
}

test "applyDecay: configurable tau controls old-memory decay" {
    const now: u64 = 48 * 3_600_000;
    const old_ts: u64 = 0;

    const tau_24h = applyDecay(0.5, old_ts, 1.0, now, 24.0);
    const tau_1y = applyDecay(0.5, old_ts, 1.0, now, 8760.0);

    try testing.expect(tau_24h < 0.14);
    try testing.expect(tau_1y > 0.99);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests — embedder enforcement & mem_reset_index    ║
// ╚═══════════════════════════════════════════════════╝
//
// These tests build a real Store + Ctx so the WAL + locking + setDurable
// paths get exercised. They are slower than the helper tests above but
// catch the actual integration: do mem_add and mem_reset_index leave the
// store in the expected state?

const compat = @import("../core/compat.zig");
const StoreModule = @import("../storage/store.zig");
const EventBus = @import("../event/bus.zig").EventBus;

/// Pack a slice of f32s as little-endian bytes — what mem_add expects on
/// the wire. Lifetime: caller owns the returned slice.
fn packF32(allocator: std.mem.Allocator, vals: []const f32) ![]u8 {
    const buf = try allocator.alloc(u8, vals.len * 4);
    for (vals, 0..) |v, i| {
        const bits: u32 = @bitCast(v);
        std.mem.writeInt(u32, buf[i * 4 ..][0..4], bits, .little);
    }
    return buf;
}

/// Spin up a fresh Store backed by a tmp WAL + snapshot. Caller is
/// responsible for `store.deinit()` and `tmp.cleanup()` in that order.
const TestStoreFixture = struct {
    tmp: std.testing.TmpDir,
    store: StoreModule.Store,
    wal_path: []u8,
    snapshot_path: []u8,

    fn init(name: []const u8) !TestStoreFixture {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const tmp_path = try compat.Dir.realPathAlloc(tmp.dir, alloc, ".");
        defer alloc.free(tmp_path);

        const wal_path = try std.fmt.allocPrint(alloc, "{s}/{s}.wal", .{ tmp_path, name });
        errdefer alloc.free(wal_path);
        const snap_path = try std.fmt.allocPrint(alloc, "{s}/{s}.snap", .{ tmp_path, name });
        errdefer alloc.free(snap_path);

        const wal_file = try std.fmt.allocPrint(alloc, "{s}.wal", .{name});
        defer alloc.free(wal_file);
        const f = try compat.Dir.createFile(tmp.dir, wal_file, .{});
        compat.File.close(f);

        const store = try StoreModule.Store.init(alloc, .{
            .wal_path = wal_path,
            .snapshot_path = snap_path,
            .sync_writes = false,
        });

        return .{ .tmp = tmp, .store = store, .wal_path = wal_path, .snapshot_path = snap_path };
    }

    fn deinit(self: *TestStoreFixture) void {
        self.store.deinit();
        testing.allocator.free(self.wal_path);
        testing.allocator.free(self.snapshot_path);
        self.tmp.cleanup();
    }
};

/// Run a procedure with `args` against `store`, return the Response.
/// Caller is responsible for any inspection of `.value` / `.err` payloads
/// — they are arena-owned and live for the lifetime of `arena`.
fn runProc(
    store: *StoreModule.Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, null, null);
    defer ctx.deinit();
    return try proc(&ctx);
}

fn runProcWithBus(
    store: *StoreModule.Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
    bus: *EventBus,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, bus, null);
    defer ctx.deinit();
    return try proc(&ctx);
}

fn runProcWithAuth(
    store: *StoreModule.Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
    auth_context: auth.AuthContext,
) !Ctx.Result {
    var ctx = Ctx.initWithAuth(store, args, arena, auth_context, null, null, null, null);
    defer ctx.deinit();
    return try proc(&ctx);
}

fn runProcWithRegistry(
    store: *StoreModule.Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
    registry: *IndexModule.NamespaceRegistry,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, null, registry);
    defer ctx.deinit();
    return try proc(&ctx);
}

test "mem_query: filters brute-force candidates by metadata before top-k" {
    var fx = try TestStoreFixture.init("memquery_filter_brute");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb1 = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb2 = try packF32(arena, &[_]f32{ 0.98, 0.02, 0.0, 0.0 });
    _ = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "semantic public", emb1, "{\"privacy_level\":1,\"category\":\"semantic\",\"sourceType\":\"chat\",\"minImportance\":0.9}", "0" },
        arena,
    );
    _ = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-2", "episodic private", emb2, "{\"privacy_level\":3,\"category\":\"episodic\",\"sourceType\":\"tool\",\"minImportance\":0.4}", "0" },
        arena,
    );

    const result = try runProc(
        &fx.store,
        memQuery,
        &.{
            "demo",
            emb1,
            "5",
            "0",
            "-999",
            "0",
            "filter=privacy_level<=1 AND category=\"semantic\" AND sourceType IN (\"chat\",\"note\") AND minImportance>=0.8",
        },
        arena,
    );
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"id\":\"doc-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"id\":\"doc-2\"") == null);
}

test "mem_query: supports ts filters and rejects invalid predicates" {
    var fx = try TestStoreFixture.init("memquery_filter_ts");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    _ = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "now", emb, "{\"category\":\"semantic\"}", "0" },
        arena,
    );

    const included = try runProc(
        &fx.store,
        memQuery,
        &.{ "demo", emb, "5", "0", "-999", "0", "filter=ts>=0" },
        arena,
    );
    try testing.expect(included == .value);
    try testing.expect(std.mem.indexOf(u8, included.value.?, "\"id\":\"doc-1\"") != null);

    const excluded = try runProc(
        &fx.store,
        memQuery,
        &.{ "demo", emb, "5", "0", "-999", "0", "filter=ts>9999999999999999" },
        arena,
    );
    try testing.expect(excluded == .value);
    try testing.expectEqualStrings("[]", excluded.value.?);

    const invalid = try runProc(
        &fx.store,
        memQuery,
        &.{ "demo", emb, "5", "0", "-999", "0", "filter=meta.user.name=\"x\"" },
        arena,
    );
    try testing.expect(invalid == .err);
    try testing.expect(std.mem.indexOf(u8, invalid.err, "filter") != null);
}

test "mem_query: filters HNSW refine candidates by metadata before top-k" {
    var fx = try TestStoreFixture.init("memquery_filter_hnsw");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = IndexModule.NamespaceRegistry.init(testing.allocator, .{});
    defer registry.deinit();

    _ = try runProcWithRegistry(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena, &registry);

    const emb_public = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb_private = try packF32(arena, &[_]f32{ 0.99, 0.01, 0.0, 0.0 });
    _ = try runProcWithRegistry(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-public", "public", emb_public, "{\"privacy_level\":1,\"category\":\"semantic\"}", "0" },
        arena,
        &registry,
    );
    _ = try runProcWithRegistry(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-private", "private", emb_private, "{\"privacy_level\":5,\"category\":\"semantic\"}", "0" },
        arena,
        &registry,
    );

    const result = try runProcWithRegistry(
        &fx.store,
        memQuery,
        &.{ "demo", emb_private, "1", "0", "-999", "0", "filter=privacy_level<=1 AND category=\"semantic\"" },
        arena,
        &registry,
    );
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"id\":\"doc-public\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"id\":\"doc-private\"") == null);
}

test "mem_get: enforces namespace-scoped read capability" {
    var fx = try TestStoreFixture.init("memget_auth_scope");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "astrid", "bge-m3", "cosine" }, arena);
    _ = try runProc(&fx.store, memInit, &.{ "raven", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    _ = try runProc(&fx.store, memAdd, &.{ "astrid", "doc-1", "allowed", emb, "{}", "0" }, arena);
    _ = try runProc(&fx.store, memAdd, &.{ "raven", "doc-1", "denied", emb, "{}", "0" }, arena);

    const caps = [_]auth.Capability{
        .{ .op = .get, .match_type = .prefix, .pattern = "mem:astrid:" },
        .{ .op = .get, .match_type = .prefix, .pattern = "vec:mem:astrid:" },
        .{ .op = .get, .match_type = .prefix, .pattern = "bq:vec:mem:astrid:" },
        .{ .op = .get, .match_type = .prefix, .pattern = "__meta:mem:astrid:" },
    };
    const state = auth.TokenState{
        .subject = "mem:astrid",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &caps,
    };

    const allowed = try runProcWithAuth(
        &fx.store,
        memGet,
        &.{ "astrid", "doc-1" },
        arena,
        .{ .enforce = &state },
    );
    try testing.expect(allowed == .value);

    const denied = try runProcWithAuth(
        &fx.store,
        memGet,
        &.{ "raven", "doc-1" },
        arena,
        .{ .enforce = &state },
    );
    try testing.expect(denied == .err);
    try testing.expectEqualStrings("permission denied", denied.err);
}

test "mem_add: accepts call without embedder_id arg (backward compat)" {
    var fx = try TestStoreFixture.init("memadd_compat");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "hello", emb },
        arena,
    );
    try testing.expect(result == .ok);
}

test "mem_init: persists and updates decay_tau_hours" {
    var fx = try TestStoreFixture.init("meminit_decay_tau");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const init_24 = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "24" }, arena);
    try testing.expect(init_24 == .ok);

    const cfg_24 = (try fx.store.getValueDupe("__meta:mem:demo:config", arena)).?;
    try testing.expectApproxEqAbs(@as(f32, 24.0), extractConfigFloat(cfg_24, "decay_tau_hours").?, 0.001);

    const init_48 = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "48" }, arena);
    try testing.expect(init_48 == .ok);

    const cfg_48 = (try fx.store.getValueDupe("__meta:mem:demo:config", arena)).?;
    try testing.expectApproxEqAbs(@as(f32, 48.0), extractConfigFloat(cfg_48, "decay_tau_hours").?, 0.001);
}

test "mem_add: rejects mismatched embedder_id" {
    var fx = try TestStoreFixture.init("memadd_mismatch");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memAdd,
        // 5th arg = meta_json, 6th = worm, 7th = embedder_id (the assert)
        &.{ "demo", "doc-1", "hello", emb, "", "1", "text-embedding-3-large" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err, "embedder mismatch") != null);

    // Side-effect check: the rejected add must not have written the doc.
    try testing.expect(fx.store.get("mem:demo:doc-1") == null);
}

test "mem_add: accepts matching embedder_id" {
    var fx = try TestStoreFixture.init("memadd_match");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "hello", emb, "", "1", "bge-m3" },
        arena,
    );
    try testing.expect(result == .ok);
    try testing.expect(fx.store.get("mem:demo:doc-1") != null);
}

test "mem_meta_set: updates metadata returned by mem_get" {
    var fx = try TestStoreFixture.init("mem_meta_set");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const add = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "hello", emb, "{\"recall_count\":0}", "0", "bge-m3" },
        arena,
    );
    try testing.expect(add == .ok);

    const update = try runProc(
        &fx.store,
        memMetaSet,
        &.{ "demo", "doc-1", "{\"recall_count\":1,\"accessed_at\":42}" },
        arena,
    );
    try testing.expect(update == .ok);

    const got = try runProc(&fx.store, memGet, &.{ "demo", "doc-1" }, arena);
    try testing.expect(got == .value);
    try testing.expect(std.mem.indexOf(u8, got.value.?, "\"recall_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, got.value.?, "\"accessed_at\":42") != null);
}

test "mem_meta_set: rejects missing doc_id" {
    var fx = try TestStoreFixture.init("mem_meta_set_missing");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const update = try runProc(
        &fx.store,
        memMetaSet,
        &.{ "demo", "missing", "{\"recall_count\":1}" },
        arena,
    );
    try testing.expect(update == .err);
    try testing.expectEqualStrings("mem_meta_set: doc_id not found", update.err);
    try testing.expect(fx.store.get("mem:demo:missing:meta") == null);
}

test "mem_verify: reports orphan vector ids" {
    var fx = try TestStoreFixture.init("memverify_orphan_vec");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    try fx.store.set("mem:demo:ok", "doc", false);
    try fx.store.set("vec:mem:demo:ok", emb, false);
    try fx.store.set("bq:vec:mem:demo:ok", "x", false);
    try fx.store.set("vec:mem:demo:orphan-vec", emb, false);

    const result = try runProc(&fx.store, memVerify, &.{"demo"}, arena);
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"doc_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"vector_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"bq_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"hnsw_node_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"orphan_vectors\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"orphan-vec\"") != null);
}

test "mem_verify: reports orphan docs and ignores metadata sidecars" {
    var fx = try TestStoreFixture.init("memverify_orphan_doc");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try fx.store.set("mem:demo:doc-only", "doc", false);
    try fx.store.set("mem:demo:doc-only:meta", "{\"k\":1}", false);

    const result = try runProc(&fx.store, memVerify, &.{"demo"}, arena);
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"doc_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"vector_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"orphan_docs\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"doc-only\"") != null);
}

test "mem_verify: reports vectors missing BQ entries" {
    var fx = try TestStoreFixture.init("memverify_missing_bq");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    try fx.store.set("mem:demo:missing-bq", "doc", false);
    try fx.store.set("vec:mem:demo:missing-bq", emb, false);

    const result = try runProc(&fx.store, memVerify, &.{"demo"}, arena);
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"missing_bq\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"missing-bq\"") != null);
}

test "mem_verify: vector-only config suppresses orphan docs" {
    var fx = try TestStoreFixture.init("memverify_vector_only");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try fx.store.set("__meta:mem:demo:config", "{\"embedder_id\":\"bge-m3\",\"metric\":\"cosine\",\"vector_only\":true}", false);
    try fx.store.set("mem:demo:sidecar-row", "doc", false);

    const result = try runProc(&fx.store, memVerify, &.{"demo"}, arena);
    try testing.expect(result == .value);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"doc_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"orphan_docs\":[]") != null);
}

test "mem_add: invalid embedder_id arg rejected before state changes" {
    var fx = try TestStoreFixture.init("memadd_invalid");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "hello", emb, "", "1", "has:colon" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(fx.store.get("mem:demo:doc-1") == null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") == null);
}

test "mem_range: returns docs in timestamp order with meta and limit" {
    var fx = try TestStoreFixture.init("memrange_order");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try fx.store.setWithTimestamp("mem:demo:old", "old", false, 1_000);
    try fx.store.setWithTimestamp("mem:demo:in-b", "second", false, 3_000);
    try fx.store.setWithTimestamp("mem:demo:in-a", "first", false, 2_000);
    try fx.store.setWithTimestamp("mem:demo:new", "new", false, 4_000);
    try fx.store.setWithTimestamp("mem:demo:in-a:meta", "{\"kind\":\"a\"}", false, 2_100);

    const limited = try runProc(
        &fx.store,
        memRange,
        &.{ "demo", "1500", "3500", "1" },
        arena,
    );
    try testing.expect(limited == .value);
    try testing.expectEqualStrings(
        "[{\"id\":\"in-a\",\"ts\":2000,\"meta\":{\"kind\":\"a\"}}]",
        limited.value.?,
    );

    const all = try runProc(
        &fx.store,
        memRange,
        &.{ "demo", "1500", "3500", "0" },
        arena,
    );
    try testing.expect(all == .value);
    try testing.expectEqualStrings(
        "[{\"id\":\"in-a\",\"ts\":2000,\"meta\":{\"kind\":\"a\"}},{\"id\":\"in-b\",\"ts\":3000,\"meta\":null}]",
        all.value.?,
    );
}

test "mem_range: applies metadata and ts filters before limit" {
    var fx = try TestStoreFixture.init("memrange_filter");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try fx.store.setWithTimestamp("mem:demo:old", "old", false, 1_000);
    try fx.store.setWithTimestamp("mem:demo:match-a", "a", false, 2_000);
    try fx.store.setWithTimestamp("mem:demo:miss", "miss", false, 3_000);
    try fx.store.setWithTimestamp("mem:demo:match-b", "b", false, 4_000);
    try fx.store.setWithTimestamp("mem:demo:match-a:meta", "{\"category\":\"semantic\",\"privacy_level\":1}", false, 2_000);
    try fx.store.setWithTimestamp("mem:demo:miss:meta", "{\"category\":\"episodic\",\"privacy_level\":1}", false, 3_000);
    try fx.store.setWithTimestamp("mem:demo:match-b:meta", "{\"category\":\"semantic\",\"privacy_level\":2}", false, 4_000);

    const result = try runProc(
        &fx.store,
        memRange,
        &.{ "demo", "0", "5000", "1", "filter=category=\"semantic\" AND privacy_level<=1 AND ts>=1500" },
        arena,
    );
    try testing.expect(result == .value);
    try testing.expectEqualStrings(
        "[{\"id\":\"match-a\",\"ts\":2000,\"meta\":{\"category\":\"semantic\",\"privacy_level\":1}}]",
        result.value.?,
    );
}

test "mem_range: rejects invalid filter predicates" {
    var fx = try TestStoreFixture.init("memrange_filter_invalid");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runProc(
        &fx.store,
        memRange,
        &.{ "demo", "0", "1000", "10", "meta.user.name=\"x\"" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expectEqualStrings("mem_range: invalid filter predicate", result.err);
}

test "mem_bulk_add: stores vectors and meta, then publishes one bulk memory event" {
    var fx = try TestStoreFixture.init("membulk_success");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const Capture = struct {
        buf: []u8,
        len: usize = 0,

        fn write(raw: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const n = @min(self.buf.len, data.len);
            @memcpy(self.buf[0..n], data[0..n]);
            self.len = n;
        }
    };

    var capture = Capture{ .buf = try testing.allocator.alloc(u8, 1024) };
    defer testing.allocator.free(capture.buf);
    _ = try bus.subscribe("mem:demo:added.bulk", Capture.write, @ptrCast(&capture));

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb1 = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb2 = try packF32(arena, &[_]f32{ 0.0, 1.0, 0.0, 0.0 });
    const result = try runProcWithBus(
        &fx.store,
        memBulkAdd,
        &.{ "demo", "2", "doc-1", emb1, "{\"k\":1}", "doc-2", emb2, "{\"k\":2}" },
        arena,
        &bus,
    );
    try testing.expect(result == .ok);

    try testing.expect(fx.store.get("vec:mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-2") != null);
    try testing.expect(fx.store.get("bq:vec:mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("mem:demo:doc-1:meta") != null);
    try testing.expect(fx.store.get("mem:demo:doc-1") == null);

    const event = capture.buf[0..capture.len];
    try testing.expect(std.mem.indexOf(u8, event, "mem:demo:added.bulk") != null);
    try testing.expect(std.mem.indexOf(u8, event, "[\"doc-1\",\"doc-2\"]") != null);
}

test "mem_bulk_add: dimension mismatch rejects whole batch before writes" {
    var fx = try TestStoreFixture.init("membulk_dim_mismatch");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb1 = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb_bad = try packF32(arena, &[_]f32{ 1.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memBulkAdd,
        &.{ "demo", "2", "doc-1", emb1, "{}", "doc-2", emb_bad, "{}" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err, "same dimension") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") == null);
    try testing.expect(fx.store.get("mem:demo:doc-1:meta") == null);
}

test "mem_bulk_add: duplicate ids reject whole batch before writes" {
    var fx = try TestStoreFixture.init("membulk_duplicate");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const emb1 = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb2 = try packF32(arena, &[_]f32{ 0.0, 1.0, 0.0, 0.0 });
    const result = try runProc(
        &fx.store,
        memBulkAdd,
        &.{ "demo", "2", "doc-1", emb1, "{}", "doc-1", emb2, "{}" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err, "duplicate") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") == null);
}

test "mem_init: persists vector_only and rejects mode flips" {
    var fx = try TestStoreFixture.init("meminit_vector_only");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const init = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "vector_only=true" }, arena);
    try testing.expect(init == .ok);

    const cfg = (try fx.store.getValueDupe("__meta:mem:demo:config", arena)).?;
    try testing.expect(std.mem.indexOf(u8, cfg, "\"vector_only\":true") != null);

    const same = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "vector_only=true" }, arena);
    try testing.expect(same == .ok);

    const flip = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);
    try testing.expect(flip == .err);
    try testing.expect(std.mem.indexOf(u8, flip.err, "vector_only") != null);
}

test "mem_add/query/get: vector_only namespace stores vector and meta without doc body" {
    var fx = try TestStoreFixture.init("memadd_vector_only");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "vector_only=true" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const add = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", emb, "{\"kind\":\"semantic\"}", "0", "bge-m3" },
        arena,
    );
    try testing.expect(add == .ok);

    try testing.expect(fx.store.get("mem:demo:doc-1") == null);
    try testing.expect(fx.store.get("mem:demo:doc-1:meta") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("bq:vec:mem:demo:doc-1") != null);

    const get = try runProc(&fx.store, memGet, &.{ "demo", "doc-1" }, arena);
    try testing.expect(get == .err);
    try testing.expect(std.mem.indexOf(u8, get.err, "vector_only") != null);

    const query = try runProc(
        &fx.store,
        memQuery,
        &.{ "demo", emb, "1" },
        arena,
    );
    try testing.expect(query == .value);
    try testing.expect(std.mem.indexOf(u8, query.value.?, "\"id\":\"doc-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, query.value.?, "\"meta\":{\"kind\":\"semantic\"}") != null);
    try testing.expect(std.mem.indexOf(u8, query.value.?, "\"doc\"") == null);
}

test "mem_add: vector_only rejects legacy doc-text shape when embedding is recognizable" {
    var fx = try TestStoreFixture.init("memadd_vector_only_legacy_shape");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine", "vector_only=true" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const add = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "text body", emb },
        arena,
    );
    try testing.expect(add == .err);
    try testing.expect(std.mem.indexOf(u8, add.err, "no text arg") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") == null);
}

test "mem_add: default namespace still stores doc and meta" {
    var fx = try TestStoreFixture.init("memadd_default_still_docs");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const add = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-1", "hello", emb, "{\"kind\":\"semantic\"}", "0" },
        arena,
    );
    try testing.expect(add == .ok);
    try testing.expect(fx.store.get("mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("mem:demo:doc-1:meta") != null);
}

test "mem_reset_index: drops vectors, preserves docs, rewrites config" {
    var fx = try TestStoreFixture.init("memreset");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    // Two docs; one with metadata, one without — reset must preserve both.
    // is_worm = "0" so reset's deleteDurable can succeed on the vec keys.
    const emb1 = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    const emb2 = try packF32(arena, &[_]f32{ 0.0, 1.0, 0.0, 0.0 });
    _ = try runProc(&fx.store, memAdd, &.{ "demo", "doc-1", "first", emb1, "{\"k\":1}", "0" }, arena);
    _ = try runProc(&fx.store, memAdd, &.{ "demo", "doc-2", "second", emb2, "", "0" }, arena);

    // Sanity: vectors and docs both present pre-reset.
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-2") != null);
    try testing.expect(fx.store.get("mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("mem:demo:doc-2") != null);

    const result = try runProc(
        &fx.store,
        memResetIndex,
        &.{ "demo", "text-embedding-3-large" },
        arena,
    );
    try testing.expect(result == .value);

    // The response JSON should report 2 vectors-to-reingest.
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"vectors_to_reingest\":2") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"embedder_id\":\"text-embedding-3-large\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.value.?, "\"metric\":\"cosine\"") != null);

    // Vectors gone …
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") == null);
    try testing.expect(fx.store.get("vec:mem:demo:doc-2") == null);
    // … docs preserved (sidecar-pattern guarantee) …
    try testing.expect(fx.store.get("mem:demo:doc-1") != null);
    try testing.expect(fx.store.get("mem:demo:doc-2") != null);
    try testing.expect(fx.store.get("mem:demo:doc-1:meta") != null);
    // … config rewritten with the new embedder. Use getValueDupe to
    // copy under the shard lock — a raw Entry pointer would be unsafe
    // if anything ever ran concurrently against this store.
    const cfg = (try fx.store.getValueDupe("__meta:mem:demo:config", arena)).?;
    try testing.expect(std.mem.indexOf(u8, cfg, "text-embedding-3-large") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "bge-m3") == null);

    // Subsequent mem_add must now require the new embedder.
    const emb3 = try packF32(arena, &[_]f32{ 0.0, 0.0, 1.0, 0.0 });
    const stale_assert = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-3", "third", emb3, "", "0", "bge-m3" },
        arena,
    );
    try testing.expect(stale_assert == .err);

    const fresh_assert = try runProc(
        &fx.store,
        memAdd,
        &.{ "demo", "doc-3", "third", emb3, "", "0", "text-embedding-3-large" },
        arena,
    );
    try testing.expect(fresh_assert == .ok);
}

test "mem_reset_index: rejects when namespace has no config" {
    var fx = try TestStoreFixture.init("memreset_noconfig");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runProc(
        &fx.store,
        memResetIndex,
        &.{ "ghost", "bge-m3" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err, "no config") != null);
}

test "mem_reset_index: aborts cleanly when WORM blocks vec deletion" {
    // Default mem_add writes vec keys with WORM=true — the typical
    // production setup. mem_reset_index must refuse to half-apply: no
    // config rewrite, no HNSW clear, no silent mixed-embedder state.
    var fx = try TestStoreFixture.init("memreset_worm");
    defer fx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try runProc(&fx.store, memInit, &.{ "demo", "bge-m3", "cosine" }, arena);

    // Default args → is_worm = true, so vec:mem:demo:doc-1 is WORM.
    const emb = try packF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    _ = try runProc(&fx.store, memAdd, &.{ "demo", "doc-1", "first", emb }, arena);

    const result = try runProc(
        &fx.store,
        memResetIndex,
        &.{ "demo", "text-embedding-3-large" },
        arena,
    );
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err, "WORM") != null);

    // Original vector + config must both still be in place.
    try testing.expect(fx.store.get("vec:mem:demo:doc-1") != null);
    const cfg = (try fx.store.getValueDupe("__meta:mem:demo:config", arena)).?;
    try testing.expect(std.mem.indexOf(u8, cfg, "bge-m3") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "text-embedding-3-large") == null);
}
