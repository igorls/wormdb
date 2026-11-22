//! TCP server implementation

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const procedures = @import("../procedures/mod.zig");
const executor = @import("executor.zig");

const Store = storage.Store;
const EventBus = event.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;
const vector_ops = @import("../procedures/vector_ops.zig");
const Metric = @import("../vector/metric.zig").Metric;
const AuthMintConfig = @import("../procedures/context.zig").AuthMintConfig;
const auth = @import("auth.zig");
const org_trust_mod = @import("../cluster/org_trust.zig");
const secure_channel = @import("../cluster/secure_channel.zig");
const ServerMetrics = @import("metrics.zig").ServerMetrics;
const ConnectionLimit = @import("connection_limit.zig").ConnectionLimit;
const IpLimiter = @import("connection_limit.zig").IpLimiter;
const CommandRateLimiter = @import("connection_limit.zig").CommandRateLimiter;

/// Fallback trust when no org_trust is configured: enforce=false, zero grants.
/// A W2 handshake verified against it always fails OrgNotTrusted (deny-by-default).
const EMPTY_ORG_TRUST = org_trust_mod.OrgTrust{};

pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 6389,
    max_connections: usize = 1024,
    /// Whole handshake/frame deadline, including time in the accept queue.
    timeout_ms: usize = 30000,
    cluster: ?*Cluster = null,
    vector_registry: ?*@import("../vector/index.zig").NamespaceRegistry = null,
    /// Number of worker threads. 0 = auto (cpu_count * 2, capped at 64).
    worker_count: usize = 0,
    /// Max concurrent connections per peer IP. 0 = unlimited (NAT'd fleets and
    /// localhost benches share one address — see `gateway.max_connections_per_ip`).
    max_connections_per_ip: u32 = 0,
    /// Skip the per-IP cap for loopback peers.
    per_ip_exempt_loopback: bool = true,
    /// Per-connection command rate limit (frames per second); 0 = unlimited.
    max_commands_per_sec: u32 = 0,
    /// Whether this binary listener enforces auth. Set by the composition root to
    /// `cfg.auth.require_auth && cfg.server.auth_enabled`. Binary connections authenticate with
    /// an AUTH frame (verified against `auth_public_keys`); enforce ⇒ protected commands fail
    /// closed until a valid token is presented. Default false keeps unit tests (which never
    /// authenticate) working; the composition root sets the secure value.
    auth_enforce: bool = false,
    /// Ed25519 public keys for SCT verification on the binary path. Empty means AUTH cannot
    /// succeed ("auth not configured", mirroring the WS gateway); it does NOT disable
    /// enforcement — commands are still rejected while `auth_enforce` is true (fail closed).
    auth_public_keys: []const auth.PublicKey = &.{},
    /// Maximum token lifetime in seconds (0 = no limit).
    auth_max_token_age: u64 = 0,
    /// Optional server-side SCT minting config.
    auth_mint: ?AuthMintConfig = null,
    /// Optional shared liveness/concurrency counters surfaced by STATUS.
    metrics: ?*ServerMetrics = null,
    /// Org trust for the replication channel (#63). Null or `enforce=false`
    /// keeps legacy behavior: unauthenticated "WR" connections are accepted.
    /// When enforcing: "WR" is rejected loudly, "W2" requires the org-cert
    /// challenge handshake, and every replicated key is checked against the
    /// peer org's granted prefixes.
    org_trust: ?*const org_trust_mod.OrgTrust = null,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    config: ServerConfig,
    metrics: ?*ServerMetrics,
    running: std.atomic.Value(bool),

    // Thread pool infrastructure
    conn_queue: ConnQueue,
    workers: []std.Thread,
    connection_limit: ConnectionLimit = .{},
    ip_limiter: IpLimiter,
    sub_reactor: ?*SubReactor = null,

    const CONN_QUEUE_CAP = 4096;

    /// An accepted connection or a resumed parked-subscriber session awaiting worker pickup.
    const QueuedConn = union(enum) {
        accepted: struct {
            conn: core.compat.net.ServerCompat.Connection,
            ip_key: ?IpLimiter.Key = null,
        },
        resumed: *SubSession,
    };

    /// Bounded queue for accepted connections awaiting worker pickup.
    const ConnQueue = struct {
        items: [CONN_QUEUE_CAP]QueuedConn = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: core.compat.Mutex = .{},
        futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn push(self: *ConnQueue, conn: QueuedConn) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count >= CONN_QUEUE_CAP) return false;
            self.items[self.tail] = conn;
            self.tail = (self.tail + 1) % CONN_QUEUE_CAP;
            self.count += 1;
            // Wake one worker
            _ = self.futex.fetchAdd(1, .release);
            core.compat.Futex.wake(&self.futex, 1);
            return true;
        }

        fn pop(self: *ConnQueue) ?QueuedConn {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const conn = self.items[self.head];
            self.head = (self.head + 1) % CONN_QUEUE_CAP;
            self.count -= 1;
            return conn;
        }

        fn len(self: *ConnQueue) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }
    };

    const TEXT_READ_BUF_SIZE = 16384;
    /// Send deadline for ONE event frame on the publish path. A subscriber whose
    /// socket cannot take a frame within this window is evicted (see
    /// `ConnectionContext.evictStalled`), so a publisher stalls at most once,
    /// briefly, per stalled subscriber — not for every publish until its token
    /// expires. Command responses keep the connection's 2 s write timeout.
    const EVENT_SEND_TIMEOUT_MS: usize = 500;
    /// Largest frame payload accepted before AUTH succeeds on an enforcing
    /// listener: an SCT is well under 1 KiB, so an anonymous peer never gets
    /// to reserve megabytes per connection by announcing a large frame (B3).
    const PRE_AUTH_MAX_PAYLOAD: usize = 16 * 1024;
    /// Per-connection arena memory kept across commands; anything beyond is
    /// returned after a large frame instead of staying mapped for the
    /// connection's lifetime.
    const ARENA_RETAIN_LIMIT: usize = 256 * 1024;

    /// Maximum buffered outbound event bytes per subscriber before evicting as stalled.
    /// Absorbs high-rate pipelined publish bursts without dropping events while capping RAM.
    const MAX_SUB_OUT_BUF: usize = 4 * 1024 * 1024;
    const SUB_OUT_INIT_CAP: usize = 16 * 1024;

    /// Heap-owned binary connection state that can be parked off the worker threadpool
    /// onto `SubReactor` while idle on Pub/Sub subscriptions, then resumed on any worker
    /// if the client later sends another frame (`UNSUB`, `SUB`, `PING`, etc.).
    const SubSession = struct {
        stream: core.compat.net.Stream,
        ip_key: ?IpLimiter.Key,
        conn_ctx: ConnectionContext,
        metrics_shard: usize,
        has_metrics: bool = false,
        /// Reactor-owned active send buffer (swapped O(1) from `conn_ctx.out_buf`).
        flush_buf: std.ArrayListUnmanaged(u8) = .empty,
        flush_pos: usize = 0,
        stalled_since_ns: ?i128 = null,
        epoll_out_armed: bool = false,
        reaping: bool = false,
    };

    /// Dedicated Linux epoll + eventfd reactor for parked Pub/Sub subscribers.
    /// Eliminates fixed threadpool starvation (>worker_count idle subscribers pin 0 workers)
    /// and coalesces pipelined publish bursts into single non-blocking `send()` syscalls.
    const SubReactor = if (builtin.os.tag == .linux) struct {
        const linux = std.os.linux;
        const posix = std.posix;
        const WAKE_TAG: u64 = std.math.maxInt(u64);
        const MAX_EVENTS: usize = 256;

        server: *Server,
        allocator: std.mem.Allocator,
        epoll_fd: posix.fd_t,
        wake_fd: posix.fd_t,
        running: std.atomic.Value(bool) = .init(true),
        sleeping: std.atomic.Value(bool) = .init(false),

        park_mutex: core.compat.Mutex = .{},
        park_list: std.ArrayListUnmanaged(*SubSession) = .empty,

        dirty_mutex: core.compat.Mutex = .{},
        dirty_list: std.ArrayListUnmanaged(*SubSession) = .empty,

        /// Owned strictly by `reactorLoop` (no mutex required).
        parked_set: std.AutoHashMapUnmanaged(posix.fd_t, *SubSession) = .empty,
        reap_list: std.ArrayListUnmanaged(*SubSession) = .empty,
        thread: ?std.Thread = null,

        fn create(server: *Server) !*SubReactor {
            const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (posix.errno(ep_rc) != .SUCCESS) return error.EpollCreateFailed;
            const epoll_fd: posix.fd_t = @intCast(ep_rc);
            errdefer core.compat.close(epoll_fd);

            const wf_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
            if (posix.errno(wf_rc) != .SUCCESS) return error.EventFdCreateFailed;
            const wake_fd: posix.fd_t = @intCast(wf_rc);
            errdefer core.compat.close(wake_fd);

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .u64 = WAKE_TAG },
            };
            const ctl_rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wake_fd, &ev);
            if (posix.errno(ctl_rc) != .SUCCESS) return error.EpollCtlFailed;

            const self = try server.allocator.create(SubReactor);
            errdefer server.allocator.destroy(self);
            self.* = .{
                .server = server,
                .allocator = server.allocator,
                .epoll_fd = epoll_fd,
                .wake_fd = wake_fd,
            };
            self.thread = try std.Thread.spawn(.{}, reactorLoop, .{self});
            return self;
        }

        fn stopAndDestroy(self: *SubReactor) void {
            self.running.store(false, .seq_cst);
            self.wakeForce();
            if (self.thread) |t| t.join();
            self.thread = null;

            self.park_list.deinit(self.allocator);
            self.dirty_list.deinit(self.allocator);
            self.parked_set.deinit(self.allocator);
            self.reap_list.deinit(self.allocator);
            core.compat.close(self.wake_fd);
            core.compat.close(self.epoll_fd);
            self.allocator.destroy(self);
        }

        inline fn wakeIfSleeping(self: *SubReactor) void {
            if (self.sleeping.load(.seq_cst)) {
                if (self.sleeping.swap(false, .acq_rel)) {
                    self.wakeForce();
                }
            }
        }

        fn wakeForce(self: *SubReactor) void {
            var one: u64 = 1;
            _ = std.c.write(self.wake_fd, @ptrCast(&one), @sizeOf(u64));
        }

        fn drainWakeFd(self: *SubReactor) void {
            var val: u64 = 0;
            while (true) {
                const rc = std.c.read(self.wake_fd, @ptrCast(&val), @sizeOf(u64));
                if (rc <= 0) break;
            }
        }

        /// Hand ownership of an idle subscribed session from a worker thread to the reactor.
        fn park(self: *SubReactor, session: *SubSession) bool {
            if (!self.running.load(.acquire)) return false;
            self.park_mutex.lock();
            self.park_list.append(self.allocator, session) catch {
                self.park_mutex.unlock();
                return false;
            };
            self.park_mutex.unlock();
            self.wakeIfSleeping();
            return true;
        }

        /// Enqueue a session with new outbound event bytes for coalesced async flushing.
        /// Caller must hold an active `in_flight` retain; this function takes an extra
        /// retain released by `reactorLoop` once the dirty entry is processed.
        fn enqueueFlush(self: *SubReactor, session: *SubSession) void {
            ConnectionContext.retain(@ptrCast(&session.conn_ctx));
            self.dirty_mutex.lock();
            self.dirty_list.append(self.allocator, session) catch {
                self.dirty_mutex.unlock();
                session.conn_ctx.out_queued.store(false, .release);
                ConnectionContext.release(@ptrCast(&session.conn_ctx));
                return;
            };
            self.dirty_mutex.unlock();
            self.wakeIfSleeping();
        }

        fn hasQueuedWork(self: *SubReactor) bool {
            self.dirty_mutex.lock();
            const has_dirty = self.dirty_list.items.len > 0;
            self.dirty_mutex.unlock();
            if (has_dirty) return true;
            self.park_mutex.lock();
            const has_park = self.park_list.items.len > 0;
            self.park_mutex.unlock();
            return has_park;
        }

        fn modEpollOut(self: *SubReactor, session: *SubSession, want_out: bool) void {
            if (session.epoll_out_armed == want_out) return;
            const fd = session.stream.getHandle();
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | (if (want_out) @as(u32, linux.EPOLL.OUT) else @as(u32, 0)),
                .data = .{ .u64 = @intFromPtr(session) },
            };
            const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
            if (posix.errno(rc) == .SUCCESS) {
                session.epoll_out_armed = want_out;
            }
        }

        fn beginReap(self: *SubReactor, session: *SubSession) void {
            if (session.reaping) return;
            session.reaping = true;
            const fd = session.stream.getHandle();
            if (self.parked_set.remove(fd)) {
                _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            }
            session.conn_ctx.parked.store(false, .release);
            session.conn_ctx.closed.store(true, .release);
            session.conn_ctx.unsubscribeAll();
            session.stream.shutdown();
            self.reap_list.append(self.allocator, session) catch {
                // Fallback: wait synchronously only on OOM
                self.server.destroySession(session);
            };
        }

        fn tryCompleteReaps(self: *SubReactor) void {
            var i: usize = 0;
            while (i < self.reap_list.items.len) {
                const sess = self.reap_list.items[i];
                if (sess.conn_ctx.in_flight.load(.acquire) == 0) {
                    _ = self.reap_list.swapRemove(i);
                    self.server.destroySession(sess);
                } else {
                    i += 1;
                }
            }
        }

        fn drainSessionOut(self: *SubReactor, session: *SubSession) void {
            if (session.reaping) return;
            if (!session.conn_ctx.parked.load(.acquire)) return;
            if (session.conn_ctx.closed.load(.acquire)) {
                self.beginReap(session);
                return;
            }

            const fd = session.stream.getHandle();
            const send_flags: u32 = linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL;

            while (true) {
                if (session.flush_pos >= session.flush_buf.items.len) {
                    session.flush_buf.clearRetainingCapacity();
                    session.flush_pos = 0;
                    session.conn_ctx.out_mutex.lock();
                    if (session.conn_ctx.out_buf.items.len > 0) {
                        std.mem.swap(std.ArrayListUnmanaged(u8), &session.flush_buf, &session.conn_ctx.out_buf);
                    }
                    session.conn_ctx.out_mutex.unlock();
                    if (session.flush_buf.items.len == 0) {
                        session.stalled_since_ns = null;
                        self.modEpollOut(session, false);
                        return;
                    }
                }

                const pending = session.flush_buf.items[session.flush_pos..];
                const rc = std.c.send(fd, pending.ptr, pending.len, send_flags);
                if (rc > 0) {
                    session.flush_pos += @intCast(rc);
                    session.stalled_since_ns = null;
                    continue;
                }
                if (rc == 0) {
                    self.beginReap(session);
                    return;
                }
                const err = posix.errno(rc);
                switch (err) {
                    .INTR => continue,
                    .AGAIN => {
                        const now = core.compat.nowNs();
                        if (session.stalled_since_ns) |since| {
                            if (now - since >= @as(i128, EVENT_SEND_TIMEOUT_MS) * 1_000_000) {
                                session.conn_ctx.event_bus.recordEviction();
                                std.log.warn("evicted stalled subscriber (WouldBlock timeout)", .{});
                                self.beginReap(session);
                                return;
                            }
                        } else {
                            session.stalled_since_ns = now;
                        }
                        self.modEpollOut(session, true);
                        return;
                    },
                    else => {
                        session.conn_ctx.event_bus.recordEviction();
                        std.log.warn("evicted stalled subscriber ({s})", .{@tagName(err)});
                        self.beginReap(session);
                        return;
                    },
                }
            }
        }

        fn unparkToWorker(self: *SubReactor, session: *SubSession) void {
            const fd = session.stream.getHandle();
            _ = self.parked_set.remove(fd);
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            session.epoll_out_armed = false;
            session.conn_ctx.parked.store(false, .release);

            if (!self.server.running.load(.acquire)) {
                self.beginReap(session);
                return;
            }
            if (!self.server.conn_queue.push(.{ .resumed = session })) {
                std.log.warn("Connection queue full on subscriber resume, closing", .{});
                self.beginReap(session);
                return;
            }
            if (self.server.metrics) |m| m.setTcpConnectionQueueDepth(self.server.conn_queue.len());
        }

        fn reactorLoop(self: *SubReactor) void {
            var events: [MAX_EVENTS]linux.epoll_event = undefined;
            var local_park: std.ArrayListUnmanaged(*SubSession) = .empty;
            defer local_park.deinit(self.allocator);
            var local_dirty: std.ArrayListUnmanaged(*SubSession) = .empty;
            defer local_dirty.deinit(self.allocator);
            var last_sweep_ns = core.compat.nowNs();

            while (self.running.load(.acquire)) {
                // 1. Register newly parked subscriber sessions.
                self.park_mutex.lock();
                if (self.park_list.items.len > 0) {
                    std.mem.swap(std.ArrayListUnmanaged(*SubSession), &local_park, &self.park_list);
                }
                self.park_mutex.unlock();

                for (local_park.items) |session| {
                    const auth_expired = session.conn_ctx.auth_enforce and
                        (if (session.conn_ctx.auth_state) |*st| st.isExpired() else true);
                    if (session.conn_ctx.closed.load(.acquire) or auth_expired) {
                        self.beginReap(session);
                        continue;
                    }
                    const fd = session.stream.getHandle();
                    var ev = linux.epoll_event{
                        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                        .data = .{ .u64 = @intFromPtr(session) },
                    };
                    const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
                    if (posix.errno(rc) != .SUCCESS) {
                        self.beginReap(session);
                        continue;
                    }
                    self.parked_set.put(self.allocator, fd, session) catch {
                        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
                        self.beginReap(session);
                        continue;
                    };
                    session.epoll_out_armed = false;
                    session.conn_ctx.parked.store(true, .release);
                    // Flush any events queued while the worker was flushing +OK.
                    self.drainSessionOut(session);
                }
                local_park.clearRetainingCapacity();

                // 2. Drain coalesced outbound event batches for all dirty subscribers.
                self.dirty_mutex.lock();
                if (self.dirty_list.items.len > 0) {
                    std.mem.swap(std.ArrayListUnmanaged(*SubSession), &local_dirty, &self.dirty_list);
                }
                self.dirty_mutex.unlock();

                for (local_dirty.items) |session| {
                    session.conn_ctx.out_queued.store(false, .release);
                    self.drainSessionOut(session);
                    ConnectionContext.release(@ptrCast(&session.conn_ctx));
                }
                local_dirty.clearRetainingCapacity();

                // 3. Reap any closed sessions whose in-flight publish refs have hit 0.
                if (self.reap_list.items.len > 0) self.tryCompleteReaps();

                // 4. Periodic sweep (every 50 ms) for stalled EPOLLOUT timeouts & auth expiry.
                const now = core.compat.nowNs();
                if (now - last_sweep_ns >= 50_000_000) {
                    last_sweep_ns = now;
                    var to_evict: [64]*SubSession = undefined;
                    var evict_n: usize = 0;
                    var it = self.parked_set.valueIterator();
                    while (it.next()) |sp| {
                        const sess = sp.*;
                        if (sess.conn_ctx.closed.load(.acquire)) {
                            if (evict_n < to_evict.len) {
                                to_evict[evict_n] = sess;
                                evict_n += 1;
                            }
                            continue;
                        }
                        if (sess.conn_ctx.auth_enforce) {
                            const auth_expired = if (sess.conn_ctx.auth_state) |*st| st.isExpired() else true;
                            if (auth_expired) {
                                if (evict_n < to_evict.len) {
                                    to_evict[evict_n] = sess;
                                    evict_n += 1;
                                }
                                continue;
                            }
                        }
                        if (sess.stalled_since_ns) |since| {
                            if (now - since >= @as(i128, EVENT_SEND_TIMEOUT_MS) * 1_000_000) {
                                sess.conn_ctx.event_bus.recordEviction();
                                std.log.warn("evicted stalled subscriber (send deadline exceeded)", .{});
                                if (evict_n < to_evict.len) {
                                    to_evict[evict_n] = sess;
                                    evict_n += 1;
                                }
                            }
                        }
                    }
                    for (to_evict[0..evict_n]) |sess| self.beginReap(sess);
                    if (self.reap_list.items.len > 0) self.tryCompleteReaps();
                }

                // 5. Dekker handshake before blocking in epoll_wait.
                self.sleeping.store(true, .seq_cst);
                if (self.hasQueuedWork() or !self.running.load(.seq_cst)) {
                    self.sleeping.store(false, .release);
                    continue;
                }

                const wait_ms: i32 = if (self.reap_list.items.len > 0) 5 else 50;
                const rc = linux.epoll_wait(self.epoll_fd, &events, MAX_EVENTS, wait_ms);
                self.sleeping.store(false, .release);
                if (posix.errno(rc) != .SUCCESS) continue;
                const nfds: usize = rc;

                for (events[0..nfds]) |ev| {
                    if (ev.data.u64 == WAKE_TAG) {
                        self.drainWakeFd();
                        continue;
                    }
                    const session: *SubSession = @ptrFromInt(ev.data.u64);
                    const fd = session.stream.getHandle();
                    if (!self.parked_set.contains(fd)) continue;

                    if ((ev.events & linux.EPOLL.OUT) != 0) {
                        self.drainSessionOut(session);
                        if (!self.parked_set.contains(fd)) continue;
                    }
                    if (session.conn_ctx.closed.load(.acquire) or (ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0) {
                        self.beginReap(session);
                        continue;
                    }
                    if ((ev.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP)) != 0) {
                        var peek: [1]u8 = undefined;
                        const prc = std.c.recv(fd, &peek, 1, linux.MSG.PEEK | linux.MSG.DONTWAIT);
                        if (prc > 0) {
                            // Client sent a command (e.g. UNSUB, SUB, PING) — resume on worker.
                            self.unparkToWorker(session);
                        } else if (prc == 0) {
                            // Clean EOF — reap directly on reactor without touching a worker.
                            self.beginReap(session);
                        } else if (posix.errno(prc) != .AGAIN and posix.errno(prc) != .INTR) {
                            self.beginReap(session);
                        }
                    }
                }
            }

            // Shutdown cleanup: release any queued dirty refs, parked sessions, and reaps.
            self.dirty_mutex.lock();
            for (self.dirty_list.items) |session| {
                session.conn_ctx.out_queued.store(false, .release);
                ConnectionContext.release(@ptrCast(&session.conn_ctx));
            }
            self.dirty_list.clearRetainingCapacity();
            self.dirty_mutex.unlock();

            self.park_mutex.lock();
            for (self.park_list.items) |session| self.beginReap(session);
            self.park_list.clearRetainingCapacity();
            self.park_mutex.unlock();

            var remaining_parked: std.ArrayListUnmanaged(*SubSession) = .empty;
            defer remaining_parked.deinit(self.allocator);
            var it = self.parked_set.valueIterator();
            while (it.next()) |sp| remaining_parked.append(self.allocator, sp.*) catch {};
            for (remaining_parked.items) |session| self.beginReap(session);

            while (self.reap_list.items.len > 0) {
                self.tryCompleteReaps();
                if (self.reap_list.items.len > 0) std.Thread.yield() catch {};
            }
        }
    } else struct {
        fn stopAndDestroy(_: *@This()) void {}
        fn enqueueFlush(_: *@This(), _: *SubSession) void {}
        fn wakeIfSleeping(_: *@This()) void {}
    };

    const ConnectionContext = struct {
        allocator: std.mem.Allocator,
        event_bus: *EventBus,
        stream: ?*core.compat.net.Stream,
        write_capture: ?*std.ArrayListUnmanaged(u8),
        write_mutex: core.compat.Mutex,
        subscriptions: std.StringHashMap(u64),
        binary_mode: bool,
        /// Verified SCT token state, set by an AUTH frame. Heap-allocated from
        /// `allocator` (NOT the per-command arena — it must outlive commands).
        auth_state: ?auth.TokenState,
        auth_enforce: bool = false,
        /// Per-connection command budget; null = unlimited. Connection thread only.
        rate_limiter: ?CommandRateLimiter = null,
        closed: std.atomic.Value(bool) = .init(false),
        in_flight: std.atomic.Value(u32) = .init(0),
        /// Non-null when this connection is owned by a Linux `Server` with a `SubReactor`.
        reactor: ?*SubReactor = null,
        session: ?*SubSession = null,
        parked: std.atomic.Value(bool) = .init(false),
        /// Guards `out_buf` and `auth_state` reads on the async Pub/Sub path (never held across I/O).
        out_mutex: core.compat.Mutex = .{},
        out_buf: std.ArrayListUnmanaged(u8) = .empty,
        out_queued: std.atomic.Value(bool) = .init(false),

        fn init(allocator: std.mem.Allocator, event_bus: *EventBus, stream: ?*core.compat.net.Stream) ConnectionContext {
            return .{
                .allocator = allocator,
                .event_bus = event_bus,
                .stream = stream,
                .write_capture = null,
                .write_mutex = .{},
                .subscriptions = std.StringHashMap(u64).init(allocator),
                .binary_mode = false,
                .auth_state = null,
            };
        }

        fn initWithCapture(
            allocator: std.mem.Allocator,
            event_bus: *EventBus,
            stream: ?*core.compat.net.Stream,
            write_capture: *std.ArrayListUnmanaged(u8),
        ) ConnectionContext {
            return .{
                .allocator = allocator,
                .event_bus = event_bus,
                .stream = stream,
                .write_capture = write_capture,
                .write_mutex = .{},
                .subscriptions = std.StringHashMap(u64).init(allocator),
                .binary_mode = false,
                .auth_state = null,
            };
        }

        fn unsubscribeAll(self: *ConnectionContext) void {
            var iter = self.subscriptions.iterator();
            while (iter.next()) |entry| {
                const channel = entry.key_ptr.*;
                const sub_id = entry.value_ptr.*;
                self.event_bus.unsubscribe(channel, sub_id);
                self.allocator.free(channel);
            }
            self.subscriptions.clearRetainingCapacity();
        }

        fn deinit(self: *ConnectionContext) void {
            self.closed.store(true, .release);
            self.unsubscribeAll();
            self.subscriptions.deinit();
            self.clearAuthState();
            while (self.in_flight.load(.acquire) != 0) {
                std.Thread.yield() catch {};
            }
            self.out_buf.deinit(self.allocator);
        }

        fn retain(ctx: *anyopaque) void {
            const self: *ConnectionContext = @ptrCast(@alignCast(ctx));
            _ = self.in_flight.fetchAdd(1, .acquire);
        }

        fn release(ctx: *anyopaque) void {
            const self: *ConnectionContext = @ptrCast(@alignCast(ctx));
            _ = self.in_flight.fetchSub(1, .release);
        }

        fn clearAuthState(self: *ConnectionContext) void {
            self.replaceAuthState(null);
        }

        fn replaceAuthState(self: *ConnectionContext, next: ?auth.TokenState) void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            self.out_mutex.lock();
            defer self.out_mutex.unlock();
            if (self.auth_state) |*state| {
                auth.freeTokenState(self.allocator, state);
            }
            self.auth_state = next;
        }

        fn subscribe(self: *ConnectionContext, channel: []const u8, filter: ?[]const u8) !void {
            if (self.subscriptions.contains(channel)) {
                return;
            }

            const channel_copy = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(channel_copy);

            const sub_id = try self.event_bus.subscribeFilteredHooks(
                channel_copy,
                filter,
                null,
                @ptrCast(self),
                .{
                    .retain_fn = ConnectionContext.retain,
                    .release_fn = ConnectionContext.release,
                    .event_fn = ConnectionContext.writeExactEvent,
                },
            );
            errdefer self.event_bus.unsubscribe(channel_copy, sub_id);

            try self.subscriptions.put(channel_copy, sub_id);
        }

        fn unsubscribe(self: *ConnectionContext, channel: []const u8) void {
            if (self.subscriptions.fetchRemove(channel)) |removed| {
                self.event_bus.unsubscribe(removed.key, removed.value);
                self.allocator.free(removed.key);
            }
        }

        fn writeAllLocked(self: *ConnectionContext, data: []const u8) void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (self.write_capture) |capture| {
                capture.appendSlice(self.allocator, data) catch {};
            }

            if (self.stream) |stream| {
                stream.writeAll(data) catch {};
            }
        }

        fn writeExactEvent(ctx: *anyopaque, channel: []const u8, message: []const u8) void {
            const self: *ConnectionContext = @ptrCast(@alignCast(ctx));
            if (self.closed.load(.acquire)) return;

            // Async coalesced path (Linux Server with SubReactor): encode once,
            // append into per-subscriber ring under brief `out_mutex`, wake reactor.
            if (comptime builtin.os.tag == .linux) {
                if (self.binary_mode and self.reactor != null and self.session != null) {
                    const total_len = wire.eventFrameSize(channel.len, message.len);
                    var stack_buf: [4096]u8 = undefined;
                    var heap_buf: ?[]u8 = null;
                    defer if (heap_buf) |hb| self.allocator.free(hb);
                    const dst: []u8 = if (total_len <= stack_buf.len)
                        &stack_buf
                    else blk: {
                        const hb = self.allocator.alloc(u8, total_len) catch return;
                        heap_buf = hb;
                        break :blk hb;
                    };
                    const frame = wire.encodeEventFrame(dst, channel, message) catch return;

                    var evicted = false;
                    var need_queue = false;
                    {
                        self.out_mutex.lock();
                        defer self.out_mutex.unlock();
                        if (self.closed.load(.acquire)) return;
                        if (self.auth_enforce) {
                            const state = if (self.auth_state) |*s| s else return;
                            if (state.isExpired() or !state.permits(.subscribe, channel)) return;
                        }
                        if (self.out_buf.items.len + frame.len > MAX_SUB_OUT_BUF) {
                            self.closed.store(true, .release);
                            evicted = true;
                        } else {
                            if (self.out_buf.capacity == 0) {
                                self.out_buf.ensureTotalCapacity(self.allocator, @max(SUB_OUT_INIT_CAP, frame.len)) catch return;
                            }
                            self.out_buf.appendSlice(self.allocator, frame) catch return;
                            need_queue = !self.out_queued.swap(true, .acq_rel);
                        }
                    }

                    const reactor = self.reactor.?;
                    if (evicted) {
                        if (self.stream) |stream| stream.shutdown();
                        self.event_bus.recordEviction();
                        std.log.warn("evicted stalled subscriber (output buffer limit exceeded)", .{});
                        reactor.wakeIfSleeping();
                        return;
                    }
                    if (need_queue) {
                        reactor.enqueueFlush(self.session.?);
                    }
                    return;
                }
            }

            if (!self.write_mutex.tryLock()) {
                self.event_bus.recordDrop();
                return;
            }
            defer self.write_mutex.unlock();
            if (self.closed.load(.acquire)) return;
            if (self.auth_enforce) {
                const state = if (self.auth_state) |*s| s else return;
                if (state.isExpired() or !state.permits(.subscribe, channel)) return;
            }

            if (self.binary_mode) {
                if (self.stream) |stream| {
                    const saved = stream.write_timeout_ms;
                    stream.write_timeout_ms = EVENT_SEND_TIMEOUT_MS;
                    defer stream.write_timeout_ms = saved;
                    // Single-syscall coalesced binary event write (eliminates 5 writes/event).
                    const total_len = wire.eventFrameSize(channel.len, message.len);
                    var stack_buf: [4096]u8 = undefined;
                    if (total_len <= stack_buf.len) {
                        const frame = wire.encodeEventFrame(&stack_buf, channel, message) catch return;
                        stream.writeAll(frame) catch |err| self.evictStalled(stream, err);
                    } else {
                        const heap_buf = self.allocator.alloc(u8, total_len) catch return;
                        defer self.allocator.free(heap_buf);
                        const frame = wire.encodeEventFrame(heap_buf, channel, message) catch return;
                        stream.writeAll(frame) catch |err| self.evictStalled(stream, err);
                    }
                }
                return;
            }

            const data = std.fmt.allocPrint(self.allocator, ">EVENT {s}\r\n{s}\r\n", .{ channel, message }) catch return;
            defer self.allocator.free(data);
            if (self.write_capture) |capture| capture.appendSlice(self.allocator, data) catch {};
            if (self.stream) |stream| {
                const saved = stream.write_timeout_ms;
                stream.write_timeout_ms = EVENT_SEND_TIMEOUT_MS;
                defer stream.write_timeout_ms = saved;
                stream.writeAll(data) catch |err| self.evictStalled(stream, err);
            }
        }

        /// A subscriber that cannot take an event frame within `EVENT_SEND_TIMEOUT_MS`
        /// (or whose socket errored) is a stalled consumer. Evict it: mark the
        /// connection closed so every later publish skips it immediately, and shut the
        /// socket down so the connection thread — possibly parked in an idle read with
        /// no deadline — wakes up and runs the normal teardown (unsubscribe, free).
        /// Called with `write_mutex` held.
        fn evictStalled(self: *ConnectionContext, stream: *core.compat.net.Stream, err: anyerror) void {
            self.closed.store(true, .release);
            stream.shutdown();
            self.event_bus.recordEviction();
            std.log.warn("evicted stalled subscriber ({s})", .{@errorName(err)});
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        config: ServerConfig,
    ) Server {
        return .{
            .allocator = allocator,
            .store = store,
            .event_bus = event_bus,
            .cluster = config.cluster,
            .config = config,
            .metrics = config.metrics,
            .running = std.atomic.Value(bool).init(false),
            .conn_queue = .{},
            .workers = &.{},
            .ip_limiter = IpLimiter.init(allocator),
        };
    }

    /// Release per-IP accounting memory. Call after `run` has returned.
    pub fn deinit(self: *Server) void {
        self.ip_limiter.deinit();
    }

    pub fn run(self: *Server) !void {
        if (self.config.max_connections == 0 or self.config.timeout_ms == 0) return error.InvalidConnectionLimits;
        self.running.store(true, .release);

        const addr = try core.compat.net.Address.parseIp(self.config.bind_address, self.config.port);
        var listener = try addr.listen(.{ .reuse_address = true, .kernel_backlog = 1024 });
        defer listener.deinit();

        // Start dedicated subscriber reactor on Linux (0 worker threads pinned per idle SUB).
        if (comptime builtin.os.tag == .linux) {
            self.sub_reactor = try SubReactor.create(self);
        }
        defer {
            if (self.sub_reactor) |reactor| {
                reactor.stopAndDestroy();
                self.sub_reactor = null;
            }
        }

        // Start worker pool
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const num_workers = if (self.config.worker_count > 0)
            self.config.worker_count
        else
            @min(cpu_count * 2, 64);

        self.workers = try self.allocator.alloc(std.Thread, num_workers);
        for (self.workers) |*w| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        std.log.info("WormDB listening on {s}:{d} ({d} workers)", .{ self.config.bind_address, self.config.port, num_workers });

        while (self.running.load(.acquire)) {
            var conn = listener.accept() catch |err| {
                std.log.err("Accept error: {}", .{err});
                continue;
            };
            if (!self.running.load(.acquire)) {
                conn.stream.close();
                break;
            }

            if (!self.connection_limit.acquire(self.config.max_connections)) {
                conn.stream.close();
                continue;
            }
            // Per-IP admission (C3): enforced only when a cap is configured AND the
            // peer address resolves; an unattributable peer is admitted uncounted.
            var ip_key: ?IpLimiter.Key = null;
            if (self.config.max_connections_per_ip > 0) {
                if (core.compat.getPeerAddress(conn.stream.getHandle())) |peer| {
                    const key = IpLimiter.keyFromAddress(peer.inner);
                    if (!(self.config.per_ip_exempt_loopback and IpLimiter.isLoopback(key))) {
                        if (self.ip_limiter.acquire(key, self.config.max_connections_per_ip)) {
                            ip_key = key;
                        } else {
                            std.log.warn("rejecting connection from {f}: per-IP cap reached ({d} active)", .{
                                peer.inner, self.config.max_connections_per_ip,
                            });
                            conn.stream.close();
                            self.connection_limit.release();
                            continue;
                        }
                    }
                }
            }
            // Preserve accept time through the queue and all pre-AUTH frames.
            conn.stream.read_limit_ns = core.compat.nowNs() + @as(i128, self.config.timeout_ms) * 1_000_000;
            if (!self.conn_queue.push(.{ .accepted = .{ .conn = conn, .ip_key = ip_key } })) {
                // Queue full — reject connection
                std.log.warn("Connection queue full, rejecting", .{});
                if (self.metrics) |metrics| metrics.setTcpConnectionQueueDepth(self.conn_queue.len());
                conn.stream.close();
                if (ip_key) |key| self.ip_limiter.release(key);
                self.connection_limit.release();
                continue;
            }
            if (self.metrics) |metrics| metrics.setTcpConnectionQueueDepth(self.conn_queue.len());
        }

        // Shutdown: wake all workers so they exit before tearing down SubReactor.
        for (self.workers) |*w| {
            _ = self.conn_queue.futex.fetchAdd(1, .release);
            core.compat.Futex.wake(&self.conn_queue.futex, 1);
            w.join();
        }
        self.allocator.free(self.workers);
        self.workers = &.{};
    }

    fn workerLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            if (self.conn_queue.pop()) |queued| {
                if (self.metrics) |metrics| metrics.setTcpConnectionQueueDepth(self.conn_queue.len());
                switch (queued) {
                    .accepted => |acc| self.handleConnection(acc.conn, acc.ip_key),
                    .resumed => |sess| self.resumeBinarySession(sess),
                }
            } else {
                // Wait for new connections
                core.compat.Futex.timedWait(&self.conn_queue.futex, self.conn_queue.futex.load(.acquire), 10_000_000);
            }
        }
        // Drain remaining connections on shutdown
        while (self.conn_queue.pop()) |queued| {
            if (self.metrics) |metrics| metrics.setTcpConnectionQueueDepth(self.conn_queue.len());
            switch (queued) {
                .accepted => |acc| self.handleConnection(acc.conn, acc.ip_key),
                .resumed => |sess| self.destroySession(sess),
            }
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        if (self.sub_reactor) |reactor| reactor.wakeIfSleeping();
    }

    fn destroySession(self: *Server, session: *SubSession) void {
        session.conn_ctx.deinit();
        session.flush_buf.deinit(self.allocator);
        session.stream.close();
        if (session.has_metrics) {
            if (self.metrics) |metrics| metrics.endTcpConnection();
        }
        if (session.ip_key) |key| self.ip_limiter.release(key);
        self.connection_limit.release();
        self.allocator.destroy(session);
    }

    fn resumeBinarySession(self: *Server, session: *SubSession) void {
        const outcome = self.handleBinarySession(session);
        if (outcome == .closed) {
            self.destroySession(session);
        }
    }

    fn handleConnection(self: *Server, conn: core.compat.net.ServerCompat.Connection, ip_key: ?IpLimiter.Key) void {
        const session = self.allocator.create(SubSession) catch {
            var s = conn.stream;
            s.close();
            if (ip_key) |key| self.ip_limiter.release(key);
            self.connection_limit.release();
            return;
        };
        session.* = .{
            .stream = conn.stream,
            .ip_key = ip_key,
            .conn_ctx = ConnectionContext.init(self.allocator, self.event_bus, null),
            .metrics_shard = if (self.metrics) |m| m.assignTcpShard() else 0,
            .has_metrics = self.metrics != null,
        };
        session.conn_ctx.stream = &session.stream;
        session.conn_ctx.session = session;
        session.conn_ctx.reactor = self.sub_reactor;
        session.conn_ctx.auth_enforce = self.config.auth_enforce;
        session.conn_ctx.rate_limiter = CommandRateLimiter.init(self.config.max_commands_per_sec, core.compat.nowNs());

        session.stream.beginRead(self.config.timeout_ms, false);
        if (self.metrics) |metrics| metrics.beginTcpConnection();

        // Disable Nagle's algorithm — critical for low-latency request/response.
        core.compat.setNoDelay(session.stream.getHandle());
        // Bound sends so a slow peer cannot pin an EventBus publisher (#84).
        core.compat.setSendTimeoutMs(session.stream.getHandle(), 2_000);
        session.stream.write_timeout_ms = 2_000;

        var handshake: [2]u8 = undefined;
        var handshake_read: usize = 0;
        while (handshake_read < handshake.len) {
            const n = session.stream.read(handshake[handshake_read..]) catch |err| {
                std.log.debug("Handshake read error: {}", .{err});
                self.destroySession(session);
                return;
            };
            if (n == 0) {
                self.destroySession(session);
                return;
            }
            handshake_read += n;
        }

        if (std.mem.eql(u8, &handshake, &wire.WIRE_MAGIC)) {
            if (!self.config.auth_enforce) session.stream.read_limit_ns = null;
            session.conn_ctx.binary_mode = true;
            const outcome = self.handleBinarySession(session);
            if (outcome == .closed) {
                self.destroySession(session);
            }
            return;
        }

        defer self.destroySession(session);
        const stream = &session.stream;
        const conn_ctx = &session.conn_ctx;

        // Replication connections: same binary protocol but skip re-replication (anti-echo).
        // Legacy "WR" carries no peer identity, so it is only acceptable while org
        // trust is NOT enforced — an enforcing node must fail closed and loudly.
        if (std.mem.eql(u8, &handshake, &wire.REPL_MAGIC)) {
            if (self.config.org_trust) |trust| {
                if (trust.enforce) {
                    std.log.warn("replication: legacy replication rejected: org trust enforced (peer must use W2 handshake)", .{});
                    wire.writeResponse(stream, .{ .err = "unauthorized: legacy replication rejected (org trust enforced)" }) catch {};
                    return;
                }
            }
            conn_ctx.binary_mode = true;
            stream.read_limit_ns = null;
            var transport = secure_channel.Transport{ .stream = stream };
            self.handleReplicationConnection(&transport, null);
            return;
        }

        // Org-authenticated replication ("W2", #63): challenge/response handshake
        // before any frame is accepted. Verified against the configured org trust;
        // with no trust configured this always rejects (deny-by-default) — an open
        // node's peers speak legacy "WR", so a W2 arrival means misconfiguration.
        if (std.mem.eql(u8, &handshake, &wire.REPL_MAGIC_V2)) {
            conn_ctx.binary_mode = true;
            if (self.config.org_trust) |trust| {
                if (trust.enforce and !trust.accept_w2) {
                    std.log.warn("replication: legacy W2 handshake rejected (org_trust.accept_w2 is false; peer must speak W3)", .{});
                    wire.writeResponse(stream, .{ .err = "unauthorized: legacy W2 replication disabled" }) catch {};
                    return;
                }
            }
            const peer_org = self.replicationOrgHandshake(stream) orelse return;
            stream.read_limit_ns = null;
            // Accepted for rolling upgrades: the peer proved its org, but this
            // link is one-way authenticated and unencrypted. Upgrade it to W3.
            std.log.warn("replication: peer uses legacy W2 handshake (unencrypted, server not authenticated) — upgrade the peer", .{});
            var transport = secure_channel.Transport{ .stream = stream };
            self.handleReplicationConnection(&transport, peer_org);
            return;
        }

        // Mutual org-authenticated, encrypted replication ("W3"): both ends
        // prove membership in a trusted org before any frame flows, and every
        // frame after the handshake travels in an encrypted record.
        if (std.mem.eql(u8, &handshake, &wire.REPL_MAGIC_V3)) {
            conn_ctx.binary_mode = true;
            var session_w3 = self.replicationMutualHandshake(stream) orelse return;
            stream.read_limit_ns = null;
            var secure = secure_channel.SecureStream.init(self.allocator, session_w3.keys);
            defer secure.deinit();
            session_w3.keys.wipe();
            var transport = secure_channel.Transport{ .stream = stream, .secure = &secure };
            self.handleReplicationConnection(&transport, session_w3.org.org_pubkey);
            return;
        }

        conn_ctx.writeAllLocked("-ERR binary protocol required\r\n");
    }

    const SessionOutcome = enum { closed, parked };

    fn handleBinarySession(self: *Server, session: *SubSession) SessionOutcome {
        const stream = &session.stream;
        const conn_ctx = &session.conn_ctx;
        // Buffered write adapter: coalesces small response frames across pipelined
        // requests into a single send syscall whenever additional frames are already
        // queued in `ReadAdapter.buf`, while still flushing immediately when the
        // read buffer drains (zero extra latency for unpipelined inflight=1).
        const WriteAdapter = struct {
            s: *core.compat.net.Stream,
            session: *SubSession,
            conn_ctx: *ConnectionContext,
            buf: [16384]u8 = undefined,
            end: usize = 0,

            pub fn writeAll(wa: *@This(), data: []const u8) !void {
                var remaining = data;
                while (remaining.len > 0) {
                    const space = wa.buf.len - wa.end;
                    if (remaining.len >= space) {
                        @memcpy(wa.buf[wa.end..][0..space], remaining[0..space]);
                        wa.end = wa.buf.len;
                        try wa.flush();
                        remaining = remaining[space..];
                    } else {
                        @memcpy(wa.buf[wa.end..][0..remaining.len], remaining);
                        wa.end += remaining.len;
                        break;
                    }
                }
            }

            pub fn flush(wa: *@This()) !void {
                // Flush any partial event frame left over from SubReactor before sending a command reply
                // so wire framing stays strictly contiguous across park/unpark boundaries.
                if (wa.session.flush_pos < wa.session.flush_buf.items.len) {
                    try wa.s.writeAll(wa.session.flush_buf.items[wa.session.flush_pos..]);
                    wa.session.flush_buf.clearRetainingCapacity();
                    wa.session.flush_pos = 0;
                }
                if (wa.end > 0) {
                    const pending = wa.buf[0..wa.end];
                    wa.end = 0;
                    // On Linux with SubReactor, this worker owns the socket exclusively while unparked.
                    // On non-Linux (or tests without SubReactor), synchronize with direct EventBus writes.
                    if (wa.conn_ctx.reactor == null and wa.conn_ctx.subscriptions.count() > 0) {
                        wa.conn_ctx.write_mutex.lock();
                        defer wa.conn_ctx.write_mutex.unlock();
                        try wa.s.writeAll(pending);
                    } else {
                        try wa.s.writeAll(pending);
                    }
                }
            }
        };

        const ReadAdapter = struct {
            stream: *core.compat.net.Stream,
            writer: *WriteAdapter,
            timeout_ms: usize,
            allow_idle_at_cmd_start: bool = false,
            deadline_armed: bool = false,
            buf: [16384]u8 = undefined,
            pos: usize = 0,
            end: usize = 0,

            inline fn hasBuffered(adapter: *const @This()) bool {
                return adapter.pos < adapter.end;
            }

            pub fn read(adapter: *@This(), dest: []u8) !usize {
                if (adapter.pos < adapter.end) {
                    const avail = adapter.end - adapter.pos;
                    const n = @min(avail, dest.len);
                    @memcpy(dest[0..n], adapter.buf[adapter.pos .. adapter.pos + n]);
                    adapter.pos += n;
                    if (adapter.pos == adapter.end) {
                        adapter.pos = 0;
                        adapter.end = 0;
                    }
                    return n;
                }
                if (adapter.writer.end > 0) {
                    adapter.writer.flush() catch return error.EndOfStream;
                }
                if (!adapter.deadline_armed) {
                    adapter.stream.beginRead(adapter.timeout_ms, adapter.allow_idle_at_cmd_start);
                    adapter.deadline_armed = true;
                }
                if (dest.len >= adapter.buf.len) {
                    return adapter.stream.read(dest);
                }
                const n_read = try adapter.stream.read(&adapter.buf);
                if (n_read == 0) return 0;
                const n = @min(n_read, dest.len);
                @memcpy(dest[0..n], adapter.buf[0..n]);
                if (n < n_read) {
                    adapter.pos = n;
                    adapter.end = n_read;
                }
                return n;
            }
        };

        var w = WriteAdapter{ .s = stream, .session = session, .conn_ctx = conn_ctx };
        var reader = ReadAdapter{
            .stream = stream,
            .writer = &w,
            .timeout_ms = self.config.timeout_ms,
        };

        var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer cmd_arena.deinit();

        const metrics_shard: usize = session.metrics_shard;
        var burst_had_success = false;

        while (true) {
            _ = cmd_arena.reset(.{ .retain_with_limit = ARENA_RETAIN_LIMIT });
            const arena_alloc = cmd_arena.allocator();

            self.expireAuthState(conn_ctx);
            reader.deadline_armed = false;
            reader.allow_idle_at_cmd_start = !reader.hasBuffered() and
                conn_ctx.subscriptions.count() > 0 and
                (!self.config.auth_enforce or conn_ctx.auth_state != null);
            const max_payload: usize = if (self.config.auth_enforce and conn_ctx.auth_state == null)
                PRE_AUTH_MAX_PAYLOAD
            else
                wire.MAX_PAYLOAD_LENGTH;
            const cmd = wire.readFrameZeroCopyLimited(&reader, arena_alloc, max_payload) catch |err| {
                if (burst_had_success) {
                    if (self.metrics) |metrics| metrics.touchTcpSuccessMsShard(metrics_shard);
                }
                switch (err) {
                    error.EndOfStream, error.Timeout => {
                        w.flush() catch {};
                        return .closed;
                    },
                    error.PayloadTooLarge => {
                        wire.writeResponse(&w, .{ .err = "request too large" }) catch {};
                        w.flush() catch {};
                        return .closed;
                    },
                    else => {
                        wire.writeResponse(&w, .{ .err = "malformed frame" }) catch {};
                        w.flush() catch {};
                        return .closed;
                    },
                }
            };

            if (conn_ctx.rate_limiter) |*limiter| {
                if (!limiter.allow(core.compat.nowNs())) {
                    wire.writeResponse(&w, .{ .err = "rate limited" }) catch return .closed;
                    if (!reader.hasBuffered()) {
                        if (burst_had_success) {
                            if (self.metrics) |metrics| metrics.touchTcpSuccessMsShard(metrics_shard);
                            burst_had_success = false;
                        }
                        w.flush() catch return .closed;
                        if (self.parkIfIdleSubscriber(session)) return .parked;
                    }
                    continue;
                }
            }

            if (self.metrics) |metrics| {
                if (burst_had_success and cmd == .status) {
                    metrics.touchTcpSuccessMsShard(metrics_shard);
                    burst_had_success = false;
                }
                metrics.beginTcpCommandShard(metrics_shard);
            }
            defer if (self.metrics) |metrics| metrics.endTcpCommandShard(metrics_shard);

            const response = self.executeForConnectionWithAlloc(cmd, conn_ctx, arena_alloc) catch |err| {
                const err_msg: []const u8 = switch (err) {
                    error.WormViolation => "WORM violation",
                    error.OutOfMemory => "out of memory",
                    error.IoError => "I/O error",
                    error.KeyNotFound => "key not found",
                    error.Corruption => "data corruption",
                    error.InvalidPredicate => "invalid filter predicate",
                };
                wire.writeResponse(&w, .{ .err = err_msg }) catch return .closed;
                const idle = !reader.hasBuffered();
                if (idle) {
                    if (burst_had_success) {
                        if (self.metrics) |metrics| metrics.touchTcpSuccessMsShard(metrics_shard);
                        burst_had_success = false;
                    }
                    w.flush() catch return .closed;
                }
                if (self.metrics) |metrics| metrics.completeTcpCommandShard(metrics_shard, false, false);
                if (idle and self.parkIfIdleSubscriber(session)) return .parked;
                continue;
            };

            const ok = responseSucceeded(response);
            wire.writeResponse(&w, response) catch return .closed;
            const more_buffered = reader.hasBuffered();
            if (self.metrics) |metrics| {
                metrics.completeTcpCommandShard(metrics_shard, ok, ok and !more_buffered);
                if (!more_buffered) {
                    if (!ok and burst_had_success) metrics.touchTcpSuccessMsShard(metrics_shard);
                    burst_had_success = false;
                } else if (ok) {
                    burst_had_success = true;
                }
            }
            if (!more_buffered) {
                w.flush() catch return .closed;
                if (self.parkIfIdleSubscriber(session)) return .parked;
            }
        }
    }

    /// Park an idle subscribed connection onto the SubReactor (Linux) so it pins no
    /// worker thread and its queued events keep draining. Every reply path that leaves
    /// the connection idle must go through here: the reactor skips unparked sessions,
    /// so events published meanwhile would sit in `out_buf` until the next command.
    /// Caller must have flushed its write adapter and hold no buffered request bytes.
    /// Returns true when the reactor now owns the session.
    fn parkIfIdleSubscriber(self: *Server, session: *SubSession) bool {
        if (comptime builtin.target.os.tag == .linux) {
            if (self.sub_reactor) |reactor| {
                const conn_ctx = &session.conn_ctx;
                if (conn_ctx.subscriptions.count() > 0 and
                    !conn_ctx.closed.load(.acquire) and
                    (!self.config.auth_enforce or conn_ctx.auth_state != null))
                {
                    return reactor.park(session);
                }
            }
        }
        return false;
    }

    /// Server side of the W2 org handshake: send a fresh 32-byte challenge,
    /// read the peer's [186B cert][64B signature] reply, verify it against the
    /// configured org trust. Returns the proven org pubkey, or null after
    /// writing an err response and logging the reason (caller closes).
    fn replicationOrgHandshake(self: *Server, stream: *core.compat.net.Stream) ?[32]u8 {
        var challenge: [org_trust_mod.CHALLENGE_LEN]u8 = undefined;
        core.compat.randomBytes(&challenge);
        stream.writeAll(&challenge) catch return null;

        var reply: [org_trust_mod.HANDSHAKE_REPLY_LEN]u8 = undefined;
        readExactFromStream(stream, &reply) catch {
            std.log.warn("replication: org handshake failed: peer closed before sending cert+signature", .{});
            return null;
        };

        const trust = self.config.org_trust orelse &EMPTY_ORG_TRUST;
        const peer = org_trust_mod.verifyPeerHandshake(
            trust,
            &challenge,
            reply[0..org_trust_mod.CERT_WIRE_LEN],
            reply[org_trust_mod.CERT_WIRE_LEN..][0..org_trust_mod.SIG_LEN],
        ) catch |err| {
            std.log.warn("replication: org handshake rejected: {s}", .{@errorName(err)});
            wire.writeResponse(stream, .{ .err = "unauthorized: replication handshake rejected" }) catch {};
            return null;
        };
        return peer.org_pubkey;
    }

    /// Server side of the mutual "W3" handshake (client side: `Cluster.replOutboundHandshake`).
    /// Reads the client's challenge, answers with our challenge + our cert + a signature over
    /// (client_challenge ++ our cert) so the CLIENT can verify us before it sends anything,
    /// then verifies the client's [cert][sig over our challenge ++ its cert] exactly like W2.
    /// Returns the proven peer identity and the session keys. Fails closed when this node
    /// has no certificate or no cluster identity to sign with.
    fn replicationMutualHandshake(self: *Server, stream: *core.compat.net.Stream) ?org_trust_mod.PeerSession {
        const trust = self.config.org_trust orelse &EMPTY_ORG_TRUST;

        var client_challenge: [org_trust_mod.CHALLENGE_LEN]u8 = undefined;
        readExactFromStream(stream, &client_challenge) catch {
            std.log.warn("replication: W3 handshake failed: peer closed before sending its challenge", .{});
            return null;
        };

        const cert_wire = trust.node_cert_wire orelse {
            std.log.warn("replication: W3 handshake rejected: this node has no node_cert_path to prove its identity", .{});
            wire.writeResponse(stream, .{ .err = "unauthorized: server has no org certificate" }) catch {};
            return null;
        };
        const cluster = self.config.cluster orelse {
            std.log.warn("replication: W3 handshake rejected: no cluster identity to sign with", .{});
            wire.writeResponse(stream, .{ .err = "unauthorized: no cluster identity" }) catch {};
            return null;
        };

        var server_challenge: [org_trust_mod.CHALLENGE_LEN]u8 = undefined;
        core.compat.randomBytes(&server_challenge);
        // Role-labeled, both-challenge-bound transcript (see org_trust.w3ServerMessage):
        // this signature verifies only as a W3 server hello, so answering an anonymous
        // caller's chosen challenge cannot hand it a client proof for W3 or legacy W2.
        const our_msg = org_trust_mod.w3ServerMessage(&client_challenge, &server_challenge, &cert_wire);
        const our_sig = cluster.signWithIdentity(&our_msg) catch {
            std.log.warn("replication: W3 handshake failed: cannot sign with the cluster identity", .{});
            return null;
        };
        var hello: [org_trust_mod.SERVER_HELLO_LEN]u8 = undefined;
        @memcpy(hello[0..org_trust_mod.CHALLENGE_LEN], &server_challenge);
        @memcpy(hello[org_trust_mod.CHALLENGE_LEN..][0..org_trust_mod.CERT_WIRE_LEN], &cert_wire);
        @memcpy(hello[org_trust_mod.CHALLENGE_LEN + org_trust_mod.CERT_WIRE_LEN ..][0..org_trust_mod.SIG_LEN], &our_sig);
        stream.writeAll(&hello) catch return null;

        var reply: [org_trust_mod.HANDSHAKE_REPLY_LEN]u8 = undefined;
        readExactFromStream(stream, &reply) catch {
            std.log.warn("replication: W3 handshake failed: peer closed before sending cert+signature", .{});
            return null;
        };
        const peer = org_trust_mod.verifyW3Client(
            trust,
            &client_challenge,
            &server_challenge,
            reply[0..org_trust_mod.CERT_WIRE_LEN],
            reply[org_trust_mod.CERT_WIRE_LEN..][0..org_trust_mod.SIG_LEN],
        ) catch |err| {
            std.log.warn("replication: W3 handshake rejected: {s}", .{@errorName(err)});
            wire.writeResponse(stream, .{ .err = "unauthorized: replication handshake rejected" }) catch {};
            return null;
        };

        const keys = secure_channel.deriveSessionKeys(.server, cluster.identity.secret_key, peer.node_pubkey, &client_challenge, &server_challenge) catch {
            std.log.warn("replication: W3 handshake failed: session key derivation failed", .{});
            return null;
        };
        return .{ .org = peer, .keys = keys };
    }

    /// True when the replicated key is allowed for this connection. Only
    /// meaningful while org trust is enforced; open mode allows everything.
    ///
    /// Two layers, both deny-by-default:
    ///   1. static grants from config (#63) — member orgs;
    ///   2. dynamic delegated-org authorization (#66) — a cached fold of OUR
    ///      org's trust log ("trust:<our_org_hex>"). Consulted only after the
    ///      static check fails, and only when the composition root wired
    ///      `trust.dynamic` (enforcement on AND this node has a cert). Every
    ///      mutating replication frame (set/delete/vinsert/vdelete/
    ///      vbulkinsert) requires the WRITE capability; revocation lands via
    ///      the trust log within the cache TTL (≤5s) — or immediately, when
    ///      the revoke was appended locally (generation bump).
    fn replicationKeyAuthorized(self: *Server, peer_org: ?[32]u8, key: []const u8) bool {
        const trust = self.config.org_trust orelse return true;
        if (!trust.enforce) return true;
        const org = peer_org orelse return false; // enforcing ⇒ only W2/W3 connections reach the loop
        if (trust.sameOrg(org)) return true; // members of our own org are full replicas
        if (trust.keyAuthorized(org, key)) return true;
        const dynamic = trust.dynamic orelse return false;
        return dynamic.authorized(org, key, org_trust_mod.CAP_WRITE);
    }

    /// Handle a replication connection from another WormDB node.
    /// Applies SET/DEL directly to the store without re-replicating (anti-echo).
    /// Emits local PUB/SUB events for replicated writes so local subscribers
    /// (e.g. WebSocket-connected clients) get real-time notifications.
    ///
    /// Persistent `PeerConnection` streams are one-way: `PeerConnection.sendCommand`
    /// never reads from the socket, so mutating commands (`set`, `delete`, `vinsert`,
    /// `vdelete`, `vbulkinsert`, `vrabitq_install`, and `EXEC append_log_witness`)
    /// must not write `.ok` or `.err` frames back on the wire (otherwise unread
    /// responses fill the TCP send/receive buffers and drop the replication link on
    /// the 2 s send timeout). Only one-shot request/response replication RPCs
    /// (`EXEC proof_prefix_root`, `EXEC vsearch_local_raw`) write a response frame
    /// because their callers explicitly drain it with `wire.readResponseAlloc`.
    fn handleReplicationConnection(self: *Server, transport: *secure_channel.Transport, peer_org: ?[32]u8) void {
        while (true) {
            // Both accepted handshakes (legacy WR in explicit open mode and
            // authenticated W2) are persistent replication sessions. Idle is
            // valid; once the first frame byte arrives, Stream.read starts the
            // normal whole-frame deadline so trickled frames still expire.
            transport.beginRead(self.config.timeout_ms, true);
            const cmd = wire.readFrameAlloc(transport, self.allocator) catch return;
            defer protocol.deinitCommand(self.allocator, cmd);

            switch (cmd) {
                .set => |params| {
                    if (!self.replicationKeyAuthorized(peer_org, params.key)) {
                        std.log.warn("replication: SET unauthorized for key '{s}'", .{params.key});
                        continue;
                    }
                    self.store.set(params.key, params.value, params.worm) catch {};
                    // No replication — this IS the replication

                    // Emit local PUB/SUB event for note changes so browser clients
                    // connected to this node get real-time updates via WebSocket.
                    if (std.mem.startsWith(u8, params.key, "note:") and
                        !std.mem.eql(u8, params.key, "notes:index"))
                    {
                        // Extract note id (strip "note:" prefix)
                        const note_id = params.key["note:".len..];
                        // Decode the note JSON from base64 to extract title/author
                        const decoded = std.base64.standard.Decoder.calcSizeForSlice(params.value) catch null;
                        if (decoded) |decoded_len| {
                            const buf = self.allocator.alloc(u8, decoded_len) catch null;
                            if (buf) |json_buf| {
                                defer self.allocator.free(json_buf);
                                if (std.base64.standard.Decoder.decode(json_buf, params.value)) |_| {
                                    // Parse title and author from note JSON
                                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_buf, .{}) catch null;
                                    var title: []const u8 = "Untitled";
                                    var author: []const u8 = "peer";
                                    if (parsed) |p| {
                                        defer p.deinit();
                                        if (p.value.object.get("title")) |t| {
                                            if (t == .string) title = t.string;
                                        }
                                        if (p.value.object.get("author")) |a| {
                                            if (a == .string) author = a.string;
                                        }
                                        // Build PUB event inside this block while parsed strings are alive
                                        const event_msg = std.fmt.allocPrint(
                                            self.allocator,
                                            "{{\"type\":\"note:updated\",\"id\":\"{s}\",\"author\":\"{s}\",\"title\":\"{s}\"}}",
                                            .{ note_id, author, title },
                                        ) catch null;
                                        if (event_msg) |msg| {
                                            defer self.allocator.free(msg);
                                            self.event_bus.publish("notes", msg) catch {};
                                        }
                                    }
                                } else |_| {}
                            }
                        }
                    }
                },
                .delete => |key| {
                    if (!self.replicationKeyAuthorized(peer_org, key)) {
                        std.log.warn("replication: DEL unauthorized for key '{s}'", .{key});
                        continue;
                    }
                    self.store.delete(key) catch {};

                    // Emit local PUB/SUB event for note deletions
                    if (std.mem.startsWith(u8, key, "note:") and
                        !std.mem.eql(u8, key, "notes:index"))
                    {
                        const note_id = key["note:".len..];
                        const event_msg = std.fmt.allocPrint(
                            self.allocator,
                            "{{\"type\":\"note:deleted\",\"id\":\"{s}\"}}",
                            .{note_id},
                        ) catch null;
                        if (event_msg) |msg| {
                            defer self.allocator.free(msg);
                            self.event_bus.publish("notes", msg) catch {};
                        }
                    }
                },
                .vinsert => |params| {
                    if (!self.replicationKeyAuthorized(peer_org, params.key)) {
                        std.log.warn("replication: VINSERT unauthorized for key '{s}'", .{params.key});
                        continue;
                    }
                    const metric_enum = Metric.fromStr(params.metric) orelse {
                        std.log.warn("replication: VINSERT unknown metric '{s}'", .{params.metric});
                        continue;
                    };
                    vector_ops.applyVinsert(
                        self.store,
                        null, // don't re-replicate — this IS the replication
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        .{
                            .key = params.key,
                            .vector = params.vector,
                            .worm = params.worm,
                            .namespace = params.namespace,
                            .metric = metric_enum,
                            .timestamp = params.timestamp,
                            .replicate = false, // anti-echo boundary
                            .is_async = params.is_async,
                        },
                    ) catch |e| {
                        std.log.warn("replication: applyVinsert failed: {s}", .{@errorName(e)});
                    };
                },
                .vdelete => |params| {
                    if (!self.replicationKeyAuthorized(peer_org, params.key)) {
                        std.log.warn("replication: VDELETE unauthorized for key '{s}'", .{params.key});
                        continue;
                    }
                    vector_ops.applyVdelete(
                        self.store,
                        null,
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        params.key,
                        params.namespace,
                        false,
                    ) catch |e| {
                        std.log.warn("replication: applyVdelete failed: {s}", .{@errorName(e)});
                    };
                },
                .vbulkinsert => |params| {
                    // Every item key must be authorized — reject the whole frame
                    // atomically rather than half-applying a bulk insert.
                    const bulk_authorized = blk: {
                        for (params.items) |item| {
                            if (!self.replicationKeyAuthorized(peer_org, item.key)) break :blk false;
                        }
                        break :blk true;
                    };
                    if (!bulk_authorized) {
                        std.log.warn("replication: VBULKINSERT unauthorized for namespace '{s}'", .{params.namespace});
                        continue;
                    }
                    const metric_enum = Metric.fromStr(params.metric) orelse {
                        std.log.warn("replication: VBULKINSERT unknown metric '{s}'", .{params.metric});
                        continue;
                    };
                    vector_ops.applyVbulkinsert(
                        self.store,
                        null, // don't re-replicate
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        params.namespace,
                        metric_enum,
                        params.worm,
                        params.is_async,
                        params.items,
                        false, // anti-echo boundary
                    ) catch |e| {
                        std.log.warn("replication: applyVbulkinsert failed: {s}", .{@errorName(e)});
                    };
                },
                .vrabitq_install => |params| {
                    if (!self.replicationKeyAuthorized(peer_org, params.namespace)) {
                        std.log.warn("replication: VRABITQ_INSTALL unauthorized for namespace '{s}'", .{params.namespace});
                        continue;
                    }
                    const inferred_metric: Metric = if (self.config.vector_registry) |reg|
                        if (reg.get(params.namespace)) |idx| idx.metric else Metric.l2
                    else
                        Metric.l2;
                    vector_ops.applyVrabitqInstall(self.config.vector_registry, .{
                        .namespace = params.namespace,
                        .dim = params.dim,
                        .seed = params.seed,
                        .centroid_bytes = params.centroid,
                        .rotation_bytes = params.rotation,
                        .metric = inferred_metric,
                    }) catch |e| {
                        std.log.warn("replication: applyVrabitqInstall failed: {s}", .{@errorName(e)});
                    };
                },
                .exec => |params| {
                    const one_way = isOneWayReplicationProcedure(params.procedure);
                    if (!isAllowedReplicationProcedure(params.procedure)) {
                        wire.writeResponse(transport, .{ .err = "unsupported replication command" }) catch return;
                        transport.flush() catch return;
                        continue;
                    }
                    // Proof-layer procedures (witness/prefix-root) take no per-key
                    // grant check, but under enforcement they still require an
                    // org-authenticated connection (proven by the W2 handshake).
                    if (self.config.org_trust) |trust| {
                        if (trust.enforce and peer_org == null) {
                            if (!one_way) {
                                wire.writeResponse(transport, .{ .err = "unauthorized: org handshake required" }) catch return;
                                transport.flush() catch return;
                            }
                            continue;
                        }
                    }

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const response = executor.execute(.{
                        .store = self.store,
                        .event_bus = self.event_bus,
                        .allocator = arena.allocator(),
                        .cluster = self.cluster,
                        .auth = .trusted,
                        .auth_mint = self.config.auth_mint,
                        .vector_registry = self.config.vector_registry,
                    }, cmd) catch |e| {
                        std.log.warn("replication: EXEC {s} failed: {s}", .{ params.procedure, @errorName(e) });
                        if (!one_way) {
                            wire.writeResponse(transport, .{ .err = "replication EXEC failed" }) catch return;
                            transport.flush() catch return;
                        }
                        continue;
                    };
                    if (!one_way) {
                        wire.writeResponse(transport, response) catch return;
                        transport.flush() catch return;
                    }
                },
                else => {
                    std.log.warn("replication: unsupported command dropped", .{});
                },
            }
        }
    }

    fn isAllowedReplicationProcedure(name: []const u8) bool {
        // NOTE: vsearch_cluster is deliberately NOT allowed here — peers may
        // only be asked for the local sub-query (vsearch_local_raw), which
        // never re-scatters, so replication-channel fan-out loops are
        // impossible by construction.
        return std.mem.eql(u8, name, "append_log_witness") or
            std.mem.eql(u8, name, "proof_prefix_root") or
            std.mem.eql(u8, name, "vsearch_local_raw");
    }

    /// True when a replication EXEC is sent fire-and-forget on `PeerConnection`
    /// (where the sender never reads a response) rather than on a one-shot RPC
    /// connection that drains the response via `wire.readResponseAlloc`.
    fn isOneWayReplicationProcedure(name: []const u8) bool {
        return std.mem.eql(u8, name, "append_log_witness");
    }

    /// Read exactly `buf.len` bytes from a raw stream (pre-framing handshake I/O).
    fn readExactFromStream(stream: *core.compat.net.Stream, buf: []u8) !void {
        var done: usize = 0;
        while (done < buf.len) {
            const n = try stream.read(buf[done..]);
            if (n == 0) return error.EndOfStream;
            done += n;
        }
    }

    fn handleTextConnection(self: *Server, stream: *core.compat.net.Stream, conn_ctx: *ConnectionContext, initial: [2]u8) void {
        var read_buf: [TEXT_READ_BUF_SIZE]u8 = undefined;
        read_buf[0] = initial[0];
        read_buf[1] = initial[1];

        var buffered_len: usize = 2;
        var discarding_oversized_line = false;

        // Process any complete line already in the handshake-prefixed buffer.
        self.processReadBuffer(conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, 0);

        while (true) {
            if (buffered_len == read_buf.len and !discarding_oversized_line) {
                buffered_len = 0;
                discarding_oversized_line = true;
                conn_ctx.writeAllLocked("-ERR request too large\r\n");
            }

            const bytes_read = stream.read(read_buf[buffered_len..]) catch |err| {
                std.log.debug("Read error: {}", .{err});
                return;
            };
            if (bytes_read == 0) return;

            self.processReadBuffer(conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, bytes_read);
        }
    }

    fn processReadBuffer(
        self: *Server,
        conn_ctx: *ConnectionContext,
        read_buf: *[TEXT_READ_BUF_SIZE]u8,
        buffered_len: *usize,
        discarding_oversized_line: *bool,
        bytes_read: usize,
    ) void {
        const end = buffered_len.* + bytes_read;

        var start: usize = 0;
        if (discarding_oversized_line.*) {
            for (read_buf[0..end], 0..) |c, i| {
                if (c == '\n') {
                    discarding_oversized_line.* = false;
                    start = i + 1;
                    break;
                }
            }

            if (discarding_oversized_line.*) {
                buffered_len.* = 0;
                return;
            }
        }

        for (read_buf[0..end], 0..) |c, i| {
            if (i < start) continue;

            if (c == '\n') {
                const line = read_buf[start..i];
                const trimmed = std.mem.trim(u8, line, "\r\n");
                if (trimmed.len > 0) {
                    self.processLine(trimmed, conn_ctx) catch {};
                }
                start = i + 1;
            }
        }

        if (start < end) {
            const remaining = end - start;
            std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[start..end]);
            buffered_len.* = remaining;
        } else {
            buffered_len.* = 0;
        }

        if (buffered_len.* == read_buf.len) {
            buffered_len.* = 0;
            discarding_oversized_line.* = true;
            conn_ctx.writeAllLocked("-ERR request too large\r\n");
        }
    }

    fn processLine(self: *Server, line: []const u8, conn_ctx: *ConnectionContext) !void {
        const cmd = protocol.parseCommand(self.allocator, line) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = switch (err) {
                error.MalformedCommand => "malformed command",
                error.InvalidArgs => "invalid arguments",
                error.UnknownCommand => "unknown command",
                error.OutOfMemory => "out of memory",
                error.TooLarge => "request too large",
            };
            const msg = std.fmt.bufPrint(&buf, "-ERR {s}\r\n", .{err_msg}) catch "-ERR internal\r\n";
            conn_ctx.writeAllLocked(msg);
            return;
        };
        defer protocol.deinitCommand(self.allocator, cmd);

        if (self.metrics) |metrics| metrics.beginTcpCommand();
        defer if (self.metrics) |metrics| metrics.endTcpCommand();

        switch (cmd) {
            .subscribe => |params| {
                conn_ctx.subscribe(params.channel, params.filter) catch |err| {
                    const err_msg = switch (err) {
                        error.InvalidPredicate => "-ERR invalid filter\r\n",
                        else => "-ERR out of memory\r\n",
                    };
                    conn_ctx.writeAllLocked(err_msg);
                    if (self.metrics) |metrics| metrics.completeTcpCommand(false);
                    return;
                };
                conn_ctx.writeAllLocked("+OK\r\n");
                if (self.metrics) |metrics| metrics.completeTcpCommand(true);
                return;
            },
            .unsubscribe => |channel| {
                conn_ctx.unsubscribe(channel);
                conn_ctx.writeAllLocked("+OK\r\n");
                if (self.metrics) |metrics| metrics.completeTcpCommand(true);
                return;
            },
            else => {},
        }

        const response = self.executeForConnection(cmd, conn_ctx) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = switch (err) {
                error.WormViolation => "WORM violation",
                error.OutOfMemory => "out of memory",
                error.IoError => "I/O error",
                error.KeyNotFound => "key not found",
                error.Corruption => "data corruption",
                error.InvalidPredicate => "invalid filter",
            };
            const msg = std.fmt.bufPrint(&buf, "-ERR {s}\r\n", .{err_msg}) catch "-ERR internal\r\n";
            conn_ctx.writeAllLocked(msg);
            if (self.metrics) |metrics| metrics.completeTcpCommand(false);
            return;
        };
        defer protocol.deinitResponse(self.allocator, response);

        var resp_buf: [4096]u8 = undefined;
        const resp_str = switch (response) {
            .value => |val| if (val) |v|
                std.fmt.bufPrint(&resp_buf, "${d}\r\n{s}\r\n", .{ v.len, v }) catch "$-1\r\n"
            else
                "$-1\r\n",
            .ok => "+OK\r\n",
            .err => |msg| std.fmt.bufPrint(&resp_buf, "-ERR {s}\r\n", .{msg}) catch "-ERR internal\r\n",
            .event => |evt| std.fmt.bufPrint(&resp_buf, ">EVENT {s}\r\n{s}\r\n", .{ evt.channel, evt.message }) catch ">EVENT error\r\n",
        };

        conn_ctx.writeAllLocked(resp_str);
        if (self.metrics) |metrics| metrics.completeTcpCommand(responseSucceeded(response));
    }

    fn executeForConnection(self: *Server, cmd: Command, conn_ctx: *ConnectionContext) !Response {
        return self.executeForConnectionWithAlloc(cmd, conn_ctx, self.allocator);
    }

    fn expireAuthState(self: *Server, conn_ctx: *ConnectionContext) void {
        if (conn_ctx.auth_state) |*state| {
            if (state.isExpired()) {
                conn_ctx.clearAuthState();
                if (conn_ctx.stream) |stream| {
                    stream.read_limit_ns = core.compat.nowNs() + @as(i128, self.config.timeout_ms) * 1_000_000;
                }
            }
        }
    }

    fn executeForConnectionWithAlloc(self: *Server, cmd: Command, conn_ctx: *ConnectionContext, alloc: std.mem.Allocator) !Response {
        // Revoke expired tokens mid-session — forces re-AUTH instead of letting a
        // long-lived connection outlive its token (mirrors the WS gateway).
        self.expireAuthState(conn_ctx);

        // AUTH is handled at the connection level (the executor has no per-connection
        // state to attach the token to). Semantics mirror gateway.zig: verify regardless
        // of `auth_enforce`, fail with "auth not configured" when no keys are set.
        // Note: peer replication uses REPL_MAGIC → handleReplicationConnection, which
        // never reaches this client path, so it is unaffected.
        return switch (cmd) {
            .auth => |token| blk: {
                if (self.config.auth_public_keys.len == 0) {
                    break :blk Response{ .err = "auth not configured" };
                }
                // Token state must outlive this command: allocate from the server
                // allocator, NOT the per-command arena `alloc`.
                const state = auth.verifyAndParse(
                    token,
                    self.config.auth_public_keys,
                    self.allocator,
                    self.config.auth_max_token_age,
                ) catch |err| {
                    const msg: []const u8 = switch (err) {
                        error.InvalidSignature => "invalid signature",
                        error.TokenExpired => "token expired",
                        error.TokenNotYetValid => "token not yet valid",
                        error.TokenTooLongLived => "token lifetime exceeds max",
                        error.TokenTooShort, error.MalformedToken => "malformed token",
                        else => "auth failed",
                    };
                    break :blk Response{ .err = msg };
                };
                // Replace previous auth state (re-AUTH refreshes the token).
                conn_ctx.replaceAuthState(state);
                if (conn_ctx.stream) |stream| stream.read_limit_ns = if (self.config.auth_enforce) state.readDeadlineNs() else null;
                break :blk .ok;
            },
            .subscribe => |params| blk: {
                // SUBSCRIBE is handled locally (it needs conn_ctx) and so bypasses the
                // executor's capability gate — enforce it here, like the gateway does.
                if (self.config.auth_enforce) {
                    if (conn_ctx.auth_state) |*state| {
                        if (!state.permits(.subscribe, params.channel)) {
                            break :blk Response{ .err = "permission denied" };
                        }
                    } else {
                        break :blk Response{ .err = "auth required" };
                    }
                }
                try conn_ctx.subscribe(params.channel, params.filter);
                break :blk .ok;
            },
            .unsubscribe => |channel| blk: {
                // Dropping your own subscription is harmless — no capability required
                // (matches the gateway).
                conn_ctx.unsubscribe(channel);
                break :blk .ok;
            },
            else => try executor.execute(.{
                .allocator = alloc,
                .store = self.store,
                .event_bus = self.event_bus,
                .cluster = self.cluster,
                .vector_registry = self.config.vector_registry,
                .auth = if (self.config.auth_enforce)
                    .{ .enforce = if (conn_ctx.auth_state) |*s| s else null }
                else
                    .disabled,
                .auth_mint = self.config.auth_mint,
                .metrics = self.metrics,
            }, cmd),
        };
    }
};

