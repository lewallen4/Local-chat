"""
tts_engine.py — Offline TTS (Kokoro) + STT (Whisper) engine.

Kokoro:  pip install kokoro soundfile
Whisper: pip install openai-whisper

Both are fully local — no cloud API calls.

Voice: af_heart (default)
STT model: base (good accuracy/speed tradeoff on CPU)
"""

import io
import re
import os
import threading
from pathlib import Path
from typing import Optional

# ── Optional imports — graceful degradation if not installed ────────

try:
    from kokoro import KPipeline
    HAS_KOKORO = True
except ImportError:
    HAS_KOKORO = False
    print("⚠  kokoro not installed — TTS disabled. Run: pip install kokoro soundfile")

try:
    import soundfile as sf
    HAS_SOUNDFILE = True
except ImportError:
    HAS_SOUNDFILE = False

try:
    import whisper as _whisper
    HAS_WHISPER = True
except ImportError:
    HAS_WHISPER = False
    print("⚠  openai-whisper not installed — STT disabled. Run: pip install openai-whisper")

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


# ── Config ──────────────────────────────────────────────────────────

DEFAULT_VOICE   = "af_heart"
WHISPER_MODEL   = "base"
SAMPLE_RATE     = 24000   # Kokoro native sample rate

# Code block summarisation map — language tag → spoken label
_CODE_LANG_MAP = {
    "python":     "a Python snippet",
    "py":         "a Python snippet",
    "javascript": "a JavaScript snippet",
    "js":         "a JavaScript snippet",
    "typescript": "a TypeScript snippet",
    "ts":         "a TypeScript snippet",
    "html":       "an HTML snippet",
    "css":        "a CSS snippet",
    "bash":       "a shell command",
    "sh":         "a shell command",
    "shell":      "a shell command",
    "sql":        "a SQL snippet",
    "json":       "a JSON snippet",
    "yaml":       "a YAML snippet",
    "yml":        "a YAML snippet",
    "toml":       "a TOML snippet",
    "rust":       "a Rust snippet",
    "go":         "a Go snippet",
    "c":          "a C snippet",
    "cpp":        "a C++ snippet",
    "java":       "a Java snippet",
    "ruby":       "a Ruby snippet",
    "php":        "a PHP snippet",
    "swift":      "a Swift snippet",
    "kotlin":     "a Kotlin snippet",
    "dockerfile": "a Dockerfile",
    "xml":        "an XML snippet",
}


# ── Text preprocessing for TTS ──────────────────────────────────────

