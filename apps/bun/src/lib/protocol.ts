export type WormResponse =
  | { type: "ok" }
  | { type: "error"; message: string }
  | { type: "null" }
  | { type: "bulk"; value: string }
  | { type: "event"; channel: string; message: string };

export function parseSingleResponse(raw: string): WormResponse {
  if (raw.startsWith("+OK")) {
    return { type: "ok" };
  }

  if (raw.startsWith("-ERR ")) {
    return { type: "error", message: raw.slice(5).trimEnd() };
  }

  if (raw.startsWith("$-1")) {
    return { type: "null" };
  }

  if (raw.startsWith("$")) {
    const split = raw.indexOf("\r\n");
    if (split === -1) {
      return { type: "error", message: "Malformed bulk response" };
    }

    const len = Number(raw.slice(1, split));
    if (!Number.isFinite(len) || len < 0) {
      return { type: "error", message: "Invalid bulk response length" };
    }

    const payloadStart = split + 2;
    const payload = raw.slice(payloadStart, payloadStart + len);
    return { type: "bulk", value: payload };
  }

  if (raw.startsWith(">EVENT ")) {
    const split = raw.indexOf("\r\n");
    if (split === -1) {
      return { type: "error", message: "Malformed event response" };
    }

    const channel = raw.slice(7, split).trim();
    const message = raw.slice(split + 2).trimEnd();
    return { type: "event", channel, message };
  }

  return { type: "error", message: `Unknown response format: ${raw.trim()}` };
}
