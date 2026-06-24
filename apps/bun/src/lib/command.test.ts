import { describe, expect, test } from "bun:test";
import { parseCommand } from "./command";

describe("parseCommand", () => {
  test("parses GET", () => {
    expect(parseCommand("GET alpha")).toEqual({ kind: "GET", key: "alpha" });
  });

  test("parses DEL", () => {
    expect(parseCommand("DEL alpha")).toEqual({ kind: "DEL", key: "alpha" });
  });

  test("parses SUB/UNSUB", () => {
    expect(parseCommand("SUB updates")).toEqual({ kind: "SUB", channel: "updates" });
    expect(parseCommand("SUB updates filter='meta.about=\"user-x\"'")).toEqual({
      kind: "SUB",
      channel: "updates",
      filter: "filter='meta.about=\"user-x\"'",
    });
    expect(parseCommand("UNSUB updates")).toEqual({ kind: "UNSUB", channel: "updates" });
  });

  test("parses STATUS and CLUSTER STATUS", () => {
    expect(parseCommand("STATUS")).toEqual({ kind: "STATUS" });
    expect(parseCommand("CLUSTER STATUS")).toEqual({ kind: "CLUSTER_STATUS" });
  });

  test("parses SET with and without WORM", () => {
    expect(parseCommand("SET k v")).toEqual({ kind: "SET", key: "k", value: "v", worm: false });
    expect(parseCommand("SET k v WORM")).toEqual({ kind: "SET", key: "k", value: "v", worm: true });
  });

  test("parses PUB with space-preserving message", () => {
    expect(parseCommand("PUB chan hello world")).toEqual({
      kind: "PUB",
      channel: "chan",
      message: "hello world",
    });
  });

  test("rejects empty input", () => {
    expect(() => parseCommand("   \n\t")).toThrow("Missing command");
  });

  test("rejects invalid command arity", () => {
    expect(() => parseCommand("GET")).toThrow("Invalid GET command");
    expect(() => parseCommand("DEL")).toThrow("Invalid DEL command");
    expect(() => parseCommand("SUB")).toThrow("Invalid SUB command");
    expect(() => parseCommand("UNSUB")).toThrow("Invalid UNSUB command");
    expect(() => parseCommand("SET k")).toThrow("Invalid SET command");
    expect(() => parseCommand("PUB chan")).toThrow("Invalid PUB command");
  });

  test("rejects unsupported commands", () => {
    expect(() => parseCommand("PING")).toThrow("Unsupported command: PING");
  });
});
