// Mesh Topology Canvas — Real-time visualization of the WireGuard mesh network
// Renders nodes in a force-directed layout with animated connections

interface MeshNode {
    id: string;
    meshIp: string;
    state: "alive" | "suspected" | "dead";
    isSelf: boolean;
    x: number;
    y: number;
    vx: number;
    vy: number;
    targetX: number;
    targetY: number;
    pulsePhase: number;
    joinedAt: number;
}

interface MeshConnection {
    from: string;
    to: string;
    strength: number; // 0-1 for animation
    particlePos: number;
}

const COLORS = {
    alive: "#00d68f",
    suspected: "#ffaa00",
    dead: "#ff4d6a",
    self: "#3e8ede",
    connection: "rgba(62, 142, 222, 0.25)",
    connectionActive: "rgba(0, 214, 143, 0.4)",
    particle: "#3e8ede",
    bg: "#1a1d21",
    gridLine: "rgba(255,255,255,0.03)",
    text: "#a0a8b4",
    textBright: "#ffffff",
};

export class MeshCanvas {
    private canvas: HTMLCanvasElement;
    private ctx: CanvasRenderingContext2D;
    private nodes: Map<string, MeshNode> = new Map();
    private connections: MeshConnection[] = [];
    private animFrame: number = 0;
    private isRunning: boolean = false;
    private selfIp: string = "";
    private frameCount: number = 0;

    constructor(canvas: HTMLCanvasElement) {
        this.canvas = canvas;
        this.ctx = canvas.getContext("2d")!;

        // ResizeObserver fires when the container actually gets real dimensions
        // (unlike getBoundingClientRect which returns 0 for display:none elements)
        const ro = new ResizeObserver(() => this.resize());
        ro.observe(canvas.parentElement!);
        window.addEventListener("resize", () => this.resize());
    }

    private resize() {
        const rect = this.canvas.parentElement!.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        this.canvas.width = rect.width * dpr;
        this.canvas.height = rect.height * dpr;
        this.canvas.style.width = `${rect.width}px`;
        this.canvas.style.height = `${rect.height}px`;
        this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        this.layoutNodes(true);
    }

    get width() {
        return this.canvas.width / (window.devicePixelRatio || 1);
    }
    get height() {
        return this.canvas.height / (window.devicePixelRatio || 1);
    }

    /** Update mesh state from cluster data + real peer info. */
    updateFromStatus(kv: Record<string, string>, peers: any[] = []) {
        const total = parseInt(kv.cluster_nodes || "0");
        const enabled = kv.cluster_enabled !== "0";

        if (!enabled || total === 0) {
            this.nodes.clear();
            this.connections = [];
            this.addOrUpdateNode("self", "127.0.0.1", "alive", true);
            return;
        }

        const existingIds = new Set(this.nodes.keys());
        const currentIds = new Set<string>();

        // Self node — use real mesh IP from CLUSTER PEERS
        const selfIp = kv.mesh_ip || "10.99.x.x";
        this.addOrUpdateNode("self", selfIp, "alive", true);
        this.selfIp = selfIp;
        currentIds.add("self");

        if (peers.length > 0) {
            // ── Real peer data from CLUSTER PEERS ──
            for (const peer of peers) {
                const id = `peer-${peer.meshIp}`;
                currentIds.add(id);
                const state: MeshNode["state"] =
                    peer.state === "alive" ? "alive"
                        : peer.state === "suspected" ? "suspected"
                            : "dead";
                this.addOrUpdateNode(id, peer.meshIp, state, false);
            }

            // Remove nodes no longer present
            for (const id of existingIds) {
                if (!currentIds.has(id)) this.nodes.delete(id);
            }

            // Connections: only draw between self and peers with active WormWire TCP
            this.connections = [];
            for (const peer of peers) {
                const peerId = `peer-${peer.meshIp}`;
                if (peer.wormwire === "connected" && this.nodes.has(peerId)) {
                    this.connections.push({
                        from: "self",
                        to: peerId,
                        strength: 1,
                        particlePos: Math.random(),
                    });
                }
            }
        } else {
            // ── Fallback: synthetic peers from counts (no CLUSTER PEERS) ──
            const alive = parseInt(kv.cluster_alive || "0");
            const suspected = parseInt(kv.cluster_suspected || "0");
            const dead = parseInt(kv.cluster_dead || "0");
            const peerCount = alive + suspected + dead;
            for (let i = 0; i < peerCount; i++) {
                const id = `peer-${i}`;
                currentIds.add(id);
                const state: MeshNode["state"] =
                    i < alive ? "alive" : i < alive + suspected ? "suspected" : "dead";
                const ip = `10.99.${Math.floor(i / 255) + 1}.${(i % 255) + 1}`;
                this.addOrUpdateNode(id, ip, state, false);
            }
            for (const id of existingIds) {
                if (!currentIds.has(id)) this.nodes.delete(id);
            }
            // Fallback: star topology from self to all alive nodes
            this.connections = [];
            const aliveNodes = [...this.nodes.values()].filter(
                (n) => n.state === "alive" && n.id !== "self"
            );
            for (const node of aliveNodes) {
                this.connections.push({
                    from: "self",
                    to: node.id,
                    strength: 1,
                    particlePos: Math.random(),
                });
            }
        }

        this.layoutNodes();
    }

