//! Zig 0.16 compatibility helpers for WormDB
//!
//! Thin wrappers around APIs that changed in Zig 0.16 to minimize
//! code churn across the codebase.

const std = @import("std");
const builtin = @import("builtin");

/// A convenience Mutex wrapper using the global single-threaded Io instance.
/// In 0.16, std.Io.Mutex.lock/unlock require an Io parameter.
/// This wrapper provides the old `.lock()` / `.unlock()` API that WormDB uses
/// extensively in shard mutexes and WAL enqueue protection.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// RwLock compatibility wrapper using the global blocking Io instance.
pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(io());
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(io());
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(io());
    }
};

/// Futex compatibility wrapper.
/// In 0.16, std.Thread.Futex moved to std.Io.futexWait/futexWake.
pub const Futex = struct {
    pub fn timedWait(ptr: *std.atomic.Value(u32), expected: u32, timeout_ns: anytype) void {
        const zio = io();
        const timeout = std.Io.Timeout{
            .duration = .{
                .raw = .fromNanoseconds(@intCast(timeout_ns)),
                .clock = .awake,
            },
        };
        zio.futexWaitTimeout(u32, &ptr.raw, expected, timeout) catch {};
    }

    pub fn wake(ptr: *std.atomic.Value(u32), count: u32) void {
        const zio = io();
        zio.futexWake(u32, &ptr.raw, count);
    }
};

/// Returns a blocking Io instance for synchronous operations.
/// Uses the global single-threaded Threaded instance.
pub inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Returns the current working directory as an Io.Dir.
pub inline fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// File I/O helpers wrapping 0.16's Io-based APIs with the blocking Io instance.
/// Provides the old writeAll/readAll/close/sync API that WormDB uses extensively.
pub const File = struct {
    pub fn writeAll(file: std.Io.File, data: []const u8) !void {
        try file.writeStreamingAll(io(), data);
    }

    pub fn readAll(file: std.Io.File, buf: []u8) !usize {
        // Use the streaming reader so successive readAll calls advance the
        // shared file-seek position (positional reader always reads from
        // offset 0, which breaks incremental parsing of WAL / snapshot).
        var reader = file.readerStreaming(io(), &.{});
        var total: usize = 0;
        while (total < buf.len) {
            const slice = reader.interface.readSliceShort(buf[total..]) catch |err| switch (err) {
                error.ReadFailed => return if (reader.err) |e| e else error.InputOutput,
            };
            if (slice == 0) break;
            total += slice;
        }
        return total;
    }

    pub fn close(file: std.Io.File) void {
        file.close(io());
    }

    pub fn sync(file: std.Io.File) !void {
        try file.sync(io());
    }

    pub fn stat(file: std.Io.File) !std.Io.File.Stat {
        return file.stat(io());
    }

    pub fn stdout() std.Io.File {
        return std.Io.File.stdout();
    }

    pub fn seekTo(file: std.Io.File, offset: u64) !void {
        const zio = io();
        try zio.vtable.fileSeekTo(zio.userdata, file, offset);
    }

    pub fn seekBy(file: std.Io.File, offset: i64) !void {
        const zio = io();
        try zio.vtable.fileSeekBy(zio.userdata, file, offset);
    }

    pub fn setLength(file: std.Io.File, new_length: u64) !void {
        try file.setLength(io(), new_length);
    }
};

/// Dir I/O helpers wrapping 0.16's Io-based APIs.
pub const Dir = struct {
    pub fn openFile(dir: std.Io.Dir, path: []const u8, opts: std.Io.Dir.OpenFileOptions) !std.Io.File {
        return dir.openFile(io(), path, opts);
    }

    pub fn createFile(dir: std.Io.Dir, path: []const u8, opts: std.Io.Dir.CreateFileOptions) !std.Io.File {
        return dir.createFile(io(), path, opts);
    }

    pub fn rename(dir: std.Io.Dir, old: []const u8, new: []const u8) !void {
        return dir.rename(old, dir, new, io());
    }

    pub fn makePath(dir: std.Io.Dir, path: []const u8) !void {
        return dir.createDirPath(io(), path);
    }

    /// Replacement for removed 0.15 `Dir.realpathAlloc(allocator, sub_path)`.
    /// Returns a caller-owned absolute path.
    pub fn realPathAlloc(dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try dir.realPathFile(io(), sub_path, &buffer);
        return allocator.dupe(u8, buffer[0..n]);
    }
};

