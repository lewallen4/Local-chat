#!/usr/bin/env python3
"""
Local LLM Chat Server with Memory Management
A production-grade web interface for running GGUF models locally
"""

import os
import sys
import json
import time
import hashlib
import logging
import threading
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, asdict
from queue import Queue
import signal
import atexit

# Try to import torch with fallback
try:
    import torch
    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False
    print("Warning: PyTorch not available, running in CPU-only mode")

# Web framework imports
from flask import Flask, request, jsonify, render_template_string
from flask_cors import CORS
from werkzeug.serving import run_simple

# LLM imports with version compatibility handling
try:
    from llama_cpp import Llama
    from llama_cpp import LlamaGrammar, LlamaCache
    LLAMA_CPP_AVAILABLE = True
except ImportError as e:
    LLAMA_CPP_AVAILABLE = False
    print(f"ERROR: llama-cpp-python not installed correctly: {e}")
    print("Please run: pip install llama-cpp-python --upgrade")
    sys.exit(1)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('llm_server.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# Add GitHub Actions detection
if os.environ.get('GITHUB_ACTIONS') == 'true':
    print("\n" + "="*50)
    print("🚀 Running in GitHub Actions")
    print("="*50)
    print("📡 Ngrok URL will be available via the workflow output")
    print("="*50 + "\n")
    
    # Force stdout to be unbuffered
    sys.stdout.reconfigure(line_buffering=True)

# ============================================================================
# Data Models
# ============================================================================

@dataclass
class Message:
    """Represents a single chat message"""
    role: str  # 'user', 'assistant', 'system'
    content: str
    timestamp: datetime
    id: str = None
    
    def __post_init__(self):
        if self.id is None:
            self.id = hashlib.md5(f"{self.timestamp}{self.content}".encode()).hexdigest()[:8]
        if isinstance(self.timestamp, str):
            self.timestamp = datetime.fromisoformat(self.timestamp)
    
    def to_dict(self):
        return {
            'id': self.id,
            'role': self.role,
            'content': self.content,
            'timestamp': self.timestamp.isoformat()
        }

@dataclass
class Session:
    """Represents a chat session"""
    id: str
    messages: List[Message]
    created_at: datetime
    last_activity: datetime
    summary: Optional[str] = None
    
    def to_dict(self):
        return {
            'id': self.id,
            'messages': [m.to_dict() for m in self.messages],
            'created_at': self.created_at.isoformat(),
            'last_activity': self.last_activity.isoformat(),
            'summary': self.summary
        }

# ============================================================================
# Memory Manager
# ============================================================================

class MemoryManager:
    """Manages long-term memory storage and retrieval"""
    
    def __init__(self, models_dir: str = "models"):
        self.models_dir = Path(models_dir)
        self.memory_file = self.models_dir / "memory.md"
        self.ensure_memory_file()
        
    def ensure_memory_file(self):
        """Create memory file if it doesn't exist"""
        self.models_dir.mkdir(exist_ok=True)
        if not self.memory_file.exists():
            with open(self.memory_file, 'w') as f:
                f.write("# LLM Memory Bank\n\n")
                f.write("## Session Summaries and Lessons Learned\n\n")
                f.write("*This file contains accumulated knowledge from past conversations*\n\n")
    
    def add_memory(self, session_summary: str, lessons: str = ""):
        """Add a new memory entry"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        memory_entry = f"""
## Session Memory - {timestamp}

### Summary
{session_summary}

### Lessons Learned
{lessons if lessons else "No specific lessons recorded."}

---
"""
        with open(self.memory_file, 'a') as f:
            f.write(memory_entry)
        logger.info(f"Added new memory entry at {timestamp}")
    
    def get_context(self, max_tokens: int = 1000) -> str:
        """Retrieve relevant context from memory"""
        try:
            with open(self.memory_file, 'r') as f:
                content = f.read()
            # Simple truncation - in production, you'd want smarter retrieval
            if len(content.split()) > max_tokens:
                words = content.split()[:max_tokens]
                return ' '.join(words) + "...\n[Memory truncated due to length]"
            return content
        except Exception as e:
            logger.error(f"Error reading memory file: {e}")
            return ""

# ============================================================================
# Session Manager
# ============================================================================

class SessionManager:
    """Manages active chat sessions"""
    
    def __init__(self, memory_manager: MemoryManager, stale_hours: int = 1):
        self.sessions: Dict[str, Session] = {}
        self.memory_manager = memory_manager
        self.stale_hours = stale_hours
        self.lock = threading.Lock()
        self.cleanup_thread = threading.Thread(target=self._cleanup_loop, daemon=True)
        self.cleanup_thread.start()
        
    def create_session(self) -> Session:
        """Create a new session"""
        session_id = hashlib.sha256(os.urandom(32)).hexdigest()[:16]
        session = Session(
            id=session_id,
            messages=[],
            created_at=datetime.now(),
            last_activity=datetime.now()
        )
        with self.lock:
            self.sessions[session_id] = session
        logger.info(f"Created new session: {session_id}")
        return session
    
    def get_session(self, session_id: str) -> Optional[Session]:
        """Get a session by ID"""
        with self.lock:
            session = self.sessions.get(session_id)
            if session:
                session.last_activity = datetime.now()
            return session
    
    def add_message(self, session_id: str, role: str, content: str) -> Optional[Message]:
        """Add a message to a session"""
        session = self.get_session(session_id)
        if not session:
            return None
        
        message = Message(
            role=role,
            content=content,
            timestamp=datetime.now()
        )
        
        with self.lock:
            session.messages.append(message)
            session.last_activity = datetime.now()
        
        return message
    
    def get_session_messages(self, session_id: str) -> List[Message]:
        """Get all messages in a session"""
        session = self.get_session(session_id)
        return session.messages if session else []
    
    def _cleanup_loop(self):
        """Background thread to cleanup stale sessions"""
        while True:
            time.sleep(300)  # Check every 5 minutes
            self._cleanup_stale_sessions()
    
    def _cleanup_stale_sessions(self):
        """Archive and remove stale sessions"""
        now = datetime.now()
        stale_sessions = []
        
        with self.lock:
            for session_id, session in list(self.sessions.items()):
                time_since_activity = now - session.last_activity
                if time_since_activity > timedelta(hours=self.stale_hours):
                    stale_sessions.append(session)
                    del self.sessions[session_id]
        
        # Archive stale sessions
        for session in stale_sessions:
            self._archive_session(session)
            logger.info(f"Archived stale session: {session.id}")
    
    def _archive_session(self, session: Session):
        """Archive a session to long-term memory"""
        if not session.messages:
            return
        
        # Generate summary using the LLM if available
        summary = self._generate_session_summary(session)
        lessons = self._extract_lessons(session)
        
        # Add to memory
        self.memory_manager.add_memory(summary, lessons)
    
    def _generate_session_summary(self, session: Session) -> str:
        """Generate a summary of the session"""
        if not session.messages:
            return "Empty session"
        
        # Simple summary generation - in production, you'd use the LLM
        message_count = len(session.messages)
        user_messages = sum(1 for m in session.messages if m.role == 'user')
        assistant_messages = sum(1 for m in session.messages if m.role == 'assistant')
        
        summary = f"Session had {message_count} messages ({user_messages} user, {assistant_messages} assistant). "
        
        if session.messages:
            first_message = session.messages[0].content[:100]
            last_message = session.messages[-1].content[:100]
            summary += f"Started with: '{first_message}...' Ended with: '{last_message}...'"
        
        return summary
    
    def _extract_lessons(self, session: Session) -> str:
        """Extract lessons from the session"""
        # This is a placeholder - in production, you'd use NLP/LLM to extract insights
        return "No automated lessons extracted. Manual review recommended."

# ============================================================================
# LLM Manager (Fixed version)
# ============================================================================

class LLMManager:
    """Manages the LLM model loading and inference"""
    
    def __init__(self, models_dir: str = "models", specific_model: str = None):
        self.models_dir = Path(models_dir)
        self.specific_model = specific_model
        self.model = None
        self.model_path = None
        self.model_lock = threading.Lock()
        self.load_model()
    
    def find_model(self) -> Optional[Path]:
        """Find a GGUF model in the models directory"""
        # If specific model is provided, use it
        if self.specific_model:
            model_path = self.models_dir / self.specific_model
            if model_path.exists():
                return model_path
            else:
                logger.error(f"Specific model {self.specific_model} not found in {self.models_dir}")
                return None
        
        # Otherwise find the largest GGUF file
        gguf_files = list(self.models_dir.glob("*.gguf"))
        if not gguf_files:
            return None
        # Use the largest GGUF file by default
        return max(gguf_files, key=lambda p: p.stat().st_size)
    
    def verify_model_file(self, model_path: Path) -> bool:
        """Verify that the model file is valid"""
        try:
            # Check file size
            file_size = model_path.stat().st_size
            if file_size < 1000000:  # Less than 1MB - probably invalid
                logger.error(f"Model file too small ({file_size} bytes), might be corrupted")
                return False
            
            # Check file header for GGUF magic number
            with open(model_path, 'rb') as f:
                header = f.read(8)
                # GGUF magic number is 'GGUF' in bytes
                if header[:4] != b'GGUF':
                    logger.error(f"File does not appear to be a valid GGUF model (magic number: {header[:4]})")
                    return False
            
            return True
        except Exception as e:
            logger.error(f"Error verifying model file: {e}")
            return False
    
    def load_model(self, model_path: Optional[str] = None):
        """Load the LLM model with better error handling"""
        try:
            if model_path:
                self.model_path = Path(model_path)
            else:
                self.model_path = self.find_model()
            
            if not self.model_path or not self.model_path.exists():
                logger.error(f"No model found in {self.models_dir}")
                return False
            
            logger.info(f"Found model: {self.model_path}")
            logger.info(f"Model size: {self.model_path.stat().st_size / (1024**3):.2f} GB")
            
            # Verify the model file
            if not self.verify_model_file(self.model_path):
                logger.error("Model file verification failed")
                return False
            
            # Check for GPU availability
            n_gpu_layers = 0  # Default to CPU only for stability in GitHub Actions
            if TORCH_AVAILABLE and torch.cuda.is_available():
                n_gpu_layers = -1  # Use all layers on GPU
                logger.info(f"GPU detected: {torch.cuda.get_device_name(0)}")
            else:
                logger.info("Running in CPU mode")
            
            # Load the model with explicit parameters for better compatibility
            logger.info("Loading model (this may take a few minutes)...")
            
            # Try loading with different configurations based on model size
            try:
                # First attempt with standard settings
                self.model = Llama(
                    model_path=str(self.model_path),
                    n_ctx=2048,  # Smaller context for stability
                    n_threads=os.cpu_count() or 4,
                    n_gpu_layers=n_gpu_layers,
                    verbose=False,
                    use_mmap=True,  # Use memory mapping for faster loading
                    use_mlock=False,  # Don't lock memory (safer for GitHub Actions)
                )
            except Exception as e:
                logger.warning(f"First load attempt failed: {e}")
                logger.info("Attempting to load with fallback parameters...")
                
                # Fallback with minimal settings
                self.model = Llama(
                    model_path=str(self.model_path),
                    n_ctx=1024,  # Minimal context
                    n_threads=2,  # Fewer threads
                    n_gpu_layers=0,  # Force CPU
                    verbose=False,
                    use_mmap=False,  # Don't use memory mapping
                    use_mlock=False,
                    low_vram=True,  # Low VRAM mode
                )
            
            logger.info("✅ Model loaded successfully")
            
            # Test the model with a simple prompt
            try:
                test_response = self.model(
                    "Hello", 
                    max_tokens=5,
                    temperature=0.1
                )
                logger.info("✅ Model test successful")
            except Exception as e:
                logger.warning(f"Model test failed but model may still work: {e}")
            
            return True
            
        except Exception as e:
            logger.error(f"❌ Failed to load model: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return False
    
    def generate_response(self, messages: List[Dict[str, str]], memory_context: str = "") -> str:
        """Generate a response from the model with better error handling"""
        if not self.model:
            return "⚠️ Model not loaded. Please check the server logs."
        
        with self.model_lock:
            try:
                # Format messages for the model
                prompt = self._format_prompt(messages, memory_context)
                
                # Generate response with conservative parameters
                response = self.model(
                    prompt,
                    max_tokens=512,  # Shorter responses for stability
                    temperature=0.7,
                    top_p=0.95,
                    repeat_penalty=1.1,
                    top_k=40,
                    stop=["User:", "\nUser ", "Human:", "\nHuman ", "<|im_end|>"],
                    echo=False
                )
                
                generated_text = response['choices'][0]['text'].strip()
                if not generated_text:
                    return "I'm having trouble generating a response. Please try again."
                
                return generated_text
                
            except Exception as e:
                logger.error(f"Error generating response: {e}")
                return f"⚠️ Error: {str(e)}"
    
    def _format_prompt(self, messages: List[Dict[str, str]], memory_context: str) -> str:
        """Format messages into a prompt for the model"""
        system_message = f"""You are a helpful AI assistant. You have access to the following memory from past conversations:

{memory_context}

Use this memory to provide consistent and helpful responses. If you don't know something, say so."""
        
        formatted = f"<|im_start|>system\n{system_message}<|im_end|>\n\n"
        
        for msg in messages:
            role = "user" if msg['role'] == 'user' else "assistant"
            formatted += f"<|im_start|>{role}\n{msg['content']}<|im_end|>\n\n"
        
        formatted += "<|im_start|>assistant\n"
        return formatted

# ============================================================================
# Web Application
# ============================================================================

# HTML Template for the chat interface (same as before)
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Local LLM Chat</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        
        #chat-container {
            width: 90%;
            max-width: 1200px;
            height: 90vh;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }
        
        #chat-header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            text-align: center;
            position: relative;
        }
        
        #chat-header h1 {
            font-size: 24px;
            margin-bottom: 5px;
        }
        
        #chat-header p {
            font-size: 14px;
            opacity: 0.9;
        }
        
        #model-status {
            position: absolute;
            top: 10px;
            right: 20px;
            font-size: 12px;
            padding: 4px 8px;
            border-radius: 12px;
            background: rgba(255,255,255,0.2);
        }
        
        #messages {
            flex: 1;
            overflow-y: auto;
            padding: 20px;
            background: #f5f5f5;
        }
        
        .message {
            margin-bottom: 20px;
            display: flex;
            flex-direction: column;
        }
        
        .message.user {
            align-items: flex-end;
        }
        
        .message-content {
            max-width: 70%;
            padding: 12px 16px;
            border-radius: 18px;
            font-size: 14px;
            line-height: 1.5;
            word-wrap: break-word;
        }
        
        .user .message-content {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border-bottom-right-radius: 4px;
        }
        
        .assistant .message-content {
            background: white;
            color: #333;
            border-bottom-left-radius: 4px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        
        .message-time {
            font-size: 11px;
            color: #999;
            margin-top: 4px;
            margin-left: 8px;
            margin-right: 8px;
        }
        
        #input-container {
            padding: 20px;
            background: white;
            border-top: 1px solid #e0e0e0;
            display: flex;
            gap: 10px;
        }
        
        #message-input {
            flex: 1;
            padding: 12px 16px;
            border: 2px solid #e0e0e0;
            border-radius: 25px;
            font-size: 14px;
            outline: none;
            transition: border-color 0.3s;
        }
        
        #message-input:focus {
            border-color: #667eea;
        }
        
        #send-button {
            padding: 12px 30px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 25px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        #send-button:hover:not(:disabled) {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        
        #send-button:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        
        #typing-indicator {
            display: none;
            padding: 12px 16px;
            background: white;
            border-radius: 18px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            max-width: 70%;
        }
        
        #typing-indicator span {
            display: inline-block;
            width: 8px;
            height: 8px;
            background: #999;
            border-radius: 50%;
            margin-right: 5px;
            animation: typing 1.4s infinite;
        }
        
        #typing-indicator span:nth-child(2) {
            animation-delay: 0.2s;
        }
        
        #typing-indicator span:nth-child(3) {
            animation-delay: 0.4s;
        }
        
        @keyframes typing {
            0%, 60%, 100% {
                transform: translateY(0);
                opacity: 0.6;
            }
            30% {
                transform: translateY(-10px);
                opacity: 1;
            }
        }
        
        #new-chat-btn {
            position: absolute;
            top: 20px;
            right: 100px;
            padding: 8px 16px;
            background: rgba(255,255,255,0.2);
            color: white;
            border: 1px solid white;
            border-radius: 20px;
            cursor: pointer;
            transition: background 0.3s;
        }
        
        #new-chat-btn:hover {
            background: rgba(255,255,255,0.3);
        }
    </style>
