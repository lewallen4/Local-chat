"""
session_manager.py — Handles memory read/write and prompt construction.

User workspace layout:

  server/users/<user_id>/
    memory.md          — per-user memory (cloned from models/default_memory.md on first login)
    sessions/          — per-user session JSON logs

Memory file structure (memory.md):

  ## FACTS
  Persistent user/project facts. Manually editable. Never auto-overwritten.

  ## RECENT SESSIONS
  Rolling log of the last MAX_SESSIONS sessions, newest at top.
  Auto-managed — oldest entry trimmed when cap exceeded.
"""

import json
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional
import hashlib


MAX_SESSIONS = 10

SYSTEM_PROMPT_PATH = Path("models/system_prompt.txt")
DEFAULT_MEMORY_PATH = Path("models/default_memory.md")
USERS_DIR = Path("users")

SYSTEM_PROMPT_FALLBACK = (
    "You are a helpful AI assistant running locally on the user's machine.\n"
    "The CONVERSATION below is your complete shared context for this session.\n"
    "Read the full conversation before responding.\n"
    "If asked to recall something mentioned earlier, find it in the conversation above and repeat it exactly.\n"
    "Answer directly and concisely, then stop. Do not write fake user messages or invent follow-up questions."
)

MAX_MEMORY_CHARS = 2000

DEFAULT_MEMORY_TEMPLATE = """\
# Local-chat Memory

## FACTS
- User ID: {user_id}

## RECENT SESSIONS
<!-- Auto-managed. Newest entries appear first. Capped at 10 sessions. -->
"""


def load_system_prompt() -> str:
    try:
        if SYSTEM_PROMPT_PATH.exists():
            content = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()
            if content:
                return content
    except Exception as e:
        print(f"Could not load system prompt: {e}")
    return SYSTEM_PROMPT_FALLBACK


def get_user_dir(user_id: str) -> Path:
    """Return the workspace directory for a given user ID."""
    return USERS_DIR / user_id


def provision_user(user_id: str) -> Path:
    """
    Create the user's workspace if it doesn't exist yet.
    Clones the default memory file, stamping in the user's ID.
    Returns the user directory path.
    """
    user_dir = get_user_dir(user_id)
    sessions_dir = user_dir / "sessions"
    memory_file = user_dir / "memory.md"

    user_dir.mkdir(parents=True, exist_ok=True)
    sessions_dir.mkdir(exist_ok=True)

    if not memory_file.exists():
        if DEFAULT_MEMORY_PATH.exists():
            # Clone the default and inject user ID into FACTS
            base = DEFAULT_MEMORY_PATH.read_text(encoding="utf-8")
            # Replace the placeholder name if present, otherwise append
            if "{user_id}" in base:
                stamped = base.replace("{user_id}", user_id)
            else:
                stamped = base
            memory_file.write_text(stamped, encoding="utf-8")
        else:
            # Fallback: generate from template
            memory_file.write_text(
                DEFAULT_MEMORY_TEMPLATE.format(user_id=user_id), encoding="utf-8"
            )
        print(f"  ✓ Provisioned new workspace for user: {user_id}")
    else:
        print(f"  ↩ Returning user: {user_id}")

    return user_dir


def is_returning_user(user_id: str) -> bool:
    """Return True if this user already has a workspace."""
    return (get_user_dir(user_id) / "memory.md").exists()


