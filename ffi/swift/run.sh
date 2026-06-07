#!/usr/bin/env bash
# Build the FFI dylib + the Swift PoC and run it. macOS (Swift = iOS-native lang).
set -euo pipefail
cd "$(dirname "$0")/../.."

zig build   # produces zig-out/lib/libwormdb_ffi.dylib

swiftc ffi/swift/WormDB.swift ffi/swift/main.swift \
  -import-objc-header ffi/wormdb.h \
  -L zig-out/lib -lwormdb_ffi \
  -o zig-out/wormdb-swift-poc

DYLD_LIBRARY_PATH=zig-out/lib exec zig-out/wormdb-swift-poc
