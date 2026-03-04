type MarkedApi = {
    parse: (input: string) => string;
};

type DomPurifyApi = {
    sanitize: (dirty: string) => string;
};

const markedApi = (window as Window & { marked?: MarkedApi }).marked;
const domPurify = (window as Window & { DOMPurify?: DomPurifyApi }).DOMPurify;
const markedParse = markedApi?.parse ?? ((t: string) => escapeHTML(t));

interface NoteMeta {
    id: string;
    title: string;
    updatedAt: string;
    locked: boolean;
}

interface Note extends NoteMeta {
    body: string;
    author: string;
}

const state = {
    notes: [] as NoteMeta[],
    currentNote: null as Note | null,
    author: localStorage.getItem("worm_author") || "Guest",
    ws: null as WebSocket | null,
    reconnectAttempts: 0,
    saveTimeout: null as any,
    isSaving: false,
    mobileView: "editor" as "editor" | "preview",
};

const elements = {
    noteList: document.getElementById("note-list")!,
    btnNewNote: document.getElementById("btn-new-note") as HTMLButtonElement,
    authorName: document.getElementById("author-name")!,
    btnEditAuthor: document.getElementById("btn-edit-author")!,

    noteTitle: document.getElementById("note-title") as HTMLInputElement,
    saveIndicator: document.getElementById("save-indicator")!,
    btnSaveSnapshot: document.getElementById("btn-save-snapshot") as HTMLButtonElement,
    btnWormLock: document.getElementById("btn-worm-lock") as HTMLButtonElement,
    btnDeleteNote: document.getElementById("btn-delete-note") as HTMLButtonElement,
    noteCount: document.getElementById("note-count")!,
    mobileViewToggle: document.getElementById("mobile-view-toggle")!,
    btnViewEditor: document.getElementById("btn-view-editor") as HTMLButtonElement,
    btnViewPreview: document.getElementById("btn-view-preview") as HTMLButtonElement,

    editorWorkspace: document.getElementById("editor-workspace")!,
    noteEditor: document.getElementById("note-editor") as HTMLTextAreaElement,
    markdownPreview: document.getElementById("markdown-preview")!,

    connIndicator: document.getElementById("conn-indicator")!,
    connText: document.getElementById("conn-text")!,
    statKeys: document.getElementById("stat-keys")!,
    statWal: document.getElementById("stat-wal")!,
    statUptime: document.getElementById("stat-uptime")!,

    toastContainer: document.getElementById("toast-container")!,

    dialogOverlay: document.getElementById("dialog-overlay")!,
    dialogTitle: document.getElementById("dialog-title")!,
    dialogMessage: document.getElementById("dialog-message")!,
    btnDialogCancel: document.getElementById("btn-dialog-cancel")!,
    btnDialogConfirm: document.getElementById("btn-dialog-confirm")!,
};

// Init
function init() {
    elements.authorName.textContent = state.author;
    if (state.author === "Guest") {
        promptAuthor();
    }

    setupListeners();
    loadNotes();
    connectWebSocket();
}

function promptAuthor() {
    const name = prompt("Enter your name:", state.author);
    if (name && name.trim()) {
        state.author = name.trim();
        localStorage.setItem("worm_author", state.author);
        elements.authorName.textContent = state.author;
    }
}

function setupListeners() {
    elements.btnEditAuthor.addEventListener("click", promptAuthor);
    elements.btnNewNote.addEventListener("click", createNote);
    elements.btnSaveSnapshot.addEventListener("click", triggerSnapshot);
    elements.btnWormLock.addEventListener("click", confirmLockNote);
    elements.btnDeleteNote.addEventListener("click", confirmDeleteNote);

    elements.noteTitle.addEventListener("input", handleEditorChange);
    elements.noteEditor.addEventListener("input", handleEditorChange);
    elements.btnViewEditor.addEventListener("click", () => setMobileView("editor"));
    elements.btnViewPreview.addEventListener("click", () => setMobileView("preview"));

    // Dialog
    elements.btnDialogCancel.addEventListener("click", closeDialog);
    elements.dialogOverlay.addEventListener("click", (event) => {
        if (event.target === elements.dialogOverlay) {
            closeDialog();
        }
    });

    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && elements.dialogOverlay.classList.contains("active")) {
            closeDialog();
        }

        if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
            event.preventDefault();
            if (state.saveTimeout) {
                clearTimeout(state.saveTimeout);
                state.saveTimeout = null;
            }
            void saveCurrentNote();
        }
    });

    window.addEventListener("resize", syncResponsiveLayout);
}

