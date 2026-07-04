//! Coordination claims on the verifiable append-log — leases without a coordinator.
//!
//! EXEC append_log_claim <log_id> <task_id> <worker_id> [lease_ms=<ms>] [hlc=<hex16>]
//! EXEC append_log_claim_status <log_id> <task_id>
//! EXEC append_log_claim_release <log_id> <task_id> <worker_id> <outcome> [hlc=<hex16>]
//! EXEC append_log_claim_supersede <log_id> <task_id> <stale_seq>
//!
//! A task lives inside a delegator-owned append-log (`log_id` is the
//! coordination log name, e.g. "coord:<org>:<agent>"). All coordination
//! events are ordinary JSON payloads on the EXISTING append-log primitive
//! (src/proof/append_log.zig), so grants are hash-chained, WORM, and covered
//! by the existing checkpoint/witness/proof_bundle EXECs. Event types:
//!
//!   {"t":"task.open","task":"<id>","body":...,"hlc":"<hex16>","by":"<identity>","expires_at_ms":N?}
//!   {"t":"claim.request","task":"<id>","hlc":"<hex16>","by":"<identity>","lease_ms":N}
//!   {"t":"claim.grant","task":"<id>","winner":"<identity>","winner_hlc":"<hex16>","granted_seq":N,"lease_expires_ms":N,"hlc":"<hex16>"}
//!   {"t":"claim.release","task":"<id>","by":"<identity>","outcome":"applied|failed|blocked","hlc":"<hex16>"}
//!   {"t":"task.superseded","task":"<id>","stale_seq":N,"hlc":"<hex16>"}
//!
//! Arbitration has no coordinator and no consensus round: it rides the
//! append-log's WORM sequence-collision property (exactly one writer wins a
//! given seq — a concurrent append surfaces as error.SequenceReuse). A
//! claimer appends its claim.request, folds the task's events, and the
//! deterministic winner — lowest (hlc, then seq) among the current epoch's
//! requests — appends the claim.grant. Racing granters collide on the seq or
//! are resolved by the fold's first-grant-of-the-epoch rule; after any grant
//! append (or SequenceReuse), the claimer RE-SCANS and returns the ACTUAL
//! grant on the log, so exactly one grant is ever authoritative per epoch.
//!
//! Epoch rule: a task's current epoch starts after the latest of task.open /
//! claim.release (by the winner) / grant lease expiry / task.superseded for
//! that task. An expired grant is IGNORED in arbitration — the task is
//! effectively reopen and only requests appended after the expired grant
//! compete for the next grant.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const append_log = @import("../proof/append_log.zig");
const hlc_mod = @import("../core/hlc.zig");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

pub const DEFAULT_LEASE_MS: u64 = 60_000;
const MAX_APPEND_ATTEMPTS: usize = 64;
const MAX_GRANT_ATTEMPTS: usize = 16;

/// Process-wide hybrid logical clock for coordination events. Procedures run
/// concurrently — Hlc is a single atomic u64 advanced by a CAS loop, so one
/// shared instance is safe.
var claim_clock: hlc_mod.Hlc = .{ .last = std.atomic.Value(u64).init(0) };

// ╔═══════════════════════════════════════════════╗
// ║  Pure fold                                     ║
// ╚═══════════════════════════════════════════════╝

/// One coordination event for a single task, decoded from the log.
pub const TaskEvent = struct {
    /// Append-log sequence number of the event (1-based, total order).
    seq: u64,
    kind: Kind = .request,
    /// Log receipt time (envelope ingest_time_ms) — used for the
    /// deterministic expired-grant replacement rule.
    at_ms: u64 = 0,
    /// Requester (claim.request) / releaser (claim.release) identity.
    by: []const u8 = "",
    /// The event's own HLC value (parsed from the "hlc" hex field).
    hlc: u64 = 0,
    /// claim.request only.
    lease_ms: u64 = 0,
    /// claim.grant only.
    winner: []const u8 = "",
    winner_hlc: u64 = 0,
    granted_seq: u64 = 0,
    lease_expires_ms: u64 = 0,
    /// task.superseded only.
    stale_seq: u64 = 0,

    pub const Kind = enum { open, request, grant, release, superseded };
};

/// A pending claim.request that would win arbitration if a grant were issued
/// right now. Lowest (hlc, then seq) among the eligible requests.
pub const Candidate = struct {
    seq: u64,
    hlc: u64,
    by: []const u8,
    lease_ms: u64,
};

pub const TaskState = struct {
    state: State,
    /// Winner of the current epoch's grant ("" when no grant).
    winner: []const u8 = "",
    winner_hlc: u64 = 0,
    /// Seq of the grant event itself (0 when no grant this epoch).
    grant_seq: u64 = 0,
    /// Seq of the winning claim.request the grant points at.
    granted_seq: u64 = 0,
    lease_expires_ms: u64 = 0,
    /// claim.requests observed in the current epoch.
    requests: usize = 0,
    /// Deterministic pending winner when no unexpired grant exists.
    candidate: ?Candidate = null,
    /// Events with seq > epoch_start_seq belong to the current epoch.
    epoch_start_seq: u64 = 0,

    pub const State = enum { open, claimed, released, expired };
};

fn betterCandidate(current: ?Candidate, next: Candidate) Candidate {
    const cur = current orelse return next;
    if (next.hlc < cur.hlc) return next;
    if (next.hlc == cur.hlc and next.seq < cur.seq) return next;
    return cur;
}