fn responseSucceeded(response: Response) bool {
    return switch (response) {
        .err => false,
        else => true,
    };
}

test "Server SUB/UNSUB command wiring updates subscriber count" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_sub_unsub.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_server_sub_unsub.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_sub_unsub.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    try server.processLine("SUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

    try server.processLine("SUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

    try server.processLine("UNSUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());

    var capture: std.ArrayListUnmanaged(u8) = .empty;
    defer capture.deinit(testing.allocator);
    var bad_ctx = Server.ConnectionContext.initWithCapture(testing.allocator, &bus, null, &capture);
    defer bad_ctx.deinit();

    try server.processLine("SUB updates filter='meta.user.name=\"x\"'", &bad_ctx);
    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());
    try testing.expect(std.mem.containsAtLeast(u8, capture.items, 1, "-ERR invalid filter"));
}

test "Server connection cleanup auto-unsubscribes remaining subscriptions" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_conn_cleanup.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_server_conn_cleanup.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_conn_cleanup.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    {
        var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
        defer conn_ctx.deinit();

        try server.processLine("SUB alpha", &conn_ctx);
        try server.processLine("SUB beta", &conn_ctx);
        try testing.expectEqual(@as(u64, 2), bus.subscriberCount());
    }

    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());
}

fn feedReadChunk(
    server: *Server,
    conn_ctx: *Server.ConnectionContext,
    read_buf: *[Server.TEXT_READ_BUF_SIZE]u8,
    buffered_len: *usize,
    discarding_oversized_line: *bool,
    chunk: []const u8,
) !void {
    const testing = std.testing;
    try testing.expect(chunk.len <= read_buf.len - buffered_len.*);

    const dest = read_buf[buffered_len.* .. buffered_len.* + chunk.len];
    std.mem.copyForwards(u8, dest, chunk);
    server.processReadBuffer(conn_ctx, read_buf, buffered_len, discarding_oversized_line, chunk.len);
}

