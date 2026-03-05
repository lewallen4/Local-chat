// Global state
let currentSessionId = null;
let isGenerating = false;
let messageHistory = [];

// DOM elements
const chatMessages = document.getElementById('chat-messages');
const userInput = document.getElementById('user-input');
const sendButton = document.getElementById('send-button');
const typingIndicator = document.getElementById('typing-indicator');
const newChatBtn = document.getElementById('new-chat');
const sessionIdDisplay = document.getElementById('session-id-display');
const messageCountDisplay = document.getElementById('message-count');
const memoryPreview = document.getElementById('memory-preview');

// Initialize the chat
async function initChat() {
    await loadMemory();
    await startNewSession();
    setupEventListeners();
}

// Load memory preview
async function loadMemory() {
    try {
        const response = await fetch('/api/memory');
        const data = await response.json();
        if (data.memory) {
            // Format memory for preview (show last few lines)
            const lines = data.memory.split('\n').slice(-10).join('\n');
            memoryPreview.textContent = lines || 'No memory yet';
        }
    } catch (error) {
        console.error('Failed to load memory:', error);
        memoryPreview.textContent = 'Failed to load memory';
    }
}

// Start a new session
async function startNewSession() {
    try {
        const response = await fetch('/api/chat/start', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                metadata: {
                    user_agent: navigator.userAgent,
                    timestamp: new Date().toISOString()
                }
            })
        });
        
        const data = await response.json();
        currentSessionId = data.session_id;
        
        // Update UI
        sessionIdDisplay.textContent = `Session: ${currentSessionId.slice(0, 8)}...`;
        messageHistory = [];
        chatMessages.innerHTML = `
            <div class="welcome-message">
                <h3>New Session Started</h3>
                <p>Memory loaded: ${data.memory_loaded ? '✅' : '❌'}</p>
            </div>
        `;
        updateMessageCount();
        
        // Enable input
        userInput.disabled = false;
        userInput.focus();
        
    } catch (error) {
        console.error('Failed to start session:', error);
        showError('Failed to start session. Check if server is running.');
    }
}

// Send a message
async function sendMessage() {
    const message = userInput.value.trim();
    if (!message || isGenerating || !currentSessionId) return;
    
    // Clear input and disable
    userInput.value = '';
    isGenerating = true;
    sendButton.disabled = true;
    userInput.disabled = true;
    
    // Add user message to UI
    addMessageToUI('user', message);
    
    // Show typing indicator
    typingIndicator.classList.add('visible');
    
    // Create assistant message placeholder
    const assistantMessageDiv = document.createElement('div');
    assistantMessageDiv.className = 'message assistant-message';
    assistantMessageDiv.innerHTML = '<div class="message-content"></div><div class="message-timestamp"></div>';
    chatMessages.appendChild(assistantMessageDiv);
    const contentDiv = assistantMessageDiv.querySelector('.message-content');
    const timestampDiv = assistantMessageDiv.querySelector('.message-timestamp');
    
    try {
        // Send message with streaming
        const response = await fetch(`/api/chat/${currentSessionId}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ message })
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            
            const chunk = decoder.decode(value);
            const lines = chunk.split('\n\n');
            
            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));
                        
                        if (data.chunk) {
                            fullResponse += data.chunk;
                            contentDiv.textContent = fullResponse;
                            // Auto-scroll
                            chatMessages.scrollTop = chatMessages.scrollHeight;
                        } else if (data.done) {
                            // Update timestamp
                            timestampDiv.textContent = new Date().toLocaleTimeString();
                        } else if (data.error) {
                            throw new Error(data.error);
                        }
                    } catch (e) {
                        console.error('Error parsing chunk:', e);
                    }
                }
            }
        }
        
        // Update message count
        messageHistory.push({ role: 'user', content: message });
        messageHistory.push({ role: 'assistant', content: fullResponse });
        updateMessageCount();
        
    } catch (error) {
        console.error('Error sending message:', error);
        contentDiv.textContent = 'Error: Failed to get response. Check if model is loaded correctly.';
        contentDiv.style.color = '#dc3545';
    } finally {
        // Hide typing indicator and re-enable input
        typingIndicator.classList.remove('visible');
        isGenerating = false;
        sendButton.disabled = false;
        userInput.disabled = false;
        userInput.focus();
    }
}

// Add message to UI
function addMessageToUI(role, content) {
    const messageDiv = document.createElement('div');
    messageDiv.className = `message ${role}-message`;
    
    const contentDiv = document.createElement('div');
    contentDiv.className = 'message-content';
    contentDiv.textContent = content;
    
    const timestampDiv = document.createElement('div');
    timestampDiv.className = 'message-timestamp';
    timestampDiv.textContent = new Date().toLocaleTimeString();
    
    messageDiv.appendChild(contentDiv);
    messageDiv.appendChild(timestampDiv);
    chatMessages.appendChild(messageDiv);
    
    // Auto-scroll
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

// Update message count display
function updateMessageCount() {
    const count = messageHistory.length / 2; // Each exchange has 2 messages
    messageCountDisplay.textContent = `${count} messages`;
}

// Show error message
function showError(message) {
    const errorDiv = document.createElement('div');
    errorDiv.className = 'message assistant-message';
    errorDiv.style.backgroundColor = '#f8d7da';
    errorDiv.style.color = '#721c24';
    errorDiv.style.border = '1px solid #f5c6cb';
    errorDiv.textContent = message;
    chatMessages.appendChild(errorDiv);
}

// Setup event listeners
function setupEventListeners() {
    // Send button click
    sendButton.addEventListener('click', sendMessage);
    
    // Enter key to send (Shift+Enter for new line)
    userInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });
    
    // New chat button
    newChatBtn.addEventListener('click', async () => {
        // End current session if exists
        if (currentSessionId) {
            try {
                await fetch(`/api/chat/${currentSessionId}/end`, {
                    method: 'POST'
                });
            } catch (error) {
                console.error('Error ending session:', error);
            }
        }
        await loadMemory(); // Reload memory preview
        await startNewSession();
    });
    
    // Auto-resize textarea
    userInput.addEventListener('input', function() {
        this.style.height = 'auto';
        this.style.height = (this.scrollHeight) + 'px';
    });
}

// Handle page unload
window.addEventListener('beforeunload', async () => {
    if (currentSessionId) {
        // Use sendBeacon for reliable final session save
        navigator.sendBeacon(`/api/chat/${currentSessionId}/end`);
    }
});

// Initialize when page loads
document.addEventListener('DOMContentLoaded', initChat);