/// Pure fold of one task's coordination events (sorted by seq ascending)
/// into its current state. `now_ms` is only used to classify an existing
/// grant as claimed vs expired — everything else is derived from the log.
///
/// Rules:
/// - task.open / claim.release (by the grant winner) / task.superseded (of
///   the current grant) start a new epoch: prior requests and grant no
///   longer compete.
/// - The FIRST grant of an epoch is authoritative. A later grant in the same
///   epoch is honored only if the earlier grant's lease had already expired
///   when the later grant was received (`lease_expires_ms <= at_ms`) — the
///   deterministic, log-derived form of "an expired lease reopens the task".
///   Anything else is a duplicate and is ignored, so even if a rare race
///   lands two grant events, the fold yields exactly one granted claim.
/// - While a grant is active, new requests queue for the post-expiry epoch:
///   after the lease expires only requests with seq > grant_seq compete.
pub fn foldTask(events: []const TaskEvent, now_ms: u64) TaskState {
    const Grant = struct {
        seq: u64,
        winner: []const u8,
        winner_hlc: u64,
        granted_seq: u64,
        lease_expires_ms: u64,
    };

    var epoch_start: u64 = 0;
    var base_state: TaskState.State = .open;
    var grant: ?Grant = null;
    var requests: usize = 0;
    var best_epoch: ?Candidate = null;
    var best_after_grant: ?Candidate = null;

    for (events) |ev| {
        if (ev.kind != .open and ev.seq <= epoch_start) continue;
        switch (ev.kind) {
            .open => {
                epoch_start = ev.seq;
                grant = null;
                requests = 0;
                best_epoch = null;
                best_after_grant = null;
                base_state = .open;
            },
            .request => {
                requests += 1;
                const cand = Candidate{
                    .seq = ev.seq,
                    .hlc = ev.hlc,
                    .by = ev.by,
                    .lease_ms = ev.lease_ms,
                };
                if (grant == null) {
                    best_epoch = betterCandidate(best_epoch, cand);
                } else {
                    best_after_grant = betterCandidate(best_after_grant, cand);
                }
            },
            .grant => {
                const next = Grant{
                    .seq = ev.seq,
                    .winner = ev.winner,
                    .winner_hlc = ev.winner_hlc,
                    .granted_seq = ev.granted_seq,
                    .lease_expires_ms = ev.lease_expires_ms,
                };
                if (grant) |g| {
                    // Replacement is only valid once the previous lease had
                    // expired by the time this grant was received.
                    if (g.lease_expires_ms <= ev.at_ms) {
                        grant = next;
                        best_after_grant = null;
                    }
                    // else: duplicate grant in the same epoch — first wins.
                } else {
                    grant = next;
                    best_after_grant = null;
                }
            },
            .release => {
                const g = grant orelse continue;
                if (!std.mem.eql(u8, ev.by, g.winner)) continue;
                grant = null;
                epoch_start = ev.seq;
                requests = 0;
                best_epoch = null;
                best_after_grant = null;
                base_state = .released;
            },
            .superseded => {
                const g = grant orelse continue;
                if (ev.stale_seq != g.seq) continue;
                grant = null;
                epoch_start = ev.seq;
                requests = 0;
                best_epoch = null;
                best_after_grant = null;
                base_state = .open;
            },
        }
    }

    if (grant) |g| {
        if (g.lease_expires_ms > now_ms) {
            return .{
                .state = .claimed,
                .winner = g.winner,
                .winner_hlc = g.winner_hlc,
                .grant_seq = g.seq,
                .granted_seq = g.granted_seq,
                .lease_expires_ms = g.lease_expires_ms,
                .requests = requests,
                .epoch_start_seq = epoch_start,
            };
        }
        return .{
            .state = .expired,
            .winner = g.winner,
            .winner_hlc = g.winner_hlc,
            .grant_seq = g.seq,
            .granted_seq = g.granted_seq,
            .lease_expires_ms = g.lease_expires_ms,
            .requests = requests,
            .candidate = best_after_grant,
            .epoch_start_seq = epoch_start,
        };
    }
    return .{
        .state = base_state,
        .requests = requests,
        .candidate = best_epoch,
        .epoch_start_seq = epoch_start,
    };
}

// ╔═══════════════════════════════════════════════╗
// ║  Log access                                    ║
// ╚═══════════════════════════════════════════════╝

const EventJson = struct {
    t: []const u8 = "",
    task: []const u8 = "",
    by: []const u8 = "",
    hlc: []const u8 = "",
    winner: []const u8 = "",
    winner_hlc: []const u8 = "",
    lease_ms: u64 = 0,
    granted_seq: u64 = 0,
    lease_expires_ms: u64 = 0,
    outcome: []const u8 = "",
    stale_seq: u64 = 0,
};

