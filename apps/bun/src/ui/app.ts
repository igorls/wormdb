import { MeshCanvas } from "./mesh";

// State Management
const MAX_HISTORY = 40;
const state = {
  currentView: "dashboard",
  isConnected: false,
  reconnectAttempts: 0,
  adminToken: localStorage.getItem("worm_admin_token") || "",
  lastStatus: null as any,
  commandHistory: [] as string[],
  historyIndex: -1,
  history: [] as any[], // List of merged status KVs
};

// DOM Elements
const elements = {
  navItems: document.querySelectorAll(".nav-item"),
  views: document.querySelectorAll(".view"),
  viewTitle: document.getElementById("view-title")!,
  connIndicator: document.getElementById("conn-indicator")!,
  connText: document.getElementById("conn-text")!,
  adminTokenInput: document.getElementById("admin-token") as HTMLInputElement,
  globalRefresh: document.getElementById("global-refresh")!,

  // Dashboard
  statKeys: document.getElementById("stat-keys")!,
  statWal: document.getElementById("stat-wal")!,
  statNodes: document.getElementById("stat-nodes")!,
  statHealth: document.getElementById("stat-health")!,
  rawStatus: document.getElementById("raw-status")!,

  // Charts
  chartKeysLine: document.querySelector("#chart-keys .chart-line") as SVGPathElement,
  chartKeysArea: document.querySelector("#chart-keys .chart-area") as SVGPathElement,
  chartWalLine: document.querySelector("#chart-wal .chart-line") as SVGPathElement,
  chartWalArea: document.querySelector("#chart-wal .chart-area") as SVGPathElement,
  keyRate: document.getElementById("key-rate")!,
  walRate: document.getElementById("wal-rate")!,

  // Console
  consoleOutput: document.getElementById("console-output")!,
  consoleInput: document.getElementById("console-input") as HTMLInputElement,

  // Cluster
  nodesTableBody: document.querySelector("#nodes-table tbody")!,

  // Mesh
  meshCanvas: document.getElementById("mesh-canvas") as HTMLCanvasElement,

  // Events
  sseIndicator: document.getElementById("sse-indicator")!,
  sseText: document.getElementById("sse-text")!,
  eventsOutput: document.getElementById("events-output")!,

  // Deployment
  deployStart: document.getElementById("deploy-start") as HTMLButtonElement,
  deployStop: document.getElementById("deploy-stop") as HTMLButtonElement,
  deployLogs: document.getElementById("deploy-logs")!,

  // Docker Panel
  dockerNodes: document.getElementById("docker-nodes")!,
  dockerCount: document.getElementById("docker-count")!,
  dockerRefresh: document.getElementById("docker-refresh")!,
};

// Initialization
let eventCount = 0;
let meshViz: MeshCanvas | null = null;
let ws: WebSocket | null = null;
let lastDockerSnapshot = "";

function init() {
  elements.adminTokenInput.value = state.adminToken;
  setupEventListeners();
  meshViz = new MeshCanvas(elements.meshCanvas);
  connectWebSocket();
}

function connectWebSocket() {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${protocol}//${location.host}/ws`);

  ws.onopen = () => {
    state.reconnectAttempts = 0;
    updateConnectionStatus(true);
    elements.sseIndicator.classList.add("online");
    elements.sseText.textContent = "Live";
  };

  ws.onclose = () => {
    updateConnectionStatus(false);
    elements.sseIndicator.classList.remove("online");
    state.reconnectAttempts += 1;
    const delay = Math.min(10000, 1000 * Math.max(1, state.reconnectAttempts));
    elements.sseText.textContent = `Reconnecting in ${Math.ceil(delay / 1000)}s`;
    setTimeout(connectWebSocket, delay);
  };

  ws.onerror = () => {
    ws?.close();
  };

  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      switch (msg.type) {
        case "status":
          handleStatusMessage(msg);
          break;
        case "event":
          handleEventMessage(msg);
          break;
        case "docker":
          renderContainerCards(msg.containers || []);
          break;
        case "command_result":
          handleCommandResult(msg);
          break;
        case "docker_result":
          // docker action completed — containers will be pushed via next docker broadcast
          break;
      }
    } catch { /* ignore malformed */ }
  };
}

