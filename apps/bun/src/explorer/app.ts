// ── WormDB KV Explorer — Client App ─────────────────────────
// All mutations route through EXEC kv_put / kv_get / kv_stats procedures.

interface KeyEntry {
    key: string;
    locked: boolean;
}

interface KeyMeta {
    created: string;
    updated: string;
    writes: number;
    reads: number;
}

const state = {
    keys: [] as KeyEntry[],
    currentKey: null as string | null,
    currentValue: "",
    currentMeta: null as KeyMeta | null,
    currentLocked: false,
    ws: null as WebSocket | null,
    reconnectAttempts: 0,
    saveTimeout: null as any,
    isSaving: false,
    filter: "",
};

const el = {
    // Stats
    statReads: document.getElementById("stat-reads")!,
    statWrites: document.getElementById("stat-writes")!,
    statKeys: document.getElementById("stat-keys")!,
    statsBar: document.getElementById("stats-bar")!,

    // Sidebar
    searchInput: document.getElementById("search-input") as HTMLInputElement,
    btnAddKey: document.getElementById("btn-add-key")!,
    keyList: document.getElementById("key-list")!,

    // Detail
    emptyState: document.getElementById("empty-state")!,
    keyDetail: document.getElementById("key-detail")!,
    detailKey: document.getElementById("detail-key")!,
    lockBadge: document.getElementById("lock-badge")!,
    btnWorm: document.getElementById("btn-worm") as HTMLButtonElement,
    btnDelete: document.getElementById("btn-delete") as HTMLButtonElement,
    valueEditor: document.getElementById("value-editor") as HTMLTextAreaElement,
    saveIndicator: document.getElementById("save-indicator")!,
    metaCreated: document.getElementById("meta-created")!,
    metaUpdated: document.getElementById("meta-updated")!,
    metaWrites: document.getElementById("meta-writes")!,
    metaReads: document.getElementById("meta-reads")!,
    procLog: document.getElementById("proc-log")!,

    // Status bar
    connIndicator: document.getElementById("conn-indicator")!,
    connText: document.getElementById("conn-text")!,
    statUptime: document.getElementById("stat-uptime")!,
    statWal: document.getElementById("stat-wal")!,

    // Toasts
    toastContainer: document.getElementById("toast-container")!,

    // Confirm dialog
    dialogOverlay: document.getElementById("dialog-overlay")!,
    dialogTitle: document.getElementById("dialog-title")!,
    dialogMessage: document.getElementById("dialog-message")!,
    btnDialogCancel: document.getElementById("btn-dialog-cancel")!,
    btnDialogConfirm: document.getElementById("btn-dialog-confirm")!,

    // Add dialog
    addDialogOverlay: document.getElementById("add-dialog-overlay")!,
    newKeyInput: document.getElementById("new-key-input") as HTMLInputElement,
    newValueInput: document.getElementById("new-value-input") as HTMLTextAreaElement,
    btnAddCancel: document.getElementById("btn-add-cancel")!,
    btnAddConfirm: document.getElementById("btn-add-confirm")!,
};

// ── Init ──────────────────────────────────────────────────────

function init() {
    setupListeners();
    loadKeys();
    connectWebSocket();
}

function setupListeners() {
    el.searchInput.addEventListener("input", () => {
        state.filter = el.searchInput.value.toLowerCase();
        renderKeyList();
    });

    el.btnAddKey.addEventListener("click", openAddDialog);
    el.valueEditor.addEventListener("input", handleValueChange);

    el.btnWorm.addEventListener("click", confirmWormLock);
    el.btnDelete.addEventListener("click", confirmDelete);

    // Confirm dialog
    el.btnDialogCancel.addEventListener("click", closeDialog);
    el.dialogOverlay.addEventListener("click", (e) => {
        if (e.target === el.dialogOverlay) closeDialog();
    });

    // Add dialog
    el.btnAddCancel.addEventListener("click", closeAddDialog);
    el.addDialogOverlay.addEventListener("click", (e) => {
        if (e.target === el.addDialogOverlay) closeAddDialog();
    });
    el.btnAddConfirm.addEventListener("click", handleAddKey);

    // Keyboard shortcuts
    document.addEventListener("keydown", (e) => {
        if (e.key === "Escape") {
            closeDialog();
            closeAddDialog();
        }
        if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
            e.preventDefault();
            if (state.saveTimeout) {
                clearTimeout(state.saveTimeout);
                state.saveTimeout = null;
            }
            void saveCurrentValue();
        }
    });
}