class SessionManager:
    def __init__(self, user_id: str):
        self.user_id = user_id
        user_dir = provision_user(user_id)
        self.memory_file = user_dir / "memory.md"
        self.sessions_dir = user_dir / "sessions"
        self.sessions_dir.mkdir(exist_ok=True)

    # ── Public API ────────────────────────────────────────────────────

    def load_memory(self) -> str:
        try:
            return self.memory_file.read_text(encoding="utf-8")
        except Exception as e:
            print(f"Error loading memory for {self.user_id}: {e}")
            return ""

    def save_to_memory(self, summary: Dict, messages: List[Dict]) -> None:
        if not summary:
            return
        entry = self._format_entry(summary)
        self._insert_entry(entry)
        self._trim_old_entries()

    def _clean_memory_for_prompt(self, raw: str) -> str:
        cleaned = re.sub(r"<!--.*?-->", "", raw, flags=re.DOTALL)
        cleaned = re.sub(r"^#{1,3} .*$", "", cleaned, flags=re.MULTILINE)
        cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
        return cleaned.strip()

    def prepare_context(self, messages: List[Dict], global_memory: str) -> Dict[str, Any]:
        recent = messages[-12:]

        conversation_lines = []
        for msg in recent:
            role = "USER" if msg["role"] == "user" else "ASSISTANT"
            content = msg["content"].strip()
            conversation_lines.append(f"{role}: {content}")

        conversation_block = "\n".join(conversation_lines)

        memory_block = ""
        if global_memory and global_memory.strip():
            cleaned = self._clean_memory_for_prompt(global_memory)
            if cleaned:
                if len(cleaned) > MAX_MEMORY_CHARS:
                    cleaned = "…(earlier memory trimmed)\n" + cleaned[-MAX_MEMORY_CHARS:]
                memory_block = f"CONTEXT FROM PREVIOUS SESSIONS:\n{cleaned}\n\n"

        system_prompt = load_system_prompt()

        prompt = (
            f"{system_prompt}\n\n"
            f"{memory_block}"
            "CONVERSATION:\n"
            f"{conversation_block}\n"
            "ASSISTANT:"
        )

        return {
            "prompt": prompt,
            "memory_used": bool(global_memory),
            "message_count": len(messages),
        }

    def save_session_log(self, session_id: str, session_data: Dict) -> None:
        log_file = self.sessions_dir / f"session_{session_id}.json"
        save_data = {
            "session_id": session_id,
            "user_id": self.user_id,
            "created_at": _iso(session_data.get("created_at")),
            "ended_at": datetime.now().isoformat(),
            "message_count": len(session_data.get("messages", [])),
            "messages": session_data.get("messages", []),
            "metadata": session_data.get("metadata", {}),
        }
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump(save_data, f, indent=2, ensure_ascii=False)

    def load_session_log(self, session_id: str) -> Optional[Dict]:
        log_file = self.sessions_dir / f"session_{session_id}.json"
        if log_file.exists():
            with open(log_file, "r", encoding="utf-8") as f:
                return json.load(f)
        return None

    def list_sessions(self) -> List[Dict]:
        """Return a summary list of all saved sessions for this user, newest first."""
        logs = sorted(self.sessions_dir.glob("session_*.json"), reverse=True)
        result = []
        for log in logs[:20]:  # cap at 20 for the sidebar
            try:
                with open(log, "r", encoding="utf-8") as f:
                    data = json.load(f)
                result.append({
                    "session_id": data.get("session_id", ""),
                    "created_at": data.get("created_at", ""),
                    "ended_at": data.get("ended_at", ""),
                    "message_count": data.get("message_count", 0),
                    "preview": _session_preview(data.get("messages", [])),
                })
            except Exception:
                pass
        return result

    def get_session_hash(self, messages: List[Dict]) -> str:
        content = "".join([f"{m['role']}:{m['content']}" for m in messages])
        return hashlib.md5(content.encode()).hexdigest()[:8]

    # ── Memory formatting ─────────────────────────────────────────────

    def _format_entry(self, summary: Dict) -> str:
        ts = summary.get("timestamp", datetime.now().strftime("%Y-%m-%d %H:%M"))
        count = summary.get("message_count", 0)
        bullets = summary.get("bullets", "- (no summary)")
        lines = [f"### {ts}  ({count} messages)", bullets, ""]
        return "\n".join(lines)

    def _insert_entry(self, entry: str) -> None:
        text = self.memory_file.read_text(encoding="utf-8")
        marker = "## RECENT SESSIONS"

        if marker in text:
            idx = text.index(marker) + len(marker)
            rest = text[idx:]
            comment_end = 0
            for line in rest.split("\n"):
                stripped = line.strip()
                if stripped.startswith("<!--") or stripped.endswith("-->") or stripped == "":
                    comment_end += len(line) + 1
                else:
                    break
            insert_at = idx + comment_end
            text = text[:insert_at] + "\n" + entry + text[insert_at:]
        else:
            text = text + "\n" + entry

        self.memory_file.write_text(text, encoding="utf-8")

    def _trim_old_entries(self) -> None:
        text = self.memory_file.read_text(encoding="utf-8")
        marker = "## RECENT SESSIONS"

        if marker not in text:
            return

        split_idx = text.index(marker)
        header_part = text[: split_idx + len(marker)]
        sessions_part = text[split_idx + len(marker):]

        entries = re.split(r"(?=^### )", sessions_part, flags=re.MULTILINE)

        preamble = ""
        real_entries = []
        for e in entries:
            if e.strip().startswith("###"):
                real_entries.append(e)
            else:
                preamble += e

        if len(real_entries) > MAX_SESSIONS:
            real_entries = real_entries[:MAX_SESSIONS]

        trimmed = header_part + preamble + "".join(real_entries)
        self.memory_file.write_text(trimmed, encoding="utf-8")


# ── Helpers ───────────────────────────────────────────────────────────

def _iso(value) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, str):
        return value
    return datetime.now().isoformat()


def _session_preview(messages: List[Dict]) -> str:
    """First user message, truncated, as a display title."""
    for m in messages:
        if m.get("role") == "user":
            text = m.get("content", "").strip()
            return text[:40] + "…" if len(text) > 40 else text
    return "Session"
