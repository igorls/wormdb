// PoC: native Swift driving the embedded WormDB engine. Mirrors how an iOS app
// would use it. Run via ffi/swift/run.sh.

import Foundation

func section(_ s: String) { print("\n— \(s) —") }

let dir = NSTemporaryDirectory() + "wormdb-poc-" + UUID().uuidString
print("WormDB embedded PoC (Swift)")
print("engine:", WormDB.version)
print("data dir:", dir)

do {
    section("open + basic set/get (durable)")
    do {
        let db = try WormDB(path: dir, persistence: .full)
        try db.set("greeting", "hello from Swift")
        try db.set("user:1", #"{"name":"Ada","role":"engineer"}"#)
        print("greeting =", try db.getString("greeting") ?? "<nil>")
        print("user:1   =", try db.getString("user:1") ?? "<nil>")
        print("missing  =", try db.getString("nope") ?? "<nil>")

        section("binary values")
        let blob = Data((0..<256).map { UInt8($0 & 0xff) })
        try db.set("blob", blob)
        let back = try db.get("blob")
        print("blob roundtrip ok:", back == blob, "(\(back?.count ?? 0) bytes)")

        section("WORM (write-once) semantics")
        try db.set("license", "MIT-2026", worm: true)
        do {
            try db.set("license", "tampered")
            print("WORM overwrite: UNEXPECTEDLY SUCCEEDED")
        } catch {
            print("WORM overwrite correctly rejected:", error)
        }
        print("license still =", try db.getString("license") ?? "<nil>")

        section("delete")
        try db.delete("user:1")
        print("user:1 after delete =", try db.getString("user:1") ?? "<nil> (gone)")
        // db closes (flushes WAL) on scope exit via deinit
    }

    section("reopen → persistence across handle close (WAL replay)")
    do {
        let db = try WormDB(path: dir, persistence: .full)
        print("greeting survived reopen =", try db.getString("greeting") ?? "<nil>")
        print("license survived reopen  =", try db.getString("license") ?? "<nil>")
        print("user:1 (deleted) =", try db.getString("user:1") ?? "<nil> (still gone)")
    }

    print("\n✅ PoC complete")
} catch {
    print("ERROR:", error)
    exit(1)
}