function handleStatusMessage(data: any) {
  updateConnectionStatus(data.connected !== false);
  if (!data.connected) {
    // Show failover info if available
    if (data.failureCount && data.failureCount >= 2) {
      updateConnectionStatus(false, `Failing over from ${data.target}...`);
    }
    return;
  }
  state.lastStatus = data;

  const statusKV = data.response?.type === "bulk" ? parseKV(data.response.value) : {};
  const clusterKV = data.cluster?.type === "bulk" ? parseKV(data.cluster.value) : {};
  const mergedKV = { ...statusKV, ...clusterKV };
  const historyEntry: Record<string, string | number> = { ...mergedKV, timestamp: Date.now() };

  // Include self mesh IP from CLUSTER PEERS
  if (data.selfMeshIp) {
    mergedKV.mesh_ip = data.selfMeshIp;
    historyEntry.mesh_ip = data.selfMeshIp;
  }

  state.history.push(historyEntry);
  if (state.history.length > MAX_HISTORY) state.history.shift();

  updateDashboard(mergedKV, data);
  updateClusterTable(mergedKV);
  updateCharts();

  // Pass real peer data to mesh visualization
  if (meshViz) {
    meshViz.updateFromStatus(mergedKV, data.peers || []);
  }
}

function handleEventMessage(data: { channel: string; message: string }) {
  if (eventCount === 0) elements.eventsOutput.innerHTML = "";
  eventCount++;
  const entry = document.createElement("div");
  entry.className = "console-entry";
  const time = new Date().toLocaleTimeString();
  const timeSpan = document.createElement("span");
  timeSpan.className = "event-time";
  timeSpan.textContent = `[${time}] `;

  const channelSpan = document.createElement("span");
  channelSpan.className = "event-channel";
  channelSpan.textContent = `[${data.channel}] `;

  const messageSpan = document.createElement("span");
  messageSpan.textContent = data.message;

  entry.append(timeSpan, channelSpan, messageSpan);
  elements.eventsOutput.appendChild(entry);
  elements.eventsOutput.scrollTop = elements.eventsOutput.scrollHeight;
}

function handleCommandResult(data: any) {
  const entry = document.createElement("div");
  entry.className = "console-entry";
  const container = document.createElement("div");
  container.className = "console-res";
  if (data.error) {
    container.classList.add("console-err");
    container.textContent = String(data.error);
  } else {
    const value = data.response?.value ?? JSON.stringify(data.response);
    container.textContent = String(value);
  }
  entry.appendChild(container);
  elements.consoleOutput.appendChild(entry);
  elements.consoleOutput.scrollTop = elements.consoleOutput.scrollHeight;
}



function setupEventListeners() {
  // Navigation
  elements.navItems.forEach(item => {
    item.addEventListener("click", () => {
      const view = item.getAttribute("data-view")!;
      switchView(view);
    });
  });

  // Admin Token
  elements.adminTokenInput.addEventListener("input", (e) => {
    state.adminToken = (e.target as HTMLInputElement).value;
    localStorage.setItem("worm_admin_token", state.adminToken);
  });

  // Global Refresh (trigger a status push from server)
  elements.globalRefresh.addEventListener("click", () => {
    // Force a fresh status fetch via HTTP as fallback
    fetch("/api/status").then(r => r.json()).then(data => {
      handleStatusMessage({ type: "status", ...data, connected: true });
    }).catch(() => { });
  });

  // Docker panel refresh
  elements.dockerRefresh.addEventListener("click", () => {
    fetch("/api/docker/containers").then(r => r.json()).then(data => {
      renderContainerCards(data.containers || []);
    }).catch(() => { });
  });

  elements.dockerNodes.addEventListener("click", (e) => {
    const target = e.target as HTMLElement;
    const button = target.closest("button[data-action][data-container]") as HTMLButtonElement | null;
    if (!button) return;
    const action = button.dataset.action;
    const container = button.dataset.container;
    if (!action || !container) return;
    containerAction(container, action);
  });

  // Console Input — send commands over WebSocket
  elements.consoleInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      const cmd = elements.consoleInput.value.trim();
      if (cmd) executeCommand(cmd);
    } else if (e.key === "ArrowUp") {
      navigateHistory(1);
    } else if (e.key === "ArrowDown") {
      navigateHistory(-1);
    }
  });

  // Deployment
  elements.deployStart.addEventListener("click", () => runDeployment("start"));
  elements.deployStop.addEventListener("click", () => runDeployment("stop"));
}

