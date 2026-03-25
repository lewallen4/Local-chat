/* Local Chat — Frontend Script */

// ── State ──────────────────────────────────────────────────────────
let currentUserId    = null;
let currentSessionId = null;
let isGenerating     = false;
let exchangeCount    = 0;
let activeReader     = null;
let isViewingHistory = false;   // true when showing a past session read-only

// ── DOM refs ───────────────────────────────────────────────────────
const $ = id => document.getElementById(id);

const idGate        = $('id-gate');
const appShell      = $('app-shell');
const userIdInput   = $('user-id-input');
const idSubmit      = $('id-submit');
const idFeedback    = $('id-feedback');

const chatMessages      = $('chat-messages');
const userInput         = $('user-input');
const sendButton        = $('send-button');
const stopButton        = $('stop-button');
const typingIndicator   = $('typing-indicator');
const newChatBtn        = $('new-chat');
const sessionIdDisplay  = $('session-id-display');
const messageCountEl    = $('message-count');
const memoryPreview     = $('memory-preview');
const statusDot         = $('status-dot');
const statusLabel       = $('status-label');
const chatTitle         = $('chat-title');
const sidebarToggle     = $('sidebar-toggle');
const themeToggle       = $('theme-toggle');
const sidebar           = document.querySelector('.sidebar');
const sessionList       = $('session-list');
const memoryToggle      = $('memory-toggle');
const memoryPanel       = $('memory-panel');
const userBadge         = $('user-badge');
const switchUserBtn     = $('switch-user-btn');
const welcomeHeading    = $('welcome-heading');
const welcomeSub        = $('welcome-sub');

// ── Theme ────────────────────────────────────────────────────────────
function initTheme() {
    const saved = localStorage.getItem('localchat-theme') || 'dark';
    applyTheme(saved);
}

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('localchat-theme', theme);
    if (themeToggle) {
        themeToggle.title     = theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode';
        themeToggle.innerHTML = theme === 'dark' ? sunIcon() : moonIcon();
    }
}

function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme') || 'dark';
    applyTheme(current === 'dark' ? 'light' : 'dark');
}

function sunIcon() {
    return `<svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>
        <path d="M12 2v2M12 20v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M2 12h2M20 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
    </svg>`;
}

function moonIcon() {
    return `<svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>`;
}

// ── ID Gate ──────────────────────────────────────────────────────────
function initIdGate() {
    const saved = sessionStorage.getItem('localchat-user-id');
    if (saved) {
        enterApp(saved, false);
        return;
    }

    idGate.classList.remove('hidden');
    appShell.classList.add('hidden');
    userIdInput.focus();

    idSubmit.addEventListener('click', submitUserId);
    userIdInput.addEventListener('keydown', e => {
        if (e.key === 'Enter') submitUserId();
    });
}

async function submitUserId() {
    const raw = userIdInput.value.trim();
    if (!raw) return;

    if (!/^[a-zA-Z0-9_\-]{2,32}$/.test(raw)) {
        showIdFeedback('error', 'ID must be 2–32 characters: letters, numbers, - or _');
        return;
    }

    idSubmit.disabled = true;
    showIdFeedback('loading', 'Checking workspace…');

    try {
        const res  = await fetch(`/api/user/${encodeURIComponent(raw)}/check`);
        const data = await res.json();

        if (!res.ok) {
            showIdFeedback('error', data.detail || 'Server error');
            idSubmit.disabled = false;
            return;
        }

        showIdFeedback('ok', data.returning
            ? `Welcome back, ${raw}. Loading your workspace…`
            : `Creating new workspace for ${raw}…`
        );

        await sleep(600);
        enterApp(raw, data.returning, data.sessions || []);

    } catch (err) {
        showIdFeedback('error', 'Could not reach server. Is it running?');
        idSubmit.disabled = false;
    }
}

function showIdFeedback(type, text) {
    idFeedback.textContent = text;
    idFeedback.className   = `id-feedback ${type}`;
}

async function enterApp(userId, returning, pastSessions = []) {
    currentUserId = userId;
    sessionStorage.setItem('localchat-user-id', userId);

    idGate.classList.add('hidden');
    appShell.classList.remove('hidden');

    userBadge.textContent = userId.toUpperCase().slice(0, 8);

    if (returning && pastSessions.length > 0) {
        welcomeHeading.textContent = `Welcome back, ${userId}.`;
        welcomeSub.textContent     = `${pastSessions.length} previous session${pastSessions.length !== 1 ? 's' : ''} loaded.`;
        populatePastSessions(pastSessions);
    } else {
        welcomeHeading.textContent = `Hello, ${userId}.`;
        welcomeSub.textContent     = 'Your local workspace is ready.';
    }

    initTheme();
    setupEventListeners();
    setStatus('loading', 'Connecting…');
    await loadMemory();
    await startSession();
}