    private addOrUpdateNode(
        id: string,
        meshIp: string,
        state: MeshNode["state"],
        isSelf: boolean
    ) {
        const existing = this.nodes.get(id);
        if (existing) {
            existing.state = state;
            existing.meshIp = meshIp;
            return;
        }

        this.nodes.set(id, {
            id,
            meshIp,
            state,
            isSelf,
            x: this.width / 2,
            y: this.height / 2,
            vx: 0,
            vy: 0,
            targetX: 0,
            targetY: 0,
            pulsePhase: Math.random() * Math.PI * 2,
            joinedAt: Date.now(),
        });
    }

    private layoutNodes(snap: boolean = false) {
        const cx = this.width / 2;
        const cy = this.height / 2;
        if (cx === 0 || cy === 0) return; // not visible yet
        const nodes = [...this.nodes.values()];
        const peerNodes = nodes.filter((n) => !n.isSelf);
        const radius = Math.min(cx, cy) * 0.55;

        // Helper: snap if requested OR if node is outside visible area (stuck at 0,0)
        const shouldSnap = (n: MeshNode) =>
            snap || n.x <= 0 || n.y <= 0 || n.x >= this.width || n.y >= this.height;

        // Self at center
        const self = nodes.find((n) => n.isSelf);
        if (self) {
            self.targetX = cx;
            self.targetY = cy;
            if (shouldSnap(self)) { self.x = cx; self.y = cy; }
        }

        // Peers in a circle
        peerNodes.forEach((node, i) => {
            const angle = (i / Math.max(peerNodes.length, 1)) * Math.PI * 2 - Math.PI / 2;
            node.targetX = cx + Math.cos(angle) * radius;
            node.targetY = cy + Math.sin(angle) * radius;
            if (shouldSnap(node)) { node.x = node.targetX; node.y = node.targetY; }
        });
    }

