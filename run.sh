#!/usr/bin/env bash
# ============================================================
#  Local Chat LLM — Run Script
#  Usage: bash run.sh [--port 8000] [--lan] [--dev]
#         bash run.sh --help
# ============================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Configuration (edit these) ─────────────────────────────────────
HOST="127.0.0.1"        # 0.0.0.0 to expose on your LAN
PORT="8000"
WORKERS="1"             # Keep 1 — model is loaded once per process
MODEL_FILE="model.gguf" # Filename inside server/models/
LOG_LEVEL="info"        # debug | info | warning | error
RELOAD="false"          # Hot-reload (dev only)

# ── Paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
MODELS_DIR="$SERVER_DIR/models"

# Same venv location as setup.sh — outside the repo so it
# survives git pulls and works on systems blocking system pip.
VENV_DIR="$HOME/.localchat-venv"
PYTHON="$VENV_DIR/bin/python"

# ── Helpers ────────────────────────────────────────────────────────
step()  { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()   { echo -e "\n${RED}✗${RESET} $1"; exit 1; }

usage() {
    echo ""
    echo "Usage: bash run.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --host HOST     Bind address (default: 127.0.0.1)"
    echo "  --port PORT     Port number  (default: 8000)"
    echo "  --lan           Expose on LAN (sets host to 0.0.0.0)"
    echo "  --dev           Enable hot-reload + debug logging"
    echo "  --model FILE    Model filename in server/models/"
    echo "  --help          Show this message"
    echo ""
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)   HOST="$2";       shift 2 ;;
        --port)   PORT="$2";       shift 2 ;;
        --model)  MODEL_FILE="$2"; shift 2 ;;
        --dev)    RELOAD="true";   LOG_LEVEL="debug"; shift ;;
        --lan)    HOST="0.0.0.0";  shift ;;
        --help)   usage ;;
        *)        warn "Unknown option: $1"; shift ;;
    esac
done

# ── Banner ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║          Local Chat — LLM                ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"

# ── Pre-flight checks ──────────────────────────────────────────────
step "Pre-flight checks"

# Virtualenv
if [ ! -f "$PYTHON" ]; then
    die "Virtualenv not found at $VENV_DIR\n  Run:  bash setup.sh"
fi
ok "Virtualenv found at $VENV_DIR"

# Model file
MODEL_PATH="$MODELS_DIR/$MODEL_FILE"
if [ ! -f "$MODEL_PATH" ]; then
    FALLBACK=$(find "$MODELS_DIR" -name "*.gguf" -o -name "*.model" 2>/dev/null | head -1)
    if [ -n "$FALLBACK" ]; then
        MODEL_FILE="$(basename "$FALLBACK")"
        MODEL_PATH="$FALLBACK"
        warn "model.gguf not found — using: $MODEL_FILE"
    else
        echo ""
        echo -e "  ${RED}✗ No model file found in server/models/${RESET}"
        echo ""
        echo "  Download a GGUF file and place it at:"
        echo "  → $MODELS_DIR/model.gguf"
        echo ""
        echo "  Then re-run:  bash run.sh"
        exit 1
    fi
fi

MODEL_MB=$(du -m "$MODEL_PATH" | cut -f1)
ok "Model: $MODEL_FILE (${MODEL_MB} MB)"

# Port availability
if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$PORT" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
        die "Port $PORT is already in use. Use --port to choose another."
    fi
fi
ok "Port $PORT is available"

# ── Export env vars for the server ────────────────────────────────
export HAVEN_MODEL_PATH="$MODEL_PATH"
export HAVEN_MEMORY_PATH="$MODELS_DIR/memory.md"

# ── Build uvicorn command ──────────────────────────────────────────
UVICORN_ARGS=(
    "app:app"
    "--host" "$HOST"
    "--port" "$PORT"
    "--log-level" "$LOG_LEVEL"
    "--workers" "$WORKERS"
)

if [ "$RELOAD" = "true" ]; then
    UVICORN_ARGS+=("--reload")
    warn "Hot-reload enabled (development mode)"
fi

# ── Launch info ────────────────────────────────────────────────────
step "Starting server"
echo ""
echo -e "  ${BOLD}Local:${RESET}   http://localhost:$PORT"
if [ "$HOST" = "0.0.0.0" ]; then
    LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-ip")
    echo -e "  ${BOLD}Network:${RESET} http://$LAN_IP:$PORT"
fi
echo ""
echo -e "  ${BOLD}Model:${RESET}   $MODEL_FILE"
echo -e "  ${BOLD}Memory:${RESET}  $MODELS_DIR/memory.md"
echo -e "  ${BOLD}Venv:${RESET}    $VENV_DIR"
echo ""
echo -e "  Press ${BOLD}Ctrl+C${RESET} to stop"
echo ""
echo -e "${CYAN}────────────────────────────────────────────${RESET}"
echo ""

# ── Trap for clean shutdown ────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "\n${YELLOW}Shutting down Local Chat...${RESET}"
    echo "Session memory preserved in server/models/memory.md"
    echo ""
}
trap cleanup INT TERM

# ── Run ───────────────────────────────────────────────────────────
cd "$SERVER_DIR"
exec "$PYTHON" -m uvicorn "${UVICORN_ARGS[@]}"