/// Current timestamp in milliseconds since UNIX epoch.
/// Replaces removed `std.time.milliTimestamp`. Uses the 0.16 `std.Io` clock
/// vtable so it works on every platform (the old `std.c.clock_gettime` path
/// did not compile for the Windows ABI).
pub fn nowMs() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

/// Current monotonic timestamp in nanoseconds.
/// Replaces removed `std.time.nanoTimestamp`. `.awake` is the monotonic clock
/// (CLOCK_MONOTONIC on Linux), matching the previous implementation.
pub fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(io(), .awake).toNanoseconds());
}

/// Fill `buf` with cryptographically secure random bytes.
/// Replaces removed `std.crypto.random.bytes`.
pub fn randomBytes(buf: []u8) void {
    io().random(buf);
}

/// Safe integer-to-enum conversion. Replaces removed `std.meta.intToEnum`.
/// Returns `error.InvalidEnumTag` if `tag` does not correspond to a valid field.
pub fn intToEnum(comptime E: type, tag: anytype) error{InvalidEnumTag}!E {
    const tag_int: @typeInfo(E).@"enum".tag_type = @intCast(tag);
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (f.value == tag_int) return @as(E, @enumFromInt(tag_int));
    }
    return error.InvalidEnumTag;
}

/// Raw libc socket() wrapper. `posix.socket` was removed in Zig 0.16.
pub fn socket(domain: u32, sock_type: u32, protocol: u32) !std.posix.fd_t {
    const rc = std.c.socket(domain, sock_type, protocol);
    if (rc < 0) return error.SocketCreationFailed;
    return @intCast(rc);
}

/// Raw libc bind() wrapper. `posix.bind` was removed in Zig 0.16.
pub fn bind(fd: std.posix.fd_t, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) !void {
    if (std.c.bind(fd, addr, len) < 0) return error.BindFailed;
}

/// Raw libc listen() wrapper. `posix.listen` was removed in Zig 0.16.
pub fn listen(fd: std.posix.fd_t, backlog: u31) !void {
    if (std.c.listen(fd, backlog) < 0) return error.ListenFailed;
}

/// Raw libc accept4() wrapper. `posix.accept` was removed in Zig 0.16.
pub fn accept4(listener_fd: std.posix.fd_t, flags: u32) !std.posix.fd_t {
    const rc = std.c.accept4(listener_fd, null, null, @intCast(flags));
    if (rc < 0) return error.AcceptFailed;
    return @intCast(rc);
}

