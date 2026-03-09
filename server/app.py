from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
import json
import asyncio
import uuid
from datetime import datetime, timedelta
from typing import Dict, Optional
from pathlib import Path
import os

from model_loader import ModelLoader
from session_manager import SessionManager
from summarizer import SessionSummarizer

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

_model_path  = os.environ.get("HAVEN_MODEL_PATH",  "models/model.gguf")
_memory_path = os.environ.get("HAVEN_MEMORY_PATH", "models/memory.md")

model_loader    = ModelLoader(_model_path)
session_manager = SessionManager(_memory_path)
summarizer      = SessionSummarizer()
summarizer.set_model(model_loader)   # inject model so summarizer can call generate_simple()

active_sessions: Dict[str, dict] = {}

SESSIONS_DIR = Path("sessions")
SESSIONS_DIR.mkdir(exist_ok=True)


# ── Write-ahead log helpers ────────────────────────────────────────
# Every message (user and assistant) is appended to a .jsonl file
# as it arrives. If the server crashes, these files survive and are
# recovered on next startup. On a clean session end the file is deleted.

def wal_path(session_id: str) -> Path:
    return SESSIONS_DIR / f"active_{session_id}.jsonl"

def wal_append(session_id: str, message: dict) -> None:
    """Append a single message to the session's write-ahead log."""
    try:
        with open(wal_path(session_id), "a", encoding="utf-8") as f:
            f.write(json.dumps(message, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"WAL write error for {session_id}: {e}")

def wal_delete(session_id: str) -> None:
    """Remove the WAL file after a clean session end."""
    try:
        p = wal_path(session_id)
        if p.exists():
            p.unlink()
    except Exception as e:
        print(f"WAL delete error for {session_id}: {e}")

def wal_read(path: Path) -> list:
    """Read all messages from a WAL file. Skips any corrupted lines."""
    messages = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"WAL: skipping corrupt line in {path.name}")
    except Exception as e:
        print(f"WAL read error {path}: {e}")
    return messages


# ── Crash recovery ─────────────────────────────────────────────────
# Called once at startup. Finds any leftover active_*.jsonl files
# from a previous crash, summarizes them into memory.md, saves a
# full session log, then deletes the WAL file.

async def recover_crashed_sessions():
    leftover = list(SESSIONS_DIR.glob("active_*.jsonl"))
    if not leftover:
        return

    print(f"🔄 Found {len(leftover)} crashed session(s) to recover...")

    for wal_file in leftover:
        # Extract session_id from filename: active_<uuid>.jsonl
        session_id = wal_file.stem[len("active_"):]
        messages   = wal_read(wal_file)

        if not messages:
            print(f"  ⚠ {wal_file.name} was empty — deleting")
            wal_file.unlink()
            continue

        print(f"  ↩ Recovering {session_id[:8]}… ({len(messages)} messages)")

        # Build a minimal session_data dict so we can reuse save_session_log
        session_data = {
            "id":             session_id,
            "messages":       messages,
            "context_memory": "",
            "created_at":     messages[0].get("timestamp", datetime.now().isoformat()),
            "metadata":       {"recovered": True, "crashed": True},
        }

        try:
            summary = await summarizer.summarize_session(messages, "")
            session_manager.save_to_memory(summary, messages)
            session_manager.save_session_log(session_id, session_data)
            print(f"  ✓ Recovered and saved to memory")
        except Exception as e:
            print(f"  ✗ Recovery failed for {session_id[:8]}: {e}")
        finally:
            wal_file.unlink()


# ── Session lifecycle ──────────────────────────────────────────────

async def end_session(session_id: str):
    if session_id not in active_sessions:
        return

    session_data = active_sessions.pop(session_id)

    # Remove WAL — clean shutdown, no recovery needed
    wal_delete(session_id)

    if not session_data.get("messages"):
        return

    summary = await summarizer.summarize_session(
        session_data["messages"],
        session_data.get("context_memory", "")
    )
    session_manager.save_to_memory(summary, session_data["messages"])
    session_manager.save_session_log(session_id, session_data)