function switchUser() {
    if (currentSessionId) {
        navigator.sendBeacon(`/api/chat/${currentSessionId}/end`);
        currentSessionId = null;
    }
    currentUserId = null;
    sessionStorage.removeItem('localchat-user-id');

    idFeedback.textContent = '';
    idFeedback.className   = 'id-feedback';
    userIdInput.value      = '';
    idSubmit.disabled      = false;

    appShell.classList.add('hidden');
    idGate.classList.remove('hidden');
    userIdInput.focus();
}

// ── Status ────────────────────────────────────────────────────────────
function setStatus(state, label) {
    statusDot.className     = 'status-dot ' + state;
    statusLabel.textContent = label;
}

// ── Memory ────────────────────────────────────────────────────────────
async function loadMemory() {
    if (!currentUserId) return;
    try {
        const res  = await fetch(`/api/memory?user_id=${encodeURIComponent(currentUserId)}`);
        const data = await res.json();
        const text = (data.memory || '').trim();
        memoryPreview.textContent = text
            ? (text.length > 800 ? '…' + text.slice(-800) : text)
            : 'No memory yet — it builds as you chat.';
    } catch {
        memoryPreview.textContent = 'Memory unavailable.';
    }
}

// ── Session lifecycle ─────────────────────────────────────────────────
async function startSession() {
    isViewingHistory = false;
    try {
        const res  = await fetch('/api/chat/start', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({
                user_id:  currentUserId,
                metadata: { timestamp: new Date().toISOString() },
            }),
        });
        const data = await res.json();

        currentSessionId = data.session_id;
        exchangeCount    = 0;

        sessionIdDisplay.textContent = currentSessionId.slice(0, 8) + '…';
        updateCount();
        setStatus('online', 'Online');

        userInput.disabled  = false;
        sendButton.disabled = false;
        userInput.focus();

    } catch {
        setStatus('error', 'Connection failed');
        appendSystemMsg('⚠ Could not reach server. Is it running?');
    }
}

async function endCurrentSession() {
    if (!currentSessionId) return;
    const sid = currentSessionId;
    currentSessionId = null;
    try {
        await fetch(`/api/chat/${sid}/end`, { method: 'POST' });
    } catch { /* best-effort */ }
}

// ── Switch to a new blank session ─────────────────────────────────────
async function switchToNewSession() {
    if (isGenerating) stopGeneration();

    markAllSessionsInactive();
    await endCurrentSession();
    exchangeCount = 0;

    chatMessages.innerHTML = `
        <div class="welcome-screen">
            <div class="welcome-icon">
                <svg width="40" height="40" viewBox="0 0 24 24" fill="none">
                    <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"
                          stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
            </div>
            <h2>New session started.</h2>
            <p>Continuing as <strong>${escHtml(currentUserId)}</strong>.</p>
            <div class="welcome-hints">
                <span class="hint">↵ Send</span>
                <span class="hint">⇧ ↵ New line</span>
                <span class="hint">Esc Clear</span>
            </div>
        </div>`;

    chatTitle.textContent        = 'New Session';
    sessionIdDisplay.textContent = '—';
    updateCount();
    userInput.disabled  = true;
    sendButton.disabled = true;

    await loadMemory();
    await startSession();
}

// ── Load a past session and continue it live ─────────────────────────
async function loadPastSession(sessionId, title) {
    // Block during generation — must wait for response to finish first
    if (isGenerating) return;

    // Don't reload the session already active
    if (currentSessionId === sessionId) return;

    // End whatever live session is currently open
    markAllSessionsInactive();
    await endCurrentSession();

    // Highlight selected item in sidebar
    const item = sessionList.querySelector('[data-sid="' + sessionId + '"]');
    if (item) item.classList.add('active');

    // Disable input while fetching history
    isViewingHistory = false;
    userInput.disabled  = true;
    sendButton.disabled = true;
    chatMessages.innerHTML = '<div class="system-msg">Loading session…</div>';
    chatTitle.textContent  = escHtml(title || sessionId.slice(0, 8));

    try {
        const res = await fetch('/api/sessions/' + sessionId + '/history');
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const messages = await res.json();

        chatMessages.innerHTML = '';
        if (messages.length) {
            messages.forEach(m => appendMessage(m.role, m.content));
        }
        appendSystemMsg('— continuing session —');
        scrollToBottom();

        // Start a fresh live session — memory already has the old session
        // summary so the model has full context automatically
        await startSession();

        exchangeCount = messages.filter(m => m.role === 'user').length;
        updateCount();

    } catch (err) {
        chatMessages.innerHTML = '<div class="system-msg">⚠ Could not load session: ' + escHtml(err.message) + '</div>';
        await startSession();
    }
}