</head>
<body>
    <div id="chat-container">
        <div id="chat-header">
            <h1>Local LLM Chat</h1>
            <p>Powered by GGUF models with persistent memory</p>
            <div id="model-status">🔄 Loading model...</div>
            <button id="new-chat-btn" onclick="newChat()">New Chat</button>
        </div>
        <div id="messages"></div>
        <div id="typing-indicator">
            <span></span>
            <span></span>
            <span></span>
        </div>
        <div id="input-container">
            <input type="text" id="message-input" placeholder="Type your message..." onkeypress="handleKeyPress(event)" disabled>
            <button id="send-button" onclick="sendMessage()" disabled>Send</button>
        </div>
    </div>

    <script>
        let sessionId = localStorage.getItem('sessionId') || '';
        let isLoading = false;
        let modelLoaded = false;

        // Check model status on load
        window.onload = function() {
            checkModelStatus();
            if (sessionId) {
                loadSession();
            } else {
                newChat();
            }
        };

        async function checkModelStatus() {
            try {
                const response = await fetch('/api/health');
                const data = await response.json();
                modelLoaded = data.model_loaded;
                
                const statusDiv = document.getElementById('model-status');
                if (modelLoaded) {
                    statusDiv.innerHTML = '✅ Model loaded';
                    statusDiv.style.background = 'rgba(76, 175, 80, 0.3)';
                    document.getElementById('message-input').disabled = false;
                    document.getElementById('send-button').disabled = false;
                } else {
                    statusDiv.innerHTML = '❌ Model not loaded';
                    statusDiv.style.background = 'rgba(244, 67, 54, 0.3)';
                }
            } catch (error) {
                console.error('Error checking model status:', error);
            }
        }

        async function newChat() {
            try {
                const response = await fetch('/api/session/new', {
                    method: 'POST'
                });
                const data = await response.json();
                sessionId = data.session_id;
                localStorage.setItem('sessionId', sessionId);
                document.getElementById('messages').innerHTML = '';
                addMessage('assistant', 'Hello! How can I help you today?');
            } catch (error) {
                console.error('Error creating new chat:', error);
            }
        }

        async function loadSession() {
            try {
                const response = await fetch(`/api/session/${sessionId}/messages`);
                const messages = await response.json();
                document.getElementById('messages').innerHTML = '';
                messages.forEach(msg => {
                    addMessage(msg.role, msg.content, msg.timestamp);
                });
            } catch (error) {
                console.error('Error loading session:', error);
                newChat();
            }
        }

        function addMessage(role, content, timestamp = null) {
            const messagesDiv = document.getElementById('messages');
            const messageDiv = document.createElement('div');
            messageDiv.className = `message ${role}`;
            
            const timeStr = timestamp ? new Date(timestamp).toLocaleTimeString() : new Date().toLocaleTimeString();
            
            messageDiv.innerHTML = `
                <div class="message-content">${escapeHtml(content)}</div>
                <div class="message-time">${timeStr}</div>
            `;
            
            messagesDiv.appendChild(messageDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function showTypingIndicator() {
            document.getElementById('typing-indicator').style.display = 'block';
            document.getElementById('messages').scrollTop = document.getElementById('messages').scrollHeight;
        }

        function hideTypingIndicator() {
            document.getElementById('typing-indicator').style.display = 'none';
        }

        async function sendMessage() {
            if (!modelLoaded) {
                alert('Model is still loading. Please wait...');
                return;
            }
            
            const input = document.getElementById('message-input');
            const message = input.value.trim();
            
            if (!message || isLoading) return;
            
            input.value = '';
            addMessage('user', message);
            
            isLoading = true;
            document.getElementById('send-button').disabled = true;
            showTypingIndicator();
            
            try {
                const response = await fetch('/api/chat', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        session_id: sessionId,
                        message: message
                    })
                });
                
                const data = await response.json();
                hideTypingIndicator();
                addMessage('assistant', data.response);
            } catch (error) {
                hideTypingIndicator();
                addMessage('assistant', 'Sorry, there was an error processing your request.');
                console.error('Error:', error);
            } finally {
                isLoading = false;
                document.getElementById('send-button').disabled = false;
                document.getElementById('message-input').focus();
            }
        }

        function handleKeyPress(event) {
            if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                sendMessage();
            }
        }

        // Periodically check model status
        setInterval(checkModelStatus, 5000);
    </script>