async def cleanup_stale_sessions():
    while True:
        await asyncio.sleep(300)
        cutoff = datetime.now() - timedelta(hours=1)
        stale  = [
            sid for sid, data in list(active_sessions.items())
            if data.get("last_active", datetime.now()) < cutoff
        ]
        for sid in stale:
            print(f"Cleaning up stale session: {sid}")
            await end_session(sid)


# ── Startup ────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup_event():
    # Recover any sessions that didn't end cleanly last time
    await recover_crashed_sessions()
    asyncio.create_task(cleanup_stale_sessions())


# ── Routes ─────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def get_chat_page(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


@app.post("/api/chat/start")
async def start_chat(request: Request):
    try:
        data = await request.json()
    except Exception:
        data = {}

    session_id    = str(uuid.uuid4())
    global_memory = session_manager.load_memory()

    active_sessions[session_id] = {
        "id":             session_id,
        "messages":       [],
        "context_memory": global_memory,
        "last_active":    datetime.now(),
        "created_at":     datetime.now(),
        "metadata":       data.get("metadata", {}),
    }

    # Create the WAL file immediately so we know the session existed
    # even if the user never sends a message before a crash
    wal_path(session_id).touch()

    return JSONResponse({
        "session_id":    session_id,
        "memory_loaded": bool(global_memory),
        "message":       "Session started",
    })


@app.post("/api/chat/{session_id}")
async def chat(session_id: str, request: Request):
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")

    data         = await request.json()
    user_message = data.get("message", "").strip()

    if not user_message:
        raise HTTPException(status_code=400, detail="Message cannot be empty")

    session                = active_sessions[session_id]
    session["last_active"] = datetime.now()

    # Guard: orphaned user turn from a previous cancelled generation
    msgs = session["messages"]
    if msgs and msgs[-1]["role"] == "user":
        print(f"Warning: removing orphan user turn in {session_id[:8]}")
        msgs.pop()

    user_msg = {
        "role":      "user",
        "content":   user_message,
        "timestamp": datetime.now().isoformat(),
    }
    msgs.append(user_msg)
    wal_append(session_id, user_msg)   # persist immediately

    full_context = session_manager.prepare_context(
        msgs,
        session["context_memory"],
    )

    async def generate():
        full_response = ""
        try:
            async for chunk in model_loader.generate_stream(full_context):
                full_response += chunk
                yield f"data: {json.dumps({'chunk': chunk})}\n\n"

            yield f"data: {json.dumps({'done': True})}\n\n"

        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

        finally:
            if full_response.strip():
                assistant_msg = {
                    "role":      "assistant",
                    "content":   full_response.strip(),
                    "timestamp": datetime.now().isoformat(),
                }
                session["messages"].append(assistant_msg)
                wal_append(session_id, assistant_msg)  # persist immediately

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.post("/api/chat/{session_id}/end")
async def end_chat_session(session_id: str):
    await end_session(session_id)
    return JSONResponse({"message": "Session ended and saved to memory"})


@app.get("/api/sessions/{session_id}/history")
async def get_session_history(session_id: str):
    if session_id in active_sessions:
        return JSONResponse(active_sessions[session_id]["messages"])
    history = session_manager.load_session_log(session_id)
    if history:
        return JSONResponse(history.get("messages", []))
    raise HTTPException(status_code=404, detail="Session not found")


@app.get("/api/memory")
async def get_memory():
    return JSONResponse({"memory": session_manager.load_memory()})


# ── Debug endpoint ─────────────────────────────────────────────────
# GET /api/debug/{session_id} — shows the exact prompt sent to the model.
# Remove or password-protect before exposing publicly.
@app.get("/api/debug/{session_id}")
async def debug_session(session_id: str):
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    session = active_sessions[session_id]
    context = session_manager.prepare_context(
        session["messages"],
        session["context_memory"],
    )
    return JSONResponse({
        "message_count":  len(session["messages"]),
        "messages":       session["messages"],
        "prompt_preview": context["prompt"],
        "prompt_length":  len(context["prompt"]),
        "memory_used":    context["memory_used"],
        "wal_exists":     wal_path(session_id).exists(),
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