/// Scan the log's event prefix (same pattern as append_log.verifyStore —
/// scanPrefix locks each shard internally; NO ctx shard locks are held) and
/// decode this task's coordination events in seq order. Non-JSON payloads
/// and other tasks' events are skipped.
fn loadTaskEvents(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    task_id: []const u8,
) ![]TaskEvent {
    const prefix = try append_log.eventKeyPrefix(allocator, log_id);
    const results = try store.scanPrefix(prefix, 0, allocator);

    var list: std.ArrayListUnmanaged(TaskEvent) = .empty;
    for (results) |r| {
        const view = append_log.decodeEnvelope(r.value) catch continue;
        const parsed = std.json.parseFromSliceLeaky(EventJson, allocator, view.payload, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (!std.mem.eql(u8, parsed.task, task_id)) continue;

        const kind: TaskEvent.Kind = if (std.mem.eql(u8, parsed.t, "task.open"))
            .open
        else if (std.mem.eql(u8, parsed.t, "claim.request"))
            .request
        else if (std.mem.eql(u8, parsed.t, "claim.grant"))
            .grant
        else if (std.mem.eql(u8, parsed.t, "claim.release"))
            .release
        else if (std.mem.eql(u8, parsed.t, "task.superseded"))
            .superseded
        else
            continue;

        try list.append(allocator, .{
            .seq = view.seq,
            .kind = kind,
            .at_ms = view.ingest_time_ms,
            .by = parsed.by,
            .hlc = parseHlcHex(parsed.hlc) orelse 0,
            .lease_ms = parsed.lease_ms,
            .winner = parsed.winner,
            .winner_hlc = parseHlcHex(parsed.winner_hlc) orelse 0,
            .granted_seq = parsed.granted_seq,
            .lease_expires_ms = parsed.lease_expires_ms,
            .stale_seq = parsed.stale_seq,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Append via the existing primitive, retrying WORM sequence collisions
/// (a concurrent writer winning the seq). Returns the landed seq.
fn appendWithRetry(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    payload: []const u8,
) !u64 {
    var attempts: usize = 0;
    while (attempts < MAX_APPEND_ATTEMPTS) : (attempts += 1) {
        const result = append_log.append(allocator, store, log_id, payload, &.{}, .{}) catch |err| switch (err) {
            error.SequenceReuse => continue,
            else => return err,
        };
        return result.seq;
    }
    return error.SequenceContention;
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: append_log_claim                        ║
// ╚═══════════════════════════════════════════════╝

pub fn claimExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "append_log_claim requires: <log_id> <task_id> <worker_id> [lease_ms=<ms>] [hlc=<hex16>]";
    const log_id = ctx.arg(0) orelse return ctx.err(usage);
    const task_id = ctx.arg(1) orelse return ctx.err(usage);
    const worker = ctx.arg(2) orelse return ctx.err(usage);
    if (log_id.len == 0 or task_id.len == 0 or worker.len == 0) return ctx.err(usage);

    var lease_ms: u64 = DEFAULT_LEASE_MS;
    var remote_hlc: ?u64 = null;
    var i: usize = 3;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "lease_ms=")) {
            lease_ms = std.fmt.parseUnsigned(u64, arg["lease_ms=".len..], 10) catch
                return ctx.err("append_log_claim: invalid lease_ms=<ms>");
            if (lease_ms == 0) return ctx.err("append_log_claim: lease_ms must be >= 1");
        } else if (std.mem.startsWith(u8, arg, "hlc=")) {
            remote_hlc = parseHlcHex(arg["hlc=".len..]) orelse
                return ctx.err("append_log_claim: invalid hlc=<hex16>");
        } else {
            return ctx.err("append_log_claim: unknown option");
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wall = ctx.timestamp();
    const my_hlc = if (remote_hlc) |remote| claim_clock.observe(remote, wall) else claim_clock.now(wall);

    // 1. Land this worker's claim.request (WORM seq races retried by the primitive contract).
    const req_payload = try requestPayload(arena, task_id, worker, my_hlc, lease_ms);
    const req_seq = appendWithRetry(arena, ctx.store, log_id, req_payload) catch
        return ctx.err("append_log_claim: request append failed");

    // 2. Arbitrate: fold, grant if we are the deterministic winner, RE-SCAN.
    var attempts: usize = 0;
    while (attempts < MAX_GRANT_ATTEMPTS) : (attempts += 1) {
        const events = loadTaskEvents(arena, ctx.store, log_id, task_id) catch
            return ctx.err("append_log_claim: log scan failed");
        const st = foldTask(events, ctx.timestamp());

        if (st.state == .claimed) {
            // A grant is authoritative (possibly ours after a retry — grant
            // idempotence: never append a second grant for the same epoch).
            return ctx.value(try claimJson(arena, task_id, .{
                .granted = std.mem.eql(u8, st.winner, worker),
                .state = st.state,
                .winner = st.winner,
                .winner_hlc = st.winner_hlc,
                .request_seq = req_seq,
                .grant_seq = st.grant_seq,
                .granted_seq = st.granted_seq,
                .lease_expires_ms = st.lease_expires_ms,
            }));
        }

        const cand = st.candidate orelse {
            // Our request fell out of the current epoch (a task.open or
            // supersede landed after it). Not granted; report the fold.
            return ctx.value(try claimJson(arena, task_id, .{
                .granted = false,
                .state = st.state,
                .winner = null,
                .winner_hlc = 0,
                .request_seq = req_seq,
                .grant_seq = 0,
                .granted_seq = 0,
                .lease_expires_ms = 0,
            }));
        };

        if (!std.mem.eql(u8, cand.by, worker)) {
            // Deterministic loser — lowest (hlc, seq) belongs to someone else.
            return ctx.value(try claimJson(arena, task_id, .{
                .granted = false,
                .state = st.state,
                .winner = cand.by,
                .winner_hlc = cand.hlc,
                .request_seq = req_seq,
                .grant_seq = 0,
                .granted_seq = cand.seq,
                .lease_expires_ms = 0,
            }));
        }

        // We are the winner: attempt to land the epoch's grant. A concurrent
        // granter colliding on the seq surfaces as SequenceReuse — RE-SCAN
        // (the fold then either shows the landed grant or lets us retry).
        const grant_lease = if (cand.lease_ms > 0) cand.lease_ms else lease_ms;
        const grant_hlc = claim_clock.now(ctx.timestamp());
        const expires = ctx.timestamp() + grant_lease;
        const grant_payload = try grantPayload(arena, task_id, cand.by, cand.hlc, cand.seq, expires, grant_hlc);
        _ = append_log.append(arena, ctx.store, log_id, grant_payload, &.{}, .{}) catch |err| switch (err) {
            error.SequenceReuse => continue,
            else => return ctx.err("append_log_claim: grant append failed"),
        };
        // Grant landed — loop back to RE-SCAN and return the ACTUAL grant on the log.
    }
    return ctx.err("append_log_claim: arbitration contention, retry");
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: append_log_claim_status                 ║
// ╚═══════════════════════════════════════════════╝

pub fn statusExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "append_log_claim_status requires: <log_id> <task_id>";
    const log_id = ctx.arg(0) orelse return ctx.err(usage);
    const task_id = ctx.arg(1) orelse return ctx.err(usage);
    if (ctx.argCount() != 2) return ctx.err(usage);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const events = loadTaskEvents(arena, ctx.store, log_id, task_id) catch
        return ctx.err("append_log_claim_status: log scan failed");
    const st = foldTask(events, ctx.timestamp());
    return ctx.value(try statusJson(arena, task_id, st));
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: append_log_claim_release                ║
// ╚═══════════════════════════════════════════════╝

pub fn releaseExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "append_log_claim_release requires: <log_id> <task_id> <worker_id> <outcome> [hlc=<hex16>]";
    const log_id = ctx.arg(0) orelse return ctx.err(usage);
    const task_id = ctx.arg(1) orelse return ctx.err(usage);
    const worker = ctx.arg(2) orelse return ctx.err(usage);
    const outcome = ctx.arg(3) orelse return ctx.err(usage);
    if (log_id.len == 0 or task_id.len == 0 or worker.len == 0) return ctx.err(usage);

    if (!std.mem.eql(u8, outcome, "applied") and
        !std.mem.eql(u8, outcome, "failed") and
        !std.mem.eql(u8, outcome, "blocked"))
    {
        return ctx.err("append_log_claim_release: outcome must be applied|failed|blocked");
    }

    var remote_hlc: ?u64 = null;
    var i: usize = 4;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "hlc=")) {
            remote_hlc = parseHlcHex(arg["hlc=".len..]) orelse
                return ctx.err("append_log_claim_release: invalid hlc=<hex16>");
        } else {
            return ctx.err("append_log_claim_release: unknown option");
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wall = ctx.timestamp();
    const my_hlc = if (remote_hlc) |remote| claim_clock.observe(remote, wall) else claim_clock.now(wall);

    var attempts: usize = 0;
    while (attempts < MAX_GRANT_ATTEMPTS) : (attempts += 1) {
        const events = loadTaskEvents(arena, ctx.store, log_id, task_id) catch
            return ctx.err("append_log_claim_release: log scan failed");
        const st = foldTask(events, ctx.timestamp());
        if (st.grant_seq == 0)
            return ctx.err("append_log_claim_release: no active claim for task");
        if (!std.mem.eql(u8, st.winner, worker))
            return ctx.err("append_log_claim_release: only the claim winner may release");

        const payload = try releasePayload(arena, task_id, worker, outcome, my_hlc);
        const result = append_log.append(arena, ctx.store, log_id, payload, &.{}, .{}) catch |err| switch (err) {
            error.SequenceReuse => continue, // re-fold and re-verify before retrying
            else => return ctx.err("append_log_claim_release: append failed"),
        };
        return ctx.value(try std.fmt.allocPrint(
            arena,
            "{{\"released\":true,\"seq\":{d},\"outcome\":\"{s}\"}}",
            .{ result.seq, outcome },
        ));
    }
    return ctx.err("append_log_claim_release: append contention, retry");
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: append_log_claim_supersede              ║
// ╚═══════════════════════════════════════════════╝

pub fn supersedeExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "append_log_claim_supersede requires: <log_id> <task_id> <stale_seq>";
    const log_id = ctx.arg(0) orelse return ctx.err(usage);
    const task_id = ctx.arg(1) orelse return ctx.err(usage);
    const stale_seq = ctx.argInt(u64, 2) orelse return ctx.err(usage);
    if (ctx.argCount() != 3) return ctx.err(usage);
    if (log_id.len == 0 or task_id.len == 0 or stale_seq == 0) return ctx.err(usage);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var attempts: usize = 0;
    while (attempts < MAX_GRANT_ATTEMPTS) : (attempts += 1) {
        const events = loadTaskEvents(arena, ctx.store, log_id, task_id) catch
            return ctx.err("append_log_claim_supersede: log scan failed");

        var target: ?TaskEvent = null;
        for (events) |ev| {
            if (ev.kind == .grant and ev.seq == stale_seq) target = ev;
        }
        const stale_grant = target orelse
            return ctx.err("append_log_claim_supersede: stale_seq is not a claim.grant for this task");

        const now_ms = ctx.timestamp();
        const st = foldTask(events, now_ms);
        const replaced_by_newer = st.grant_seq != 0 and st.grant_seq != stale_seq;
        const lease_expired = stale_grant.lease_expires_ms <= now_ms;
        if (!replaced_by_newer and !lease_expired)
            return ctx.err("append_log_claim_supersede: claim is not stale");

        const payload = try supersedePayload(arena, task_id, stale_seq, claim_clock.now(now_ms));
        const result = append_log.append(arena, ctx.store, log_id, payload, &.{}, .{}) catch |err| switch (err) {
            error.SequenceReuse => continue,
            else => return ctx.err("append_log_claim_supersede: append failed"),
        };
        return ctx.value(try std.fmt.allocPrint(
            arena,
            "{{\"superseded\":true,\"seq\":{d},\"stale_seq\":{d}}}",
            .{ result.seq, stale_seq },
        ));
    }
    return ctx.err("append_log_claim_supersede: append contention, retry");
}

// ╔═══════════════════════════════════════════════╗
// ║  JSON payload / response builders              ║
// ╚═══════════════════════════════════════════════╝

fn requestPayload(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    worker: []const u8,
    hlc_value: u64,
    lease_ms: u64,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"claim.request\",\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"hlc\":\"");
    try appendHlcHex(&json, allocator, hlc_value);
    try json.appendSlice(allocator, "\",\"by\":");
    try appendJsonString(&json, allocator, worker);
    try json.appendSlice(allocator, ",\"lease_ms\":");
    try appendU64(&json, allocator, lease_ms);
    try json.appendSlice(allocator, "}");
    return json.toOwnedSlice(allocator);
}

fn grantPayload(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    winner: []const u8,
    winner_hlc: u64,
    granted_seq: u64,
    lease_expires_ms: u64,
    hlc_value: u64,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"claim.grant\",\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"winner\":");
    try appendJsonString(&json, allocator, winner);
    try json.appendSlice(allocator, ",\"winner_hlc\":\"");
    try appendHlcHex(&json, allocator, winner_hlc);
    try json.appendSlice(allocator, "\",\"granted_seq\":");
    try appendU64(&json, allocator, granted_seq);
    try json.appendSlice(allocator, ",\"lease_expires_ms\":");
    try appendU64(&json, allocator, lease_expires_ms);
    try json.appendSlice(allocator, ",\"hlc\":\"");
    try appendHlcHex(&json, allocator, hlc_value);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn releasePayload(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    worker: []const u8,
    outcome: []const u8,
    hlc_value: u64,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"claim.release\",\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"by\":");
    try appendJsonString(&json, allocator, worker);
    try json.appendSlice(allocator, ",\"outcome\":\"");
    try json.appendSlice(allocator, outcome);
    try json.appendSlice(allocator, "\",\"hlc\":\"");
    try appendHlcHex(&json, allocator, hlc_value);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn supersedePayload(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    stale_seq: u64,
    hlc_value: u64,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"task.superseded\",\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"stale_seq\":");
    try appendU64(&json, allocator, stale_seq);
    try json.appendSlice(allocator, ",\"hlc\":\"");
    try appendHlcHex(&json, allocator, hlc_value);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

const ClaimView = struct {
    granted: bool,
    state: TaskState.State,
    winner: ?[]const u8,
    winner_hlc: u64,
    request_seq: u64,
    grant_seq: u64,
    granted_seq: u64,
    lease_expires_ms: u64,
};

fn claimJson(allocator: std.mem.Allocator, task_id: []const u8, view: ClaimView) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"granted\":");
    try json.appendSlice(allocator, if (view.granted) "true" else "false");
    try json.appendSlice(allocator, ",\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"state\":\"");
    try json.appendSlice(allocator, stateName(view.state));
    try json.appendSlice(allocator, "\",\"winner\":");
    if (view.winner) |w| {
        try appendJsonString(&json, allocator, w);
        try json.appendSlice(allocator, ",\"winner_hlc\":\"");
        try appendHlcHex(&json, allocator, view.winner_hlc);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, "null,\"winner_hlc\":null");
    }
    try json.appendSlice(allocator, ",\"request_seq\":");
    try appendU64(&json, allocator, view.request_seq);
    try json.appendSlice(allocator, ",\"grant_seq\":");
    try appendU64(&json, allocator, view.grant_seq);
    try json.appendSlice(allocator, ",\"granted_seq\":");
    try appendU64(&json, allocator, view.granted_seq);
    try json.appendSlice(allocator, ",\"lease_expires_ms\":");
    try appendU64(&json, allocator, view.lease_expires_ms);
    try json.appendSlice(allocator, "}");
    return json.toOwnedSlice(allocator);
}

