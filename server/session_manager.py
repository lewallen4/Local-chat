"""
session_manager.py — Handles memory read/write and prompt construction.

Memory file structure (memory.md):

  ## FACTS
  Persistent user/project facts you want the model to always know.
  Manually editable. Never auto-overwritten, only appended to.

  ## RECENT SESSIONS
  Rolling log of the last MAX_SESSIONS sessions, newest at top.
  Auto-managed — oldest entry trimmed when cap is exceeded.

This split means:
- FACTS section stays small and high-signal forever
- RECENT SESSIONS gives the model recent context without unbounded growth
- The model gets both injected at prompt time
"""

import json
import re
import os
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional
import hashlib


# Max recent sessions to keep in memory.md before trimming the oldest
MAX_SESSIONS = 10

# Max characters of memory injected into the prompt.
# Keeps small models from choking on huge context.
MAX_MEMORY_CHARS = 2000

MEMORY_TEMPLATE = """\
# Haven Memory

## FACTS
<!-- Add persistent facts here. This section is never auto-modified. -->
<!-- Examples:
- User's name is Skye
- Project: Haven — encrypted local chat + AI server
- Preferred stack: Python, FastAPI, llama.cpp
-->

## RECENT SESSIONS
<!-- Auto-managed. Do not edit manually below this line. -->
"""