// UI Logic
function switchView(viewId: string) {
  state.currentView = viewId;

  elements.navItems.forEach(item => {
    item.classList.toggle("active", item.getAttribute("data-view") === viewId);
  });

  elements.views.forEach(view => {
    view.classList.toggle("hidden", view.id !== `view-${viewId}`);
  });

  const titleByView: Record<string, string> = {
    dashboard: "Dashboard",
    console: "Console",
    mesh: "Mesh Topology",
    cluster: "Cluster Nodes",
    events: "Event Stream",
    deployment: "Deployment",
  };
  elements.viewTitle.textContent = titleByView[viewId] ?? "Dashboard";

  if (viewId === "console") {
    setTimeout(() => elements.consoleInput.focus(), 10);
  }

  // Start/stop mesh render loop based on visibility
  if (viewId === "mesh" && meshViz) {
    // Trigger resize after the view becomes visible (canvas needs non-zero dimensions)
    requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"));
    });
    meshViz.start();
  } else if (meshViz) {
    meshViz.stop();
  }
}

function updateConnectionStatus(online: boolean, message?: string) {
  state.isConnected = online;
  elements.connIndicator.classList.toggle("online", online);
  elements.connText.textContent = message ?? (online ? "Connected" : "Disconnected");
}

function formatBytes(bytes: number) {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
}

function parseKV(text: string): Record<string, string> {
  const lines = text.split("\n");
  const kv: Record<string, string> = {};
  lines.forEach(line => {
    const [key, ...rest] = line.split("=");
    if (key && rest.length > 0) {
      kv[key.trim()] = rest.join("=").trim();
    }
  });
  return kv;
}



function updateCharts() {
  if (state.history.length < 2) return;

  const width = 400;
  const height = 120;
  const padding = 5;

  // Calculate rates (per second)
  const last = state.history[state.history.length - 1];
  const prev = state.history[state.history.length - 2];
  const dt = (last.timestamp - prev.timestamp) / 1000;

  const keyDiff = (parseInt(last.keys || "0") - parseInt(prev.keys || "0"));
  const keyRate = dt > 0 ? (keyDiff / dt).toFixed(1) : "0.0";
  elements.keyRate.textContent = `${keyRate} keys/s`;

  const walDiff = (parseInt(last.wal_size || "0") - parseInt(prev.wal_size || "0"));
  const walRate = dt > 0 ? (walDiff / dt) : 0;
  elements.walRate.textContent = `${formatBytes(Math.abs(walRate))}/s`;

  // Draw Keys Chart
  const keyValues = state.history.map(h => parseInt(h.keys || "0"));
  drawSVGChart(elements.chartKeysLine, elements.chartKeysArea, keyValues, width, height, padding);

  // Draw WAL Chart
  const walValues = state.history.map(h => parseInt(h.wal_size || "0"));
  drawSVGChart(elements.chartWalLine, elements.chartWalArea, walValues, width, height, padding);
}

function drawSVGChart(lineEl: SVGPathElement, areaEl: SVGPathElement, values: number[], width: number, height: number, padding: number) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;

  const points = values.map((v, i) => {
    const x = (i / (MAX_HISTORY - 1)) * width;
    const y = height - padding - ((v - min) / range) * (height - 2 * padding);
    return { x, y };
  });

  if (points.length === 0) return;

  const lineD = points.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ");
  lineEl.setAttribute("d", lineD);

  const areaD = `${lineD} L ${points[points.length - 1].x} ${height} L ${points[0].x} ${height} Z`;
  areaEl.setAttribute("d", areaD);
}

function updateDashboard(kv: Record<string, string>, raw: any) {
  elements.statKeys.textContent = kv.keys || "0";
  elements.statWal.textContent = kv.wal_size ? formatBytes(parseInt(kv.wal_size)) : "0 B";
  elements.statNodes.textContent = kv.cluster_nodes || "1";

  const alive = parseInt(kv.cluster_alive || "0");
  const dead = parseInt(kv.cluster_dead || "0");

  if (kv.cluster_enabled === "0") {
    elements.statHealth.textContent = "Standalone";
    elements.statHealth.style.color = "var(--text-secondary)";
  } else if (dead > 0) {
    elements.statHealth.textContent = "Degraded";
    elements.statHealth.style.color = "var(--warning)";
  } else {
    elements.statHealth.textContent = "Healthy";
    elements.statHealth.style.color = "var(--success)";
  }

  elements.rawStatus.textContent = JSON.stringify(raw, null, 2);
}

