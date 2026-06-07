// JNI bridge: dev.wormdb.WormDB (Kotlin) -> wormdb C FFI (ffi/wormdb.h).
// Built into libwormdb_jni.so alongside libwormdb_ffi.so via the NDK.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "wormdb.h"

#define DB(handle) ((wormdb_Db *)(intptr_t)(handle))

JNIEXPORT jlong JNICALL
Java_dev_wormdb_WormDB_nativeOpen(JNIEnv *env, jobject self, jstring path, jint persistence) {
    (void)self;
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    wormdb_Db *db = wormdb_open(p, persistence);
    (*env)->ReleaseStringUTFChars(env, path, p);
    return (jlong)(intptr_t)db;
}

JNIEXPORT void JNICALL
Java_dev_wormdb_WormDB_nativeClose(JNIEnv *env, jobject self, jlong handle) {
    (void)env; (void)self;
    wormdb_close(DB(handle));
}

JNIEXPORT jint JNICALL
Java_dev_wormdb_WormDB_nativeSet(JNIEnv *env, jobject self, jlong handle,
                                 jbyteArray key, jbyteArray val, jboolean worm) {
    (void)self;
    jbyte *kp = (*env)->GetByteArrayElements(env, key, NULL);
    jbyte *vp = (*env)->GetByteArrayElements(env, val, NULL);
    jsize klen = (*env)->GetArrayLength(env, key);
    jsize vlen = (*env)->GetArrayLength(env, val);
    int rc = worm
        ? wormdb_set_worm(DB(handle), (const unsigned char *)kp, (size_t)klen,
                          (const unsigned char *)vp, (size_t)vlen)
        : wormdb_set(DB(handle), (const unsigned char *)kp, (size_t)klen,
                     (const unsigned char *)vp, (size_t)vlen);
    (*env)->ReleaseByteArrayElements(env, key, kp, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, val, vp, JNI_ABORT);
    return rc;
}

JNIEXPORT jbyteArray JNICALL
Java_dev_wormdb_WormDB_nativeGet(JNIEnv *env, jobject self, jlong handle, jbyteArray key) {
    (void)self;
    jbyte *kp = (*env)->GetByteArrayElements(env, key, NULL);
    jsize klen = (*env)->GetArrayLength(env, key);

    unsigned char *out = NULL;
    size_t outlen = 0;
    int rc = wormdb_get(DB(handle), (const unsigned char *)kp, (size_t)klen, &out, &outlen);
    (*env)->ReleaseByteArrayElements(env, key, kp, JNI_ABORT);

    if (rc != WORMDB_OK || out == NULL) return NULL;  // not found / error
    jbyteArray result = (*env)->NewByteArray(env, (jsize)outlen);
    if (result != NULL) {
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)outlen, (const jbyte *)out);
    }
    wormdb_free(out, outlen);
    return result;
}

JNIEXPORT jint JNICALL
Java_dev_wormdb_WormDB_nativeDelete(JNIEnv *env, jobject self, jlong handle, jbyteArray key) {
    (void)self;
    jbyte *kp = (*env)->GetByteArrayElements(env, key, NULL);
    jsize klen = (*env)->GetArrayLength(env, key);
    int rc = wormdb_delete(DB(handle), (const unsigned char *)kp, (size_t)klen);
    (*env)->ReleaseByteArrayElements(env, key, kp, JNI_ABORT);
    return rc;
}