// ── Toasts ────────────────────────────────────────────────────

function showToast(msg: string, durationMs = 3000) {
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg> ${escapeHTML(msg)}`;
    el.toastContainer.appendChild(toast);
    setTimeout(() => {
        toast.classList.add("fade-out");
        setTimeout(() => toast.remove(), 300);
    }, durationMs);
}

// ── Dialogs ───────────────────────────────────────────────────

let dialogCallback: (() => void) | null = null;
function showDialog(title: string, message: string, onConfirm: () => void) {
    el.dialogTitle.textContent = title;
    el.dialogMessage.textContent = message;
    dialogCallback = onConfirm;
    el.dialogOverlay.classList.add("active");
    el.btnDialogConfirm.onclick = () => {
        const cb = dialogCallback;
        closeDialog();
        if (cb) cb();
    };
}

function closeDialog() {
    el.dialogOverlay.classList.remove("active");
    dialogCallback = null;
}

function openAddDialog() {
    el.newKeyInput.value = "";
    el.newValueInput.value = "";
    el.addDialogOverlay.classList.add("active");
    setTimeout(() => el.newKeyInput.focus(), 50);
}

function closeAddDialog() {
    el.addDialogOverlay.classList.remove("active");
}

// ── Network ───────────────────────────────────────────────────

async function loadKeys() {
    try {
        const res = await fetch("/api/keys");
        if (!res.ok) throw new Error("Failed to load keys");
        state.keys = await res.json();
        renderKeyList();
        updateKeyCount();
    } catch {
        showToast("Error loading keys");
    }
}

async function handleAddKey() {
    const key = el.newKeyInput.value.trim();
    const value = el.newValueInput.value;

    if (!key) {
        showToast("Key cannot be empty");
        return;
    }

    try {
        const res = await fetch("/api/keys", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ key, value }),
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(text);
        }
        const data = await res.json();
        logProcCall(`EXEC kv_put ${key} <value>`, "OK");
        closeAddDialog();

        // Add to local state
        if (!state.keys.find(k => k.key === key)) {
            state.keys.unshift({ key, locked: false });
        }
        renderKeyList();
        updateKeyCount();
        selectKey(key);
        showToast(`Key "${key}" created`);
    } catch (err: any) {
        showToast(err.message || "Failed to create key");
    }
}

async function selectKey(key: string) {
    state.currentKey = key;

    try {
        const res = await fetch(`/api/keys/${encodeURIComponent(key)}`);
        if (!res.ok) throw new Error("Key not found");
        const data = await res.json();

        state.currentValue = data.value ?? "";
        state.currentLocked = data.locked ?? false;
        state.currentMeta = data.meta ?? null;

        logProcCall(`EXEC kv_get ${key}`, data.value ? `"${truncate(data.value, 40)}"` : "null");

        renderKeyList();
        renderDetail();
    } catch {
        showToast("Error loading key");
    }
}

function handleValueChange() {
    if (!state.currentKey || state.currentLocked) return;
    state.currentValue = el.valueEditor.value;

    el.saveIndicator.classList.add("visible", "saving");
    el.saveIndicator.classList.remove("saved");

    if (state.saveTimeout) clearTimeout(state.saveTimeout);
    state.saveTimeout = setTimeout(saveCurrentValue, 500);
}

async function saveCurrentValue() {
    if (!state.currentKey) return;
    state.isSaving = true;

    try {
        const res = await fetch(`/api/keys/${encodeURIComponent(state.currentKey)}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ value: state.currentValue }),
        });

        if (!res.ok) throw new Error("Save failed");

        logProcCall(`EXEC kv_put ${state.currentKey} <value>`, "OK");

        // Refresh metadata
        const data = await res.json();
        if (data.meta) {
            state.currentMeta = data.meta;
            renderMeta();
        }

        el.saveIndicator.classList.remove("saving");
        el.saveIndicator.classList.add("saved");
        setTimeout(() => {
            if (!state.isSaving && el.saveIndicator.classList.contains("saved")) {
                el.saveIndicator.classList.remove("visible", "saved");
            }
        }, 2000);
    } catch {
        showToast("Save failed");
        el.saveIndicator.classList.remove("saving", "saved");
    } finally {
        state.isSaving = false;
    }
}

