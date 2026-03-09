/* Haven Local AI — Frontend Script */

// ── State ──────────────────────────────────────────────────────────
let currentSessionId = null;
let isGenerating     = false;
let exchangeCount    = 0;
let activeReader     = null;   // holds the stream reader so we can cancel it

// ── DOM refs ───────────────────────────────────────────────────────
const $ = id => document.getElementById(id);

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

// ── Theme ───────────────────────────────────────────────────────────
function initTheme() {
    const saved = localStorage.getItem('haven-theme') || 'dark';
    applyTheme(saved);
}

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('haven-theme', theme);
    if (themeToggle) {
        themeToggle.title   = theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode';
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

// ── Init ───────────────────────────────────────────────────────────
async function init() {
    initTheme();
    setupEventListeners();
    setStatus('loading', 'Connecting...');
    await loadMemory();
    await startSession();
}

// ── Status helpers ──────────────────────────────────────────────────
function setStatus(state, label) {
    statusDot.className    = 'status-dot ' + state;
    statusLabel.textContent = label;
}

// ── Memory ─────────────────────────────────────────────────────────
async function loadMemory() {
    try {
        const res  = await fetch('/api/memory');
        const data = await res.json();
        const text = (data.memory || '').trim();
        memoryPreview.textContent = text
            ? (text.length > 800 ? '…' + text.slice(-800) : text)
            : 'No memory yet — it builds as you chat.';
    } catch {
        memoryPreview.textContent = 'Memory unavailable.';
    }
}

// ── Session ─────────────────────────────────────────────────────────
async function startSession() {
    try {
        const res  = await fetch('/api/chat/start', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ metadata: { timestamp: new Date().toISOString() } })
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

async function endSession(sessionId) {
    if (!sessionId) return;
    try { await fetch(`/api/chat/${sessionId}/end`, { method: 'POST' }); }
    catch { /* best-effort */ }
}

// ── Stop generation ─────────────────────────────────────────────────
function stopGeneration() {
    if (activeReader) {
        activeReader.cancel();
        activeReader = null;
    }
}

// ── Send message ────────────────────────────────────────────────────
async function sendMessage() {
    const text = userInput.value.trim();
    if (!text || isGenerating || !currentSessionId) return;

    userInput.value = '';
    autoResize();
    isGenerating    = true;

    sendButton.classList.add('hidden');
    stopButton.classList.remove('hidden');
    userInput.disabled = true;

    const welcome = document.querySelector('.welcome-screen');
    if (welcome) welcome.remove();

    appendMessage('user', text);

    // Add/update session in sidebar list on first message
    if (exchangeCount === 0) {
        addSessionToList(currentSessionId, text);
    }

    typingIndicator.classList.remove('hidden');
    scrollToBottom();

    // Create assistant bubble.
    // IMPORTANT: textNode is the ONLY child of contentEl during streaming.
    // Cursor is a CSS ::after pseudo-element — no competing DOM sibling.
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
            body:    JSON.stringify({ message: text })
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const reader  = res.body.getReader();
        const decoder = new TextDecoder();
        activeReader  = reader;

        // Buffer handles SSE lines that arrive split across network chunks
        let buffer = '';

        outer: while (true) {
            let value, done;
            try {
                ({ value, done } = await reader.read());
            } catch {
                // Cancelled via stopGeneration()
                stopped = true;
                break;
            }
            if (done) break;

            buffer += decoder.decode(value, { stream: true });

            // SSE events are separated by blank lines (\n\n)
            const events = buffer.split('\n\n');
            buffer = events.pop(); // keep any incomplete trailing event

            for (const event of events) {
                for (const line of event.split('\n')) {
                    if (!line.startsWith('data: ')) continue;

                    let payload;
                    try {
                        payload = JSON.parse(line.slice(6));
                    } catch {
                        continue; // skip malformed line, keep going
                    }

                    if (payload.chunk !== undefined) {
                        fullResponse += payload.chunk;
                        // Single text node update = horizontal text, no DOM thrash
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
        // Keep whatever streamed before the error
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

// ── DOM helpers ─────────────────────────────────────────────────────
function appendMessage(role, text) {
    const row = document.createElement('div');
    row.className = `message-row ${role}`;

    const avatar = document.createElement('div');
    avatar.className   = role === 'user' ? 'avatar user-avatar' : 'avatar ai-avatar';
    avatar.textContent = role === 'user' ? 'U' : 'AI';

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

// ── Auto-resize textarea ─────────────────────────────────────────────
function autoResize() {
    userInput.style.height = 'auto';
    userInput.style.height = Math.min(userInput.scrollHeight, 160) + 'px';
}

// ── Sidebar toggle ───────────────────────────────────────────────────
function toggleSidebar() {
    sidebar.classList.toggle('collapsed');
}

// ── Session list ─────────────────────────────────────────────────────
const sessionHistory = []; // [{id, title, time, exchanges}]

function addSessionToList(sessionId, firstMessage) {
    // Remove "no sessions" placeholder
    const empty = sessionList.querySelector('.session-empty');
    if (empty) empty.remove();

    // Mark all others inactive
    sessionList.querySelectorAll('.session-item').forEach(el => el.classList.remove('active'));

    const title = firstMessage
        ? (firstMessage.length > 28 ? firstMessage.slice(0, 28) + '…' : firstMessage)
        : 'New session';
    const time  = formatTime(new Date());

    const item  = document.createElement('div');
    item.className   = 'session-item active';
    item.dataset.sid = sessionId;
    item.innerHTML   = `
        <div class="session-item-icon">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
                <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"
                      stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
        </div>
        <div class="session-item-body">
            <div class="session-item-title">${title}</div>
            <div class="session-item-meta">${time}</div>
        </div>`;

    // Prepend so newest is at top
    sessionList.insertBefore(item, sessionList.firstChild);
    sessionHistory.unshift({ id: sessionId, title, time });
}

function updateActiveSession(sessionId, firstMessage) {
    const item = sessionList.querySelector(`[data-sid="${sessionId}"]`);
    if (item) {
        const titleEl = item.querySelector('.session-item-title');
        if (titleEl && firstMessage) {
            const t = firstMessage.length > 28 ? firstMessage.slice(0, 28) + '…' : firstMessage;
            titleEl.textContent = t;
        }
    }
}

function markSessionInactive(sessionId) {
    const item = sessionList.querySelector(`[data-sid="${sessionId}"]`);
    if (item) item.classList.remove('active');
}

// ── Memory toggle ─────────────────────────────────────────────────────
function initMemoryToggle() {
    // Collapsed by default — no class needed since CSS defaults to collapsed
    memoryToggle.addEventListener('click', () => {
        memoryPanel.classList.toggle('expanded');
    });
}

// ── Event listeners ──────────────────────────────────────────────────
function setupEventListeners() {
    sendButton.addEventListener('click', sendMessage);
    stopButton.addEventListener('click', stopGeneration);
    themeToggle.addEventListener('click', toggleTheme);

    userInput.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
        if (e.key === 'Escape') { userInput.value = ''; autoResize(); }
    });

    userInput.addEventListener('input', autoResize);

    newChatBtn.addEventListener('click', async () => {
        if (isGenerating) { stopGeneration(); return; }
        markSessionInactive(currentSessionId);
        await endSession(currentSessionId);
        currentSessionId = null;
        exchangeCount    = 0;

        chatMessages.innerHTML = `
            <div class="welcome-screen">
                <div class="welcome-icon">
                    <svg width="40" height="40" viewBox="0 0 24 24" fill="none">
                        <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"
                              stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                    </svg>
                </div>
                <h2>Local Chat is ready.</h2>
                <p>Your fully local AI assistant. No cloud, no telemetry, no traces.</p>
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
    });

    sidebarToggle.addEventListener('click', toggleSidebar);
    initMemoryToggle();

    document.addEventListener('keydown', e => {
        if ((e.metaKey || e.ctrlKey) && e.key === 'n') { e.preventDefault(); newChatBtn.click(); }
        if ((e.metaKey || e.ctrlKey) && e.key === 'b') { e.preventDefault(); toggleSidebar(); }
    });
}

// ── Page unload ───────────────────────────────────────────────────────
window.addEventListener('beforeunload', () => {
    if (currentSessionId) navigator.sendBeacon(`/api/chat/${currentSessionId}/end`);
});

// ── Boot ──────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', init);
