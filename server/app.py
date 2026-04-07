from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
import json
import asyncio
import uuid
import re
from datetime import datetime, timedelta
from typing import Dict, Optional
from pathlib import Path
import os

from model_loader import ModelLoader
from session_manager import SessionManager, is_returning_user, provision_user
from summarizer import SessionSummarizer
from knowledge_base import KnowledgeBase

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

_model_path = os.environ.get("HAVEN_MODEL_PATH", "models/model.gguf")

model_loader = ModelLoader(_model_path)
summarizer = SessionSummarizer()
summarizer.set_model(model_loader)
knowledge = KnowledgeBase()
knowledge.set_model(model_loader)

# active_sessions maps session_id -> session dict (includes user_id + SessionManager)
active_sessions: Dict[str, dict] = {}

SESSIONS_DIR = Path("sessions")   # legacy / WAL root — WAL files still go here
SESSIONS_DIR.mkdir(exist_ok=True)

# ── User ID validation ─────────────────────────────────────────────
USER_ID_RE = re.compile(r"^[a-zA-Z0-9_\-]{5,5}$")

def validate_user_id(user_id: str) -> bool:
    """Alphanumeric + underscore/hyphen, 2–32 chars. Keeps filesystem paths safe."""
    return bool(USER_ID_RE.match(user_id))


# ── Write-ahead log helpers ────────────────────────────────────────

def wal_path(session_id: str) -> Path:
    return SESSIONS_DIR / f"active_{session_id}.jsonl"