// Dialogs
let dialogCallback: (() => void) | null = null;
function showDialog(title: string, message: string, onConfirm: () => void) {
    elements.dialogTitle.textContent = title;
    elements.dialogMessage.textContent = message;
    dialogCallback = onConfirm;
    elements.dialogOverlay.classList.add("active");
    elements.btnDialogConfirm.onclick = () => {
        const onConfirmAction = dialogCallback;
        closeDialog();
        if (onConfirmAction) onConfirmAction();
    };
}

function closeDialog() {
    elements.dialogOverlay.classList.remove("active");
    dialogCallback = null;
}

// Toasts
function showToast(message: string, durationMs = 3000) {
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg> ${message}`;
    elements.toastContainer.appendChild(toast);

    setTimeout(() => {
        toast.classList.add("fade-out");
        setTimeout(() => toast.remove(), 300);
    }, durationMs);
}

// Network 
async function loadNotes() {
    try {
        const res = await fetch("/api/notes");
        if (!res.ok) throw new Error("Failed to load notes");
        state.notes = await res.json();
        renderNoteList();
    } catch (err) {
        showToast("Error loading notes");
    }
}

async function createNote() {
    try {
        const res = await fetch("/api/notes", { method: "POST" });
        if (!res.ok) throw new Error("Failed to create note");
        const note = await res.json();
        state.notes.unshift({ id: note.id, title: note.title, updatedAt: note.updatedAt, locked: note.locked });
        renderNoteList();
        selectNote(note.id);
    } catch (err) {
        showToast("Error creating note");
    }
}

async function selectNote(id: string) {
    try {
        const res = await fetch(`/api/notes/${id}`);
        if (!res.ok) throw new Error("Note not found");
        const note: Note = await res.json();
        state.currentNote = note;
        renderNoteList(); // update active state
        renderEditor();
    } catch (err) {
        showToast("Error loading note");
    }
}

function handleEditorChange() {
    if (!state.currentNote || state.currentNote.locked) return;

    state.currentNote.title = elements.noteTitle.value || "Untitled Note";
    state.currentNote.body = elements.noteEditor.value;

    // Local list optimistic update
    const listNode = state.notes.find(n => n.id === state.currentNote!.id);
    if (listNode) {
        listNode.title = state.currentNote.title;
        renderNoteList();
    }

    // Live preview
    renderPreview();

    // Debounce save
    if (state.saveTimeout) clearTimeout(state.saveTimeout);

    elements.saveIndicator.classList.add("visible", "saving");
    elements.saveIndicator.classList.remove("saved");

    state.saveTimeout = setTimeout(saveCurrentNote, 500);
}

async function saveCurrentNote() {
    if (!state.currentNote) return;
    state.isSaving = true;

    try {
        const res = await fetch(`/api/notes/${state.currentNote.id}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                title: state.currentNote.title,
                body: state.currentNote.body,
                author: state.author
            })
        });

        if (!res.ok) {
            throw new Error("Failed to save note");
        }

        // Keep list metadata fresh after successful writes when backend returns note data.
        const updatedNote = await res.json().catch(() => null) as Partial<Note> | null;
        if (updatedNote?.updatedAt) {
            const listNode = state.notes.find((note) => note.id === state.currentNote!.id);
            if (listNode) {
                listNode.updatedAt = updatedNote.updatedAt;
            }
        }

        elements.saveIndicator.classList.remove("saving");
        elements.saveIndicator.classList.add("saved");
        setTimeout(() => {
            if (!state.isSaving && elements.saveIndicator.classList.contains("saved")) {
                elements.saveIndicator.classList.remove("visible", "saved");
            }
        }, 2000);
    } catch (err) {
        showToast("Save failed");
        elements.saveIndicator.classList.remove("saving");
        elements.saveIndicator.classList.remove("saved");
    } finally {
        state.isSaving = false;
    }
}

function confirmLockNote() {
    if (!state.currentNote) return;
    showDialog(
        "Lock Note Permanently",
        "This will make the note read-only forever. This action cannot be undone. Are you sure?",
        async () => {
            try {
                const res = await fetch(`/api/notes/${state.currentNote!.id}/lock`, { method: "POST" });
                if (!res.ok) throw new Error("Failed to lock note");

                state.currentNote!.locked = true;
                const listNode = state.notes.find(n => n.id === state.currentNote!.id);
                if (listNode) listNode.locked = true;

                renderNoteList();
                renderEditor();
                showToast("Note locked successfully");
            } catch (err) {
                showToast("Error locking note");
            }
        }
    );
}