/// Raw libc close() wrapper. `posix.close` was removed in Zig 0.16.
pub fn close(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

/// Disable Nagle's algorithm (TCP_NODELAY) on a connected socket — critical
/// for low-latency request/response. Best-effort: failures are ignored.
///
/// `std.posix.setsockopt` is a hard `@compileError` on Windows, so the Windows
/// path calls Winsock's `setsockopt` directly. The Io.net socket handle is a
/// `HANDLE` wrapping the underlying `SOCKET`, recovered here via `@intFromPtr`.
pub fn setNoDelay(handle: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        const setsockopt = @extern(
            *const fn (usize, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
            .{ .name = "setsockopt", .library_name = "ws2_32" },
        );
        const IPPROTO_TCP: c_int = 6;
        const TCP_NODELAY: c_int = 1;
        const one: c_int = 1;
        _ = setsockopt(@intFromPtr(handle), IPPROTO_TCP, TCP_NODELAY, @ptrCast(&one), @sizeOf(c_int));
    } else {
        std.posix.setsockopt(
            handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }
}

/// Bound socket send so slow/dead peers cannot block a writer forever.
/// Best-effort; failures are ignored.
///
/// Windows: `SO_SNDTIMEO` is a DWORD in milliseconds.
/// POSIX: `struct timeval`.
pub fn setSendTimeoutMs(handle: std.posix.fd_t, timeout_ms: u32) void {
    if (builtin.os.tag == .windows) {
        const setsockopt = @extern(
            *const fn (usize, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
            .{ .name = "setsockopt", .library_name = "ws2_32" },
        );
        // winsock2.h
        const SOL_SOCKET: c_int = 0xffff;
        const SO_SNDTIMEO: c_int = 0x1005;
        var ms: u32 = timeout_ms;
        _ = setsockopt(@intFromPtr(handle), SOL_SOCKET, SO_SNDTIMEO, @ptrCast(&ms), @sizeOf(u32));
    } else {
        const sec: i64 = @intCast(timeout_ms / 1000);
        const usec: i64 = @as(i64, @intCast(timeout_ms % 1000)) * 1000;
        const timeval = std.posix.timeval{ .sec = @intCast(sec), .usec = @intCast(usec) };
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeval),
        ) catch {};
    }
}

/// Windows sockets created by Zig use AFD directly and are not Winsock socket
/// objects. Submit the same AFD read/write as std.Io, but wait on a private event
/// with a deadline. Always cancel AND drain a pending request before its stack
/// buffers or the destination can go out of scope.
fn socketWindowsBefore(comptime reading: bool, handle: std.posix.fd_t, buf: if (reading) []u8 else []const u8, deadline_ns: i128) !usize {
    const win = std.os.windows;
    if (deadline_ns <= nowNs()) return error.Timeout;
    var event: win.HANDLE = undefined;
    const event_all_access: win.ACCESS_MASK = @bitCast(@as(u32, 0x001f0003));
    if (win.ntdll.NtCreateEvent(&event, event_all_access, null, .Notification, .FALSE) != .SUCCESS) return error.SystemResources;
    defer win.CloseHandle(event);
    var iovec = win.AFD.WSABUF(if (reading) .@"var" else .@"const"){ .len = @intCast(@min(buf.len, std.math.maxInt(u32))), .buf = buf.ptr };
    const request: if (reading) win.AFD.RECV_INFO else win.AFD.SEND_INFO = .{
        .BufferArray = @ptrCast(&iovec),
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = if (reading) .{ .NORMAL = true } else .{},
    };
    var iosb: win.IO_STATUS_BLOCK = undefined;
    const status = win.ntdll.NtDeviceIoControlFile(handle, event, null, null, &iosb, if (reading) win.IOCTL.AFD.RECEIVE else win.IOCTL.AFD.SEND, &request, @sizeOf(@TypeOf(request)), null, 0);
    switch (status) {
        .SUCCESS => {},
        .PENDING => {
            const remaining = @max(deadline_ns - nowNs(), 0);
            const timeout: i64 = -@as(i64, @intCast(@min(@divTrunc(remaining + 99, 100), std.math.maxInt(i64))));
            const waited = win.ntdll.NtWaitForSingleObject(event, .FALSE, &timeout);
            if (waited != .SUCCESS) {
                var cancel_iosb: win.IO_STATUS_BLOCK = undefined;
                _ = win.ntdll.NtCancelIoFileEx(handle, &iosb, &cancel_iosb);
                _ = win.ntdll.NtWaitForSingleObject(event, .FALSE, null);
                return if (waited == .TIMEOUT) error.Timeout else error.SocketIoFailed;
            }
        },
        else => return error.SocketIoFailed,
    }
    if (iosb.u.Status != .SUCCESS) return error.SocketIoFailed;
    return iosb.Information;
}

/// POSIX readiness wait before a single-reader socket read. Never extend the
/// absolute deadline on EINTR or when the peer drips another byte.
fn waitReadable(handle: std.posix.fd_t, deadline_ns: i128) !void {
    while (true) {
        const remaining = deadline_ns - nowNs();
        if (remaining <= 0) return error.Timeout;
        const ms: c_int = @intCast(@min(@divTrunc(remaining + 999_999, 1_000_000), std.math.maxInt(c_int)));
        var pfd = std.posix.pollfd{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 };
        const rc = std.c.poll(@ptrCast(&pfd), 1, ms);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.SocketPollFailed;
        }
        if ((pfd.revents & std.posix.POLL.NVAL) != 0) return error.SocketPollFailed;
        if (rc > 0) return;
    }
}