function updateClusterTable(kv: Record<string, string>) {
  if (kv.cluster_enabled === "0") {
    elements.nodesTableBody.innerHTML = '<tr><td colspan="4" class="text-center">Cluster mode disabled</td></tr>';
    return;
  }

  // In a real scenario, we'd have a list of nodes. 
  // For now, let's synthesize from status if it's all we have, 
  // or handle a more detailed nodes list if the API provided it.

  let html = "";
  const total = parseInt(kv.cluster_nodes || "0");
  for (let i = 0; i < total; i++) {
    const isLocal = i === 0;
    html += `
      <tr>
        <td><code style="color:var(--accent)">node-${i}</code> ${isLocal ? "(self)" : ""}</td>
        <td>127.0.0.1:${6389 + i}</td>
        <td><span style="color:var(--success)">● Alive</span></td>
        <td>${i === 0 ? "Leader" : "Follower"}</td>
      </tr>
    `;
  }
  elements.nodesTableBody.innerHTML = html || '<tr><td colspan="4" class="text-center">No nodes detected</td></tr>';
}

async function executeCommand(cmd: string) {
  // Add to UI immediately
  const entry = document.createElement("div");
  entry.className = "console-entry";
  const cmdLine = document.createElement("div");
  cmdLine.className = "console-cmd";
  cmdLine.textContent = `> ${cmd}`;
  entry.appendChild(cmdLine);
  elements.consoleOutput.appendChild(entry);
  elements.consoleInput.value = "";
  elements.consoleOutput.scrollTop = elements.consoleOutput.scrollHeight;

  // Add to history
  state.commandHistory.unshift(cmd);
  if (state.commandHistory.length > 50) state.commandHistory.pop();
  state.historyIndex = -1;

  // Send over WebSocket
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: "command", command: cmd }));
  } else {
    // Fallback to HTTP
    try {
      const res = await fetch("/api/db/command", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-admin-token": state.adminToken },
        body: JSON.stringify({ command: cmd })
      });
      const data = await res.json();
      handleCommandResult(data);
    } catch (err) {
      handleCommandResult({ error: `System Error: ${err instanceof Error ? err.message : String(err)}` });
    }
  }
}

function navigateHistory(direction: number) {
  if (state.commandHistory.length === 0) return;

  state.historyIndex += direction;
  if (state.historyIndex >= state.commandHistory.length) state.historyIndex = state.commandHistory.length - 1;
  if (state.historyIndex < -1) state.historyIndex = -1;

  if (state.historyIndex === -1) {
    elements.consoleInput.value = "";
  } else {
    elements.consoleInput.value = state.commandHistory[state.historyIndex];
  }
}

