"""
logger.py — Size-rotated file logger.

Logs model I/O, session events, knowledge queries, and errors
to server/logs/skye-ai.log. When the active log exceeds
MAX_BYTES, it's renamed to skye-ai.log.1 (replacing any prior
.1) and a fresh skye-ai.log is started.

This is dramatically faster than the previous read-rewrite
approach: rotation is a single rename() syscall instead of
reading and rewriting the entire file on every chat turn.

Usage:
    from logger import log
    log("SESSION", "start sid=abc123 user=skyee")
    log("PROMPT", full_prompt_text)
    log("RESPONSE", response_text)
    log("ERROR", "something broke")
"""

from pathlib import Path
from datetime import datetime
import os
import threading

LOG_DIR = Path("logs")
LOG_FILE = LOG_DIR / "skye-ai.log"
LOG_FILE_PREV = LOG_DIR / "skye-ai.log.1"

# Roll once the active log gets above ~5 MB. With prompts averaging
# 8KB and a couple of log entries per chat turn, this is roughly
# 300 turns of headroom — plenty for live debugging without ever
# blocking a request on a multi-megabyte rewrite.
MAX_BYTES = 5 * 1024 * 1024

_lock = threading.Lock()


def _ensure_dir():
    LOG_DIR.mkdir(exist_ok=True)


def log(category: str, message: str) -> None:
    """
    Append a timestamped log entry. Thread-safe.
    Category should be one of: SESSION, PROMPT, RESPONSE, SUMMARY,
    KNOWLEDGE, SETTINGS, ERROR, WARN, INFO
    """
    _ensure_dir()
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    cat = category.upper().ljust(10)

    # Format multi-line messages with continuation indent
    lines = message.rstrip().split("\n")
    formatted = f"[{timestamp}] {cat}| {lines[0]}\n"
    for continuation in lines[1:]:
        formatted += f"[{timestamp}] {cat}| {continuation}\n"

    with _lock:
        try:
            # Rotate before write if the active file is too big.
            _rotate_if_needed()
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(formatted)
        except Exception as e:
            # Don't crash the app if logging fails
            print(f"Log write error: {e}")


def _rotate_if_needed():
    """
    Rename active log to .1 if it has exceeded MAX_BYTES.
    Single rename() is O(1) on the filesystem — no read or rewrite.
    """
    try:
        if not LOG_FILE.exists():
            return
        if LOG_FILE.stat().st_size <= MAX_BYTES:
            return
        # Replace any prior backup atomically
        if LOG_FILE_PREV.exists():
            LOG_FILE_PREV.unlink()
        os.rename(LOG_FILE, LOG_FILE_PREV)
    except Exception:
        pass


def log_prompt(arch: str, prompt: str, memory_used: bool, knowledge_used: bool, temperature: float) -> None:
    """Log a full prompt with metadata header."""
    char_count = len(prompt)
    meta = f"arch={arch} chars={char_count} memory={'yes' if memory_used else 'no'} knowledge={'yes' if knowledge_used else 'no'} temp={temperature}"
    log("PROMPT", f"{meta}\n{'─' * 60}\n{prompt}\n{'─' * 60}")


def log_response(response: str, duration_ms: int = 0) -> None:
    """Log a model response with stats."""
    char_count = len(response)
    duration_str = f" {duration_ms}ms" if duration_ms else ""
    log("RESPONSE", f"{char_count} chars{duration_str}\n{'─' * 60}\n{response}\n{'─' * 60}")


def log_session(event: str, session_id: str, user_id: str = "", extra: str = "") -> None:
    """Log a session lifecycle event."""
    sid_short = session_id[:8] if session_id else "—"
    parts = [f"{event} sid={sid_short}"]
    if user_id:
        parts.append(f"user={user_id}")
    if extra:
        parts.append(extra)
    log("SESSION", " ".join(parts))


def log_knowledge(query: str, results_count: int, top_score: float = 0) -> None:
    """Log a knowledge base search."""
    log("KNOWLEDGE", f"query=\"{query[:100]}\" results={results_count} top_score={top_score:.3f}")


def log_summary(session_id: str, summary: str) -> None:
    """Log a session summary."""
    sid_short = session_id[:8] if session_id else "—"
    log("SUMMARY", f"sid={sid_short} → {summary}")


def log_error(context: str, error: Exception) -> None:
    """Log an error with context."""
    log("ERROR", f"[{context}] {type(error).__name__}: {error}")
