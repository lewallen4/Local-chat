from typing import List, Dict
import re
from datetime import datetime

class SessionSummarizer:
    def __init__(self):
        self.summary_prompt = """Please summarize this conversation, focusing on:
1. Main topics discussed
2. Key decisions or conclusions
3. Important information shared by the user
4. Any action items or follow-ups
5. The overall tone and context

Conversation:
{conversation}

Summary:"""
    
    async def summarize_session(self, messages: List[Dict], existing_memory: str = "") -> str:
        """Generate a summary of the session"""
        
        if not messages:
            return "No messages in this session."
        
        # Format conversation for summarization
        conversation_text = ""
        for msg in messages:
            role = "User" if msg["role"] == "user" else "Assistant"
            conversation_text += f"{role}: {msg['content']}\n\n"
        
        # Simple extractive summary (since we don't want to use the model for this)
        summary_parts = []
        
        # Extract user's main questions/interests
        user_messages = [m["content"] for m in messages if m["role"] == "user"]
        if user_messages:
            summary_parts.append("User was interested in: " + 
                               self._extract_key_points(user_messages))
        
        # Extract key information provided
        assistant_messages = [m["content"] for m in messages if m["role"] == "assistant"]
        if assistant_messages:
            key_info = self._extract_key_information(assistant_messages)
            if key_info:
                summary_parts.append("Key information shared: " + key_info)
        
        # Determine conversation length and tone
        total_messages = len(messages)
        tone = self._determine_tone(messages)
        summary_parts.append(f"Conversation had {total_messages} exchanges with a {tone} tone.")
        
        return "\n".join(summary_parts)
    
    def _extract_key_points(self, messages: List[str]) -> str:
        """Extract key points from user messages"""
        # Look for questions and main topics
        questions = []
        for msg in messages:
            # Find sentences with question marks
            if '?' in msg:
                sentences = re.split(r'[.!?]+', msg)
                for s in sentences:
                    if '?' in s:
                        questions.append(s.strip())
        
        if questions:
            return " ".join(questions[:3])  # Return first 3 questions
        else:
            # Return first 100 chars of first message
            return messages[0][:100] + "..."
    
    def _extract_key_information(self, messages: List[str]) -> str:
        """Extract key information from assistant responses"""
        # Look for definitive statements and facts
        facts = []
        for msg in messages:
            # Look for sentences that seem informative
            sentences = re.split(r'[.!?]+', msg)
            for s in sentences:
                s = s.strip()
                # Check if sentence has informative patterns
                if any(pattern in s.lower() for pattern in 
                      [' is ', ' are ', ' was ', ' were ', ' can ', ' will ']):
                    if len(s.split()) > 5:  # Reasonable sentence length
                        facts.append(s)
        
        if facts:
            return facts[0]  # Return first key fact
        return ""
    
    def _determine_tone(self, messages: List[Dict]) -> str:
        """Determine the overall tone of conversation"""
        # Simple tone detection based on keywords
        all_text = " ".join([m["content"] for m in messages]).lower()
        
        if any(word in all_text for word in ['thank', 'thanks', 'appreciate']):
            return "appreciative"
        elif any(word in all_text for word in ['problem', 'issue', 'error', 'bug']):
            return "problem-solving"
        elif any(word in all_text for word in ['hello', 'hi', 'hey']):
            return "casual"
        else:
            return "neutral"