// ── Stop generation ───────────────────────────────────────────────────
function stopGeneration() {
    if (activeReader) {
        activeReader.cancel();
        activeReader = null;
    }
}

// ── Send message ──────────────────────────────────────────────────────
async function sendMessage() {
    const text = userInput.value.trim();
    if (!text || isGenerating || !currentSessionId) return;

    userInput.value = '';
    autoResize();
    isGenerating = true;

    sendButton.classList.add('hidden');
    stopButton.classList.remove('hidden');
    userInput.disabled = true;

    const welcome = document.querySelector('.welcome-screen');
    if (welcome) welcome.remove();

    appendMessage('user', text);

    if (exchangeCount === 0) {
        addSessionToList(currentSessionId, text);
    }

    typingIndicator.classList.remove('hidden');
    scrollToBottom();

    const { row, contentEl, metaEl } = createAssistantBubble();
    chatMessages.appendChild(row);

    const textNode = document.createTextNode('');
    contentEl.appendChild(textNode);
    contentEl.classList.add('streaming');

    let fullResponse = '';
    let stopped      = false;

    try {
        const res = await fetch(`/api/chat/${currentSessionId}`, {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ message: text }),
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const reader  = res.body.getReader();
        const decoder = new TextDecoder();
        activeReader  = reader;

        let buffer = '';

        outer: while (true) {
            let value, done;
            try {
                ({ value, done } = await reader.read());
            } catch {
                stopped = true;
                break;
            }
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const events = buffer.split('\n\n');
            buffer = events.pop();

            for (const event of events) {
                for (const line of event.split('\n')) {
                    if (!line.startsWith('data: ')) continue;
                    let payload;
                    try { payload = JSON.parse(line.slice(6)); }
                    catch { continue; }

                    if (payload.chunk !== undefined) {
                        fullResponse += payload.chunk;
                        textNode.textContent = fullResponse;
                        scrollToBottom();
                    } else if (payload.done) {
                        break outer;
                    } else if (payload.error) {
                        throw new Error(payload.error);
                    }
                }
            }
        }

        activeReader = null;
        contentEl.classList.remove('streaming');

        if (stopped) {
            const mark = document.createElement('span');
            mark.className   = 'stop-mark';
            mark.textContent = ' [stopped]';
            contentEl.appendChild(mark);
        }

        metaEl.textContent = formatTime(new Date());
        exchangeCount++;
        updateCount();
        chatTitle.textContent = `Session ${currentSessionId.slice(0, 6)}`;

    } catch (err) {
        contentEl.classList.remove('streaming');
        if (!stopped) {
            const mark = document.createElement('span');
            mark.className   = 'stop-mark';
            mark.textContent = ` ⚠ ${err.message}`;
            contentEl.appendChild(mark);
        }
    } finally {
        typingIndicator.classList.add('hidden');
        isGenerating = false;
        stopButton.classList.add('hidden');
        sendButton.classList.remove('hidden');
        sendButton.disabled = false;
        userInput.disabled  = false;
        userInput.focus();
        scrollToBottom();
    }
}

// ── DOM helpers ───────────────────────────────────────────────────────
function appendMessage(role, text) {
    const row = document.createElement('div');
    row.className = `message-row ${role}`;

    const avatar = document.createElement('div');
    avatar.className   = role === 'user' ? 'avatar user-avatar' : 'avatar ai-avatar';
    avatar.textContent = role === 'user' ? (currentUserId ? currentUserId.slice(0,2).toUpperCase() : 'U') : 'AI';

    const bubble  = document.createElement('div');
    bubble.className = 'message-bubble';

    const content = document.createElement('div');
    content.className   = 'bubble-content';
    content.textContent = text;

    const meta = document.createElement('div');
    meta.className   = 'bubble-meta';
    meta.textContent = formatTime(new Date());

    bubble.appendChild(content);
    bubble.appendChild(meta);
    row.appendChild(avatar);
    row.appendChild(bubble);
    chatMessages.appendChild(row);
    scrollToBottom();
    return row;
}