fn statusJson(allocator: std.mem.Allocator, task_id: []const u8, st: TaskState) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"task\":");
    try appendJsonString(&json, allocator, task_id);
    try json.appendSlice(allocator, ",\"state\":\"");
    try json.appendSlice(allocator, stateName(st.state));
    try json.appendSlice(allocator, "\",\"winner\":");
    if (st.grant_seq != 0) {
        try appendJsonString(&json, allocator, st.winner);
        try json.appendSlice(allocator, ",\"winner_hlc\":\"");
        try appendHlcHex(&json, allocator, st.winner_hlc);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, "null,\"winner_hlc\":null");
    }
    try json.appendSlice(allocator, ",\"grant_seq\":");
    try appendU64(&json, allocator, st.grant_seq);
    try json.appendSlice(allocator, ",\"granted_seq\":");
    try appendU64(&json, allocator, st.granted_seq);
    try json.appendSlice(allocator, ",\"lease_expires_ms\":");
    try appendU64(&json, allocator, st.lease_expires_ms);
    try json.appendSlice(allocator, ",\"requests\":");
    try appendU64(&json, allocator, st.requests);
    try json.appendSlice(allocator, ",\"candidate\":");
    if (st.candidate) |cand| {
        try appendJsonString(&json, allocator, cand.by);
        try json.appendSlice(allocator, ",\"candidate_seq\":");
        try appendU64(&json, allocator, cand.seq);
    } else {
        try json.appendSlice(allocator, "null,\"candidate_seq\":0");
    }
    try json.appendSlice(allocator, "}");
    return json.toOwnedSlice(allocator);
}