def wal_append(session_id: str, message: dict) -> None:
    try:
        with open(wal_path(session_id), "a", encoding="utf-8") as f:
            f.write(json.dumps(message, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"WAL write error for {session_id}: {e}")

def wal_delete(session_id: str) -> None:
    try:
        p = wal_path(session_id)
        if p.exists():
            p.unlink()
    except Exception as e:
        print(f"WAL delete error for {session_id}: {e}")

def wal_read(path: Path) -> list:
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

async def recover_crashed_sessions():
    leftover = list(SESSIONS_DIR.glob("active_*.jsonl"))
    if not leftover:
        return

    print(f"🔄 Found {len(leftover)} crashed session(s) to recover...")

    for wal_file in leftover:
        session_id = wal_file.stem[len("active_"):]
        messages = wal_read(wal_file)

        if not messages:
            wal_file.unlink()
            continue

        print(f"  ↩ Recovering {session_id[:8]}… ({len(messages)} messages)")

        # Try to find user_id from first message metadata, else use "unknown"
        user_id = "unknown"
        session_data = {
            "id": session_id,
            "messages": messages,
            "context_memory": "",
            "created_at": messages[0].get("timestamp", datetime.now().isoformat()),
            "metadata": {"recovered": True, "crashed": True},
        }

        try:
            sm = SessionManager(user_id)
            summary = await summarizer.summarize_session(messages, "")
            sm.save_to_memory(summary, messages)
            sm.save_session_log(session_id, session_data)
            print(f"  ✓ Recovered and saved")
        except Exception as e:
            print(f"  ✗ Recovery failed for {session_id[:8]}: {e}")
        finally:
            wal_file.unlink()


# ── Session lifecycle ──────────────────────────────────────────────

async def end_session(session_id: str):
    if session_id not in active_sessions:
        return

    session_data = active_sessions.pop(session_id)
    wal_delete(session_id)

    if not session_data.get("messages"):
        return

    sm: SessionManager = session_data["session_manager"]
    summary = await summarizer.summarize_session(
        session_data["messages"],
        session_data.get("context_memory", ""),
    )
    sm.save_to_memory(summary, session_data["messages"])
    sm.save_session_log(session_id, session_data)


async def cleanup_stale_sessions():
    while True:
        await asyncio.sleep(300)
        cutoff = datetime.now() - timedelta(hours=1)
        stale = [
            sid for sid, data in list(active_sessions.items())
            if data.get("last_active", datetime.now()) < cutoff
        ]
        for sid in stale:
            print(f"Cleaning up stale session: {sid}")
            await end_session(sid)


# ── Startup ────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup_event():
    await recover_crashed_sessions()
    knowledge.load_index()
    asyncio.create_task(cleanup_stale_sessions())


# ── Routes ─────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def get_chat_page(request: Request):
    return templates.TemplateResponse(request, "index.html")


# ── User identification ────────────────────────────────────────────

@app.get("/api/user/{user_id}/check")
async def check_user(user_id: str):
    """
    Returns whether this user_id already has a workspace.
    Frontend uses this to show 'Welcome back' vs 'Creating workspace'.
    """
    if not validate_user_id(user_id):
        raise HTTPException(status_code=400, detail="Invalid user ID format")

    returning = is_returning_user(user_id)
    sessions = []
    if returning:
        sm = SessionManager(user_id)
        sessions = sm.list_sessions()

    return JSONResponse({
        "user_id": user_id,
        "returning": returning,
        "session_count": len(sessions),
        "sessions": sessions,
    })


@app.post("/api/chat/start")
async def start_chat(request: Request):
    try:
        data = await request.json()
    except Exception:
        data = {}

    user_id = data.get("user_id", "").strip()
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    if not validate_user_id(user_id):
        raise HTTPException(
            status_code=400,
            detail="Invalid user ID. Must be exactly 5 alphanumeric characters, hyphens, or underscores."
        )

    # End any existing active session for this user first (one active session per user)
    existing_sids = [
        sid for sid, s in list(active_sessions.items())
        if s.get("user_id") == user_id
    ]
    for sid in existing_sids:
        await end_session(sid)

    # Provision workspace (no-op if already exists)
    sm = SessionManager(user_id)
    global_memory = sm.load_memory()

    session_id = str(uuid.uuid4())

    # Optional: seed session with messages from a prior session being continued.
    # Strip timestamps so they don't confuse the model, keep role + content only.
    prior = data.get("prior_messages", [])
    seeded = []
    for m in prior:
        if m.get("role") in ("user", "assistant") and m.get("content", "").strip():
            seeded.append({
                "role":      m["role"],
                "content":   m["content"].strip(),
                "timestamp": m.get("timestamp", datetime.now().isoformat()),
            })

    active_sessions[session_id] = {
        "id": session_id,
        "user_id": user_id,
        "session_manager": sm,
        "messages": seeded,
        "context_memory": global_memory,
        "last_active": datetime.now(),
        "created_at": datetime.now(),
        "metadata": data.get("metadata", {}),
    }

    # Write seeded messages to WAL so crash recovery captures them
    for m in seeded:
        wal_append(session_id, m)

    return JSONResponse({
        "session_id": session_id,
        "user_id": user_id,
        "returning": True,
        "memory_loaded": bool(global_memory),
        "seeded_messages": len(seeded),
        "message": "Session started",
    })


@app.post("/api/chat/rejoin")
async def rejoin_session(request: Request):
    """
    Rejoin an existing saved session. Loads the session log back into
    active_sessions so the user can continue chatting without creating
    a duplicate session.
    """
    try:
        data = await request.json()
    except Exception:
        data = {}

    user_id    = data.get("user_id", "").strip()
    session_id = data.get("session_id", "").strip()

    if not user_id or not validate_user_id(user_id):
        raise HTTPException(status_code=400, detail="Valid user_id is required")
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required")

    # If this session is already active, just return it
    if session_id in active_sessions:
        session = active_sessions[session_id]
        session["last_active"] = datetime.now()
        return JSONResponse({
            "session_id": session_id,
            "user_id": user_id,
            "rejoined": True,
            "message_count": len(session["messages"]),
        })

    # End any other active session for this user first
    existing_sids = [
        sid for sid, s in list(active_sessions.items())
        if s.get("user_id") == user_id
    ]
    for sid in existing_sids:
        await end_session(sid)

    # Load from saved session log
    sm = SessionManager(user_id)
    log = sm.load_session_log(session_id)
    if not log:
        raise HTTPException(status_code=404, detail="Session not found")

    messages = log.get("messages", [])
    global_memory = sm.load_memory()

    active_sessions[session_id] = {
        "id": session_id,
        "user_id": user_id,
        "session_manager": sm,
        "messages": messages,
        "context_memory": global_memory,
        "last_active": datetime.now(),
        "created_at": log.get("created_at", datetime.now().isoformat()),
        "metadata": log.get("metadata", {}),
    }

    # Re-establish WAL
    for m in messages:
        wal_append(session_id, m)

    return JSONResponse({
        "session_id": session_id,
        "user_id": user_id,
        "rejoined": True,
        "message_count": len(messages),
    })


@app.post("/api/chat/{session_id}")
async def chat(session_id: str, request: Request):
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")

    data = await request.json()
    user_message = data.get("message", "").strip()

    if not user_message:
        raise HTTPException(status_code=400, detail="Message cannot be empty")

    session = active_sessions[session_id]
    session["last_active"] = datetime.now()
    sm: SessionManager = session["session_manager"]

    msgs = session["messages"]
    if msgs and msgs[-1]["role"] == "user":
        print(f"Warning: removing orphan user turn in {session_id[:8]}")
        msgs.pop()

    user_msg = {
        "role": "user",
        "content": user_message,
        "timestamp": datetime.now().isoformat(),
    }
    msgs.append(user_msg)
    wal_append(session_id, user_msg)

    # Retrieve relevant knowledge chunks for this query
    kb_context = ""
    if knowledge.ready:
        kb_context = knowledge.get_context(user_message)

    full_context = sm.prepare_context(msgs, session["context_memory"], kb_context)

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
                    "role": "assistant",
                    "content": full_response.strip(),
                    "timestamp": datetime.now().isoformat(),
                }
                session["messages"].append(assistant_msg)
                wal_append(session_id, assistant_msg)

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.post("/api/chat/{session_id}/end")
async def end_chat_session(session_id: str):
    await end_session(session_id)
    return JSONResponse({"message": "Session ended and saved to memory"})