test "TCP framing handles partial command split across reads" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_partial_reads.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_partial_reads.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_partial_reads.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET alpha va");
    try testing.expectEqual(@as(usize, "SET alpha va".len), buffered_len);
    try testing.expect(store.get("alpha") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "lue\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const entry = store.get("alpha") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("value", entry.value);
}

test "TCP framing handles multiple commands in one read" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_multi_commands.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_multi_commands.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_multi_commands.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET k1 v1\nSET k2 v2\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const e1 = store.get("k1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v1", e1.value);

    const e2 = store.get("k2") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v2", e2.value);
}

test "TCP framing preserves buffered tail across mixed full and partial reads" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_mixed_reads.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_mixed_reads.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_mixed_reads.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET k3 v3\nSET k4 ");

    const e3 = store.get("k3") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v3", e3.value);
    try testing.expectEqual(@as(usize, "SET k4 ".len), buffered_len);
    try testing.expectEqualStrings("SET k4 ", read_buf[0..buffered_len]);
    try testing.expect(store.get("k4") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "v4\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const e4 = store.get("k4") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v4", e4.value);
}

test "binary AUTH: verify, enforce capabilities, replace and free token state" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_auth.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_auth.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_auth.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const kp = auth.generateKeypair();
    const pks = [_]auth.PublicKey{kp.public_key};

    var server = Server.init(testing.allocator, &store, &bus, .{
        .auth_enforce = true,
        .auth_public_keys = &pks,
        .auth_max_token_age = 7200,
    });

    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    // Unauthenticated: protected command fails closed.
    {
        const resp = try server.executeForConnectionWithAlloc(
            .{ .set = .{ .key = "ok:1", .value = "v" } },
            &conn_ctx,
            testing.allocator,
        );
        try testing.expect(resp == .err);
        try testing.expectEqualStrings("auth required", resp.err);
    }

    // Garbage token: rejected, no state stored.
    {
        const resp = try server.executeForConnectionWithAlloc(.{ .auth = "junk" }, &conn_ctx, testing.allocator);
        try testing.expect(resp == .err);
        try testing.expect(conn_ctx.auth_state == null);
    }

    // Valid token scoped to "ok:" set access.
    const now: u64 = @intCast(@divFloor(core.compat.nowMs(), 1000));
    const caps = &[_]auth.Capability{
        .{ .op = .set, .match_type = .prefix, .pattern = "ok:" },
        .{ .op = .subscribe, .match_type = .prefix, .pattern = "ok:" },
    };
    const token = try auth.encode("alice", now, now + 3600, 7, caps, &kp.secret_key, testing.allocator);
    defer testing.allocator.free(token);

    {
        const resp = try server.executeForConnectionWithAlloc(.{ .auth = token }, &conn_ctx, testing.allocator);
        try testing.expect(resp == .ok);
        try testing.expect(conn_ctx.auth_state != null);
        try testing.expectEqualStrings("alice", conn_ctx.auth_state.?.subject);
    }

    // Authenticated: in-scope write permitted, out-of-scope denied.
    {
        const ok_resp = try server.executeForConnectionWithAlloc(
            .{ .set = .{ .key = "ok:1", .value = "v" } },
            &conn_ctx,
            testing.allocator,
        );
        try testing.expect(ok_resp == .ok);

        const denied = try server.executeForConnectionWithAlloc(
            .{ .set = .{ .key = "no:1", .value = "v" } },
            &conn_ctx,
            testing.allocator,
        );
        try testing.expect(denied == .err);
        try testing.expectEqualStrings("permission denied", denied.err);
    }

    // SUBSCRIBE is capability-gated at the connection layer.
    {
        const ok_sub = try server.executeForConnectionWithAlloc(.{ .subscribe = .{ .channel = "ok:events" } }, &conn_ctx, testing.allocator);
        try testing.expect(ok_sub == .ok);
        try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

        const denied_sub = try server.executeForConnectionWithAlloc(.{ .subscribe = .{ .channel = "no:events" } }, &conn_ctx, testing.allocator);
        try testing.expect(denied_sub == .err);
        try testing.expectEqualStrings("permission denied", denied_sub.err);
    }

    // Re-AUTH replaces the previous state without leaking it (leak check via testing allocator).
    {
        const token2 = try auth.encode("bob", now, now + 3600, 8, caps, &kp.secret_key, testing.allocator);
        defer testing.allocator.free(token2);
        const resp = try server.executeForConnectionWithAlloc(.{ .auth = token2 }, &conn_ctx, testing.allocator);
        try testing.expect(resp == .ok);
        try testing.expectEqualStrings("bob", conn_ctx.auth_state.?.subject);
    }
}