/// Best-effort peer IP of a connected socket via getpeername(2).
/// Returns null when the peer address is unavailable (getpeername failure or a
/// non-IP family) — callers must treat null as "cannot attribute this
/// connection to an IP", never as an error (#89: per-IP policies are enforced
/// only when the peer address is available on the accept path).
///
/// `std.posix.getpeername` is a hard `@compileError` on Windows, so the
/// Windows path calls Winsock's `getpeername` directly (same pattern as
/// `setNoDelay` above) and parses the raw sockaddr bytes.
pub fn getPeerAddress(handle: std.posix.fd_t) ?net.Address {
    if (builtin.os.tag == .windows) {
        const getpeername_fn = @extern(
            *const fn (usize, [*]u8, *c_int) callconv(.c) c_int,
            .{ .name = "getpeername", .library_name = "ws2_32" },
        );
        var buf: [128]u8 align(8) = undefined;
        var len: c_int = buf.len;
        if (getpeername_fn(@intFromPtr(handle), &buf, &len) != 0) return null;
        const family = std.mem.bytesToValue(u16, buf[0..2]);
        switch (family) {
            2 => { // AF_INET
                if (len < 8) return null;
                return .{ .inner = .{ .ip4 = .{
                    .bytes = buf[4..8].*,
                    .port = std.mem.readInt(u16, buf[2..4], .big),
                } } };
            },
            23 => { // AF_INET6
                if (len < 24) return null;
                return .{ .inner = .{ .ip6 = .{
                    .bytes = buf[8..24].*,
                    .port = std.mem.readInt(u16, buf[2..4], .big),
                } } };
            },
            else => return null,
        }
    } else {
        var storage_buf = std.mem.zeroes(std.posix.sockaddr.storage);
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        std.posix.getpeername(handle, @ptrCast(&storage_buf), &len) catch return null;
        switch (storage_buf.family) {
            std.posix.AF.INET => {
                const sa: *const std.posix.sockaddr.in = @ptrCast(&storage_buf);
                return .{ .inner = .{ .ip4 = .{
                    .bytes = @bitCast(sa.addr),
                    .port = std.mem.bigToNative(u16, sa.port),
                } } };
            },
            std.posix.AF.INET6 => {
                const sa: *const std.posix.sockaddr.in6 = @ptrCast(&storage_buf);
                return .{ .inner = .{ .ip6 = .{
                    .bytes = sa.addr,
                    .port = std.mem.bigToNative(u16, sa.port),
                } } };
            },
            else => return null,
        }
    }
}