    /** Main render loop — call once, runs continuously. */
    start() {
        if (this.isRunning) return;
        this.isRunning = true;

        // Defer first resize by 2 frames so container has real dimensions
        // (display:none → visible needs a layout pass before getBoundingClientRect works)
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                if (!this.isRunning) return;
                this.resize();
                this._startLoop();
            });
        });
    }

    stop() {
        this.isRunning = false;
        if (this.animFrame) cancelAnimationFrame(this.animFrame);
        this.animFrame = 0;
    }

    private _startLoop() {
        if (!this.isRunning) return;
        const loop = () => {
            if (!this.isRunning) return;
            this.frameCount++;
            this.update();
            this.draw();
            this.animFrame = requestAnimationFrame(loop);
        };
        loop();
    }

    private update() {
        // Smooth node movement toward targets
        for (const node of this.nodes.values()) {
            const dx = node.targetX - node.x;
            const dy = node.targetY - node.y;
            node.x += dx * 0.08;
            node.y += dy * 0.08;
            node.pulsePhase += 0.015;
        }

        // Animate connection particles
        for (const conn of this.connections) {
            conn.particlePos += 0.003;
            if (conn.particlePos > 1) conn.particlePos = 0;
        }
    }

    private draw() {
        const ctx = this.ctx;
        const w = this.width;
        const h = this.height;

        // Background
        ctx.fillStyle = COLORS.bg;
        ctx.fillRect(0, 0, w, h);

        // Subtle grid
        this.drawGrid(ctx, w, h);

        // Connections
        for (const conn of this.connections) {
            this.drawConnection(ctx, conn);
        }

        // Nodes (draw self last so it's on top)
        const sorted = [...this.nodes.values()].sort((a, b) =>
            a.isSelf ? 1 : b.isSelf ? -1 : 0
        );
        for (const node of sorted) {
            this.drawNode(ctx, node);
        }

        // HUD overlay
        this.drawHUD(ctx, w, h);
    }

    private drawGrid(ctx: CanvasRenderingContext2D, w: number, h: number) {
        ctx.strokeStyle = COLORS.gridLine;
        ctx.lineWidth = 1;
        const spacing = 40;
        for (let x = 0; x < w; x += spacing) {
            ctx.beginPath();
            ctx.moveTo(x, 0);
            ctx.lineTo(x, h);
            ctx.stroke();
        }
        for (let y = 0; y < h; y += spacing) {
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
            ctx.stroke();
        }
    }

    private drawConnection(ctx: CanvasRenderingContext2D, conn: MeshConnection) {
        const from = this.nodes.get(conn.from);
        const to = this.nodes.get(conn.to);
        if (!from || !to) return;

        // Connection line
        ctx.strokeStyle = COLORS.connectionActive;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.moveTo(from.x, from.y);
        ctx.lineTo(to.x, to.y);
        ctx.stroke();

        // Traveling particle (data flowing through WireGuard tunnel)
        const px = from.x + (to.x - from.x) * conn.particlePos;
        const py = from.y + (to.y - from.y) * conn.particlePos;

        ctx.beginPath();
        ctx.arc(px, py, 2.5, 0, Math.PI * 2);
        ctx.fillStyle = COLORS.particle;
        ctx.fill();

        // Particle glow
        const grad = ctx.createRadialGradient(px, py, 0, px, py, 8);
        grad.addColorStop(0, "rgba(62, 142, 222, 0.4)");
        grad.addColorStop(1, "rgba(62, 142, 222, 0)");
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(px, py, 8, 0, Math.PI * 2);
        ctx.fill();
    }

    private drawNode(ctx: CanvasRenderingContext2D, node: MeshNode) {
        const baseRadius = node.isSelf ? 22 : 16;
        const pulse = Math.sin(node.pulsePhase) * 0.15 + 1;
        const r = baseRadius * pulse;
        const color = node.isSelf
            ? COLORS.self
            : COLORS[node.state] || COLORS.alive;

        // Outer glow
        const glowRadius = r * 2.5;
        const glow = ctx.createRadialGradient(
            node.x,
            node.y,
            r * 0.8,
            node.x,
            node.y,
            glowRadius
        );
        glow.addColorStop(0, color + "30");
        glow.addColorStop(1, color + "00");
        ctx.fillStyle = glow;
        ctx.beginPath();
        ctx.arc(node.x, node.y, glowRadius, 0, Math.PI * 2);
        ctx.fill();

        // Node ring
        ctx.strokeStyle = color;
        ctx.lineWidth = 2.5;
        ctx.beginPath();
        ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
        ctx.stroke();

        // Node fill (glassmorphic)
        ctx.fillStyle = color + "15";
        ctx.beginPath();
        ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
        ctx.fill();

        // Center dot
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.arc(node.x, node.y, 3.5, 0, Math.PI * 2);
        ctx.fill();

        // Label
        ctx.fillStyle = node.isSelf ? COLORS.textBright : COLORS.text;
        ctx.font = node.isSelf
            ? '600 12px "Inter", system-ui, sans-serif'
            : '500 11px "Inter", system-ui, sans-serif';
        ctx.textAlign = "center";
        ctx.textBaseline = "top";

        const label = node.isSelf ? "self" : node.meshIp;
        ctx.fillText(label, node.x, node.y + r + 8);

        // Mesh IP below label for self
        if (node.isSelf && node.meshIp !== "127.0.0.1") {
            ctx.font = '400 10px "Inter", system-ui, sans-serif';
            ctx.fillStyle = COLORS.text;
            ctx.fillText(node.meshIp, node.x, node.y + r + 24);
        }

        // State badge for non-self
        if (!node.isSelf && node.state !== "alive") {
            ctx.font = '600 9px "Inter", system-ui, sans-serif';
            ctx.fillStyle = COLORS[node.state];
            ctx.fillText(
                node.state.toUpperCase(),
                node.x,
                node.y + r + 22
            );
        }
    }

    private drawHUD(ctx: CanvasRenderingContext2D, w: number, h: number) {
        // Bottom-left status overlay
        const alive = [...this.nodes.values()].filter(
            (n) => n.state === "alive"
        ).length;
        const total = this.nodes.size;
        const connCount = this.connections.length;

        ctx.fillStyle = COLORS.text;
        ctx.font = '500 11px "Inter", system-ui, sans-serif';
        ctx.textAlign = "left";
        ctx.textBaseline = "bottom";

        const lines = [
            `${total} nodes · ${alive} alive · ${connCount} tunnels`,
            `WireGuard mesh · WormWire replication`,
        ];

        lines.forEach((line, i) => {
            ctx.fillText(line, 16, h - 16 - (lines.length - 1 - i) * 18);
        });

        // Top-right "LIVE" badge
        const t = Date.now();
        const blink = Math.sin(t / 500) > 0;
        if (blink) {
            ctx.fillStyle = "#ff4d6a";
            ctx.beginPath();
            ctx.arc(w - 52, 20, 4, 0, Math.PI * 2);
            ctx.fill();
        }
        ctx.fillStyle = COLORS.text;
        ctx.font = '600 10px "Inter", system-ui, sans-serif';
        ctx.textAlign = "right";
        ctx.textBaseline = "top";
        ctx.fillText("LIVE", w - 16, 14);
    }
}