test "binary AUTH without configured keys reports auth not configured" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_auth_nokeys.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_auth_nokeys.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_auth_nokeys.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    const resp = try server.executeForConnectionWithAlloc(.{ .auth = "whatever" }, &conn_ctx, testing.allocator);
    try testing.expect(resp == .err);
    try testing.expectEqualStrings("auth not configured", resp.err);
}

test "TCP framing rejects oversized line and recovers for next valid command" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_oversized_line.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_oversized_line.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_oversized_line.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    var writes: std.ArrayListUnmanaged(u8) = .empty;
    defer writes.deinit(testing.allocator);

    var conn_ctx = Server.ConnectionContext.initWithCapture(testing.allocator, &bus, null, &writes);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    var oversized: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    @memset(&oversized, 'x');

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, oversized[0..]);
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(discarding_oversized_line);
    try testing.expect(std.mem.indexOf(u8, writes.items, "-ERR request too large\r\n") != null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "tail-without-newline");
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(discarding_oversized_line);
    try testing.expect(store.get("ok") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "\nSET ok value\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(!discarding_oversized_line);

    const ok_entry = store.get("ok") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("value", ok_entry.value);
}

test "handleReplicationConnection does not emit unread acks on one-way replication commands" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    const listen_addr = try core.compat.net.Address.parseIp("127.0.0.1", 0);
    var listener = try listen_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const bound_port = listener.inner.socket.address.getPort();

    const AcceptCtx = struct {
        listener: *core.compat.net.ServerCompat,
        server: *Server,

        fn run(ctx: @This()) void {
            var conn = ctx.listener.accept() catch return;
            defer conn.stream.close();
            var transport = secure_channel.Transport{ .stream = &conn.stream };
            ctx.server.handleReplicationConnection(&transport, null);
        }
    };

    const thread = try std.Thread.spawn(.{}, AcceptCtx.run, .{AcceptCtx{
        .listener = &listener,
        .server = &server,
    }});
    defer thread.join();

    const connect_addr = core.compat.net.Address.initIp4(.{ 127, 0, 0, 1 }, bound_port);
    var client = try core.compat.net.tcpConnectToAddress(connect_addr);
    defer client.close();

    var key_buf: [32]u8 = undefined;
    var val_buf: [1024]u8 = undefined;
    @memset(&val_buf, 'r');

    // Stream 500 one-way SET frames + 1 DEL frame without reading any response.
    for (0..500) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "repl:key:{d}", .{i});
        try wire.writeCommand(&client, .{ .set = .{
            .key = key,
            .value = &val_buf,
            .worm = false,
        } });
    }
    try wire.writeCommand(&client, .{ .delete = "repl:key:0" });

    // Follow immediately with a request-response replication RPC (proof_prefix_root).
    // If one-way commands emitted .ok frames, reading the next frame here would read .ok
    // instead of the proof_prefix_root JSON value payload.
    var rpc_args = [_][]const u8{ "repl:key:", "limit=0" };
    try wire.writeCommand(&client, .{ .exec = .{
        .procedure = "proof_prefix_root",
        .args = rpc_args[0..],
    } });

    const ReadAdapter = struct {
        stream: *core.compat.net.Stream,
        pub fn read(adapter: *@This(), dest: []u8) !usize {
            return adapter.stream.read(dest);
        }
    };
    var reader = ReadAdapter{ .stream = &client };
    const resp = try wire.readResponseAlloc(&reader, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, resp);

    try testing.expect(resp == .value);
    try testing.expect(resp.value != null);
    try testing.expect(std.mem.indexOf(u8, resp.value.?, "\"entry_count\":499") != null);
    try testing.expect(store.get("repl:key:0") == null);
    try testing.expect(store.get("repl:key:499") != null);
}

