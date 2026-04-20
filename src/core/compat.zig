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
};