function confirmDeleteNote() {
    if (!state.currentNote) return;
    showDialog(
        "Delete Note",
        "Are you sure you want to delete this note? This action cannot be undone.",
        async () => {
            try {
                const res = await fetch(`/api/notes/${state.currentNote!.id}`, { method: "DELETE" });
                if (!res.ok) throw new Error("Failed to delete note");

                state.notes = state.notes.filter(n => n.id !== state.currentNote!.id);
                state.currentNote = null;
                renderNoteList();
                renderEditor();
                showToast("Note deleted");
            } catch (err) {
                showToast("Error deleting note. Is it locked?");
            }
        }
    );
}

async function triggerSnapshot() {
    try {
        const res = await fetch("/api/save", { method: "POST" });
        if (res.ok) showToast("Snapshot saved to disk");
        else throw new Error();
    } catch (err) {
        showToast("Failed to save snapshot");
    }
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
        if (key && rest.length > 0) kv[key.trim()] = rest.join("=").trim();
    });
    return kv;
}

// WebSocket
function connectWebSocket() {
    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    state.ws = new WebSocket(`${protocol}//${location.host}/ws`);

    state.ws.onopen = () => {
        state.reconnectAttempts = 0;
        elements.connIndicator.classList.add("online");
        elements.connText.textContent = "Connected";
    };

    state.ws.onclose = () => {
        elements.connIndicator.classList.remove("online");
        state.reconnectAttempts++;
        const delay = Math.min(10000, 1000 * Math.max(1, state.reconnectAttempts));
        elements.connText.textContent = `Reconnecting in ${Math.ceil(delay / 1000)}s...`;
        setTimeout(connectWebSocket, delay);
    };

    state.ws.onmessage = (e) => {
        try {
            const msg = JSON.parse(e.data);
            if (msg.type === "status") {
                const kv = parseKV(msg.response?.value || "");
                elements.statKeys.textContent = kv.keys || "0";
                elements.statWal.textContent = kv.wal_size ? formatBytes(parseInt(kv.wal_size)) : "0 B";
                elements.statUptime.textContent = kv.uptime_in_seconds ? `${kv.uptime_in_seconds}s` : "-";
            } else if (msg.type === "note:updated") {
                handleRemoteUpdate(msg);
            } else if (msg.type === "note:deleted") {
                handleRemoteDelete(msg);
            } else if (msg.type === "note:locked") {
                handleRemoteLock(msg);
            }
        } catch { }
    };
}

function handleRemoteUpdate(msg: any) {
    // Skip events from ourselves — the API response already handles our own edits.
    // This prevents duplicates from the race: WS event arrives before fetch() completes.
    if (msg.author === state.author) return;

    // Update list
    const existing = state.notes.find(n => n.id === msg.id);
    if (existing) {
        existing.title = msg.title;
        existing.updatedAt = new Date().toISOString();
        // Sort to top
        state.notes = [existing, ...state.notes.filter(n => n.id !== msg.id)];
    } else {
        // New note from another node/user
        state.notes.unshift({ id: msg.id, title: msg.title, updatedAt: new Date().toISOString(), locked: false });
    }
    renderNoteList();

    // Auto-reload if we have this note open
    if (state.currentNote && state.currentNote.id === msg.id) {
        showToast(`Note updated by ${msg.author}`);
        selectNote(msg.id);
    }
}

function handleRemoteDelete(msg: any) {
    state.notes = state.notes.filter(n => n.id !== msg.id);
    renderNoteList();

    if (state.currentNote && state.currentNote.id === msg.id) {
        state.currentNote = null;
        renderEditor();
        showToast("This note was deleted by another user");
    }
}

function setMobileView(view: "editor" | "preview") {
    state.mobileView = view;
    elements.editorWorkspace.dataset.mobileView = view;
    elements.btnViewEditor.classList.toggle("active", view === "editor");
    elements.btnViewPreview.classList.toggle("active", view === "preview");
}

function syncResponsiveLayout() {
    const isMobile = window.innerWidth <= 900;
    elements.mobileViewToggle.classList.toggle("visible", isMobile);
    if (!isMobile) {
        elements.editorWorkspace.removeAttribute("data-mobile-view");
        return;
    }

    setMobileView(state.mobileView);
}