/// Networking compatibility layer.
/// Maps the old std.net.* API to the new std.Io.net.* API.
pub const net = struct {
    /// Compatibility wrapper for std.net.Address → std.Io.net.IpAddress.
    pub const Address = struct {
        inner: std.Io.net.IpAddress,

        pub fn parseIp(addr: []const u8, port: u16) !Address {
            return .{ .inner = try std.Io.net.IpAddress.parse(addr, port) };
        }

        /// Create IPv4 address from 4 bytes and port.
        pub fn initIp4(bytes: [4]u8, port: u16) Address {
            return .{ .inner = .{ .ip4 = .{
                .bytes = bytes,
                .port = port,
            } } };
        }

        pub fn listen(self: Address, opts: struct {
            reuse_address: bool = true,
            /// Kernel accept queue depth. Join storms under multiplayer load
            /// need more than the Zig default (128) or clients see connect drops.
            kernel_backlog: u31 = 1024,
        }) !ServerCompat {
            const server = try std.Io.net.IpAddress.listen(&self.inner, io(), .{
                .reuse_address = opts.reuse_address,
                .kernel_backlog = opts.kernel_backlog,
            });
            return .{ .inner = server };
        }
    };

    /// Compatibility wrapper for std.net.Server.
    pub const ServerCompat = struct {
        inner: std.Io.net.Server,

        pub const Connection = struct {
            stream: Stream,
        };

        pub fn accept(self: *ServerCompat) !Connection {
            const stream = try self.inner.accept(io());
            return .{ .stream = .{ .inner = stream } };
        }

        pub fn deinit(self: *ServerCompat) void {
            self.inner.deinit(io());
        }
    };

    /// Compatibility wrapper for std.net.Stream.
    /// Provides the old read/writeAll/close API over std.Io.net.Stream.
    pub const Stream = struct {
        inner: std.Io.net.Stream,
        read_timeout_ms: usize = 0,
        read_deadline_ns: ?i128 = null,
        /// Optional session deadline (e.g. accept-to-AUTH). Message boundaries
        /// cannot extend it. The owner clears it only after authentication.
        read_limit_ns: ?i128 = null,
        write_timeout_ms: usize = 0,

        pub fn beginRead(self: *Stream, timeout_ms: usize, allow_idle: bool) void {
            self.read_timeout_ms = timeout_ms;
            self.read_deadline_ns = if (allow_idle) null else nowNs() + @as(i128, timeout_ms) * 1_000_000;
        }

        pub fn read(self: *Stream, buf: []u8) !usize {
            if (buf.len == 0) return 0;
            var deadline = self.read_deadline_ns;
            if (self.read_limit_ns) |limit| deadline = if (deadline) |d| @min(d, limit) else limit;
            const handle = self.inner.socket.handle;
            const n = if (deadline) |d| blk: {
                if (builtin.os.tag == .windows) break :blk try socketWindowsBefore(true, handle, buf, d);
                try waitReadable(handle, d);
                break :blk try self.readAvailable(buf);
            } else try self.readAvailable(buf);
            if (n > 0 and self.read_deadline_ns == null and self.read_timeout_ms > 0) {
                self.read_deadline_ns = nowNs() + @as(i128, self.read_timeout_ms) * 1_000_000;
            }
            return n;
        }

        fn readAvailable(self: *Stream, buf: []u8) !usize {
            const handle = self.inner.socket.handle;
            if (builtin.os.tag == .windows) {
                // Winsock SOCKETs are not CRT file descriptors, so the POSIX
                // read(2) path below is invalid on Windows. Route through the
                // Io net vtable (AFD receive under the hood).
                const zio = io();
                var iov = [_][]u8{buf};
                return zio.vtable.netRead(zio.userdata, handle, &iov);
            }
            // POSIX: raw read(2) on the socket fd.
            return std.posix.read(handle, buf);
        }

        pub fn writeAll(self: *Stream, data: []const u8) !void {
            const handle = self.inner.socket.handle;
            const deadline: ?i128 = if (self.write_timeout_ms > 0) nowNs() + @as(i128, self.write_timeout_ms) * 1_000_000 else null;
            if (builtin.os.tag == .windows) {
                // AFD send; use a cancellable request when a deadline is set.
                // netWrite treats `data[data.len-1]` as the splat pattern, so
                // `data` must be non-empty: pass the payload as a one-element
                // vector with splat=1 and an empty header (an empty `data`
                // slice underflows `data.len - 1` inside the vtable).
                const zio = io();
                const empty_header: []const u8 = "";
                var written: usize = 0;
                while (written < data.len) {
                    const chunk = [_][]const u8{data[written..]};
                    const n = if (deadline) |d|
                        try socketWindowsBefore(false, handle, data[written..], d)
                    else
                        try zio.vtable.netWrite(zio.userdata, handle, empty_header, &chunk, 1);
                    if (n == 0) return error.BrokenPipe;
                    written += n;
                }
                return;
            }
            var written: usize = 0;
            while (written < data.len) {
                if (deadline) |d| if (nowNs() >= d) return error.Timeout;
                const rc = std.c.write(handle, data[written..].ptr, data.len - written);
                if (rc < 0) {
                    const errno = std.posix.errno(rc);
                    switch (errno) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock, // respect SO_SNDTIMEO
                        .PIPE => return error.BrokenPipe,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .BADF => return error.NotOpenForWriting,
                        else => return error.Unexpected,
                    }
                }
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                written += n;
            }
        }

        pub fn close(self: *const Stream) void {
            self.inner.close(io());
        }

        /// Raw fd handle for setsockopt etc.
        pub fn getHandle(self: *const Stream) std.posix.fd_t {
            return self.inner.socket.handle;
        }
    };

    /// Connect to a remote TCP address (used by cluster node).
    pub fn tcpConnectToAddress(addr: Address) !Stream {
        const zio = io();
        const stream = try std.Io.net.IpAddress.connect(&addr.inner, zio, .{ .mode = .stream });
        return .{ .inner = stream };
    }
};