fn stateName(state: TaskState.State) []const u8 {
    return switch (state) {
        .open => "open",
        .claimed => "claimed",
        .released => "released",
        .expired => "expired",
    };
}

// ╔═══════════════════════════════════════════════╗
// ║  Small helpers                                 ║
// ╚═══════════════════════════════════════════════╝

fn parseHlcHex(hex: []const u8) ?u64 {
    if (hex.len == 0 or hex.len > 16) return null;
    return std.fmt.parseUnsigned(u64, hex, 16) catch null;
}

fn appendHlcHex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u64) !void {
    const alphabet = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    for (&buf, 0..) |*c, i| {
        const shift: u6 = @intCast((15 - i) * 4);
        c.* = alphabet[@intCast((v >> shift) & 0xf)];
    }
    try list.appendSlice(allocator, buf[0..]);
}

fn appendU64(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: u64) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

fn appendJsonString(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try list.append(allocator, '"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                try list.appendSlice(allocator, "\\u00");
                const alphabet = "0123456789abcdef";
                try list.append(allocator, alphabet[byte >> 4]);
                try list.append(allocator, alphabet[byte & 0x0f]);
            },
            else => try list.append(allocator, byte),
        }
    }
    try list.append(allocator, '"');
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

const Response = @import("../core/types.zig").Response;

