import json
import os
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional
import hashlib

class SessionManager:
    def __init__(self, memory_file: str):
        self.memory_file = Path(memory_file)
        self.sessions_dir = Path("sessions")
        self.sessions_dir.mkdir(exist_ok=True)
        
        # Create memory file if it doesn't exist
        if not self.memory_file.exists():
            self.memory_file.parent.mkdir(exist_ok=True)
            self.memory_file.write_text("# Session Memory\n\n## Lessons Learned\n\n")
    
    def load_memory(self) -> str:
        """Load memory from memory.md file"""
        try:
            return self.memory_file.read_text(encoding='utf-8')
        except Exception as e:
            print(f"Error loading memory: {e}")
            return ""
    
    def save_to_memory(self, summary: str, messages: List[Dict]) -> None:
        """Append session summary to memory.md"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        # Create memory entry
        memory_entry = f"""
## Session: {timestamp}

### Summary
{summary}

### Key Lessons
{self._extract_lessons(messages)}

### Topics Discussed
{self._extract_topics(messages)}

---
"""
        
        # Append to memory file
        with open(self.memory_file, 'a', encoding='utf-8') as f:
            f.write(memory_entry)
    
    def _extract_lessons(self, messages: List[Dict]) -> str:
        """Extract lessons from conversation"""
        # This is a simple implementation - you could make it smarter
        lessons = []
        for msg in messages:
            if msg["role"] == "assistant" and any(word in msg["content"].lower() for word in 
                                                  ["remember", "important", "key", "lesson", "learn"]):
                lessons.append(f"- {msg['content'][:200]}...")
        
        if not lessons:
            lessons = ["- No explicit lessons identified in this session"]
        
        return "\n".join(lessons)
    
    def _extract_topics(self, messages: List[Dict]) -> str:
        """Extract main topics from conversation"""
        # Simple topic extraction - could be enhanced
        user_messages = [m["content"] for m in messages if m["role"] == "user"]
        if not user_messages:
            return "- No topics identified"
        
        # Take first few words of each user message as topics
        topics = []
        for msg in user_messages[:5]:  # Limit to first 5 messages
            words = msg.split()[:5]
            if words:
                topics.append(f"- {' '.join(words)}...")
        
        return "\n".join(topics)
    
    def prepare_context(self, messages: List[Dict], global_memory: str) -> Dict[str, Any]:
        """Prepare the full context for the model"""
        # Format conversation history
        conversation = []
        for msg in messages[-10:]:  # Limit to last 10 messages for context
            conversation.append(f"{msg['role'].upper()}: {msg['content']}")
        
        context = {
            "prompt": f"""You are an AI assistant with access to previous conversation memory.

PREVIOUS MEMORY:
{global_memory}

CURRENT CONVERSATION:
{chr(10).join(conversation)}

Please continue the conversation naturally, taking into account the memory above.

Assistant:""",
            "memory_used": bool(global_memory),
            "message_count": len(messages)
        }
        
        return context
    
    def save_session_log(self, session_id: str, session_data: Dict) -> None:
        """Save complete session log to file"""
        log_file = self.sessions_dir / f"session_{session_id}.json"
        
        # Prepare data for saving
        save_data = {
            "session_id": session_id,
            "created_at": session_data.get("created_at", datetime.now()).isoformat(),
            "ended_at": datetime.now().isoformat(),
            "message_count": len(session_data.get("messages", [])),
            "messages": session_data.get("messages", []),
            "metadata": session_data.get("metadata", {})
        }
        
        # Save to file
        with open(log_file, 'w', encoding='utf-8') as f:
            json.dump(save_data, f, indent=2, ensure_ascii=False)
    
    def load_session_log(self, session_id: str) -> Optional[Dict]:
        """Load a previous session log"""
        log_file = self.sessions_dir / f"session_{session_id}.json"
        
        if log_file.exists():
            with open(log_file, 'r', encoding='utf-8') as f:
                return json.load(f)
        return None
    
    def get_session_hash(self, messages: List[Dict]) -> str:
        """Generate a hash of the session for deduplication"""
        content = "".join([f"{m['role']}:{m['content']}" for m in messages])
        return hashlib.md5(content.encode()).hexdigest()[:8]