function confirmWormLock() {
    if (!state.currentKey) return;
    showDialog(
        "WORM Lock Key",
        `This will permanently lock "${state.currentKey}". The value can never be changed or deleted. Continue?`,
        async () => {
            try {
                const res = await fetch(`/api/keys/${encodeURIComponent(state.currentKey!)}/lock`, { method: "POST" });
                if (!res.ok) throw new Error("Lock failed");

                state.currentLocked = true;
                const entry = state.keys.find(k => k.key === state.currentKey);
                if (entry) entry.locked = true;

                renderDetail();
                renderKeyList();
                showToast(`"${state.currentKey}" is now WORM-locked`);
            } catch {
                showToast("Failed to lock key");
            }
        }
    );
}

function confirmDelete() {
    if (!state.currentKey) return;
    showDialog(
        "Delete Key",
        `Delete "${state.currentKey}"? This action cannot be undone.`,
        async () => {
            try {
                const res = await fetch(`/api/keys/${encodeURIComponent(state.currentKey!)}`, { method: "DELETE" });
                if (!res.ok) throw new Error("Delete failed");

                state.keys = state.keys.filter(k => k.key !== state.currentKey);
                state.currentKey = null;
                state.currentMeta = null;
                renderKeyList();
                renderDetail();
                updateKeyCount();
                showToast("Key deleted");
            } catch {
                showToast("Cannot delete — key may be WORM-locked");
            }
        }
    );
}

// ── WebSocket ─────────────────────────────────────────────────

function connectWebSocket() {
    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    state.ws = new WebSocket(`${protocol}//${location.host}/ws`);

    state.ws.onopen = () => {
        state.reconnectAttempts = 0;
        el.connIndicator.classList.add("online");
        el.connText.textContent = "Connected";
    };

    state.ws.onclose = () => {
        el.connIndicator.classList.remove("online");
        state.reconnectAttempts++;
        const delay = Math.min(10000, 1000 * Math.max(1, state.reconnectAttempts));
        el.connText.textContent = `Reconnecting in ${Math.ceil(delay / 1000)}s...`;
        setTimeout(connectWebSocket, delay);
    };

    state.ws.onmessage = (e) => {
        try {
            const msg = JSON.parse(e.data);
            if (msg.type === "status") handleStatusMsg(msg);
            else if (msg.type === "stats") handleStatsMsg(msg);
            else if (msg.type === "kv:updated") handleRemoteUpdate(msg);
            else if (msg.type === "kv:deleted") handleRemoteDelete(msg);
            else if (msg.type === "kv:locked") handleRemoteLock(msg);
        } catch { }
    };
}

function handleStatusMsg(msg: any) {
    const kv = parseKV(msg.response?.value || "");
    el.statUptime.textContent = kv.uptime_in_seconds ? `${kv.uptime_in_seconds}s` : "—";
    el.statWal.textContent = kv.wal_size ? formatBytes(parseInt(kv.wal_size)) : "0 B";
}

function handleStatsMsg(msg: any) {
    animateStat(el.statReads, msg.reads ?? 0);
    animateStat(el.statWrites, msg.writes ?? 0);
}

function handleRemoteUpdate(msg: any) {
    if (!state.keys.find(k => k.key === msg.key)) {
        state.keys.unshift({ key: msg.key, locked: false });
        renderKeyList();
        updateKeyCount();
    }

    if (state.currentKey === msg.key) {
        selectKey(msg.key); // Reload
    }
}

function handleRemoteDelete(msg: any) {
    state.keys = state.keys.filter(k => k.key !== msg.key);
    renderKeyList();
    updateKeyCount();

    if (state.currentKey === msg.key) {
        state.currentKey = null;
        renderDetail();
        showToast(`Key "${msg.key}" was deleted remotely`);
    }
}

function handleRemoteLock(msg: any) {
    const entry = state.keys.find(k => k.key === msg.key);
    if (entry) entry.locked = true;

    if (state.currentKey === msg.key) {
        state.currentLocked = true;
        renderDetail();
    }
    renderKeyList();
}

// ── Rendering ─────────────────────────────────────────────────