fn runProc(store: *Store, func: *const fn (*Ctx) anyerror!Response, args: []const []const u8, allocator: std.mem.Allocator) !Response {
    var ctx = Ctx.init(store, args, allocator, null, null, null, null);
    defer ctx.deinit();
    return try func(&ctx);
}

fn injectEvent(allocator: std.mem.Allocator, store: *Store, log_id: []const u8, payload: []const u8) !u64 {
    var result = try append_log.append(allocator, store, log_id, payload, &.{}, .{});
    defer result.deinit(allocator);
    return result.seq;
}

fn extractJsonU64(json: []const u8, field: []const u8) ?u64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const pos = start + needle.len;
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseUnsigned(u64, json[pos..end], 10) catch null;
}

test "foldTask: empty log is open" {
    const testing = std.testing;
    const st = foldTask(&.{}, 1000);
    try testing.expectEqual(TaskState.State.open, st.state);
    try testing.expectEqual(@as(usize, 0), st.requests);
    try testing.expect(st.candidate == null);
}

test "foldTask: deterministic winner by lowest hlc, then lowest seq" {
    const testing = std.testing;
    // Lower hlc wins even with a higher seq.
    const by_hlc = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x20, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .request, .by = "worker-b", .hlc = 0x10, .lease_ms = 1000 },
    };
    const st1 = foldTask(&by_hlc, 5);
    try testing.expectEqual(@as(usize, 2), st1.requests);
    try testing.expectEqualStrings("worker-b", st1.candidate.?.by);
    try testing.expectEqual(@as(u64, 2), st1.candidate.?.seq);

    // Tie on hlc: lower seq wins.
    const by_seq = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .request, .by = "worker-b", .hlc = 0x10, .lease_ms = 1000 },
    };
    const st2 = foldTask(&by_seq, 5);
    try testing.expectEqualStrings("worker-a", st2.candidate.?.by);
    try testing.expectEqual(@as(u64, 1), st2.candidate.?.seq);
}

test "foldTask: active grant is claimed, expired grant reopens for later requests" {
    const testing = std.testing;
    const events = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .grant, .at_ms = 100, .winner = "worker-a", .winner_hlc = 0x10, .granted_seq = 1, .lease_expires_ms = 5000 },
        .{ .seq = 3, .kind = .request, .by = "worker-b", .hlc = 0x05, .lease_ms = 1000 },
    };
    // Lease still active: claimed by worker-a, no candidate.
    const active = foldTask(&events, 4000);
    try testing.expectEqual(TaskState.State.claimed, active.state);
    try testing.expectEqualStrings("worker-a", active.winner);
    try testing.expectEqual(@as(u64, 2), active.grant_seq);
    try testing.expectEqual(@as(u64, 1), active.granted_seq);
    try testing.expect(active.candidate == null);

    // Lease expired: the grant is ignored in arbitration; worker-b's queued
    // request (appended after the grant) becomes the candidate.
    const expired = foldTask(&events, 6000);
    try testing.expectEqual(TaskState.State.expired, expired.state);
    try testing.expectEqualStrings("worker-a", expired.winner);
    try testing.expectEqualStrings("worker-b", expired.candidate.?.by);
    try testing.expectEqual(@as(u64, 3), expired.candidate.?.seq);
}

test "foldTask: release by winner starts a new epoch, non-winner release ignored" {
    const testing = std.testing;
    const base = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .grant, .at_ms = 100, .winner = "worker-a", .winner_hlc = 0x10, .granted_seq = 1, .lease_expires_ms = 999_999 },
        .{ .seq = 3, .kind = .release, .by = "worker-x" }, // not the winner: ignored
    };
    const still = foldTask(&base, 500);
    try testing.expectEqual(TaskState.State.claimed, still.state);

    const released = [_]TaskEvent{
        base[0],
        base[1],
        .{ .seq = 3, .kind = .release, .by = "worker-a" },
        .{ .seq = 4, .kind = .request, .by = "worker-b", .hlc = 0x99, .lease_ms = 1000 },
    };
    const st = foldTask(released[0..3], 500);
    try testing.expectEqual(TaskState.State.released, st.state);
    try testing.expectEqual(@as(u64, 0), st.grant_seq);
    try testing.expectEqual(@as(usize, 0), st.requests);

    // A request after the release starts competing in the fresh epoch.
    const next = foldTask(&released, 500);
    try testing.expectEqualStrings("worker-b", next.candidate.?.by);
    try testing.expectEqual(@as(usize, 1), next.requests);
}

