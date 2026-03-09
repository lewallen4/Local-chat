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

active_sessions: Dict[str, dict] = {}


# ── Session lifecycle ──────────────────────────────────────────────

async def end_session(session_id: str):
    if session_id not in active_sessions:
        return

    session_data = active_sessions.pop(session_id)

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

    # ── Guard: if the last message is a user turn with no assistant reply
    # (from a cancelled generation), remove it so history stays properly
    # alternating. Without this the model sees two USER turns in a row
    # and gets confused about whose turn it is.
    msgs = session["messages"]
    if msgs and msgs[-1]["role"] == "user":
        print(f"Warning: last message was user with no assistant reply — removing orphan turn")
        msgs.pop()

    msgs.append({
        "role":      "user",
        "content":   user_message,
        "timestamp": datetime.now().isoformat(),
    })

    full_context = session_manager.prepare_context(
        msgs,
        session["context_memory"],
    )

    async def generate():
        full_response = ""
        generation_ok = False
        try:
            async for chunk in model_loader.generate_stream(full_context):
                full_response += chunk
                yield f"data: {json.dumps({'chunk': chunk})}\n\n"

            generation_ok = True
            yield f"data: {json.dumps({'done': True})}\n\n"

        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

        finally:
            # Always save whatever we got, even on partial/cancelled responses.
            # An empty response means the user message becomes an orphan — the
            # guard at the top of this route will clean it up next turn.
            if full_response.strip():
                session["messages"].append({
                    "role":      "assistant",
                    "content":   full_response.strip(),
                    "timestamp": datetime.now().isoformat(),
                })

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


# ── Debug endpoint — see exactly what prompt the model receives ───
# Hit: GET /api/debug/{session_id}
# Remove or protect this before exposing to the internet.
@app.get("/api/debug/{session_id}")
async def debug_session(session_id: str):
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    session  = active_sessions[session_id]
    context  = session_manager.prepare_context(
        session["messages"],
        session["context_memory"],
    )
    return JSONResponse({
        "message_count":   len(session["messages"]),
        "messages":        session["messages"],
        "prompt_preview":  context["prompt"],
        "prompt_length":   len(context["prompt"]),
        "memory_used":     context["memory_used"],
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
