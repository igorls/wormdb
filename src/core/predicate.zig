//! Reusable predicate parser/evaluator for memory filters.
//!
//! Grammar, deliberately small:
//!   expr    := clause ("AND" clause)*
//!   clause  := field (= | < | <= | >= | >) literal
//!           | field IN (literal (, literal)*)
//!   field   := ts | <top-level-meta-field> | meta.<top-level-meta-field>
//!   literal := "string" | 'string' | number

const std = @import("std");

pub const PredicateError = error{ InvalidPredicate, OutOfMemory };

pub const Literal = union(enum) {
    string: []const u8,
    number: f64,
};

pub const Operator = enum {
    eq,
    lt,
    lte,
    gte,
    gt,
    in,
};

pub const Clause = struct {
    field: []const u8,
    op: Operator,
    values: []Literal,
};

pub const Predicate = struct {
    clauses: []Clause,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Predicate) void {
        for (self.clauses) |clause| {
            self.allocator.free(clause.values);
        }
        self.allocator.free(self.clauses);
    }

    pub fn matches(self: *const Predicate, meta_json: ?[]const u8, ts_ms: u64) bool {
        for (self.clauses) |clause| {
            if (!evalClause(clause, meta_json, ts_ms)) return false;
        }
        return true;
    }
};

const FieldValue = union(enum) {
    missing,
    string: []const u8,
    number: f64,
};

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) PredicateError!Predicate {
    const expr = unwrapFilterArg(std.mem.trim(u8, raw, " \t\r\n"));
    if (expr.len == 0) return error.InvalidPredicate;

    var clauses: std.ArrayListUnmanaged(Clause) = .empty;
    errdefer {
        for (clauses.items) |clause| allocator.free(clause.values);
        clauses.deinit(allocator);
    }

    var rest = expr;
    while (true) {
        const split = findTopLevelAnd(rest);
        const clause_src = std.mem.trim(u8, rest[0..split], " \t\r\n");
        if (clause_src.len == 0) return error.InvalidPredicate;
        try clauses.append(allocator, try parseClause(allocator, clause_src));
        if (split == rest.len) break;
        rest = rest[split + 3 ..];
    }

    return .{
        .clauses = try clauses.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn unwrapFilterArg(raw: []const u8) []const u8 {
    var s = raw;
    if (startsWithIgnoreCase(s, "filter=")) s = s["filter=".len..];
    s = std.mem.trim(u8, s, " \t\r\n");
    if (s.len >= 2 and ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '"' and s[s.len - 1] == '"'))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn parseClause(allocator: std.mem.Allocator, src: []const u8) PredicateError!Clause {
    const op_info = findOperator(src) orelse return error.InvalidPredicate;
    const field_raw = std.mem.trim(u8, src[0..op_info.start], " \t\r\n");
    const rhs = std.mem.trim(u8, src[op_info.end..], " \t\r\n");
    const field = normalizeField(field_raw) orelse return error.InvalidPredicate;

    if (op_info.op == .in) {
        if (rhs.len < 2 or rhs[0] != '(' or rhs[rhs.len - 1] != ')') return error.InvalidPredicate;
        var vals: std.ArrayListUnmanaged(Literal) = .empty;
        errdefer vals.deinit(allocator);
        var inner = rhs[1 .. rhs.len - 1];
        while (true) {
            inner = std.mem.trim(u8, inner, " \t\r\n");
            if (inner.len == 0) break;
            const parsed = parseLiteralPrefix(inner) orelse return error.InvalidPredicate;
            try vals.append(allocator, parsed.literal);
            inner = std.mem.trim(u8, inner[parsed.end..], " \t\r\n");
            if (inner.len == 0) break;
            if (inner[0] != ',') return error.InvalidPredicate;
            inner = inner[1..];
        }
        if (vals.items.len == 0) return error.InvalidPredicate;
        return .{ .field = field, .op = .in, .values = try vals.toOwnedSlice(allocator) };
    }

    const parsed = parseLiteralPrefix(rhs) orelse return error.InvalidPredicate;
    if (std.mem.trim(u8, rhs[parsed.end..], " \t\r\n").len != 0) return error.InvalidPredicate;
    const vals = try allocator.alloc(Literal, 1);
    vals[0] = parsed.literal;
    return .{ .field = field, .op = op_info.op, .values = vals };
}

const OpInfo = struct {
    op: Operator,
    start: usize,
    end: usize,
};

fn findOperator(src: []const u8) ?OpInfo {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\'', '"' => {
                i = skipQuoted(src, i) orelse return null;
            },
            '<' => {
                if (i + 1 < src.len and src[i + 1] == '=') return .{ .op = .lte, .start = i, .end = i + 2 };
                return .{ .op = .lt, .start = i, .end = i + 1 };
            },
            '>' => {
                if (i + 1 < src.len and src[i + 1] == '=') return .{ .op = .gte, .start = i, .end = i + 2 };
                return .{ .op = .gt, .start = i, .end = i + 1 };
            },
            '=' => return .{ .op = .eq, .start = i, .end = i + 1 },
            else => {
                if (i + 2 <= src.len and wordAtIgnoreCase(src, i, "IN")) {
                    return .{ .op = .in, .start = i, .end = i + 2 };
                }
            },
        }
    }
    return null;
}