</body>
</html>
"""

class ChatServer:
    """Main Flask application"""
    
    def __init__(self, models_dir: str = "models", specific_model: str = None, host: str = "0.0.0.0", port: int = 5000):
        self.app = Flask(__name__)
        CORS(self.app)
        self.host = host
        self.port = port
        self.models_dir = Path(models_dir)
        self.specific_model = specific_model
        
        # Initialize components
        self.memory_manager = MemoryManager(models_dir)
        self.session_manager = SessionManager(self.memory_manager)
        self.llm_manager = LLMManager(models_dir, specific_model)
        
        # Setup routes
        self.setup_routes()
        
        # Register shutdown handler
        atexit.register(self.shutdown)
    
    def setup_routes(self):
        """Setup all routes"""
        
        @self.app.route('/')
        def index():
            return render_template_string(HTML_TEMPLATE)
        
        @self.app.route('/api/session/new', methods=['POST'])
        def new_session():
            session = self.session_manager.create_session()
            return jsonify({'session_id': session.id})
        
        @self.app.route('/api/session/<session_id>/messages', methods=['GET'])
        def get_messages(session_id):
            messages = self.session_manager.get_session_messages(session_id)
            return jsonify([m.to_dict() for m in messages])
        
        @self.app.route('/api/chat', methods=['POST'])
        def chat():
            data = request.json
            session_id = data.get('session_id')
            message = data.get('message')
            
            if not session_id or not message:
                return jsonify({'error': 'Missing session_id or message'}), 400
            
            # Add user message
            self.session_manager.add_message(session_id, 'user', message)
            
            # Get session messages and memory context
            messages = self.session_manager.get_session_messages(session_id)
            memory_context = self.memory_manager.get_context()
            
            # Generate response
            response = self.llm_manager.generate_response(
                [m.to_dict() for m in messages],
                memory_context
            )
            
            # Add assistant message
            self.session_manager.add_message(session_id, 'assistant', response)
            
            return jsonify({'response': response})
        
        @self.app.route('/api/health', methods=['GET'])
        def health():
            return jsonify({
                'status': 'healthy',
                'model_loaded': self.llm_manager.model is not None,
                'model_path': str(self.llm_manager.model_path) if self.llm_manager.model_path else None,
                'sessions_active': len(self.session_manager.sessions),
                'gpu_available': TORCH_AVAILABLE and torch.cuda.is_available() if TORCH_AVAILABLE else False
            })
        
        @self.app.route('/api/memory', methods=['GET'])
        def get_memory():
            return jsonify({'memory': self.memory_manager.get_context()})
    
    def shutdown(self):
        """Cleanup on shutdown"""
        logger.info("Shutting down server...")
        # Archive any remaining sessions
        for session_id in list(self.session_manager.sessions.keys()):
            session = self.session_manager.sessions.get(session_id)
            if session:
                self.session_manager._archive_session(session)
    
    def run(self):
        """Run the server"""
        logger.info(f"Starting LLM Chat Server on http://{self.host}:{self.port}")
        logger.info(f"Models directory: {self.models_dir.absolute()}")
        logger.info(f"Memory file: {self.memory_manager.memory_file}")
        logger.info(f"GPU Available: {TORCH_AVAILABLE and torch.cuda.is_available() if TORCH_AVAILABLE else False}")
        
        if not self.llm_manager.model:
            logger.warning("No model loaded. The web interface will show an error.")
        else:
            logger.info("✅ Model loaded and ready!")
        
        # Run with production settings
        run_simple(
            self.host,
            self.port,
            self.app,
            use_reloader=False,
            use_debugger=False,
            use_evalex=False,
            threaded=True
        )

# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Local LLM Chat Server with Memory')
    parser.add_argument('--models-dir', type=str, default='models',
                       help='Directory containing GGUF models (default: models)')
    parser.add_argument('--model', type=str, default=None,
                       help='Specific model filename to load (default: auto-detect)')
    parser.add_argument('--host', type=str, default='0.0.0.0',
                       help='Host to bind to (default: 0.0.0.0)')
    parser.add_argument('--port', type=int, default=5000,
                       help='Port to bind to (default: 5000)')
    parser.add_argument('--stale-hours', type=int, default=1,
                       help='Hours before a session is considered stale (default: 1)')
    
    args = parser.parse_args()
    
    # Create models directory if it doesn't exist
    models_path = Path(args.models_dir)
    models_path.mkdir(exist_ok=True)
    
    # Create memory file if it doesn't exist
    memory_file = models_path / "memory.md"
    if not memory_file.exists():
        with open(memory_file, 'w') as f:
            f.write("# LLM Memory Bank\n\n")
            f.write("## Session Summaries and Lessons Learned\n\n")
            f.write("*This file contains accumulated knowledge from past conversations*\n\n")
    
    # Start server
    server = ChatServer(
        models_dir=args.models_dir,
        specific_model=args.model,
        host=args.host,
        port=args.port
    )
    
    # Override stale hours
    server.session_manager.stale_hours = args.stale_hours
    
    # Handle shutdown signals
    def signal_handler(sig, frame):
        logger.info("Received shutdown signal")
        server.shutdown()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Run server
    server.run()

if __name__ == '__main__':
    main()