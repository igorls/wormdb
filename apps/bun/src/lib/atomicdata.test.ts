// Golden vectors ported verbatim from the Rust `crates/atomicdata` tests — the cross-repo parity anchor.
// If these pass, the TS decoder is byte-for-byte the same as the segment builder's decode.
import { describe, expect, test } from "bun:test";
import { deserialize, parseFormat, canonVal, toAttrPairs, type Field } from "./atomicdata";

const hx = (s: string) => Uint8Array.from((s.replace(/\s+/g, "").match(/../g) ?? []).map((p) => parseInt(p, 16)));
const fmt = (pairs: [string, string][]): Field[] => pairs.map(([name, type]) => ({ name, type }));
const vals = (data: Uint8Array, format: Field[]) => deserialize(data, format).map((a) => [a.name, a.value]);

describe("atomicdata decode", () => {
  // THE GOLDEN VECTOR — a real on-chain 84-byte blob: uint64, string, fixed16[], negative float, bool,
  // ipfs (CIDv0), int16, int16[] (extremes + negatives), with a sparse/absent int32 field.
  test("golden on-chain vector", () => {
    const format = fmt([
      ["id", "uint64"], ["name", "string"], ["test2", "fixed16[]"], ["test3", "float"],
      ["unused", "int32"], ["isTrueTrue", "bool"], ["image", "ipfs"], ["gibnumber", "int16"], ["onemore", "int16[]"],
    ]);
    const data = hx(
      "04 12 05 06 4d 75 6e 69 63 68 06 04 12 00 7b 00 21 00 90 03 07 00 00 40 bf 09 01 0a 22 " +
      "12 20 b7 41 a3 b1 cf 5b fe ae 20 8c 86 ef bf ac 8e 0b bc 0c 92 ee a7 ef 9a 2d 96 40 12 " +
      "e6 c2 21 0f 4c 0b f6 01 0c 08 fe ff 03 ff ff 03 10 18 10 be 3a a9 03 f2 c0 01",
    );
    expect(data.length).toBe(84);
    expect(vals(data, format)).toEqual([
      ["id", "18"], // uint64 -> string
      ["name", "Munich"],
      ["test2", [18, 123, 33, 912]],
      ["test3", -0.75],
      ["isTrueTrue", 1],
      ["image", "Qmag1NRBcpYyz27Kq2demHavXoi7nwbcCfkUq5vh6nuNN7"],
      ["gibnumber", 123],
      ["onemore", [32767, -32768, 8, 12, 8, 3743, -213, 12345]],
    ]);
  });

  test("int16 vs uint16 vs fixed16 of the same 534 -> distinct encodings", () => {
    const format = fmt([["p0", "uint8"], ["p1", "uint8"], ["i", "int16"], ["u", "uint16"], ["p4", "uint8"], ["f", "fixed16"]]);
    expect(vals(hx("06 ac 08 07 96 04 09 16 02"), format)).toEqual([["i", 534], ["u", 534], ["f", 534]]);
  });

  test("float and double, IEEE-754 LE", () => {
    const format = fmt([["wear", "float"], ["share", "double"]]);
    expect(vals(hx("04 00 00 40 3f 05 00 00 00 00 00 01 90 40"), format)).toEqual([["wear", 0.75], ["share", 1024.25]]);
  });

  test("negative int and 64-bit strings", () => {
    const format = fmt([["a", "int32"], ["b", "uint64"], ["c", "int64"]]);
    expect(vals(hx("04 09 05 ff ff ff ff ff ff ff ff ff 01 06 01"), format)).toEqual([
      ["a", -5], ["b", "18446744073709551615"], ["c", "-1"],
    ]);
  });

  test("a field named image with TYPE image is a plain string, NOT base58", () => {
    expect(vals(hx("04 05 68 65 6c 6c 6f"), fmt([["image", "image"]]))).toEqual([["image", "hello"]]);
  });

  test("empty blob, empty string + ipfs", () => {
    expect(deserialize(hx(""), fmt([["id", "uint64"]]))).toEqual([]);
    expect(vals(hx("04 00 05 00"), fmt([["s", "string"], ["i", "ipfs"]]))).toEqual([["s", ""], ["i", ""]]);
  });

  test("errors on truncation / bad identifier", () => {
    const format = fmt([["id", "uint64"]]);
    expect(() => deserialize(hx("04"), format)).toThrow();   // id 4 but no value
    expect(() => deserialize(hx("63 00"), format)).toThrow(); // id 99 out of range
    expect(() => deserialize(hx("01 00"), format)).toThrow(); // id 1 < RESERVED
  });

  test("parseFormat", () => {
    expect(parseFormat([{ name: "rarity", type: "string" }, { name: "power", type: "uint32" }]))
      .toEqual([{ name: "rarity", type: "string" }, { name: "power", type: "uint32" }]);
  });
});

describe("canonVal + toAttrPairs (overlay string form, matches bson_canon)", () => {
  test("canonVal renders like the Rust builder", () => {
    expect(canonVal("Munich")).toBe("Munich");
    expect(canonVal(96)).toBe("96");
    expect(canonVal(-11)).toBe("-11");
    expect(canonVal("265328800")).toBe("265328800"); // uint64 already a string
    expect(canonVal([18, 123, 33, 912])).toBe("[18,123,33,912]");
    expect(canonVal(["a", "b"])).toBe("[a,b]"); // string elements unquoted, matching bson_canon
    expect(canonVal(null as any)).toBe(""); // non-finite float/double -> Null -> "" (NOT "null")
  });

  test("a non-finite float decodes + canonicalizes to '' like bson_canon's Bson::Null", () => {
    // f32 +Inf = 7F800000 (LE 00 00 80 7f) -> decoder returns null -> canon "" (the segment builder stores "")
    expect(toAttrPairs(hx("04 00 00 80 7f"), fmt([["x", "float"]]))).toEqual([[0, ""]]);
  });

  test("toAttrPairs yields [schemaIndex, valueString] for the aa_mint JSON arg", () => {
    // shipload/v1.gas style: quantity(uint32 @idx2), stats(uint64 @idx3), origin_y(int32 @idx5)
    const format = fmt([
      ["name", "string"], ["item_id", "uint16"], ["quantity", "uint32"], ["stats", "uint64"],
      ["origin_x", "int32"], ["origin_y", "int32"],
    ]);
    // ids 6,7,9 -> idx 2,3,5: quantity=96 (uint32 LEB128 "60"), stats=1 (uint64), origin_y=-11 (int32 zigzag 21="15")
    const pairs = toAttrPairs(hx("06 60 07 01 09 15"), format);
    expect(pairs).toEqual([[2, "96"], [3, "1"], [5, "-11"]]);
  });
});
