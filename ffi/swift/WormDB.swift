// Idiomatic Swift wrapper over the WormDB C FFI (ffi/wormdb.h).
//
// This is the kind of thin native layer an iOS app would embed: an in-process,
// single-node KV store backed by the Zig engine (WAL + snapshot persistence,
// std.crypto — no libsodium). No socket server, no clustering.

import Foundation

public final class WormDB {
    public enum Persistence: Int32 {
        case full = 0      // WAL on every write + snapshots (durable)
        case snapshot = 1  // load/save only, no per-write IO
        case memory = 2    // pure in-memory
    }

    public enum WormDBError: Error {
        case openFailed
        case writeFailed      // includes WORM violations
        case deleteFailed
    }

    private let handle: OpaquePointer

    /// Open or create a database rooted at `path` (an app-sandbox directory).
    public init(path: String, persistence: Persistence = .full) throws {
        guard let h = wormdb_open(path, persistence.rawValue) else {
            throw WormDBError.openFailed
        }
        handle = h
    }

    deinit { wormdb_close(handle) }

    public static var version: String { String(cString: wormdb_version()) }

    public func set(_ key: String, _ value: Data, worm: Bool = false) throws {
        let key = Array(key.utf8)
        let rc = key.withUnsafeBufferPointer { kp in
            value.withUnsafeBytes { (vp: UnsafeRawBufferPointer) -> Int32 in
                let vb = vp.bindMemory(to: UInt8.self)
                let fn = worm ? wormdb_set_worm : wormdb_set
                return fn(handle, kp.baseAddress, key.count, vb.baseAddress, value.count)
            }
        }
        if rc != 0 { throw WormDBError.writeFailed }
    }

    /// Convenience for string values.
    public func set(_ key: String, _ value: String, worm: Bool = false) throws {
        try set(key, Data(value.utf8), worm: worm)
    }

    public func get(_ key: String) throws -> Data? {
        let key = Array(key.utf8)
        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: Int = 0
        let rc = key.withUnsafeBufferPointer { kp in
            wormdb_get(handle, kp.baseAddress, key.count, &outPtr, &outLen)
        }
        if rc == 1 { return nil }                 // WORMDB_NOT_FOUND
        if rc != 0 { throw WormDBError.writeFailed }
        guard let p = outPtr else { return nil }
        defer { wormdb_free(p, outLen) }          // buffer is library-owned
        return Data(bytes: p, count: outLen)
    }

    public func getString(_ key: String) throws -> String? {
        guard let d = try get(key) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    public func delete(_ key: String) throws {
        let key = Array(key.utf8)
        let rc = key.withUnsafeBufferPointer { kp in
            wormdb_delete(handle, kp.baseAddress, key.count)
        }
        if rc != 0 { throw WormDBError.deleteFailed }
    }
}
