# Local Chat

A self-hosted AI chat client built on FastAPI and llama.cpp. Private, local-first, multi-user.

## What it is

Local Chat runs a local LLM on your hardware and serves a clean web UI for chatting with it. No cloud APIs, no telemetry, no data leaving your machine. Multi-user support with per-user memory, session history, and context summarization — all stored locally.

## Stack

- **Backend:** FastAPI + llama.cpp (via llama-cpp-python)
- **Frontend:** Vanilla JS, no frameworks
- **Models:** IBM Granite 4 (default), any GGUF-compatible model

## Features

- Per-user workspaces with persistent memory
- Session history with resume support
- Streaming responses with markdown rendering, syntax-highlighted code blocks, and collapsible `<think>` blocks
- Context window summarization for long conversations
- Light/dark theme
- Reverse-proxy auto-login and TLS support
- Copy button on all code blocks

## Setup

```bash
chmod +x setup.sh
./setup.sh
```

This handles Python dependencies, model directory structure, and initial configuration.

## Pulling a model

```bash
./model_pull.sh
# or for a GUI picker:
./gui_model_pull.sh
```

Models are pulled via curl — no HuggingFace CLI involved.

## Running

```bash
./run.sh
```

Opens on `https://localhost:8443` by default (TLS). Log in with any 5-character user ID.

## Project structure

```
server/
├── app.py              # FastAPI routes + SSE streaming
├── model_loader.py     # llama.cpp model management
├── session_manager.py  # per-user session persistence
├── summarizer.py       # context window summarization
├── models/
│   ├── system_prompt.txt
│   ├── memory.md
│   └── default_memory.md
├── static/
│   ├── script.js       # frontend logic + markdown rendering
│   └── style.css
└── templates/
    └── index.html
```
