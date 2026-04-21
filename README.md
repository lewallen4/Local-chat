# Skye-AI

A self-hosted AI chat server built on FastAPI and llama.cpp. Fully local, multi-user, with persistent memory, session history, a built-in knowledge base, and offline voice I/O — no cloud APIs, no telemetry, no data leaving your machine.

---

## Quick Start

```bash
git clone https://github.com/lewallen4/Local-chat.git
cd Local-chat
bash setup.sh
bash gui_model_pull.sh
bash run.sh --lan
```

Open `http://your-ip:8000` from any device on your network.

---

## Requirements

- Python 3.12
- A GGUF model file (downloaded via the included model puller)
- Linux (Ubuntu/Debian, RHEL/Fedora) or macOS
- ffmpeg (required for voice input — `sudo apt install ffmpeg` or `brew install ffmpeg`)
- Recommended: NVIDIA GPU with 8+ GB VRAM (CPU-only works but is slower)

---

## Setup

```bash
bash setup.sh
```

Creates a Python virtual environment at `~/.skyeai-venv`, installs all dependencies, and prepares the directory structure. In a non-interactive shell (CI, GitHub Actions) everything installs automatically including TTS/STT. In an interactive terminal it will ask before installing the voice packages (~450MB).

To install voice support separately at any time:

```bash
bash tts_model_pull.sh
```

---

## Downloading a Model

### GUI picker (recommended)

```bash
bash gui_model_pull.sh
```

Presents an interactive menu with models from Meta (Llama), Mistral, IBM (Granite), and Google (Gemma). Select a number and it downloads via curl with a progress bar. Available models include:

| # | Model | Size | RAM Needed |
|---|-------|------|------------|
| 1–6 | Llama 3.1 / 3.2 / 3.3 / 4 Scout | 0.8–50 GB | 4–64 GB |
| 7 | Mistral Small 3.1 24B | 14.5 GB | 20 GB |
| 8 | IBM Granite 3.3 8B | 4.6 GB | 8 GB |
| 9–10 | IBM Granite 4 (1B / 32B) | 0.9–19.5 GB | 4–24 GB |
| 11 | IBM Granite Guardian 3.2 5B | 3.1 GB | 8 GB |
| 12–15 | Google Gemma 4 31B (multiple quants) | 18–33 GB | 24–40 GB |

### Minimal (no menu)

```bash
bash model_pull.sh
```

Downloads a small default model. Models are saved to `server/models/model.gguf`.

---

## Running the Server

```bash
bash run.sh              # localhost only
bash run.sh --lan        # LAN accessible (0.0.0.0)
bash run.sh --port 9000  # custom port
bash run.sh --dev        # hot-reload + debug logging
```

### As a Background Service (systemd)

```bash
sudo bash install-service.sh          # runs as your user
sudo bash install-service.sh --root   # runs as root
```

```bash
sudo systemctl status skye-ai
journalctl -u skye-ai -f
sudo systemctl restart skye-ai
sudo systemctl stop skye-ai
sudo bash install-service.sh remove
```

---

## Using the Chat

1. Open `http://localhost:8000`
2. Enter a 5-character user ID (letters, numbers, `-`, `_`)
3. Start chatting

Each user ID gets its own isolated workspace — separate memory, session history, settings, and facts. The sidebar shows all past sessions; click any to resume it live.

### Chat features

- **Streaming responses** with markdown rendering, syntax-highlighted code blocks, and copy buttons per block
- **Collapsible thinking blocks** for models that emit reasoning (Gemma 4, DeepSeek, Qwen) — toggle visibility in settings
- **Light/dark theme** toggle, persisted across sessions
- **Keyboard shortcuts:** `Ctrl+N` new session · `Ctrl+B` toggle sidebar · `Esc` clear input · `Shift+Enter` new line

---

## Memory System

Skye-AI builds a memory file for each user that persists across sessions.

### How it works

At the end of every session the model writes a 1–3 sentence prose summary of what was discussed. That summary is prepended to the user's `memory.md` under `## RECENT SESSIONS`. On the next session start, the 10 most recent summaries are injected into the system prompt as context.

### Facts

Facts are persistent user-defined notes that live in the `## FACTS` section of `memory.md`. Unlike session summaries they are never auto-modified — only you can add or remove them.

To manage facts, open **Settings → Add a Fact**. Facts appear listed below the input with a delete button on each. The `User ID` fact is locked and cannot be removed.

Facts are good for things the model should always know: your name, your project names, your preferences, recurring context that you don't want to re-explain every session.

### Storage layout

```
server/users/<user_id>/
├── memory.md          # facts + rolling session summaries (10 max in prompt)
└── sessions/          # full session JSON logs (20 most recent kept active)

server/cold_session_storage/<user_id>/sessions/
                       # older sessions archived here automatically
```

---

## Settings

Open the settings panel with the gear icon in the sidebar.

| Setting | What it does |
|---------|--------------|
| **Temperature** | 0.0 = deterministic/precise, 1.0 = creative/random |
| **Thinking mode** | Enables step-by-step reasoning before answering. Works best with Gemma 4. |
| **Show thoughts** | Toggle visibility of `<think>` blocks in the chat UI |
| **Response length** | Short / Medium / Long / Extra Long / Epic — controls max tokens and prompt hint |
| **Voice mode** | Enable auto-TTS on AI responses (requires TTS packages installed) |
| **Show TTS buttons** | Toggle waveform playback buttons on individual messages |
| **Add a Fact** | Add a permanent note to your memory file |