test "handleReplicationConnection applies vrabitq_install without emitting unread ack" {
    const testing = std.testing;
    const NamespaceRegistry = @import("../vector/index.zig").NamespaceRegistry;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();
    _ = try reg.getOrCreate("vec:rbq:", .cosine);

    var server = Server.init(testing.allocator, &store, &bus, .{
        .vector_registry = &reg,
    });

    const listen_addr = try core.compat.net.Address.parseIp("127.0.0.1", 0);
    var listener = try listen_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const bound_port = listener.inner.socket.address.getPort();

    const AcceptCtx = struct {
        listener: *core.compat.net.ServerCompat,
        server: *Server,

        fn run(ctx: @This()) void {
            var conn = ctx.listener.accept() catch return;
            defer conn.stream.close();
            var transport = secure_channel.Transport{ .stream = &conn.stream };
            ctx.server.handleReplicationConnection(&transport, null);
        }
    };

    const thread = try std.Thread.spawn(.{}, AcceptCtx.run, .{AcceptCtx{
        .listener = &listener,
        .server = &server,
    }});
    defer thread.join();

    const connect_addr = core.compat.net.Address.initIp4(.{ 127, 0, 0, 1 }, bound_port);
    var client = try core.compat.net.tcpConnectToAddress(connect_addr);
    defer client.close();

    const centroid_floats = [_]f32{ 0.25, -0.5, 0.75, 1.0 };
    const rotation_floats = [_]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };

    try wire.writeCommand(&client, .{ .vrabitq_install = .{
        .namespace = "vec:rbq:",
        .dim = 4,
        .seed = 0xCAFE_1234,
        .centroid = std.mem.sliceAsBytes(&centroid_floats),
        .rotation = std.mem.sliceAsBytes(&rotation_floats),
    } });

    // Follow with a request-response RPC to prove vrabitq_install has been
    // processed and emitted no unread .ok frame ahead of the RPC response.
    var rpc_args = [_][]const u8{ "vec:rbq:", "limit=0" };
    try wire.writeCommand(&client, .{ .exec = .{
        .procedure = "proof_prefix_root",
        .args = rpc_args[0..],
    } });

    const ReadAdapter = struct {
        stream: *core.compat.net.Stream,
        pub fn read(adapter: *@This(), dest: []u8) !usize {
            return adapter.stream.read(dest);
        }
    };
    var reader = ReadAdapter{ .stream = &client };
    const resp = try wire.readResponseAlloc(&reader, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, resp);
    try testing.expect(resp == .value);

    const idx = reg.get("vec:rbq:") orelse return error.TestUnexpectedResult;
    idx.lock.lockShared();
    defer idx.lock.unlockShared();
    const params = idx.getRabitqParams() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 4), params.dim);
    try testing.expectEqual(@as(u64, 0xCAFE_1234), params.seed);
    try testing.expectApproxEqAbs(@as(f32, 0.25), params.centroid[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), params.centroid[3], 1e-6);
    try testing.expectEqual(Metric.cosine, idx.metric);
}