const ParsedLiteral = struct {
    literal: Literal,
    end: usize,
};

fn parseLiteralPrefix(src: []const u8) ?ParsedLiteral {
    if (src.len == 0) return null;
    if (src[0] == '\'' or src[0] == '"') {
        const end_quote = skipQuoted(src, 0) orelse return null;
        return .{ .literal = .{ .string = src[1..end_quote] }, .end = end_quote + 1 };
    }

    var end: usize = 0;
    while (end < src.len) : (end += 1) {
        const c = src[end];
        if (!((c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E')) break;
    }
    if (end == 0) return null;
    const n = std.fmt.parseFloat(f64, src[0..end]) catch return null;
    return .{ .literal = .{ .number = n }, .end = end };
}

fn normalizeField(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    const field = if (startsWithIgnoreCase(raw, "meta.")) raw["meta.".len..] else raw;
    if (field.len == 0) return null;
    for (field) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return null;
    }
    return field;
}

fn evalClause(clause: Clause, meta_json: ?[]const u8, ts_ms: u64) bool {
    const actual = fieldValue(clause.field, meta_json, ts_ms);
    if (actual == .missing) return false;

    return switch (clause.op) {
        .eq => literalEquals(actual, clause.values[0]),
        .lt => compareNumber(actual, clause.values[0], .lt),
        .lte => compareNumber(actual, clause.values[0], .lte),
        .gte => compareNumber(actual, clause.values[0], .gte),
        .gt => compareNumber(actual, clause.values[0], .gt),
        .in => blk: {
            for (clause.values) |lit| {
                if (literalEquals(actual, lit)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn fieldValue(field: []const u8, meta_json: ?[]const u8, ts_ms: u64) FieldValue {
    if (std.mem.eql(u8, field, "ts")) return .{ .number = @floatFromInt(ts_ms) };
    const meta = meta_json orelse return .missing;
    if (jsonTopLevelField(meta, field)) |v| return v;
    return .missing;
}

fn literalEquals(actual: FieldValue, literal: Literal) bool {
    return switch (literal) {
        .string => |s| switch (actual) {
            .string => |a| std.mem.eql(u8, a, s),
            .number => |n| blk: {
                const parsed = std.fmt.parseFloat(f64, s) catch break :blk false;
                break :blk n == parsed;
            },
            .missing => false,
        },
        .number => |n| switch (actual) {
            .number => |a| a == n,
            .string => |s| blk: {
                const parsed = std.fmt.parseFloat(f64, s) catch break :blk false;
                break :blk parsed == n;
            },
            .missing => false,
        },
    };
}

fn compareNumber(actual: FieldValue, literal: Literal, op: Operator) bool {
    const a = switch (actual) {
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, s) catch return false,
        .missing => return false,
    };
    const b = switch (literal) {
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, s) catch return false,
    };
    return switch (op) {
        .lt => a < b,
        .lte => a <= b,
        .gte => a >= b,
        .gt => a > b,
        else => false,
    };
}

fn jsonTopLevelField(json: []const u8, field: []const u8) ?FieldValue {
    var pos: usize = 0;
    while (pos < json.len and isWs(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '{') return null;
    pos += 1;

    while (pos < json.len) {
        while (pos < json.len and (isWs(json[pos]) or json[pos] == ',')) : (pos += 1) {}
        if (pos >= json.len or json[pos] == '}') return null;
        if (json[pos] != '"') return null;

        const key_end = skipQuoted(json, pos) orelse return null;
        const key = json[pos + 1 .. key_end];
        pos = key_end + 1;

        while (pos < json.len and isWs(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') return null;
        pos += 1;
        while (pos < json.len and isWs(json[pos])) : (pos += 1) {}
        if (pos >= json.len) return null;

        if (std.mem.eql(u8, key, field)) {
            return parseJsonScalar(json, pos);
        }
        pos = skipJsonValue(json, pos) orelse return null;
    }
    return null;
}

fn parseJsonScalar(json: []const u8, pos: usize) ?FieldValue {
    if (json[pos] == '"') {
        const end_quote = skipQuoted(json, pos) orelse return null;
        return .{ .string = json[pos + 1 .. end_quote] };
    }

    var end = pos;
    while (end < json.len and !isWs(json[end]) and json[end] != ',' and json[end] != '}') : (end += 1) {}
    if (end == pos) return null;
    const n = std.fmt.parseFloat(f64, json[pos..end]) catch return null;
    return .{ .number = n };
}

fn skipJsonValue(json: []const u8, start: usize) ?usize {
    if (start >= json.len) return null;
    if (json[start] == '"') {
        const end_quote = skipQuoted(json, start) orelse return null;
        return end_quote + 1;
    }
    if (json[start] == '{' or json[start] == '[') {
        var object_depth: usize = if (json[start] == '{') 1 else 0;
        var array_depth: usize = if (json[start] == '[') 1 else 0;
        var i = start + 1;
        while (i < json.len) : (i += 1) {
            switch (json[i]) {
                '\'', '"' => i = skipQuoted(json, i) orelse return null,
                '{' => object_depth += 1,
                '[' => array_depth += 1,
                '}' => {
                    if (object_depth == 0) return null;
                    object_depth -= 1;
                    if (object_depth == 0 and array_depth == 0) return i + 1;
                },
                ']' => {
                    if (array_depth == 0) return null;
                    array_depth -= 1;
                    if (object_depth == 0 and array_depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return null;
    }

    var end = start;
    while (end < json.len and !isWs(json[end]) and json[end] != ',' and json[end] != '}') : (end += 1) {}
    return end;
}

fn findTopLevelAnd(src: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\'', '"' => i = skipQuoted(src, i) orelse return src.len,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {
                if (depth == 0 and wordAtIgnoreCase(src, i, "AND")) return i;
            },
        }
    }
    return src.len;
}

fn skipQuoted(src: []const u8, start: usize) ?usize {
    const quote = src[start];
    var i = start + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == quote) return i;
    }
    return null;
}

fn wordAtIgnoreCase(src: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > src.len) return false;
    if (start > 0 and isIdent(src[start - 1])) return false;
    if (start + word.len < src.len and isIdent(src[start + word.len])) return false;
    return eqlIgnoreCase(src[start .. start + word.len], word);
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn isIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

const testing = std.testing;

test "predicate parses equality, comparison, IN, and ts" {
    var pred = try parse(testing.allocator, "privacy_level<=1 AND category=\"semantic\" AND sourceType IN ('chat','tool') AND ts>=1700000000");
    defer pred.deinit();

    try testing.expect(pred.matches("{\"privacy_level\":1,\"category\":\"semantic\",\"sourceType\":\"chat\"}", 1700000001));
    try testing.expect(!pred.matches("{\"privacy_level\":2,\"category\":\"semantic\",\"sourceType\":\"chat\"}", 1700000001));
    try testing.expect(!pred.matches("{\"privacy_level\":1,\"category\":\"episodic\",\"sourceType\":\"chat\"}", 1700000001));
    try testing.expect(!pred.matches("{\"privacy_level\":1,\"category\":\"semantic\",\"sourceType\":\"other\"}", 1700000001));
    try testing.expect(!pred.matches("{\"privacy_level\":1,\"category\":\"semantic\",\"sourceType\":\"chat\"}", 1699999999));
}

test "predicate accepts filter wrapper and meta prefix" {
    var pred = try parse(testing.allocator, "filter='meta.about=\"user-x\" AND minImportance>0.7'");
    defer pred.deinit();

    try testing.expect(pred.matches("{\"about\":\"user-x\",\"minImportance\":0.8}", 0));
    try testing.expect(!pred.matches("{\"about\":\"user-y\",\"minImportance\":0.8}", 0));
}

test "predicate rejects unsupported nested fields and OR" {
    try testing.expectError(error.InvalidPredicate, parse(testing.allocator, "meta.user.name=\"x\""));
    try testing.expectError(error.InvalidPredicate, parse(testing.allocator, "a=1 OR b=2"));
}

test "predicate only reads top-level metadata fields" {
    var pred = try parse(testing.allocator, "privacy_level<=1");
    defer pred.deinit();

    try testing.expect(!pred.matches("{\"nested\":{\"privacy_level\":1}}", 0));
    try testing.expect(pred.matches("{\"nested\":{\"privacy_level\":5},\"privacy_level\":1}", 0));
}
