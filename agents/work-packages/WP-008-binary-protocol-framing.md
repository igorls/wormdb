# WP-008: Binary Protocol Framing over TCP

## Objective

Migrate WormDB from a text-based, space-delimited protocol to a fast, zero-copy capable, and binary-safe custom binary protocol over raw TCP. This resolves the inability to handle spaces in values and significantly improves parsing efficiency.

## Motivation

The current protocol parser uses `std.mem.tokenizeAny` on spaces and tabs (`SET mykey my value`). This breaks if a value contains a space. While RESP (Redis protocol) is an option, a custom length-prefixed binary protocol maps perfectly to Zig's memory management, enabling zero-copy reads, eliminating string-parsing overhead, and providing robust cross-language support (e.g., for the Bun client).

## Architecture: The "WormWire" Protocol (v1)

The protocol consists of a magic prefix, a fixed-size header, and a variable-length payload. All multi-byte integers are transmitted in **Big Endian** (network byte order) for cross-platform compatibility.

### 1. Connection Handshake (2 Bytes, once per connection)

The first two bytes sent by the client on a new connection **must** be the magic number:

```
[ 0x57 0x57 ]   ("WW" — WormWire)
```

If the server reads any other first two bytes, it must reject the connection with `-ERR binary protocol required\r\n`.

### 2. Frame Header (5 Bytes)

```
[ 1 byte: Command ID ] [ 4 bytes: Total Payload Length (u32, big endian) ]
```

### 3. Payload Size Limit

The maximum allowed payload length is **16 MiB** (`MAX_PAYLOAD_LENGTH = 16 * 1024 * 1024`). The server **must** reject any frame with a declared payload length exceeding this value **before allocating memory**, responding with `ERR (0x03)` and closing the connection. This replaces the oversized-line protection from WP-006.

### 4. Command IDs (u8)

- `0x01` : GET
- `0x02` : SET
- `0x03` : DEL
- `0x04` : STATUS
- `0x05` : CLUSTER_STATUS
- `0x06` : SUB
- `0x07` : UNSUB
- `0x08` : PUB

### 5. Payload Structures

Payloads are sequences of length-prefixed byte arrays or flags.

**GET (0x01), DEL (0x03), SUB (0x06), UNSUB (0x07)**

```
[ 4 bytes: Key/Channel Length ] [ N bytes: Key/Channel Data ]
```

**SET (0x02)**

```
[ 1 byte: Flags ]
    bit 0 = WORM
    bits 1-7 = reserved, must be 0
[ 4 bytes: Key Length ]
[ N bytes: Key Data ]
[ 4 bytes: Value Length ]
[ M bytes: Value Data ]
```

**PUB (0x08)**

```
[ 4 bytes: Channel Length ]
[ N bytes: Channel Data ]
[ 4 bytes: Message Length ]
[ M bytes: Message Data ]
```

**STATUS (0x04) / CLUSTER_STATUS (0x05)**

- _Payload Length: 0_

### 6. Server Responses

Responses use a similar framed structure. Clients **must** always check the response code before interpreting the payload.

**Response Header (5 Bytes)**

```
[ 1 byte: Response Code ] [ 4 bytes: Payload Length (u32, big endian) ]
```

**Response Codes (u8)**

- `0x00` : OK (Success, payload length 0)
- `0x01` : VALUE (Payload contains data — used for GET results and STATUS/CLUSTER_STATUS diagnostics)
- `0x02` : NULL (Key not found, payload length 0)
- `0x03` : ERR (Payload is the UTF-8 error string)
- `0x04` : EVENT (Unsolicited pub/sub push — see §7)

### 7. Pipelining & Pub/Sub Ordering

**Pipelining** is supported: clients may send multiple frames without waiting for responses. The server processes commands sequentially per connection and returns responses in the same order.

**Pub/Sub interleaving:** An `EVENT` (0x04) response may arrive at any point in the response stream, interleaved between responses to pipelined commands. Clients **must** handle this by checking the response code of every frame:

- If `0x04 (EVENT)`: dispatch to the subscription handler.
- Otherwise: match to the next pending request in the pipeline.

## Implementation Plan

### 1. Update `src/core/types.zig`

- Add the `CommandId` enum (`u8`) mapping command variants to their wire IDs.
- Add `pub const MAX_PAYLOAD_LENGTH: u32 = 16 * 1024 * 1024;`

### 2. Create `src/protocol/wire.zig`

- Implement `readFrameAlloc(reader: anytype, allocator: std.mem.Allocator) !Command`.
  - Read the 5-byte header.
  - Validate payload length against `MAX_PAYLOAD_LENGTH`.
  - Switch on Command ID.
  - Read exact bytes based on the lengths provided in the payload.
- Implement `writeResponse(writer: anytype, response: Response) !void`.
  - Write the 1-byte response code.
  - Write payload length (big endian) and data.
- Implement `writeCommand(writer: anytype, cmd: Command) !void`.
  - Symmetric to `readFrameAlloc`, for cluster replication and Zig integration tests.
- All multi-byte reads/writes use `std.mem.readInt(u32, buf, .big)` / `std.mem.writeInt(u32, buf, value, .big)`.

### 3. Update `src/server/tcp.zig`

- On new connection, read the first 2 bytes:
  - If `0x57 0x57`: switch to binary frame read loop using `wire.readFrameAlloc`.
  - Otherwise: fall back to the existing `processReadBuffer` text path.
- For binary connections: replace line-based processing with a streaming `reader` loop that reads headers then payloads. Reject oversized frames before allocating (replaces WP-006 logic for binary mode).
- Reject non-WormWire handshake bytes and close the connection.

### 4. Update the Bun Client (`apps/bun/src/lib/client.ts`)

- Send the `0x5757` magic on connect.
- Refactor the `WormClient` to use `Buffer` and `DataView` for constructing binary payloads and parsing binary responses (big endian).
- Add response-code dispatch to handle interleaved `EVENT` pushes.

### 5. Binary-Only Enforcement

- Require WormWire magic bytes on every new TCP connection.
- Reject non-WormWire handshakes with `-ERR binary protocol required\r\n`.

## Advantages of this Approach

- **O(1) Allocations:** We know exactly how many bytes to allocate for keys and values before reading them.
- **Binary Transparency:** Values can be images, protobuf messages, encrypted payloads, or text containing spaces/newlines. The server doesn't care.
- **Speed:** No tokenization, trim, or string splitting loops required on the server's hot path.
- **Cross-platform safety:** Big endian wire format is universally expected by network tooling and client libraries.
- **Protocol detection:** Magic-byte handshake instantly rejects non-WormWire connections with a clear error message.
