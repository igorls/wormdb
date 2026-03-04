#!/usr/bin/env bun
/**
 * WormDB SCT Keygen — Generate Ed25519 keypair for auth.
 *
 * Outputs:
 *   - Base64-encoded public key (for WormDB config `auth.public_keys`)
 *   - Base64-encoded secret key (for auth provider)
 *   - Hex-encoded keys (for debugging)
 *
 * Usage:
 *   bun run keygen.ts
 *   bun run keygen.ts --save   # writes to .wormdb-keys.json
 */

const keypair = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    true, // extractable
    ["sign", "verify"]
);

// Export raw key bytes
const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", keypair.publicKey));
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keypair.privateKey));

// PKCS#8 for Ed25519 has a 16-byte header, the actual 32-byte seed starts at offset 16
// But we need the full 64-byte libsodium secret key (seed + public key)
const seed = pkcs8.slice(16, 48);
const secretKey = new Uint8Array(64);
secretKey.set(seed, 0);
secretKey.set(publicRaw, 32);

const publicB64 = Buffer.from(publicRaw).toString("base64");
const secretB64 = Buffer.from(secretKey).toString("base64");
const publicHex = Buffer.from(publicRaw).toString("hex");
const secretHex = Buffer.from(secretKey).toString("hex");

console.log("╔═══════════════════════════════════════════════════════════╗");
console.log("║  WormDB Ed25519 Keypair                                   ║");
console.log("╚═══════════════════════════════════════════════════════════╝");
console.log();
console.log("Public Key (base64 — for wormdb.json auth.public_keys):");
console.log(`  ${publicB64}`);
console.log();
console.log("Secret Key (base64 — for auth provider SECRET_KEY env):");
console.log(`  ${secretB64}`);
console.log();
console.log("Public Key (hex):");
console.log(`  ${publicHex}`);
console.log();

if (process.argv.includes("--save")) {
    const keysFile = ".wormdb-keys.json";
    await Bun.write(keysFile, JSON.stringify({
        publicKey: publicB64,
        secretKey: secretB64,
        publicKeyHex: publicHex,
        generatedAt: new Date().toISOString(),
        _warning: "Keep secretKey private. Only share publicKey with WormDB nodes.",
    }, null, 2));
    console.log(`Keys saved to ${keysFile}`);
    console.log("⚠️  Add this file to .gitignore!");
} else {
    console.log("Tip: run with --save to persist keys to .wormdb-keys.json");
}