test "foldTask: supersede resets only when stale_seq matches the current grant" {
    const testing = std.testing;
    const events = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .grant, .at_ms = 100, .winner = "worker-a", .winner_hlc = 0x10, .granted_seq = 1, .lease_expires_ms = 200 },
        .{ .seq = 3, .kind = .superseded, .stale_seq = 99 }, // wrong seq: ignored
    };
    const unchanged = foldTask(&events, 150);
    try testing.expectEqual(TaskState.State.claimed, unchanged.state);

    const matched = [_]TaskEvent{
        events[0],
        events[1],
        .{ .seq = 3, .kind = .superseded, .stale_seq = 2 },
    };
    const st = foldTask(&matched, 150);
    try testing.expectEqual(TaskState.State.open, st.state);
    try testing.expectEqual(@as(u64, 0), st.grant_seq);
    try testing.expectEqual(@as(u64, 3), st.epoch_start_seq);
}

test "foldTask: exactly one grant per epoch — duplicates ignored, post-expiry replacement honored" {
    const testing = std.testing;
    // A racing duplicate grant (old lease still active at its receipt) is ignored.
    const dup = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .grant, .at_ms = 100, .winner = "worker-a", .winner_hlc = 0x10, .granted_seq = 1, .lease_expires_ms = 999_999 },
        .{ .seq = 3, .kind = .grant, .at_ms = 101, .winner = "worker-b", .winner_hlc = 0x20, .granted_seq = 1, .lease_expires_ms = 999_999 },
    };
    const first_wins = foldTask(&dup, 500);
    try testing.expectEqualStrings("worker-a", first_wins.winner);
    try testing.expectEqual(@as(u64, 2), first_wins.grant_seq);

    // A grant received AFTER the previous lease expired replaces it (epoch rollover).
    const rollover = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .grant, .at_ms = 100, .winner = "worker-a", .winner_hlc = 0x10, .granted_seq = 1, .lease_expires_ms = 200 },
        .{ .seq = 3, .kind = .request, .by = "worker-b", .hlc = 0x20, .lease_ms = 1000 },
        .{ .seq = 4, .kind = .grant, .at_ms = 300, .winner = "worker-b", .winner_hlc = 0x20, .granted_seq = 3, .lease_expires_ms = 999_999 },
    };
    const st = foldTask(&rollover, 500);
    try testing.expectEqual(TaskState.State.claimed, st.state);
    try testing.expectEqualStrings("worker-b", st.winner);
    try testing.expectEqual(@as(u64, 4), st.grant_seq);
    try testing.expectEqual(@as(u64, 3), st.granted_seq);
}

test "foldTask: task.open starts a fresh epoch" {
    const testing = std.testing;
    const events = [_]TaskEvent{
        .{ .seq = 1, .kind = .request, .by = "worker-a", .hlc = 0x10, .lease_ms = 1000 },
        .{ .seq = 2, .kind = .open },
        .{ .seq = 3, .kind = .request, .by = "worker-b", .hlc = 0x99, .lease_ms = 1000 },
    };
    const st = foldTask(&events, 500);
    try testing.expectEqual(TaskState.State.open, st.state);
    try testing.expectEqual(@as(usize, 1), st.requests);
    try testing.expectEqualStrings("worker-b", st.candidate.?.by);
}

test "claim: winner grants deterministically, loser sees the winner" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // worker-a's claim.request is already on the log with a very low HLC —
    // it is the deterministic winner regardless of who arbitrates first.
    _ = try injectEvent(allocator, &store,
        "coord:test",
        "{\"t\":\"claim.request\",\"task\":\"task-1\",\"hlc\":\"0000000000000010\",\"by\":\"worker-a\",\"lease_ms\":3600000}",
    );

    // worker-b claims: it appends its own request (wall-clock HLC, far above
    // 0x10), arbitrates, and loses to the pending winner worker-a.
    const lost = try runProc(&store, claimExecute, &.{ "coord:test", "task-1", "worker-b" }, allocator);
    const lost_value = lost.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, lost_value, 1, "\"granted\":false"));
    try testing.expect(std.mem.containsAtLeast(u8, lost_value, 1, "\"winner\":\"worker-a\""));
    try testing.expectEqual(@as(u64, 0), extractJsonU64(lost_value, "grant_seq").?);

    // worker-a claims: arbitration picks its seq-1 request and lands the grant.
    const won = try runProc(&store, claimExecute, &.{ "coord:test", "task-1", "worker-a" }, allocator);
    const won_value = won.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"granted\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"winner\":\"worker-a\""));
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"state\":\"claimed\""));
    try testing.expectEqual(@as(u64, 1), extractJsonU64(won_value, "granted_seq").?);
    try testing.expect(extractJsonU64(won_value, "grant_seq").? > 0);

    // A later claim by worker-b sees the actual grant on the log.
    const late = try runProc(&store, claimExecute, &.{ "coord:test", "task-1", "worker-b" }, allocator);
    const late_value = late.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, late_value, 1, "\"granted\":false"));
    try testing.expect(std.mem.containsAtLeast(u8, late_value, 1, "\"winner\":\"worker-a\""));
    try testing.expect(std.mem.containsAtLeast(u8, late_value, 1, "\"state\":\"claimed\""));

    // Status fold agrees.
    const status = try runProc(&store, statusExecute, &.{ "coord:test", "task-1" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"state\":\"claimed\""));
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"winner\":\"worker-a\""));
}

test "claim: expired lease reopens the task for a new claim" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // worker-a held the task, but the lease expired long ago (epoch ms 1).
    _ = try injectEvent(allocator, &store,
        "coord:test",
        "{\"t\":\"claim.request\",\"task\":\"task-2\",\"hlc\":\"0000000000000010\",\"by\":\"worker-a\",\"lease_ms\":1}",
    );
    _ = try injectEvent(allocator, &store,
        "coord:test",
        "{\"t\":\"claim.grant\",\"task\":\"task-2\",\"winner\":\"worker-a\",\"winner_hlc\":\"0000000000000010\",\"granted_seq\":1,\"lease_expires_ms\":1,\"hlc\":\"0000000000000011\"}",
    );

    // worker-b claims after expiry: the stale grant is ignored and worker-b
    // wins the new epoch.
    const won = try runProc(&store, claimExecute, &.{ "coord:test", "task-2", "worker-b", "lease_ms=3600000" }, allocator);
    const won_value = won.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"granted\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"winner\":\"worker-b\""));

    const status = try runProc(&store, statusExecute, &.{ "coord:test", "task-2" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"state\":\"claimed\""));
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"winner\":\"worker-b\""));
}

