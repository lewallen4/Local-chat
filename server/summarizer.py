"""
summarizer.py — Extracts structured, useful facts from a session.

Design goals:
- No model calls (fast, no extra tokens burned)
- Output is a compact structured dict, not a prose blob
- Focuses on what's actually useful to recall: user facts, decisions,
  topics, named entities — not generic filler like "the tone was neutral"
"""

import re
from typing import List, Dict, Tuple
from datetime import datetime


# ── Patterns we care about ──────────────────────────────────────────

# Things the user stated about themselves
USER_FACT_PATTERNS = [
    r"\bmy name is\b",
    r"\bi('m| am)\b",
    r"\bi work\b",
    r"\bi use\b",
    r"\bi prefer\b",
    r"\bi like\b",
    r"\bi have\b",
    r"\bi want\b",
    r"\bi need\b",
    r"\bwe('re| are)\b",
    r"\bmy (project|app|system|server|setup|repo|code|file)\b",
]

# Action/decision signals
DECISION_PATTERNS = [
    r"\blet'?s\b",
    r"\bwe('ll| will)\b",
    r"\bi('ll| will)\b",
    r"\bdecided\b",
    r"\bgoing to\b",
    r"\bplan to\b",
    r"\bneed to\b",
    r"\bshould\b",
]

# Technical named entities (crude but effective without NLP)
TECH_PATTERN = re.compile(
    r'\b(python|fastapi|flask|uvicorn|llama|gguf|ollama|docker|nginx|'
    r'git|github|postgres|sqlite|redis|react|javascript|typescript|'
    r'linux|ubuntu|windows|mac|ssh|ngrok|aws|gcp|azure|api|json|'
    r'haven|model|server|endpoint|route|session|memory)\b',
    re.IGNORECASE
)


class SessionSummarizer:
    def __init__(self):
        pass

    async def summarize_session(
        self,
        messages: List[Dict],
        existing_memory: str = ""
    ) -> Dict:
        """
        Returns a structured summary dict:
        {
            "user_facts":   [...],   # things user said about themselves/their setup
            "decisions":    [...],   # action items or conclusions reached
            "topics":       [...],   # main subjects discussed
            "tech_stack":   [...],   # technologies mentioned
            "message_count": int,
            "timestamp":    str,
        }
        """
        if not messages:
            return {}

        user_msgs      = [m for m in messages if m["role"] == "user"]
        assistant_msgs = [m for m in messages if m["role"] == "assistant"]

        user_facts  = self._extract_user_facts(user_msgs)
        decisions   = self._extract_decisions(user_msgs + assistant_msgs)
        topics      = self._extract_topics(user_msgs)
        tech_stack  = self._extract_tech(messages)

        return {
            "user_facts":    user_facts,
            "decisions":     decisions,
            "topics":        topics,
            "tech_stack":    sorted(tech_stack),
            "message_count": len(messages),
            "timestamp":     datetime.now().strftime("%Y-%m-%d %H:%M"),
        }

    # ── Extractors ────────────────────────────────────────────────────

    def _extract_user_facts(self, user_msgs: List[Dict]) -> List[str]:
        """Sentences where the user stated something about themselves."""
        facts = []
        for msg in user_msgs:
            sentences = self._split_sentences(msg["content"])
            for s in sentences:
                sl = s.lower()
                if any(re.search(p, sl) for p in USER_FACT_PATTERNS):
                    cleaned = s.strip()
                    if 10 < len(cleaned) < 200:
                        facts.append(cleaned)
        # Deduplicate while preserving order
        return list(dict.fromkeys(facts))[:8]

    def _extract_decisions(self, messages: List[Dict]) -> List[str]:
        """Sentences expressing a decision, plan, or action item."""
        decisions = []
        for msg in messages:
            sentences = self._split_sentences(msg["content"])
            for s in sentences:
                sl = s.lower()
                if any(re.search(p, sl) for p in DECISION_PATTERNS):
                    cleaned = s.strip()
                    if 10 < len(cleaned) < 200:
                        decisions.append(cleaned)
        return list(dict.fromkeys(decisions))[:6]

    def _extract_topics(self, user_msgs: List[Dict]) -> List[str]:
        """
        Core subject of each user message — the first meaningful noun phrase
        or question, kept short so the memory stays scannable.
        """
        topics = []
        for msg in user_msgs:
            text = msg["content"].strip()
            # Take first sentence only
            first = re.split(r'[.!?\n]', text)[0].strip()
            if len(first) > 120:
                first = first[:120] + "…"
            if first:
                topics.append(first)
        return list(dict.fromkeys(topics))[:6]

    def _extract_tech(self, messages: List[Dict]) -> set:
        """All technology names mentioned across the whole conversation."""
        all_text = " ".join(m["content"] for m in messages)
        return {m.lower() for m in TECH_PATTERN.findall(all_text)}

    # ── Helpers ───────────────────────────────────────────────────────

    def _split_sentences(self, text: str) -> List[str]:
        return [s for s in re.split(r'(?<=[.!?])\s+', text) if s.strip()]
