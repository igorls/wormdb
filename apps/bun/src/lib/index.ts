/**
 * Public surface of the embeddable WormDB Bun client.
 *
 * `WormDB` is the library-grade client (persistent connection, reconnect,
 * pub/sub push, AUTH, append-log wrappers). `WormClient` is the low-level
 * one-shot/persistent request client kept for backwards compatibility.
 */

export {
  WormDB,
  WormServerError,
  type AppendLogCheckpoint,
  type AppendLogCheckpointOptions,
  type AppendLogMmrProof,
  type AppendLogProofBundle,
  type AppendLogReceipt,
  type AppendLogVerifyResult,
  type AppendLogWitness,
  type AppendLogWitnessOptions,
  type EventHandler,
  type ReconnectOptions,
  type Subscription,
  type VsearchHit,
  type VsearchOptions,
  type WormDBOptions,
  type WormDBState,
  type WormEvent,
  type WormEventIterator,
} from "./wormdb";

export {
  WormClient,
  ClientConnectionClosedError,
  ClientTimeoutError,
  type WormClientOptions,
} from "./client";

export {
  MAX_PAYLOAD,
  PayloadTooLargeError,
  WIRE_MAGIC,
  concatBytes,
  decodeResponse,
  encodeAuth,
  encodeCommandFrame,
  encodeSave,
  encodeVdelete,
  isEventCode,
  toBytes,
  tryConsumeFrame,
  type Bytes,
} from "./wire";

export { parseCommand, type ParsedCommand } from "./command";
export type { WormResponse } from "./protocol";