test "stalled subscriber is evicted instead of stalling publishers" {
    if (comptime core.compat.wasm_target) return error.SkipZigTest;
    const testing = std.testing;
    const net = core.compat.net;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const listen_addr = try net.Address.parseIp("127.0.0.1", 0);
    var listener = try listen_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const port = listener.inner.socket.address.getPort();

    // The subscriber's end of the socket: connects and never reads.
    var client = try net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer client.close();
    var accepted = try listener.accept();
    defer accepted.stream.close();
    accepted.stream.write_timeout_ms = 2_000;

    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, &accepted.stream);
    conn_ctx.binary_mode = true;
    defer conn_ctx.deinit();
    try conn_ctx.subscribe("feed", null);

    // Publish large events until the peer's buffers are full and one send hits the
    // event deadline. Before this change every publish from here on blocked 2 s.
    const payload = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    const started = core.compat.nowNs();
    var published: usize = 0;
    while (published < 4096 and !conn_ctx.closed.load(.acquire)) : (published += 1) {
        try bus.publish("feed", payload);
    }
    const until_evicted_ms = @divTrunc(core.compat.nowNs() - started, 1_000_000);

    try testing.expect(conn_ctx.closed.load(.acquire));
    try testing.expectEqual(@as(u64, 1), bus.evictionCount());
    // One bounded send deadline, not an unbounded stall.
    try testing.expect(until_evicted_ms < 10_000);

    // Once evicted, publishing to the dead subscriber costs nothing.
    const t2 = core.compat.nowNs();
    var i: usize = 0;
    while (i < 100) : (i += 1) try bus.publish("feed", payload);
    try testing.expect(@divTrunc(core.compat.nowNs() - t2, 1_000_000) < 1_000);
    try testing.expectEqual(@as(u64, 1), bus.evictionCount());

    // The peer sees the shutdown (EOF or error) after draining what was buffered,
    // rather than a hung socket.
    client.beginRead(5_000, false);
    var sink: [4096]u8 = undefined;
    var saw_end = false;
    var reads: usize = 0;
    while (reads < 1_000_000) : (reads += 1) {
        const n = client.read(&sink) catch {
            saw_end = true;
            break;
        };
        if (n == 0) {
            saw_end = true;
            break;
        }
    }
    try testing.expect(saw_end);
}

