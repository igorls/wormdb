// Minimal WASI preview1 shim — the same one the browser page uses.
//
// Only what the in-memory path needs is implemented properly; everything else returns
// ENOSYS. That is the point: with persistence=none the engine touches the clock, RNG and
// exit, and nothing else. No filesystem, no preopens, no host-specific interface.
//
// errno: badf=8, inval=28, noent=44, nosys=52 (WASI preview1 numbering)

const ENOSYS = 52;
const EBADF = 8;

//  is late-bound: it gets  set to the instance memory after
// instantiation, because the memory does not exist before then.
export function createWasi(memoryRef, { onStdout = () => {} } = {}) {
  const dv = () => new DataView(memoryRef.buffer.buffer);
  const u8 = () => new Uint8Array(memoryRef.buffer.buffer);
  const stub = () => ENOSYS;

  return {
    args_sizes_get(argc, argvBufSize) {
      dv().setUint32(argc, 0, true);
      dv().setUint32(argvBufSize, 0, true);
      return 0;
    },
    args_get: () => 0,
    environ_sizes_get(a, b) {
      dv().setUint32(a, 0, true);
      dv().setUint32(b, 0, true);
      return 0;
    },
    environ_get: () => 0,

    clock_res_get(_id, out) {
      dv().setBigUint64(out, 1n, true); // 1ns
      return 0;
    },
    clock_time_get(id, _precision, out) {
      // 0 = realtime, 1 = monotonic, 2 = process cputime, 3 = thread cputime
      const ms = id === 0 ? Date.now() : performance.now();
      dv().setBigUint64(out, BigInt(Math.floor(ms * 1e6)), true);
      return 0;
    },

    random_get(buf, len) {
      const view = u8().subarray(buf, buf + len);
      if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(view);
      else for (let i = 0; i < len; i++) view[i] = (Math.random() * 256) | 0;
      return 0;
    },

    fd_write(fd, iovs, iovsLen, nwritten) {
      const d = dv();
      let total = 0;
      let text = "";
      for (let i = 0; i < iovsLen; i++) {
        const ptr = d.getUint32(iovs + i * 8, true);
        const len = d.getUint32(iovs + i * 8 + 4, true);
        text += new TextDecoder().decode(u8().subarray(ptr, ptr + len));
        total += len;
      }
      d.setUint32(nwritten, total, true);
      if (fd === 1 || fd === 2) onStdout(text);
      return 0;
    },

    proc_exit(code) {
      const e = new Error(`wasm proc_exit(${code})`);
      e.wasmExit = code;
      throw e;
    },
    sched_yield: () => 0,
    poll_oneoff: () => ENOSYS, // nothing blocks on I/O in the in-memory path

    // Filesystem surface: deliberately unimplemented. persistence=none does not use it, and
    // if something starts to, it should fail loudly rather than silently pretend.
    fd_prestat_get: () => EBADF,
    fd_prestat_dir_name: () => EBADF,
    fd_fdstat_get: () => ENOSYS,
    fd_filestat_get: stub,
    fd_filestat_set_size: stub,
    fd_filestat_set_times: stub,
    fd_pread: stub,
    fd_pwrite: stub,
    fd_read: stub,
    fd_seek: stub,
    fd_sync: stub,
    fd_readdir: stub,
    fd_close: stub,
    path_create_directory: stub,
    path_filestat_get: stub,
    path_filestat_set_times: stub,
    path_link: stub,
    path_open: stub,
    path_readlink: stub,
    path_remove_directory: stub,
    path_rename: stub,
    path_symlink: stub,
    path_unlink_file: stub,
  };
}
