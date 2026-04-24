export type ParsedCommand =
  | { kind: "GET"; key: string }
  | { kind: "DEL"; key: string }
  | { kind: "SUB"; channel: string }
  | { kind: "UNSUB"; channel: string }
  | { kind: "STATUS" }
  | { kind: "CLUSTER_STATUS" }
  | { kind: "CLUSTER_PEERS" }
  | { kind: "SET"; key: string; value: string; worm: boolean }
  | { kind: "PUB"; channel: string; message: string }
  | { kind: "EXEC"; procedure: string; args: (string | Uint8Array)[] }
  | {
      kind: "VINSERT";
      key: string;
      vector: Uint8Array;
      worm: boolean;
      namespace: string;
      metric: "cosine" | "dot" | "l2";
      timestamp: bigint;
      async: boolean;
    };

export function parseCommand(command: string): ParsedCommand {
  const parts = command.trim().split(/\s+/);
  if (parts.length === 0 || parts[0].length === 0) {
    throw new Error("Missing command");
  }

  const verb = parts[0].toUpperCase();

  if (verb === "GET") {
    if (parts.length < 2) throw new Error("Invalid GET command");
    return { kind: "GET", key: parts[1] };
  }

  if (verb === "DEL") {
    if (parts.length < 2) throw new Error("Invalid DEL command");
    return { kind: "DEL", key: parts[1] };
  }

  if (verb === "SUB") {
    if (parts.length < 2) throw new Error("Invalid SUB command");
    return { kind: "SUB", channel: parts[1] };
  }

  if (verb === "UNSUB") {
    if (parts.length < 2) throw new Error("Invalid UNSUB command");
    return { kind: "UNSUB", channel: parts[1] };
  }

  if (verb === "STATUS") {
    return { kind: "STATUS" };
  }

  if (verb === "CLUSTER" && parts[1]?.toUpperCase() === "STATUS") {
    return { kind: "CLUSTER_STATUS" };
  }

  if (verb === "CLUSTER" && parts[1]?.toUpperCase() === "PEERS") {
    return { kind: "CLUSTER_PEERS" };
  }

  if (verb === "SET") {
    if (parts.length < 3) throw new Error("Invalid SET command");
    const hasWorm = parts.some((p) => p.toUpperCase() === "WORM");
    return {
      kind: "SET",
      key: parts[1],
      value: parts[2],
      worm: hasWorm,
    };
  }

  if (verb === "PUB") {
    if (parts.length < 3) throw new Error("Invalid PUB command");
    return {
      kind: "PUB",
      channel: parts[1],
      message: parts.slice(2).join(" "),
    };
  }

  if (verb === "EXEC") {
    if (parts.length < 2) throw new Error("Invalid EXEC command");
    return {
      kind: "EXEC",
      procedure: parts[1],
      args: parts.slice(2),
    };
  }

  throw new Error(`Unsupported command: ${verb}`);
}