function handleRemoteLock(msg: any) {
    const existing = state.notes.find(n => n.id === msg.id);
    if (existing) {
        existing.locked = true;
        renderNoteList();
    }

    if (state.currentNote && state.currentNote.id === msg.id) {
        state.currentNote.locked = true;
        renderEditor();
        if (msg.author !== state.author) {
            showToast(`Note locked by ${msg.author}`);
        }
    }
}

// Rendering
function renderNoteList() {
    elements.noteCount.textContent = `${state.notes.length} ${state.notes.length === 1 ? "note" : "notes"}`;

    if (state.notes.length === 0) {
        elements.noteList.innerHTML = `<li class="empty-list-state">No notes yet. Create one to get started.</li>`;
        return;
    }

    elements.noteList.innerHTML = "";
    state.notes.forEach(note => {
        const li = document.createElement("li");
        li.className = `note-item ${state.currentNote?.id === note.id ? "active" : ""}`;
        li.tabIndex = 0;
        li.setAttribute("role", "button");

        const d = new Date(note.updatedAt);
        const timeStr = isNaN(d.getTime()) ? "" : d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

        li.innerHTML = `
      <div class="note-item-header">
        <span class="note-item-title">${escapeHTML(note.title || "Untitled Note")}</span>
        <span class="lock-icon ${note.locked ? "" : "hidden"}" title="WORM Locked">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>
        </span>
      </div>
      <div class="note-item-meta">
        <span>${timeStr}</span>
      </div>
    `;

        li.onclick = () => selectNote(note.id);
        li.onkeydown = (event) => {
            if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                void selectNote(note.id);
            }
        };
        elements.noteList.appendChild(li);
    });
}

function renderEditor() {
    if (!state.currentNote) {
        elements.editorWorkspace.classList.remove("active");
        elements.noteTitle.value = "";
        elements.noteTitle.disabled = true;
        elements.noteEditor.value = "";
        elements.noteEditor.disabled = true;
        elements.markdownPreview.innerHTML = "";

        elements.btnWormLock.disabled = true;
        elements.btnWormLock.classList.remove("locked");
        elements.btnDeleteNote.disabled = true;
        return;
    }

    elements.editorWorkspace.classList.add("active");
    elements.noteTitle.value = state.currentNote.title;
    elements.noteEditor.value = state.currentNote.body;

    const isLocked = state.currentNote.locked;
    elements.noteTitle.disabled = isLocked;
    elements.noteEditor.disabled = isLocked;

    elements.btnWormLock.disabled = isLocked;
    elements.btnWormLock.classList.toggle("locked", isLocked);
    if (isLocked) {
        elements.btnWormLock.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg> Locked`;
    } else {
        elements.btnWormLock.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg> WORM Lock`;
    }

    elements.btnDeleteNote.disabled = isLocked;

    renderPreview();
}

function renderPreview() {
    if (!state.currentNote) return;
    const rawHtml = markedParse(state.currentNote.body || "");
    elements.markdownPreview.innerHTML = sanitizeHtml(rawHtml);
    hardenPreviewLinks();
}

function sanitizeHtml(html: string): string {
    if (domPurify) {
        return domPurify.sanitize(html);
    }

    const template = document.createElement("template");
    template.innerHTML = html;

    template.content
        .querySelectorAll("script, iframe, object, embed, link, meta")
        .forEach((node) => node.remove());

    template.content.querySelectorAll("*").forEach((element) => {
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLowerCase();
            const value = attribute.value.trim().toLowerCase();
            if (name.startsWith("on") || name === "srcdoc") {
                element.removeAttribute(attribute.name);
                continue;
            }
            if ((name === "href" || name === "src") && (value.startsWith("javascript:") || value.startsWith("data:text/html"))) {
                element.removeAttribute(attribute.name);
            }
        }
    });

    return template.innerHTML;
}

function hardenPreviewLinks() {
    const links = elements.markdownPreview.querySelectorAll("a[href]");
    links.forEach((link) => {
        const href = link.getAttribute("href") ?? "";
        if (href.trim().toLowerCase().startsWith("javascript:")) {
            link.removeAttribute("href");
            return;
        }
        link.setAttribute("target", "_blank");
        link.setAttribute("rel", "noopener noreferrer");
    });
}

function escapeHTML(str: string) {
    return str.replace(/[&<>'"]/g,
        tag => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            "'": '&#39;',
            '"': '&quot;'
        }[tag] || tag)
    );
}

// Start
init();
syncResponsiveLayout();