test "binary pipelining coalesces bursts and flushes before partial-frame read" {
    if (comptime core.compat.wasm_target) return error.SkipZigTest;
    const testing = std.testing;
    const net = core.compat.net;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();
    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();
    var metrics = ServerMetrics.init();

    var server = Server.init(testing.allocator, &store, &bus, .{
        .metrics = &metrics,
        .timeout_ms = 5_000,
    });

    const listen_addr = try net.Address.parseIp("127.0.0.1", 0);
    var listener = try listen_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const port = listener.inner.socket.address.getPort();

    const AcceptCtx = struct {
        listener: *net.ServerCompat,
        server: *Server,
        fn run(ctx: @This()) void {
            var conn = ctx.listener.accept() catch return;
            _ = ctx.server.connection_limit.acquire(ctx.server.config.max_connections);
            ctx.server.handleConnection(conn, null);
            _ = &conn;
        }
    };
    const th = try std.Thread.spawn(.{}, AcceptCtx.run, .{AcceptCtx{
        .listener = &listener,
        .server = &server,
    }});
    defer th.join();

    var client = try net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer client.close();
    core.compat.setNoDelay(client.getHandle());
    client.beginRead(2_000, false);

    // Serialize "WW" + 5 complete frames + the first 3 bytes of a 6th GET frame.
    const VecWriter = struct {
        list: std.ArrayListUnmanaged(u8) = .empty,
        alloc: std.mem.Allocator,
        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.list.appendSlice(self.alloc, data);
        }
    };
    var batch = VecWriter{ .alloc = testing.allocator };
    defer batch.list.deinit(testing.allocator);
    try batch.writeAll(&wire.WIRE_MAGIC);
    try wire.writeCommand(&batch, .{ .set = .{ .key = "pipe:1", .value = "v1", .worm = false } });
    try wire.writeCommand(&batch, .{ .set = .{ .key = "pipe:2", .value = "v2", .worm = false } });
    try wire.writeCommand(&batch, .{ .get = "pipe:1" });
    try wire.writeCommand(&batch, .{ .get = "pipe:2" });
    try wire.writeCommand(&batch, .{ .get = "pipe:missing" });

    var tail_cmd = VecWriter{ .alloc = testing.allocator };
    defer tail_cmd.list.deinit(testing.allocator);
    try wire.writeCommand(&tail_cmd, .{ .get = "pipe:1" });
    try testing.expect(tail_cmd.list.items.len > 3);

    // Send 5 complete frames + partial 6th header in a single write.
    try batch.writeAll(tail_cmd.list.items[0..3]);
    try client.writeAll(batch.list.items);

    const ReadAdapter = struct {
        stream: *net.Stream,
        pub fn read(a: *@This(), dest: []u8) !usize {
            return a.stream.read(dest);
        }
    };
    var reader = ReadAdapter{ .stream = &client };

    // All 5 responses must arrive immediately even though frame 6 is incomplete
    // (ReadAdapter must flush before blocking on the remaining bytes of frame 6).
    for (0..5) |idx| {
        const resp = try wire.readResponseAlloc(&reader, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        switch (idx) {
            0, 1 => try testing.expect(resp == .ok),
            2 => try testing.expectEqualStrings("v1", resp.value.?),
            3 => try testing.expectEqualStrings("v2", resp.value.?),
            4 => try testing.expect(resp == .value and resp.value == null),
            else => unreachable,
        }
    }

    // Complete frame 6 and verify reply + sharded metrics snapshot.
    try client.writeAll(tail_cmd.list.items[3..]);
    const resp6 = try wire.readResponseAlloc(&reader, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, resp6);
    try testing.expectEqualStrings("v1", resp6.value.?);

    const snap = metrics.snapshot();
    try testing.expectEqual(@as(u64, 6), snap.tcp_commands_completed);
    try testing.expectEqual(@as(u64, 6), snap.tcp_commands_succeeded);
    try testing.expect(snap.tcp_last_successful_command_completed_ms > 0);
}

