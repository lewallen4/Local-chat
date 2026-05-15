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
import re


def _strip_think_blocks_for_summary(text: str) -> str:
    """
    Strip reasoning/thinking traces from assistant turns before summarizing.
    Reasoning is internal to the model and shouldn't appear in session
    summaries — it's also a common source of role-confusion since it can
    contain phrases like "the user wants..." that the summarizer mistakes
    for actual user statements.
    """
    text = re.sub(r"<\|channel>thought[\s\S]*?<channel\|>", "", text)
    text = re.sub(r"<thought>[\s\S]*?</thought>", "", text)
    text = re.sub(r"<think>[\s\S]*?</think>", "", text)
    text = re.sub(r"</?(thought|think)>", "", text)
    return text.strip()


# ── Summary prompt ──────────────────────────────────────────────────
# Directive: 1–3 sentences of prose. No bullets, no headers.
# Short enough to reinject into future system prompts without bloat.

SUMMARY_PROMPT_TEMPLATE = """\
Below is a transcript of a chat session between a USER (a human) and the AI ASSISTANT.
Each line is clearly labeled with who said it.

Write a 1-3 sentence summary of the session. Capture only the key facts,
decisions, or requests. Be careful to attribute statements correctly:
the USER asked the questions and made the requests; the AI ASSISTANT
gave the answers and explanations. Do not flip these.

Do NOT use bullet points. Write plain prose sentences only.
If nothing notable happened, write: No notable content.

---
{conversation}
---

Summary: """


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
            "summary":       str,   # 1–3 sentence prose summary
            "message_count": int,
            "timestamp":     str,
        }
        Falls back gracefully if model is unavailable.
        """
        if not messages:
            return {}

        timestamp     = datetime.now().strftime("%Y-%m-%d %H:%M")
        message_count = len(messages)

        summary = self._model_summary(messages)

        return {
            "summary":       summary,
            "message_count": message_count,
            "timestamp":     timestamp,
        }

    # ── Internal ──────────────────────────────────────────────────────

    def _model_summary(self, messages: List[Dict]) -> str:
        """
        Ask the model to summarize the session.
        Returns 1–3 sentences of prose. Always produces at least one
        meaningful sentence even if the model call fails.
        """
        # Build the content-based fallback first so every path can use it
        fallback = self._fallback_summary(messages)

        if self._model is None:
            return fallback

        # Build a compact transcript using clear, unambiguous labels.
        # Earlier versions used "Person:" / "AI:" which the model sometimes
        # confused, attributing assistant statements to the user. The
        # all-caps role names plus brackets are visually distinct enough
        # that the model gets attribution right.
        user_lines = []
        for m in messages:
            role_label = "[USER]" if m["role"] == "user" else "[AI ASSISTANT]"
            content = m["content"].strip()
            # Strip thinking blocks from assistant turns so they don't
            # leak into the summary or confuse role attribution.
            if m["role"] != "user":
                content = _strip_think_blocks_for_summary(content)
            if len(content) > 300:
                content = content[:300] + "…"
            user_lines.append(f"{role_label} {content}")

        if not user_lines:
            return fallback

        # Cap at last 20 messages so the prompt stays under context limit
        transcript = "\n".join(user_lines[-20:])
        prompt     = SUMMARY_PROMPT_TEMPLATE.format(conversation=transcript)

        try:
            raw = self._model.generate_summary(prompt, max_tokens=150)
        except Exception as e:
            print(f"Summarizer model call failed: {e}")
            return fallback

        if not raw or not raw.strip():
            return fallback

        # Clean: collapse to at most 3 sentences
        raw = raw.strip()
        # Remove any bullets the model snuck in
        lines = raw.splitlines()
        cleaned = " ".join(
            line.lstrip("-•* ").strip()
            for line in lines
            if line.strip()
        )

        # Split on sentence boundaries, keep first 3
        sentences = re.split(r'(?<=[.!?])\s+', cleaned)
        sentences = [s.strip() for s in sentences if s.strip()]
        if not sentences:
            return fallback

        result = " ".join(sentences[:3])
        # Ensure it ends with punctuation
        if result and result[-1] not in ".!?":
            result += "."

        return result

    def _fallback_summary(self, messages: List[Dict]) -> str:
        """
        Build a concrete one-sentence summary from the first user message.
        Guarantees every session has a real description, not a placeholder.
        """
        first_user_msg = ""
        for m in messages:
            if m.get("role") == "user":
                first_user_msg = m["content"].strip()
                break

        count = len(messages)

        if first_user_msg:
            preview = first_user_msg[:120]
            if len(first_user_msg) > 120:
                preview += "…"
            return f"Session with {count} messages, starting with: {preview}"

        return f"Session with {count} messages."
