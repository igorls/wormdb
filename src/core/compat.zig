//! Zig 0.16 compatibility helpers for WormDB
//!
//! Thin wrappers around APIs that changed in Zig 0.16 to minimize
//! code churn across the codebase.

const std = @import("std");

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
    pub fn timedWait(ptr: *std.atomic.Value(u32), expected: u32, _timeout_ns: anytype) void {
        _ = _timeout_ns;
        // Use uncancelable futex wait (non-blocking / no io param needed for cancel)
        const zio = io();
        zio.futexWaitUncancelable(u32, &ptr.raw, expected);
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
        var reader = file.reader(io(), &.{});
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
/// Replaces removed `std.time.milliTimestamp`.
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const sec_ms: i64 = @as(i64, @intCast(ts.sec)) * std.time.ms_per_s;
    const nsec_ms: i64 = @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    return sec_ms + nsec_ms;
}

/// Current monotonic timestamp in nanoseconds.
/// Replaces removed `std.time.nanoTimestamp`.
pub fn nowNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
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

        pub fn listen(self: Address, _opts: struct { reuse_address: bool = false }) !ServerCompat {
            _ = _opts;
            const server = try std.Io.net.IpAddress.listen(&self.inner, io(), .{
                .reuse_address = true,
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

        pub fn read(self: *Stream, buf: []u8) !usize {
            const zio = io();
            const result = self.inner.socket.handle;
            // Use low-level posix read since Io.net.Stream uses Reader interface
            const n = std.posix.read(result, buf) catch |err| {
                return err;
            };
            _ = zio;
            return n;
        }

        pub fn writeAll(self: *Stream, data: []const u8) !void {
            const handle = self.inner.socket.handle;
            var written: usize = 0;
            while (written < data.len) {
                const rc = std.c.write(handle, data[written..].ptr, data.len - written);
                if (rc < 0) {
                    const errno = std.posix.errno(rc);
                    switch (errno) {
                        .INTR => continue,
                        .AGAIN => continue,
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