function renderKeyList() {
    const filtered = state.keys.filter(k =>
        !state.filter || k.key.toLowerCase().includes(state.filter)
    );

    if (filtered.length === 0) {
        el.keyList.innerHTML = `<li class="empty-list-state">${state.filter ? "No matching keys" : "No keys yet. Click + to add one."}</li>`;
        return;
    }

    el.keyList.innerHTML = "";
    filtered.forEach(entry => {
        const li = document.createElement("li");
        li.className = `key-item ${state.currentKey === entry.key ? "active" : ""}`;
        li.tabIndex = 0;

        const initial = entry.key.charAt(0).toUpperCase();

        li.innerHTML = `
      <div class="key-item-icon">${escapeHTML(initial)}</div>
      <div class="key-item-info">
        <div class="key-item-name">${escapeHTML(entry.key)}</div>
        <div class="key-item-meta">${entry.locked ? "🔒 WORM locked" : "mutable"}</div>
      </div>
      <span class="lock-icon ${entry.locked ? "" : "hidden"}">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
      </span>
    `;

        li.onclick = () => selectKey(entry.key);
        li.onkeydown = (e) => {
            if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                selectKey(entry.key);
            }
        };
        el.keyList.appendChild(li);
    });
}

function renderDetail() {
    if (!state.currentKey) {
        el.emptyState.classList.remove("hidden");
        el.keyDetail.classList.add("hidden");
        return;
    }

    el.emptyState.classList.add("hidden");
    el.keyDetail.classList.remove("hidden");

    el.detailKey.textContent = state.currentKey;
    el.valueEditor.value = state.currentValue;
    el.valueEditor.disabled = state.currentLocked;

    el.lockBadge.classList.toggle("hidden", !state.currentLocked);
    el.btnWorm.disabled = state.currentLocked;
    el.btnDelete.disabled = state.currentLocked;

    renderMeta();
}

function renderMeta() {
    if (!state.currentMeta) {
        el.metaCreated.textContent = "—";
        el.metaUpdated.textContent = "—";
        el.metaWrites.textContent = "0";
        el.metaReads.textContent = "0";
        return;
    }

    el.metaCreated.textContent = formatTimestamp(state.currentMeta.created);
    el.metaUpdated.textContent = formatTimestamp(state.currentMeta.updated);
    el.metaWrites.textContent = String(state.currentMeta.writes);
    el.metaReads.textContent = String(state.currentMeta.reads);
}

function updateKeyCount() {
    el.statKeys.textContent = String(state.keys.length);
    flashChip(el.statKeys.closest(".stat-chip"));
}

// ── Procedure Log ─────────────────────────────────────────────

let procLogCount = 0;
function logProcCall(cmd: string, result: string, isError = false) {
    if (procLogCount === 0) el.procLog.innerHTML = "";
    procLogCount++;

    const entry = document.createElement("div");
    entry.className = "proc-entry";
    const time = new Date().toLocaleTimeString();
    entry.innerHTML = `
    <span class="proc-time">[${time}]</span>
    <span class="proc-cmd">${escapeHTML(cmd)}</span>
    <span class="proc-result ${isError ? "error" : ""}">${escapeHTML("→ " + result)}</span>
  `;
    el.procLog.appendChild(entry);
    el.procLog.scrollTop = el.procLog.scrollHeight;

    // Keep log trimmed
    while (el.procLog.children.length > 50) {
        el.procLog.removeChild(el.procLog.children[0]);
    }
}

// ── Helpers ───────────────────────────────────────────────────

function escapeHTML(str: string) {
    return str.replace(/[&<>'"]/g,
        tag => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[tag] || tag)
    );
}

function truncate(str: string, len: number) {
    return str.length > len ? str.slice(0, len) + "…" : str;
}

function formatBytes(bytes: number) {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
}

function formatTimestamp(val: string) {
    const num = parseInt(val);
    if (isNaN(num) || num === 0) return "—";
    const d = new Date(num);
    return d.toLocaleString();
}

function parseKV(text: string): Record<string, string> {
    const kv: Record<string, string> = {};
    text.split("\n").forEach(line => {
        const [key, ...rest] = line.split("=");
        if (key && rest.length > 0) kv[key.trim()] = rest.join("=").trim();
    });
    return kv;
}

function animateStat(el: HTMLElement, value: number) {
    const prev = parseInt(el.textContent || "0");
    if (prev !== value) {
        el.textContent = String(value);
        flashChip(el.closest(".stat-chip"));
    }
}

function flashChip(chip: Element | null) {
    if (!chip) return;
    chip.classList.remove("flash");
    void (chip as HTMLElement).offsetWidth; // force reflow
    chip.classList.add("flash");
}

// ── Start ─────────────────────────────────────────────────────
init();

export { };
