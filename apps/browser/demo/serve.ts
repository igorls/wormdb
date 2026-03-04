/**
 * Minimal static file server for the wormdb-web demo.
 * Usage: bun run apps/browser/demo/serve.ts
 */

const PORT = 8080;

Bun.serve({
    port: PORT,
    async fetch(req) {
        const url = new URL(req.url);
        let path = url.pathname;

        // Default to index.html
        if (path === "/" || path === "") path = "/demo/index.html";

        // Resolve relative to apps/browser/
        const filePath = `./apps/browser${path}`;

        const file = Bun.file(filePath);
        if (await file.exists()) {
            return new Response(file, {
                headers: {
                    // Enable high-resolution performance.now() (µs precision)
                    // Without these, browsers coarsen to 1ms due to Spectre mitigations
                    "Cross-Origin-Opener-Policy": "same-origin",
                    "Cross-Origin-Embedder-Policy": "credentialless",
                },
            });
        }

        return new Response("Not Found", { status: 404 });
    },
});

console.log(`\n  🌐 Demo server: http://localhost:${PORT}\n`);
