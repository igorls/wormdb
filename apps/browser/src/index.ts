/**
 * wormdb-web — Browser client for WormDB
 *
 * Zero-dependency library for direct browser-to-database access
 * over WebSocket using the WormWire binary protocol.
 *
 * @example
 * ```ts
 * import { WormDB } from "wormdb-web";
 *
 * const db = new WormDB("ws://localhost:6390");
 * await db.connect();
 *
 * await db.set("user:1", "alice");
 * const name = await db.get("user:1"); // "alice"
 *
 * await db.subscribe("events", (channel, message) => {
 *   console.log(`${channel}: ${message}`);
 * });
 *
 * const result = await db.exec("increment", "counter", "1");
 * ```
 *
 * @module
 */

export { WormDB, WormDBError } from "./client.js";
export type { WormDBOptions, EventHandler, WormResponse } from "./client.js";

// Low-level codec for advanced usage
export {
    encodeGet,
    encodeSet,
    encodeDel,
    encodeExec,
    encodeAuth,
    encodeSub,
    encodeUnsub,
    encodePub,
    encodeStatus,
    decodeResponse,
    CMD,
    RESP,
} from "./wire.js";