def preprocess_for_tts(text: str) -> str:
    """
    Transform raw markdown/model output into speakable prose.

    - Fenced code blocks → "Here's <lang> snippet"
    - Inline code (long) → "some code"
    - Headers → plain text
    - Bold/italic markers → stripped
    - Think blocks → omitted entirely
    - URLs → "a link"
    - Bullet/numbered lists → natural sentences
    """

    # Strip thinking blocks entirely
    text = re.sub(r"<\|channel>thought[\s\S]*?<channel\|>", "", text)
    text = re.sub(r"<thought>[\s\S]*?</thought>", "", text)
    text = re.sub(r"<think>[\s\S]*?</think>", "", text)
    text = re.sub(r"</?(thought|think)>", "", text)

    # Fenced code blocks — replace with spoken label
    def replace_fence(m):
        lang = (m.group(1) or "").strip().lower()
        label = _CODE_LANG_MAP.get(lang, "a code snippet")
        return f"Here's {label}."

    text = re.sub(r"```(\w*)\n[\s\S]*?```", replace_fence, text)
    text = re.sub(r"```[\s\S]*?```", "Here's a code snippet.", text)

    # Inline code — keep short ones, replace long ones
    def replace_inline(m):
        inner = m.group(1)
        if len(inner) <= 20:
            return inner
        return "some code"

    text = re.sub(r"`([^`]+)`", replace_inline, text)

    # URLs
    text = re.sub(r"https?://\S+", "a link", text)

    # Markdown headers → plain
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)

    # Bold / italic
    text = re.sub(r"\*\*\*(.+?)\*\*\*", r"\1", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\*(.+?)\*", r"\1", text)
    text = re.sub(r"__(.+?)__", r"\1", text)
    text = re.sub(r"_(.+?)_", r"\1", text)

    # Bullet lists → comma-separated or natural flow
    text = re.sub(r"^\s*[-*•]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*\d+\.\s+", "", text, flags=re.MULTILINE)

    # Horizontal rules
    text = re.sub(r"^[-*_]{3,}$", "", text, flags=re.MULTILINE)

    # Collapse whitespace
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.strip()

    return text


# ── TTS Engine ───────────────────────────────────────────────────────

class TTSEngine:
    """
    Wraps Kokoro for offline text-to-speech.
    Thread-safe — uses a lock since Kokoro pipelines aren't reentrant.
    """

    def __init__(self, voice: str = DEFAULT_VOICE):
        self._voice   = voice
        self._pipeline: Optional[object] = None
        self._lock    = threading.Lock()
        self._ready   = False
        self._load()

    def _load(self):
        if not HAS_KOKORO or not HAS_SOUNDFILE:
            print("  ✗ TTS engine not available (missing kokoro/soundfile)")
            return
        try:
            # lang_code 'a' = American English
            self._pipeline = KPipeline(lang_code="a")
            self._ready = True
            print(f"  ✓ TTS engine ready (Kokoro, voice={self._voice})")
        except Exception as e:
            print(f"  ✗ TTS engine failed to load: {e}")

    @property
    def ready(self) -> bool:
        return self._ready

    def synthesize(self, text: str) -> Optional[bytes]:
        """
        Convert text to WAV bytes. Returns None on failure.
        Preprocessing strips markdown/code before synthesis.
        """
        if not self._ready or not self._pipeline:
            return None

        clean = preprocess_for_tts(text)
        if not clean.strip():
            return None

        with self._lock:
            try:
                audio_chunks = []
                generator = self._pipeline(clean, voice=self._voice)
                for _, _, audio in generator:
                    if audio is not None:
                        if HAS_NUMPY:
                            audio_chunks.append(audio)
                        else:
                            audio_chunks.append(audio)

                if not audio_chunks:
                    return None

                # Concatenate all chunks
                if HAS_NUMPY:
                    full_audio = np.concatenate(audio_chunks)
                else:
                    full_audio = audio_chunks[0]

                # Write to WAV in memory
                buf = io.BytesIO()
                sf.write(buf, full_audio, SAMPLE_RATE, format="WAV")
                buf.seek(0)
                return buf.read()

            except Exception as e:
                print(f"TTS synthesis error: {e}")
                return None


# ── STT Engine ───────────────────────────────────────────────────────

class STTEngine:
    """
    Wraps OpenAI Whisper for offline speech-to-text.
    Loaded once at startup, thread-safe for inference.
    """

    def __init__(self, model_name: str = WHISPER_MODEL):
        self._model     = None
        self._lock      = threading.Lock()
        self._ready     = False
        self._model_name = model_name
        self._load()

    def _load(self):
        if not HAS_WHISPER:
            print("  ✗ STT engine not available (missing openai-whisper)")
            return
        try:
            print(f"  → Loading Whisper '{self._model_name}' model...")
            self._model = _whisper.load_model(self._model_name)
            self._ready = True
            print(f"  ✓ STT engine ready (Whisper {self._model_name})")
        except Exception as e:
            print(f"  ✗ STT engine failed to load: {e}")

    @property
    def ready(self) -> bool:
        return self._ready

    def transcribe(self, audio_bytes: bytes, mime_type: str = "audio/webm") -> Optional[str]:
        """
        Transcribe audio bytes to text.
        Accepts raw bytes from MediaRecorder (webm/opus typically).
        Returns transcribed string or None on failure.
        """
        if not self._ready or not self._model:
            return None

        import tempfile
        import traceback

        # Determine file extension from mime type
        ext = ".webm"
        if "wav" in mime_type:
            ext = ".wav"
        elif "ogg" in mime_type:
            ext = ".ogg"
        elif "mp4" in mime_type:
            ext = ".mp4"

        print(f"  STT: received {len(audio_bytes)} bytes, mime={mime_type}, ext={ext}")

        with self._lock:
            tmp_path = None
            try:
                with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
                    tmp.write(audio_bytes)
                    tmp_path = tmp.name

                print(f"  STT: transcribing {tmp_path}...")
                result = self._model.transcribe(tmp_path, language="en", fp16=False)
                text = result.get("text", "").strip()
                print(f"  STT: result → '{text[:80]}'" if text else "  STT: no text produced")

                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass

                return text if text else None

            except Exception as e:
                print(f"STT transcribe error: {type(e).__name__}: {e}")
                traceback.print_exc()
                if tmp_path:
                    try:
                        os.unlink(tmp_path)
                    except Exception:
                        pass
                return None


# ── Module-level singletons (lazy, injected by app.py) ──────────────

_tts: Optional[TTSEngine] = None
_stt: Optional[STTEngine] = None


def init_tts(voice: str = DEFAULT_VOICE) -> TTSEngine:
    global _tts
    _tts = TTSEngine(voice=voice)
    return _tts


def init_stt(model: str = WHISPER_MODEL) -> STTEngine:
    global _stt
    _stt = STTEngine(model_name=model)
    return _stt


def get_tts() -> Optional[TTSEngine]:
    return _tts


def get_stt() -> Optional[STTEngine]:
    return _stt