class SessionManager:
    def __init__(self, memory_file: str):
        self.memory_file  = Path(memory_file)
        self.sessions_dir = Path("sessions")
        self.sessions_dir.mkdir(exist_ok=True)

        if not self.memory_file.exists():
            self.memory_file.parent.mkdir(parents=True, exist_ok=True)
            self.memory_file.write_text(MEMORY_TEMPLATE, encoding='utf-8')

    # ── Public API ────────────────────────────────────────────────────

    def load_memory(self) -> str:
        """Return full memory.md text."""
        try:
            return self.memory_file.read_text(encoding='utf-8')
        except Exception as e:
            print(f"Error loading memory: {e}")
            return ""

    def save_to_memory(self, summary: Dict, messages: List[Dict]) -> None:
        """
        Append a new session entry to the RECENT SESSIONS section,
        then trim to MAX_SESSIONS.
        """
        if not summary:
            return

        entry = self._format_entry(summary)
        self._insert_entry(entry)
        self._trim_old_entries()

    def _clean_memory_for_prompt(self, raw: str) -> str:
        """
        Strip everything that would confuse the model:
        - HTML comments <!-- ... -->  (these were making the model hallucinate
          a multi-user system by reading the template instructions)
        - Markdown headers (## FACTS, ## RECENT SESSIONS, # Haven Memory)
        - Excess blank lines
        Returns only actual content the model should know about.
        """
        # Remove HTML block comments (multiline)
        cleaned = re.sub(r'<!--.*?-->', '', raw, flags=re.DOTALL)
        # Remove markdown headers
        cleaned = re.sub(r'^#{1,3} .*$', '', cleaned, flags=re.MULTILINE)
        # Collapse 3+ blank lines down to one
        cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)
        return cleaned.strip()

    def prepare_context(self, messages: List[Dict], global_memory: str) -> Dict[str, Any]:
        """
        Build the prompt sent to the model.

        Memory is trimmed to MAX_MEMORY_CHARS so small models don't overflow.
        Only the last 12 messages are included in the conversation block.
        Role labels (USER/ASSISTANT) match the stop sequences in model_loader.py.
        """
        recent = messages[-12:]

        conversation_lines = []
        for msg in recent:
            role    = "USER" if msg["role"] == "user" else "ASSISTANT"
            content = msg["content"].strip()
            conversation_lines.append(f"{role}: {content}")

        conversation_block = "\n".join(conversation_lines)

        # Strip comments/headers, then trim to budget
        memory_block = ""
        if global_memory and global_memory.strip():
            cleaned = self._clean_memory_for_prompt(global_memory)
            if cleaned:
                if len(cleaned) > MAX_MEMORY_CHARS:
                    cleaned = "…(earlier memory trimmed)\n" + cleaned[-MAX_MEMORY_CHARS:]
                memory_block = f"CONTEXT FROM PREVIOUS SESSIONS:\n{cleaned}\n\n"

        prompt = (
            "You are a helpful AI assistant running locally on the user's machine.\n"
            "The CONVERSATION below is your complete shared context for this session.\n"
            "Read the full conversation before responding.\n"
            "If asked to recall something mentioned earlier, find it in the conversation above and repeat it exactly.\n"
            "Answer directly and concisely, then stop. Do not write fake user messages.\n\n"
            f"{memory_block}"
            "CONVERSATION:\n"
            f"{conversation_block}\n"
            "ASSISTANT:"
        )

        return {
            "prompt":        prompt,
            "memory_used":   bool(global_memory),
            "message_count": len(messages),
        }

    def save_session_log(self, session_id: str, session_data: Dict) -> None:
        """Save full session transcript as JSON (separate from memory.md)."""
        log_file  = self.sessions_dir / f"session_{session_id}.json"
        save_data = {
            "session_id":    session_id,
            "created_at":    _iso(session_data.get("created_at")),
            "ended_at":      datetime.now().isoformat(),
            "message_count": len(session_data.get("messages", [])),
            "messages":      session_data.get("messages", []),
            "metadata":      session_data.get("metadata", {}),
        }
        with open(log_file, 'w', encoding='utf-8') as f:
            json.dump(save_data, f, indent=2, ensure_ascii=False)

    def load_session_log(self, session_id: str) -> Optional[Dict]:
        log_file = self.sessions_dir / f"session_{session_id}.json"
        if log_file.exists():
            with open(log_file, 'r', encoding='utf-8') as f:
                return json.load(f)
        return None

    def get_session_hash(self, messages: List[Dict]) -> str:
        content = "".join([f"{m['role']}:{m['content']}" for m in messages])
        return hashlib.md5(content.encode()).hexdigest()[:8]

    # ── Memory formatting ─────────────────────────────────────────────

    def _format_entry(self, summary: Dict) -> str:
        """Turn a summary dict into a compact, readable memory entry."""
        ts    = summary.get("timestamp", datetime.now().strftime("%Y-%m-%d %H:%M"))
        count = summary.get("message_count", 0)

        lines = [f"### {ts}  ({count} messages)"]

        topics = summary.get("topics", [])
        if topics:
            lines.append("**Topics:** " + " · ".join(topics[:4]))

        user_facts = summary.get("user_facts", [])
        if user_facts:
            lines.append("**User said:**")
            for f in user_facts[:4]:
                lines.append(f"  - {f}")

        decisions = summary.get("decisions", [])
        if decisions:
            lines.append("**Decisions/plans:**")
            for d in decisions[:3]:
                lines.append(f"  - {d}")

        tech = summary.get("tech_stack", [])
        if tech:
            lines.append("**Tech:** " + ", ".join(tech[:8]))

        lines.append("")  # trailing blank line
        return "\n".join(lines)

    def _insert_entry(self, entry: str) -> None:
        """Insert a new entry immediately after the RECENT SESSIONS header."""
        text   = self.memory_file.read_text(encoding='utf-8')
        marker = "## RECENT SESSIONS"

        if marker in text:
            # Find the end of the marker line and the comment block below it
            idx = text.index(marker) + len(marker)
            # Skip past any comment lines right after the marker
            rest = text[idx:]
            comment_end = 0
            for line in rest.split('\n'):
                stripped = line.strip()
                if stripped.startswith('<!--') or stripped.endswith('-->') or stripped == '':
                    comment_end += len(line) + 1
                else:
                    break
            insert_at = idx + comment_end
            text = text[:insert_at] + "\n" + entry + text[insert_at:]
        else:
            # Fallback: just append
            text = text + "\n" + entry

        self.memory_file.write_text(text, encoding='utf-8')

    def _trim_old_entries(self) -> None:
        """Keep only the most recent MAX_SESSIONS entries in RECENT SESSIONS."""
        text   = self.memory_file.read_text(encoding='utf-8')
        marker = "## RECENT SESSIONS"

        if marker not in text:
            return

        split_idx    = text.index(marker)
        header_part  = text[:split_idx + len(marker)]
        sessions_part = text[split_idx + len(marker):]

        # Each entry starts with "### "
        entries = re.split(r'(?=^### )', sessions_part, flags=re.MULTILINE)

        # First element may be the comment block — preserve it
        preamble = ""
        real_entries = []
        for e in entries:
            if e.strip().startswith('###'):
                real_entries.append(e)
            else:
                preamble += e

        if len(real_entries) > MAX_SESSIONS:
            real_entries = real_entries[:MAX_SESSIONS]  # newest first

        trimmed = header_part + preamble + "".join(real_entries)
        self.memory_file.write_text(trimmed, encoding='utf-8')


# ── Helpers ───────────────────────────────────────────────────────────

def _iso(value) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, str):
        return value
    return datetime.now().isoformat()