async function runDeployment(action: "start" | "stop") {
  elements.deployStart.disabled = true;
  elements.deployStop.disabled = true;
  elements.deployLogs.textContent = `Running docker compose ${action === "start" ? "up -d" : "down"}...\n`;

  try {
    const res = await fetch(`/api/deploy/${action}`, {
      method: "POST",
      headers: { "x-admin-token": state.adminToken }
    });
    const data = await res.json();
    elements.deployLogs.textContent += `\n[Exit Code ${data.code}]\nSTDOUT:\n${data.stdout}\nSTDERR:\n${data.stderr}`;
  } catch (err) {
    elements.deployLogs.textContent += `\nError: ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    elements.deployStart.disabled = false;
    elements.deployStop.disabled = false;
  }
}

interface ContainerInfo {
  name: string;
  service: string;
  state: string;
  status: string;
  ports: string;
}

function renderDockerActions(container: string, isRunning: boolean): HTMLElement {
  const actions = document.createElement("div");
  actions.className = "docker-actions";

  if (isRunning) {
    const stopBtn = document.createElement("button");
    stopBtn.className = "docker-btn stop";
    stopBtn.dataset.action = "stop";
    stopBtn.dataset.container = container;
    stopBtn.title = "Graceful stop (SIGTERM, 10s timeout)";
    stopBtn.textContent = "Stop";

    const killBtn = document.createElement("button");
    killBtn.className = "docker-btn kill";
    killBtn.dataset.action = "kill";
    killBtn.dataset.container = container;
    killBtn.title = "Force kill (SIGKILL)";
    killBtn.textContent = "Kill";

    actions.append(stopBtn, killBtn);
  } else {
    const startBtn = document.createElement("button");
    startBtn.className = "docker-btn start";
    startBtn.dataset.action = "start";
    startBtn.dataset.container = container;
    startBtn.title = "Start container";
    startBtn.textContent = "Start";
    actions.appendChild(startBtn);
  }

  return actions;
}

function createDockerCard(container: ContainerInfo): HTMLDivElement {
  const card = document.createElement("div");
  const dot = document.createElement("div");
  const info = document.createElement("div");
  const nameEl = document.createElement("span");
  const statusEl = document.createElement("span");

  card.className = "docker-node-card";
  card.dataset.container = container.name;

  dot.className = "docker-node-dot";
  info.className = "docker-node-info";
  nameEl.className = "docker-node-name";
  statusEl.className = "docker-node-status";

  info.append(nameEl, statusEl);
  card.append(dot, info);
  card.appendChild(renderDockerActions(container.name, container.state === "running"));

  return card;
}

function updateDockerCard(card: HTMLDivElement, container: ContainerInfo) {
  const normalizedState = container.state || "unknown";
  card.className = `docker-node-card ${normalizedState}`;
  card.dataset.container = container.name;

  const dot = card.querySelector(".docker-node-dot") as HTMLDivElement;
  const nameEl = card.querySelector(".docker-node-name") as HTMLSpanElement;
  const statusEl = card.querySelector(".docker-node-status") as HTMLSpanElement;

  dot.className = `docker-node-dot ${normalizedState}`;
  nameEl.textContent = container.name.replace("wormdb-", "");
  statusEl.textContent = container.status || container.state;

  const nextRunning = container.state === "running";
  const actions = card.querySelector(".docker-actions") as HTMLElement;
  const hasStopBtn = !!actions.querySelector("button[data-action='stop']");
  const shouldSwapActions = (nextRunning && !hasStopBtn) || (!nextRunning && hasStopBtn);
  if (shouldSwapActions) {
    actions.replaceWith(renderDockerActions(container.name, nextRunning));
  } else {
    actions.querySelectorAll("button").forEach((btn) => {
      (btn as HTMLButtonElement).dataset.container = container.name;
    });
  }

  // Fresh server state means the card is no longer in transient action mode.
  card.classList.remove("busy");
}

function renderContainerCards(containers: ContainerInfo[]) {
  const running = containers.filter((c) => c.state === "running").length;
  elements.dockerCount.textContent = `${running} / ${containers.length}`;

  // Skip DOM churn when payload is effectively unchanged.
  const snapshot = containers
    .map((c) => `${c.name}|${c.state}|${c.status}|${c.ports}`)
    .sort()
    .join("\n");
  if (snapshot === lastDockerSnapshot) return;
  lastDockerSnapshot = snapshot;

  if (containers.length === 0) {
    elements.dockerNodes.innerHTML = '<div class="docker-empty">No containers found</div>';
    return;
  }

  // Sort: running first, then by name
  containers.sort((a, b) => {
    if (a.state === "running" && b.state !== "running") return -1;
    if (a.state !== "running" && b.state === "running") return 1;
    return a.name.localeCompare(b.name);
  });

  const empty = elements.dockerNodes.querySelector(".docker-empty");
  if (empty) empty.remove();

  const existing = new Map<string, HTMLDivElement>();
  elements.dockerNodes.querySelectorAll(".docker-node-card").forEach((node) => {
    const card = node as HTMLDivElement;
    const name = card.dataset.container;
    if (name) existing.set(name, card);
  });

  for (const container of containers) {
    const current = existing.get(container.name);
    const card = current ?? createDockerCard(container);
    updateDockerCard(card, container);

    // appendChild moves an existing node, giving us keyed reordering
    // without replacing the full container list.
    elements.dockerNodes.appendChild(card);
    existing.delete(container.name);
  }

  for (const stale of existing.values()) {
    stale.remove();
  }
}

function containerAction(container: string, action: string) {
  // Mark card as busy
  const card = document.querySelector(`[data-container="${container}"]`);
  if (card) card.classList.add("busy");

  // Send over WebSocket
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: "docker_action", container, action }));
  }
}

// Start the app
init();