test "SubReactor serves more subscribers than worker threads and resumes on UNSUB" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const net = core.compat.net;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();
    try store.set("after:unsub", "alive", false);

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    // Pick an ephemeral free port, then hand it to Server.run with only 4 workers.
    var probe = try (try net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    const port = probe.inner.socket.address.getPort();
    probe.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{
        .bind_address = "127.0.0.1",
        .port = port,
        .worker_count = 4,
        .timeout_ms = 5_000,
    });
    defer server.deinit();

    const RunCtx = struct {
        s: *Server,
        fn run(ctx: @This()) void {
            ctx.s.run() catch {};
        }
    };
    const srv_th = try std.Thread.spawn(.{}, RunCtx.run, .{RunCtx{ .s = &server }});
    defer {
        server.stop();
        // Wake blocked listener.accept() with one loopback connect.
        if (net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, port))) |*wake_c| {
            var wc = wake_c.*;
            wc.close();
        } else |_| {}
        srv_th.join();
    }

    // Wait until Server.run is listening.
    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const n_subs: usize = 24; // 6x the 4-worker pool!
    const n_msgs: usize = 100;
    var subs: [n_subs]net.Stream = undefined;
    var opened: usize = 0;
    errdefer for (0..opened) |i| subs[i].close();

    const ReadAdapter = struct {
        stream: *net.Stream,
        pub fn read(a: *@This(), dest: []u8) !usize {
            return a.stream.read(dest);
        }
    };

    for (0..n_subs) |i| {
        var c: net.Stream = undefined;
        var tries: usize = 0;
        while (true) : (tries += 1) {
            if (net.tcpConnectToAddress(addr)) |s| {
                c = s;
                break;
            } else |_| {
                if (tries > 200) return error.TestUnexpectedResult;
                core.compat.io().sleep(.fromMilliseconds(5), .awake) catch {};
            }
        }
        core.compat.setNoDelay(c.getHandle());
        c.beginRead(5_000, false);
        try c.writeAll(&wire.WIRE_MAGIC);
        try wire.writeCommand(&c, .{ .subscribe = .{ .channel = "fanout:test", .filter = null } });
        var r = ReadAdapter{ .stream = &c };
        const resp = try wire.readResponseAlloc(&r, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        try testing.expect(resp == .ok);
        subs[i] = c;
        opened += 1;
    }

    // Open a 25th connection (publisher) while all 24 subscribers are parked — must NOT starve!
    var pub_c = try net.tcpConnectToAddress(addr);
    defer pub_c.close();
    core.compat.setNoDelay(pub_c.getHandle());
    pub_c.beginRead(5_000, false);
    try pub_c.writeAll(&wire.WIRE_MAGIC);

    for (0..n_msgs) |m| {
        var payload_buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "msg-{d}", .{m});
        try wire.writeCommand(&pub_c, .{ .publish = .{ .channel = "fanout:test", .message = payload } });
    }
    var pub_r = ReadAdapter{ .stream = &pub_c };
    for (0..n_msgs) |_| {
        const resp = try wire.readResponseAlloc(&pub_r, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        try testing.expect(resp == .ok);
    }

    // Every one of the 24 subscribers must receive all 100 events in strict order!
    for (0..n_subs) |i| {
        var r = ReadAdapter{ .stream = &subs[i] };
        for (0..n_msgs) |m| {
            const ev = try wire.readResponseAlloc(&r, testing.allocator);
            defer protocol.deinitResponse(testing.allocator, ev);
            try testing.expect(ev == .event);
            var exp_buf: [32]u8 = undefined;
            const exp = try std.fmt.bufPrint(&exp_buf, "msg-{d}", .{m});
            try testing.expectEqualStrings("fanout:test", ev.event.channel);
            try testing.expectEqualStrings(exp, ev.event.message);
        }
    }

    // Subscriber #0 sends UNSUB + GET to verify seamless unpark-to-worker resumption.
    try wire.writeCommand(&subs[0], .{ .unsubscribe = "fanout:test" });
    try wire.writeCommand(&subs[0], .{ .get = "after:unsub" });
    var r0 = ReadAdapter{ .stream = &subs[0] };
    const u_resp = try wire.readResponseAlloc(&r0, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, u_resp);
    try testing.expect(u_resp == .ok);
    const g_resp = try wire.readResponseAlloc(&r0, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, g_resp);
    try testing.expect(g_resp == .value);
    try testing.expectEqualStrings("alive", g_resp.value.?);

    for (0..n_subs) |i| subs[i].close();
}

test "SubReactor re-parks a subscriber after a rate-limited reply" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const net = core.compat.net;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var probe = try (try net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    const port = probe.inner.socket.address.getPort();
    probe.deinit();

    // One command per second: SUB spends the only token, so the next frame is refused.
    var server = Server.init(testing.allocator, &store, &bus, .{
        .bind_address = "127.0.0.1",
        .port = port,
        .worker_count = 2,
        .timeout_ms = 5_000,
        .max_commands_per_sec = 1,
    });
    defer server.deinit();

    const RunCtx = struct {
        s: *Server,
        fn run(ctx: @This()) void {
            ctx.s.run() catch {};
        }
    };
    const srv_th = try std.Thread.spawn(.{}, RunCtx.run, .{RunCtx{ .s = &server }});
    defer {
        server.stop();
        if (net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, port))) |*wake_c| {
            var wc = wake_c.*;
            wc.close();
        } else |_| {}
        srv_th.join();
    }

    const ReadAdapter = struct {
        stream: *net.Stream,
        pub fn read(a: *@This(), dest: []u8) !usize {
            return a.stream.read(dest);
        }
    };

    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var sub_c: net.Stream = undefined;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        if (net.tcpConnectToAddress(addr)) |s| {
            sub_c = s;
            break;
        } else |_| {
            if (tries > 200) return error.TestUnexpectedResult;
            core.compat.io().sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
    defer sub_c.close();
    core.compat.setNoDelay(sub_c.getHandle());
    sub_c.beginRead(5_000, false);
    try sub_c.writeAll(&wire.WIRE_MAGIC);
    try wire.writeCommand(&sub_c, .{ .subscribe = .{ .channel = "repark:test", .filter = null } });
    var sub_r = ReadAdapter{ .stream = &sub_c };
    {
        const resp = try wire.readResponseAlloc(&sub_r, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        try testing.expect(resp == .ok);
    }

    // Unpark the session with commands until one is refused. The refusal is the last
    // reply on an otherwise idle connection, which is the state under test.
    var limited = false;
    var attempts: usize = 0;
    while (!limited and attempts < 20) : (attempts += 1) {
        try wire.writeCommand(&sub_c, .{ .get = "repark:missing" });
        const resp = try wire.readResponseAlloc(&sub_r, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        if (resp == .err) {
            try testing.expectEqualStrings("rate limited", resp.err);
            limited = true;
        }
    }
    try testing.expect(limited);

    var pub_c = try net.tcpConnectToAddress(addr);
    defer pub_c.close();
    core.compat.setNoDelay(pub_c.getHandle());
    pub_c.beginRead(5_000, false);
    try pub_c.writeAll(&wire.WIRE_MAGIC);
    try wire.writeCommand(&pub_c, .{ .publish = .{ .channel = "repark:test", .message = "after-limit" } });
    var pub_r = ReadAdapter{ .stream = &pub_c };
    {
        const resp = try wire.readResponseAlloc(&pub_r, testing.allocator);
        defer protocol.deinitResponse(testing.allocator, resp);
        try testing.expect(resp == .ok);
    }

    // The event must arrive without the subscriber sending anything else.
    const ev = try wire.readResponseAlloc(&sub_r, testing.allocator);
    defer protocol.deinitResponse(testing.allocator, ev);
    try testing.expect(ev == .event);
    try testing.expectEqualStrings("repark:test", ev.event.channel);
    try testing.expectEqualStrings("after-limit", ev.event.message);
}
