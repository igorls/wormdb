package dev.wormdb

/**
 * Embedded WormDB key/value store for Android — single-node, in-process, backed
 * by the Zig engine (WAL + snapshot persistence, std.crypto, no libsodium).
 *
 * Usage:
 *   val db = WormDB(context.filesDir.resolve("wormdb").absolutePath)
 *   db.set("greeting".toByteArray(), "hello".toByteArray())
 *   val v = db.get("greeting".toByteArray())   // ByteArray? (null if absent)
 *   db.use { ... }                             // AutoCloseable
 */
class WormDB(path: String, persistence: Int = PERSIST_FULL) : AutoCloseable {

    private val handle: Long = nativeOpen(path, persistence)

    init {
        require(handle != 0L) { "wormdb_open failed for path: $path" }
    }

    fun set(key: ByteArray, value: ByteArray, worm: Boolean = false) {
        check(nativeSet(handle, key, value, worm) == 0) { "wormdb_set failed" }
    }

    fun set(key: String, value: String, worm: Boolean = false) =
        set(key.toByteArray(), value.toByteArray(), worm)

    /** Returns the value bytes, or null if the key is absent. */
    fun get(key: ByteArray): ByteArray? = nativeGet(handle, key)

    fun getString(key: String): String? = get(key.toByteArray())?.toString(Charsets.UTF_8)

    fun delete(key: ByteArray) {
        check(nativeDelete(handle, key) == 0) { "wormdb_delete failed" }
    }

    fun delete(key: String) = delete(key.toByteArray())

    override fun close() = nativeClose(handle)

    private external fun nativeOpen(path: String, persistence: Int): Long
    private external fun nativeClose(handle: Long)
    private external fun nativeSet(handle: Long, key: ByteArray, value: ByteArray, worm: Boolean): Int
    private external fun nativeGet(handle: Long, key: ByteArray): ByteArray?
    private external fun nativeDelete(handle: Long, key: ByteArray): Int

    companion object {
        const val PERSIST_FULL = 0      // WAL every write + snapshots (durable)
        const val PERSIST_SNAPSHOT = 1  // load/save only
        const val PERSIST_MEMORY = 2    // in-memory only

        init {
            System.loadLibrary("wormdb_ffi") // the Zig engine
            System.loadLibrary("wormdb_jni") // this JNI bridge
        }
    }
}
