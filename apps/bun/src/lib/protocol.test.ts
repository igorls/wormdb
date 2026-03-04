import { describe, expect, test } from "bun:test";
import { parseSingleResponse } from "./protocol";

describe("parseSingleResponse", () => {
  test("parses +OK", () => {
    expect(parseSingleResponse("+OK\r\n")).toEqual({ type: "ok" });
  });

  test("parses -ERR", () => {
    expect(parseSingleResponse("-ERR boom\r\n")).toEqual({ type: "error", message: "boom" });
  });

  test("parses null bulk", () => {
    expect(parseSingleResponse("$-1\r\n")).toEqual({ type: "null" });
  });

  test("parses bulk payload", () => {
    expect(parseSingleResponse("$5\r\nhello\r\n")).toEqual({ type: "bulk", value: "hello" });
  });

  test("reports malformed bulk payload", () => {
    expect(parseSingleResponse("$5 hello")).toEqual({ type: "error", message: "Malformed bulk response" });
    expect(parseSingleResponse("$abc\r\nhello\r\n")).toEqual({
      type: "error",
      message: "Invalid bulk response length",
    });
  });

  test("parses event payload", () => {
    expect(parseSingleResponse(">EVENT updates\r\nhello\r\n")).toEqual({
      type: "event",
      channel: "updates",
      message: "hello",
    });
  });

  test("reports malformed event payload", () => {
    expect(parseSingleResponse(">EVENT updates hello")).toEqual({
      type: "error",
      message: "Malformed event response",
    });
  });

  test("reports unknown response", () => {
    expect(parseSingleResponse("WAT\r\n")).toEqual({
      type: "error",
      message: "Unknown response format: WAT",
    });
  });
});