function createAssistantBubble() {
    const row = document.createElement('div');
    row.className = 'message-row assistant';

    const avatar = document.createElement('div');
    avatar.className   = 'avatar ai-avatar';
    avatar.textContent = 'AI';

    const bubble  = document.createElement('div');
    bubble.className = 'message-bubble';

    const content = document.createElement('div');
    content.className = 'bubble-content';

    const meta = document.createElement('div');
    meta.className = 'bubble-meta';

    bubble.appendChild(content);
    bubble.appendChild(meta);
    row.appendChild(avatar);
    row.appendChild(bubble);

    return { row, contentEl: content, metaEl: meta };
}

function appendSystemMsg(text) {
    const el = document.createElement('div');
    el.className   = 'system-msg';
    el.textContent = text;
    chatMessages.appendChild(el);
    scrollToBottom();
}

function scrollToBottom() {
    chatMessages.scrollTo({ top: chatMessages.scrollHeight, behavior: 'smooth' });
}

function updateCount() {
    messageCountEl.textContent = exchangeCount === 1 ? '1 exchange' : `${exchangeCount} exchanges`;
}

function formatTime(d) {
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function escHtml(str) {
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function autoResize() {
    userInput.style.height = 'auto';
    userInput.style.height = Math.min(userInput.scrollHeight, 160) + 'px';
}

function toggleSidebar() {
    sidebar.classList.toggle('collapsed');
}

// ── Session list helpers ──────────────────────────────────────────────
function markAllSessionsInactive() {
    sessionList.querySelectorAll('.session-item').forEach(el => el.classList.remove('active'));
}

function markSessionInactive(sessionId) {
    const item = sessionList.querySelector(`[data-sid="${sessionId}"]`);
    if (item) item.classList.remove('active');
}

// Creates a session item and wires up its click handler
function createSessionItem(sessionId, title, meta, isActive) {
    const item = document.createElement('div');
    item.className   = `session-item${isActive ? ' active' : ''}`;
    item.dataset.sid = sessionId;
    item.innerHTML   = `
        <div class="session-item-icon">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
                <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"
                      stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
        </div>
        <div class="session-item-body">
            <div class="session-item-title">${escHtml(title)}</div>
            <div class="session-item-meta">${escHtml(meta)}</div>
        </div>`;

    item.addEventListener('click', () => loadPastSession(sessionId, title));
    return item;
}

// Called when a brand-new live session sends its first message
function addSessionToList(sessionId, firstMessage) {
    const empty = sessionList.querySelector('.session-empty');
    if (empty) empty.remove();

    markAllSessionsInactive();

    const title = firstMessage
        ? (firstMessage.length > 28 ? firstMessage.slice(0, 28) + '…' : firstMessage)
        : 'New session';

    const item = createSessionItem(sessionId, title, formatTime(new Date()), true);
    sessionList.insertBefore(item, sessionList.firstChild);
}

// Called on login with the user's historical sessions
function populatePastSessions(sessions) {
    const empty = sessionList.querySelector('.session-empty');
    if (empty) empty.remove();

    sessions.forEach(s => {
        const ts = s.ended_at
            ? new Date(s.ended_at).toLocaleDateString([], { month: 'short', day: 'numeric' })
            : '—';
        const meta  = `${ts} · ${s.message_count} msgs`;
        const title = s.preview || 'Session';
        const item  = createSessionItem(s.session_id, title, meta, false);
        sessionList.appendChild(item);
    });
}

// ── Memory toggle ─────────────────────────────────────────────────────
function initMemoryToggle() {
    memoryToggle.addEventListener('click', () => {
        memoryPanel.classList.toggle('expanded');
    });
}

// ── Event listeners ───────────────────────────────────────────────────
function setupEventListeners() {
    sendButton.addEventListener('click', sendMessage);
    stopButton.addEventListener('click', stopGeneration);
    themeToggle.addEventListener('click', toggleTheme);
    switchUserBtn.addEventListener('click', switchUser);

    userInput.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
        if (e.key === 'Escape') { userInput.value = ''; autoResize(); }
    });

    userInput.addEventListener('input', autoResize);
    newChatBtn.addEventListener('click', switchToNewSession);
    sidebarToggle.addEventListener('click', toggleSidebar);
    initMemoryToggle();

    document.addEventListener('keydown', e => {
        if ((e.metaKey || e.ctrlKey) && e.key === 'n') { e.preventDefault(); switchToNewSession(); }
        if ((e.metaKey || e.ctrlKey) && e.key === 'b') { e.preventDefault(); toggleSidebar(); }
    });
}

// ── Page unload ───────────────────────────────────────────────────────
window.addEventListener('beforeunload', () => {
    if (currentSessionId) navigator.sendBeacon(`/api/chat/${currentSessionId}/end`);
});

// ── Boot ──────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    initTheme();
    initIdGate();
});