test "release: winner reopens the task, non-winner is rejected" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const won = try runProc(&store, claimExecute, &.{ "coord:test", "task-3", "worker-a", "lease_ms=3600000" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, won.value.?, 1, "\"granted\":true"));

    // Non-winner may not release.
    const denied = try runProc(&store, releaseExecute, &.{ "coord:test", "task-3", "worker-b", "applied" }, allocator);
    try testing.expectEqualStrings("append_log_claim_release: only the claim winner may release", denied.err);

    // Bad outcome is rejected.
    const bad = try runProc(&store, releaseExecute, &.{ "coord:test", "task-3", "worker-a", "done" }, allocator);
    try testing.expectEqualStrings("append_log_claim_release: outcome must be applied|failed|blocked", bad.err);

    // Winner releases with an outcome.
    const released = try runProc(&store, releaseExecute, &.{ "coord:test", "task-3", "worker-a", "applied" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, released.value.?, 1, "\"released\":true"));

    const status = try runProc(&store, statusExecute, &.{ "coord:test", "task-3" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"state\":\"released\""));

    // Double release: the epoch has no active claim any more.
    const again = try runProc(&store, releaseExecute, &.{ "coord:test", "task-3", "worker-a", "applied" }, allocator);
    try testing.expectEqualStrings("append_log_claim_release: no active claim for task", again.err);

    // The task is claimable again in the fresh epoch.
    const reclaimed = try runProc(&store, claimExecute, &.{ "coord:test", "task-3", "worker-b", "lease_ms=3600000" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, reclaimed.value.?, 1, "\"granted\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, reclaimed.value.?, 1, "\"winner\":\"worker-b\""));
}

test "supersede: stale grant is marked, active grant is protected" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A grant whose lease expired at epoch ms 1 — a worker rejoining from a
    // partition would still believe it holds this claim.
    _ = try injectEvent(allocator, &store,
        "coord:test",
        "{\"t\":\"claim.request\",\"task\":\"task-4\",\"hlc\":\"0000000000000010\",\"by\":\"worker-a\",\"lease_ms\":1}",
    );
    const stale_grant_seq = try injectEvent(allocator, &store,
        "coord:test",
        "{\"t\":\"claim.grant\",\"task\":\"task-4\",\"winner\":\"worker-a\",\"winner_hlc\":\"0000000000000010\",\"granted_seq\":1,\"lease_expires_ms\":1,\"hlc\":\"0000000000000011\"}",
    );

    // Unknown seq is rejected.
    const missing = try runProc(&store, supersedeExecute, &.{ "coord:test", "task-4", "99" }, allocator);
    try testing.expectEqualStrings("append_log_claim_supersede: stale_seq is not a claim.grant for this task", missing.err);

    var seq_buf: [20]u8 = undefined;
    const stale_seq_arg = try std.fmt.bufPrint(&seq_buf, "{d}", .{stale_grant_seq});
    const marked = try runProc(&store, supersedeExecute, &.{ "coord:test", "task-4", stale_seq_arg }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, marked.value.?, 1, "\"superseded\":true"));

    // The fold shows the task reopened; the rejoining worker's claim is gone.
    const status = try runProc(&store, statusExecute, &.{ "coord:test", "task-4" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, status.value.?, 1, "\"state\":\"open\""));
    const rejoin_release = try runProc(&store, releaseExecute, &.{ "coord:test", "task-4", "worker-a", "applied" }, allocator);
    try testing.expectEqualStrings("append_log_claim_release: no active claim for task", rejoin_release.err);

    // An ACTIVE grant may not be superseded.
    const won = try runProc(&store, claimExecute, &.{ "coord:test", "task-4", "worker-b", "lease_ms=3600000" }, allocator);
    const won_value = won.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, won_value, 1, "\"granted\":true"));
    const active_grant_seq = extractJsonU64(won_value, "grant_seq").?;
    var active_buf: [20]u8 = undefined;
    const active_arg = try std.fmt.bufPrint(&active_buf, "{d}", .{active_grant_seq});
    const protected = try runProc(&store, supersedeExecute, &.{ "coord:test", "task-4", active_arg }, allocator);
    try testing.expectEqualStrings("append_log_claim_supersede: claim is not stale", protected.err);
}

test "claim_status: unknown task folds to open with zero requests" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const status = try runProc(&store, statusExecute, &.{ "coord:test", "no-such-task" }, allocator);
    const value = status.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"state\":\"open\""));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"requests\":0"));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"winner\":null"));
}

test "claim: observes a caller-supplied hlc and stays deterministic" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Sole claimer with an explicit hlc wins its own epoch.
    const won = try runProc(&store, claimExecute, &.{ "coord:test", "task-5", "worker-a", "lease_ms=3600000", "hlc=0000000000000001" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, won.value.?, 1, "\"granted\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, won.value.?, 1, "\"winner\":\"worker-a\""));

    // Malformed hlc is rejected.
    const bad = try runProc(&store, claimExecute, &.{ "coord:test", "task-5", "worker-a", "hlc=zz" }, allocator);
    try testing.expectEqualStrings("append_log_claim: invalid hlc=<hex16>", bad.err);
}