Settings are saved per-user and persist across sessions.

---

## Voice (TTS / STT)

Skye-AI supports fully offline voice input and output using Kokoro TTS and Whisper STT. No microphone data or audio leaves your machine.

### Setup

```bash
bash tts_model_pull.sh
```

This installs the Python packages and pre-downloads the voice models:
- **Kokoro af_heart** — American English female voice (~300MB)
- **Whisper base** — speech recognition model (~145MB)

ffmpeg must be installed on the system for Whisper to process audio.

### Voice output (TTS)

Every chat message has a small waveform button in its timestamp row. Click it to have that message read aloud. The button animates while playing and dims after playback to show it has been played — click again to replay.

Only one message plays at a time. Clicking a new message while audio is playing stops the current one and starts the new one.

Code blocks are never read verbatim. Instead the voice says things like *"Here's a Python snippet"* or *"Here's a shell command"* and moves on.

### Voice mode

Enable **Voice mode** in settings to have the AI automatically read every response aloud after it finishes generating. This pairs with voice input for a fully hands-free loop.

### Voice input (PTT)

When voice mode is enabled and STT is available, a waveform button appears in the input bar next to the send button.

**Hold** the button to record. **Release** to stop — Whisper transcribes the audio and drops the text into the input box for you to review before sending. If you're in voice mode the AI will also read its response back automatically.

The button shows recording state (red pulse) while active and a processing state while transcribing.

---

## Knowledge Base

Make the AI an expert on your own documents. Skye-AI can ingest Confluence XML exports, HTML exports, markdown, and plain text, retrieve relevant chunks at query time, and inject them into the prompt automatically.

No external embedding model or vector database required — embeddings are generated by your loaded chat model.

### Setup

1. Create the knowledge directory and drop files in:

```
server/knowledge/
├── confluence-export.xml
├── docs/
│   ├── architecture.md
│   └── runbook.txt
└── notes.html
```

Supported formats: `.xml` (Confluence XML/HTML export), `.html`, `.md`, `.txt`. Subdirectories are supported.

2. Start the server, then ingest:

```bash
bash ingest.sh
```

This parses all documents, splits them into overlapping chunks, embeds each chunk, and saves the index to `server/knowledge_index.json`. May take a few minutes depending on document volume.

3. Chat normally. Relevant knowledge is retrieved automatically and injected into the prompt when you ask questions.

Re-run `bash ingest.sh` any time documents change.

---

## Configuration

### System prompt

Edit `server/models/system_prompt.txt` to change the AI's base behavior and personality.

### Context window

Edit `n_ctx` in `server/model_loader.py`. Default is 8192.

```python
n_ctx=16384,  # increase if your model and RAM support it
```

### GPU offload

Edit `n_gpu_layers` in `server/model_loader.py`. Default is 0 (CPU only).

```python
n_gpu_layers=35,  # adjust based on your VRAM
```

---

## Project Structure

```
Skye-AI/
├── setup.sh                 # environment + dependency setup
├── run.sh                   # server launcher
├── install-service.sh       # systemd service installer
├── model_pull.sh            # minimal model downloader
├── gui_model_pull.sh        # interactive model picker
├── tts_model_pull.sh        # voice model downloader (Kokoro + Whisper)
├── ingest.sh                # knowledge base ingestion
└── server/
    ├── app.py               # FastAPI routes, SSE streaming, session lifecycle
    ├── model_loader.py      # llama.cpp loading, generation, embedding
    ├── session_manager.py   # per-user memory, prompt assembly, session persistence
    ├── summarizer.py        # end-of-session summarization
    ├── knowledge_base.py    # document ingestion, chunking, embedding, retrieval
    ├── tts_engine.py        # Kokoro TTS + Whisper STT, text preprocessing
    ├── logger.py            # rotating file logger (3000 line cap)
    ├── requirements.txt
    ├── models/
    │   ├── model.gguf       # your downloaded model (not in git)
    │   ├── system_prompt.txt
    │   └── default_memory.md
    ├── knowledge/           # drop documents here (not in git)
    ├── static/
    │   ├── script.js
    │   └── style.css
    └── templates/
        └── index.html
```

---

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Chat UI |
| `GET` | `/api/user/{id}/check` | Check if user exists |
| `POST` | `/api/chat/start` | Start new session |
| `POST` | `/api/chat/rejoin` | Rejoin existing session |
| `POST` | `/api/chat/{sid}` | Send message (SSE stream) |
| `POST` | `/api/chat/{sid}/end` | End session + save to memory |
| `GET` | `/api/sessions/{sid}/history` | Get session messages |
| `GET` | `/api/user/{id}/sessions` | List user sessions |
| `GET` | `/api/memory?user_id=` | Get user memory file |
| `GET` | `/api/user/{id}/settings` | Get user settings |
| `POST` | `/api/user/{id}/settings` | Save user settings |
| `POST` | `/api/user/{id}/facts` | Add a fact |
| `DELETE` | `/api/user/{id}/facts` | Remove a fact |
| `GET` | `/api/knowledge/status` | Knowledge base status |
| `POST` | `/api/knowledge/ingest` | Trigger ingestion |
| `GET` | `/api/knowledge/search?q=` | Search knowledge base |
| `GET` | `/api/tts/status` | TTS/STT availability |
| `POST` | `/api/tts/speak` | Synthesize text to WAV |
| `POST` | `/api/stt/transcribe` | Transcribe audio to text |
