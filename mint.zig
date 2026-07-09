const std = @import("std");
const auth = @import("src/server/auth.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const kp = auth.generateKeypair();
    const caps = &[_]auth.Capability{
        .{ .op = .exec, .match_type = .prefix, .pattern = "inc_" },
        .{ .op = .subscribe, .match_type = .prefix, .pattern = "inc:" },
        .{ .op = .publish, .match_type = .prefix, .pattern = "inc:" },
    };
    
    // expiry way in the future (2100-01-01)
    const token = try auth.encode("web-client", 0, 4102444800, 1, caps, &kp.secret_key, allocator);
    defer allocator.free(token);
    
    const b64_encoder = std.base64.standard.Encoder;
    const token_b64 = try allocator.alloc(u8, b64_encoder.calcSize(token.len));
    defer allocator.free(token_b64);
    _ = b64_encoder.encode(token_b64, token);

    const pk_b64 = try allocator.alloc(u8, b64_encoder.calcSize(kp.public_key.len));
    defer allocator.free(pk_b64);
    _ = b64_encoder.encode(pk_b64, &kp.public_key);

    std.debug.print("export PROXY_SCT={s}\n", .{token_b64});
    std.debug.print("export PROXY_PUBLIC_KEY={s}\n", .{pk_b64});
}
