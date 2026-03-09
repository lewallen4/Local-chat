"""
summarizer.py — Uses the model to write a compact summary of each session.

The summary is written into memory.md under RECENT SESSIONS so the model
has useful context about past conversations on startup.

If the model call fails for any reason (model not loaded, timeout, etc.)
the fallback is a minimal entry with just the message count and timestamp
so memory.md always gets something written.
"""

from typing import List, Dict
from datetime import datetime


# ── Summary prompt ──────────────────────────────────────────────────
# Kept very short and directive so even TinyLlama produces clean output.
# The model is asked for plain bullet points — no headers, no prose,
# easy to inject into future prompts without confusing the model.

SUMMARY_PROMPT_TEMPLATE = """\
You are a note-taking assistant. Read this conversation and write a short memory note.

Rules:
- Maximum 6 bullet points total
- Each bullet starts with "- "
- Only include facts, decisions, or topics that would be useful to remember later
- Do not summarize the AI's responses, only what the USER said or decided
- Do not add headers, titles, or any formatting other than "- " bullets
- If there is nothing worth remembering, write only: - (no notable facts)

CONVERSATION:
{conversation}

MEMORY NOTE:"""


class SessionSummarizer:
    def __init__(self):
        # model_loader is injected after init to avoid circular imports
        self._model = None

    def set_model(self, model_loader) -> None:
        """Called by app.py after both objects are created."""
        self._model = model_loader

    async def summarize_session(
        self,
        messages: List[Dict],
        existing_memory: str = ""
    ) -> Dict:
        """
        Returns a summary dict consumed by session_manager.save_to_memory().
        {
            "bullets":       str,   # the model's bullet-point summary
            "message_count": int,
            "timestamp":     str,
        }
        Falls back gracefully if model is unavailable.
        """
        if not messages:
            return {}

        timestamp     = datetime.now().strftime("%Y-%m-%d %H:%M")
        message_count = len(messages)

        bullets = self._model_summary(messages)

        return {
            "bullets":       bullets,
            "message_count": message_count,
            "timestamp":     timestamp,
        }

    # ── Internal ──────────────────────────────────────────────────────

    def _model_summary(self, messages: List[Dict]) -> str:
        """
        Ask the model to summarize the session.
        Returns a string of "- bullet" lines, or a fallback if unavailable.
        """
        if self._model is None:
            return "- (summary unavailable — model not set)"

        # Build a compact transcript for the prompt.
        # We only send user messages — the model's own replies aren't
        # useful to remember and waste context tokens.
        user_lines = []
        for m in messages:
            if m["role"] == "user":
                # Truncate very long messages to keep the prompt manageable
                content = m["content"].strip()
                if len(content) > 300:
                    content = content[:300] + "…"
                user_lines.append(f"User: {content}")

        if not user_lines:
            return "- (no user messages to summarize)"

        # Cap at last 20 user messages so the prompt stays under context limit
        transcript = "\n".join(user_lines[-20:])
        prompt     = SUMMARY_PROMPT_TEMPLATE.format(conversation=transcript)

        try:
            raw = self._model.generate_simple(prompt, max_tokens=200)
        except Exception as e:
            print(f"Summarizer model call failed: {e}")
            return f"- (summary failed: {e})"

        if not raw:
            return "- (model returned empty summary)"

        # Clean up the output — ensure every line starts with "- "
        cleaned_lines = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            if not line.startswith("- "):
                line = "- " + line.lstrip("-• ").strip()
            cleaned_lines.append(line)

        if not cleaned_lines:
            return "- (no summary produced)"

        return "\n".join(cleaned_lines[:6])  # hard cap at 6 bullets
