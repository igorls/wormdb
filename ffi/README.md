# WormDB embedding FFI (Path A)

Embed the WormDB engine directly in a native app as a **single-node, in-process**
key/value store — KV + WAL + snapshot persistence, `std.crypto` (no libsodium),
no socket server, no clustering. This is "Path A" from
[meshguard#102](https://github.com/igorls/meshguard/issues/102): once libsodium
became optional, the engine cross-compiles to mobile/ARM as a plain libc library.

## Layout

| file | role |
|---|---|
| [`src/ffi.zig`](../src/ffi.zig) | the C-ABI surface (`export fn wormdb_*`) over `Store` |
| [`ffi/wormdb.h`](wormdb.h) | C header for any caller (Swift bridging header / JNI) |
| [`ffi/swift/`](swift/) | idiomatic Swift wrapper + runnable PoC (iOS-native language) |
| [`ffi/android/`](android/) | JNI bridge (`wormdb_jni.c`) + Kotlin `WormDB.kt` |

`zig build` produces `zig-out/lib/libwormdb_ffi.{dylib,so}` (and a static `.a` on
iOS, since apps cannot `dlopen` user dylibs).

## API

```c
wormdb_Db *wormdb_open(const char *dir, int persistence);  // WORMDB_PERSIST_{FULL,SNAPSHOT,NONE}
void       wormdb_close(wormdb_Db *db);
int        wormdb_set(wormdb_Db*, const u8 *key, size_t, const u8 *val, size_t);
int        wormdb_set_worm(...);            // write-once entry
int        wormdb_get(wormdb_Db*, const u8 *key, size_t, u8 **out, size_t *out_len);  // free with wormdb_free
int        wormdb_delete(wormdb_Db*, const u8 *key, size_t);
void       wormdb_free(u8 *ptr, size_t len);
```

Values from `wormdb_get` are library-owned — release with `wormdb_free`. The store
is internally sharded with per-shard locks, so a handle is safe to share across
threads.

## macOS / Swift — runnable PoC

```bash
bash ffi/swift/run.sh
```

Builds the dylib, compiles [`ffi/swift/WormDB.swift`](swift/WormDB.swift) +
[`main.swift`](swift/main.swift) against the bridging header, and runs a demo that
sets/gets string + binary values, exercises WORM rejection, deletes, and **reopens
to prove persistence** (WAL replay). This is the same `WormDB` class an iOS app
would ship.

## iOS

The Zig source is portable to `aarch64-ios`; only libc/SDK wiring is needed (Zig
stops at "unable to find libSystem" without the SDK sysroot). Produce a static lib
per slice and bundle as an `.xcframework`:

```bash
# device (arm64) + simulator (arm64); add x86_64 sim if you need Intel Macs
zig build -Dtarget=aarch64-ios          -Dno-sodium=true \
  --sysroot "$(xcrun --sdk iphoneos --show-sdk-path)"
zig build -Dtarget=aarch64-ios-simulator -Dno-sodium=true \
  --sysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)"
# -> libwormdb_ffi.a per slice; xcodebuild -create-xcframework ...
```

In Xcode: add the `.xcframework`, set `ffi/wormdb.h` as the bridging header, drop
in `WormDB.swift`. Open with `context` paths under the app sandbox, e.g.
`FileManager.default.urls(for: .applicationSupportDirectory, ...)`.

## Android

Cross-compile the engine `.so` per ABI, then build the JNI bridge `.so` with the
NDK, and place both in `jniLibs/<abi>/`:

```bash
# 1. engine: needs an NDK libc file (see deps/meshguard/android-aarch64-libc.conf
#    as a template; point it at your $ANDROID_NDK_HOME sysroot)
zig build -Dtarget=aarch64-linux-android -Dno-sodium=true --libc android-aarch64-libc.conf
#    -> libwormdb_ffi.so

# 2. JNI bridge (CMake/ndk-build), linking libwormdb_ffi + ffi/wormdb.h:
#    $NDK/.../clang --target=aarch64-linux-android21 -shared \
#       ffi/android/wormdb_jni.c -I ffi -Iffi -L<engine.so dir> -lwormdb_ffi \
#       -o libwormdb_jni.so
```

Add [`WormDB.kt`](android/WormDB.kt) (package `dev.wormdb`) to your sources; it
`System.loadLibrary`s both `.so`s. Open under `context.filesDir`.

## Status (verified in this PoC)

- ✅ Swift PoC builds + runs on macOS: set/get (string + 256-byte binary), WORM
  rejection, delete, and persistence across reopen via WAL replay.
- ✅ `wormdb_jni.c` compiles against the JDK's `jni.h` (JNI ABI correct).
- ✅ FFI library cross-compiles to `aarch64-linux-musl` (ARM, static-friendly,
  no libsodium) — same class of build as Android/iOS, which additionally need
  their NDK/SDK libc.

Not included: clustering / multi-device replication ("Path B") — that layer is
Linux-only today.
