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

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

# Initialize components
model_loader = ModelLoader("models/model.model")
session_manager = SessionManager("models/memory.md")
summarizer = SessionSummarizer()

# Store active sessions
active_sessions: Dict[str, dict] = {}

# Background task for cleaning up stale sessions
async def cleanup_stale_sessions():
    while True:
        await asyncio.sleep(300)  # Check every 5 minutes
        current_time = datetime.now()
        stale_sessions = []
        
        for session_id, session_data in active_sessions.items():
            last_active = session_data.get("last_active")
            if last_active and current_time - last_active > timedelta(hours=1):
                stale_sessions.append(session_id)
        
        for session_id in stale_sessions:
            await end_session(session_id)

async def end_session(session_id: str):
    """End a session and save to memory"""
    if session_id in active_sessions:
        session_data = active_sessions[session_id]
        
        # Generate summary
        if session_data.get("messages"):
            summary = await summarizer.summarize_session(
                session_data["messages"],
                session_data.get("context_memory", "")
            )
            
            # Save to memory.md
            session_manager.save_to_memory(summary, session_data["messages"])
        
        # Save session log
        session_manager.save_session_log(session_id, session_data)
        
        # Remove from active sessions
        del active_sessions[session_id]

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(cleanup_stale_sessions())

@app.get("/", response_class=HTMLResponse)
async def get_chat_page(request: Request):
    """Serve the chat interface"""
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/api/chat/start")
async def start_chat(request: Request):
    """Start a new chat session"""
    data = await request.json() if await request.body() else {}
    session_id = str(uuid.uuid4())
    
    # Load global memory
    global_memory = session_manager.load_memory()
    
    # Initialize session
    active_sessions[session_id] = {
        "id": session_id,
        "messages": [],
        "context_memory": global_memory,
        "last_active": datetime.now(),
        "created_at": datetime.now(),
        "metadata": data.get("metadata", {})
    }
    
    return JSONResponse({
        "session_id": session_id,
        "memory_loaded": bool(global_memory),
        "message": "Session started"
    })

@app.post("/api/chat/{session_id}")
async def chat(session_id: str, request: Request):
    """Handle chat messages for a session"""
    if session_id not in active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    
    data = await request.json()
    user_message = data.get("message", "").strip()
    
    if not user_message:
        raise HTTPException(status_code=400, detail="Message cannot be empty")
    
    session = active_sessions[session_id]
    session["last_active"] = datetime.now()
    
    # Add user message to history
    session["messages"].append({
        "role": "user",
        "content": user_message,
        "timestamp": datetime.now().isoformat()
    })
    
    # Prepare context with memory
    full_context = session_manager.prepare_context(
        session["messages"],
        session["context_memory"]
    )
    
    # Stream response
    async def generate():
        try:
            full_response = ""
            async for chunk in model_loader.generate_stream(full_context):
                full_response += chunk
                yield f"data: {json.dumps({'chunk': chunk})}\n\n"
            
            # Add assistant response to history
            session["messages"].append({
                "role": "assistant",
                "content": full_response,
                "timestamp": datetime.now().isoformat()
            })
            
            yield f"data: {json.dumps({'done': True})}\n\n"
            
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
    
    return StreamingResponse(generate(), media_type="text/event-stream")

@app.post("/api/chat/{session_id}/end")
async def end_chat_session(session_id: str):
    """Manually end a session"""
    await end_session(session_id)
    return JSONResponse({"message": "Session ended and saved to memory"})

@app.get("/api/sessions/{session_id}/history")
async def get_session_history(session_id: str):
    """Get history for a specific session"""
    if session_id in active_sessions:
        return JSONResponse(active_sessions[session_id]["messages"])
    else:
        # Try to load from disk
        history = session_manager.load_session_log(session_id)
        if history:
            return JSONResponse(history.get("messages", []))
        raise HTTPException(status_code=404, detail="Session not found")

@app.get("/api/memory")
async def get_memory():
    """Get the current memory.md content"""
    memory = session_manager.load_memory()
    return JSONResponse({"memory": memory})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)