@app.get("/api/sessions/{session_id}/history")
async def get_session_history(session_id: str):
    if session_id in active_sessions:
        return JSONResponse(active_sessions[session_id]["messages"])
    # Try all user dirs
    from session_manager import USERS_DIR
    for user_dir in USERS_DIR.iterdir():
        log_file = user_dir / "sessions" / f"session_{session_id}.json"
        if log_file.exists():
            with open(log_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            return JSONResponse(data.get("messages", []))
    raise HTTPException(status_code=404, detail="Session not found")


@app.get("/api/user/{user_id}/sessions")
async def get_user_sessions(user_id: str):
    """Return all past sessions for a user (for sidebar history)."""
    if not validate_user_id(user_id):
        raise HTTPException(status_code=400, detail="Invalid user ID")
    sm = SessionManager(user_id)
    return JSONResponse({"sessions": sm.list_sessions()})


@app.get("/api/memory")
async def get_memory(user_id: str = ""):
    """Return memory for a specific user (pass ?user_id=...)."""
    if not user_id or not validate_user_id(user_id):
        return JSONResponse({"memory": ""})
    sm = SessionManager(user_id)
    return JSONResponse({"memory": sm.load_memory()})


@app.get("/api/knowledge/status")
async def knowledge_status():
    """Check whether the knowledge base is loaded and how many chunks it has."""
    return JSONResponse({
        "ready": knowledge.ready,
        "chunk_count": knowledge.chunk_count,
    })


@app.post("/api/knowledge/ingest")
async def knowledge_ingest():
    """
    Trigger ingestion of all files in the knowledge/ directory.
    This embeds every chunk with the loaded model — may take a few minutes.
    """
    count = knowledge.ingest()
    if count == 0:
        raise HTTPException(
            status_code=400,
            detail="No chunks ingested. Put .xml, .md, or .txt files in the knowledge/ directory."
        )
    return JSONResponse({
        "message": f"Ingested {count} chunks",
        "chunk_count": count,
    })


@app.get("/api/knowledge/search")
async def knowledge_search(q: str = ""):
    """Test search against the knowledge base."""
    if not q:
        raise HTTPException(status_code=400, detail="Pass ?q=your+query")
    if not knowledge.ready:
        return JSONResponse({"results": [], "message": "Knowledge base not loaded"})
    results = knowledge.search(q)
    return JSONResponse({
        "query": q,
        "results": [{"title": r["title"], "text": r["text"][:200], "score": round(r["score"], 4)} for r in results],
    })


@app.get("/api/debug/{session_id}")
async def debug_session(session_id: str):
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    session = active_sessions[session_id]
    sm: SessionManager = session["session_manager"]
    context = sm.prepare_context(session["messages"], session["context_memory"])
    return JSONResponse({
        "user_id": session["user_id"],
        "message_count": len(session["messages"]),
        "messages": session["messages"],
        "prompt_preview": context["prompt"],
        "prompt_length": len(context["prompt"]),
        "memory_used": context["memory_used"],
        "wal_exists": wal_path(session_id).exists(),
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
