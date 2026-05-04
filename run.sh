#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Server Launch
#  Supports: Ubuntu/Debian, RHEL/CentOS/Fedora, macOS
#  Usage: bash run.sh [--port 8000] [--lan] [--dev]
#         bash run.sh --help
# ============================================================

set -uo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Defaults ───────────────────────────────────────────────────────
HOST="127.0.0.1"
PORT="8000"
WORKERS="1"
MODEL_FILE="model.gguf"
LOG_LEVEL="info"
RELOAD="false"

# ── Paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
MODELS_DIR="$SERVER_DIR/models"
VENV_DIR="$HOME/.skyeai-venv"
PYTHON="$VENV_DIR/bin/python"

# ── Helpers ────────────────────────────────────────────────────────
step() { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n${RED}✗${RESET} $1\n"; exit 1; }

usage() {
    echo ""
    echo "Usage: bash run.sh [OPTIONS]"
    echo ""
    echo "  --host HOST     Bind address     (default: 127.0.0.1)"
    echo "  --port PORT     Port number      (default: 8000)"
    echo "  --lan           Expose on LAN    (sets host to 0.0.0.0)"
    echo "  --dev           Hot-reload + debug logging"
    echo "  --model FILE    Model filename in server/models/"
    echo "  --help          Show this message"
    echo ""
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  HOST="$2";       shift 2 ;;
        --port)  PORT="$2";       shift 2 ;;
        --model) MODEL_FILE="$2"; shift 2 ;;
        --dev)   RELOAD="true";   LOG_LEVEL="debug"; shift ;;
        --lan)   HOST="0.0.0.0";  shift ;;
        --help)  usage ;;
        *)       warn "Unknown option: $1"; shift ;;
    esac
done

# ── Banner ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║           Skye-AI  —  Server             ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"

# ── Pre-flight checks ──────────────────────────────────────────────
step "Pre-flight checks"

# ── Virtualenv ────────────────────────────────────────────────────
if [ ! -f "$PYTHON" ]; then
    echo ""
    echo -e "  ${RED}✗${RESET} Virtualenv not found at $VENV_DIR"
    echo ""
    echo "  Run setup first:"
    echo "  → bash setup.sh"
    echo ""
    read -rp "  Run setup.sh now? (y/N): " _RUN_SETUP
    if [[ "$_RUN_SETUP" =~ ^[Yy]$ ]]; then
        bash "$SCRIPT_DIR/setup.sh" || die "Setup failed. Fix errors above and re-run."
        [ -f "$PYTHON" ] || die "Setup completed but virtualenv still not found."
    else
        exit 1
    fi
fi
ok "Virtualenv: $VENV_DIR"

# ── Model file ────────────────────────────────────────────────────
MODEL_PATH="$MODELS_DIR/$MODEL_FILE"
if [ ! -f "$MODEL_PATH" ]; then
    FALLBACK=$(find "$MODELS_DIR" -maxdepth 2 \( -name "*.gguf" -o -name "*.model" \) 2>/dev/null | sort | head -1)
    if [ -n "$FALLBACK" ]; then
        MODEL_FILE="$(basename "$FALLBACK")"
        MODEL_PATH="$FALLBACK"
        warn "model.gguf not found — using: $MODEL_FILE"
    else
        echo ""
        echo -e "  ${RED}✗${RESET} No model file found in server/models/"
        echo ""
        read -rp "  Run model_pull.sh now? (y/N): " _RUN_PULL
        if [[ "$_RUN_PULL" =~ ^[Yy]$ ]]; then
            bash "$SCRIPT_DIR/model_pull.sh" || die "Model download failed."
            FALLBACK=$(find "$MODELS_DIR" -maxdepth 2 \( -name "*.gguf" -o -name "*.model" \) 2>/dev/null | sort | head -1)
            [ -n "$FALLBACK" ] || die "No model found after download. Check model_pull.sh output."
            MODEL_FILE="$(basename "$FALLBACK")"
            MODEL_PATH="$FALLBACK"
        else
            echo ""
            echo "  Download a model with:  bash model_pull.sh"
            echo ""
            exit 1
        fi
    fi
fi

MODEL_MB=$(du -m "$MODEL_PATH" | cut -f1)
ok "Model: $MODEL_FILE (${MODEL_MB} MB)"

# ── Model family detection ───────────────────────────────────────
# Identifies model family from filename for display only.
# Stop sequences are handled automatically in model_loader.py by
# reading general.architecture from GGUF metadata at load time.
# granitehybrid (4.0 H) and granite (4.1) are both handled correctly.
detect_model_family() {
    local f="${1,,}"
    if [[ "$f" == *"granite-4.0-h"* || "$f" == *"granitehybrid"* ]]; then
        echo "IBM Granite 4.0 H (granitehybrid)"
    elif [[ "$f" == *"granite-4.1"* ]]; then
        echo "IBM Granite 4.1"
    elif [[ "$f" == *"granite"* ]]; then
        echo "IBM Granite"
    elif [[ "$f" == *"gemma"* ]]; then
        echo "Gemma"
    elif [[ "$f" == *"mistral"* ]]; then
        echo "Mistral"
    elif [[ "$f" == *"llama"* ]]; then
        echo "Llama"
    else
        echo "Unknown"
    fi
}
MODEL_FAMILY=$(detect_model_family "$MODEL_FILE")
ok "Model family: $MODEL_FAMILY"
export SKYEAI_USE_JINJA="0"

# ── Port availability ─────────────────────────────────────────────
port_in_use() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$PORT" -sTCP:LISTEN -P -n >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -q ":$PORT "
    else
        return 1
    fi
}

if port_in_use; then
    die "Port $PORT is already in use. Use --port to choose another."
fi
ok "Port $PORT available"

# ── LAN IP detection (cross-platform) ────────────────────────────
get_lan_ip() {
    if command -v hostname >/dev/null 2>&1; then
        local IP
        IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$IP" ] && echo "$IP" && return
    fi
    if command -v ipconfig >/dev/null 2>&1; then
        local IP
        IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
        [ -n "$IP" ] && echo "$IP" && return
    fi
    if command -v ip >/dev/null 2>&1; then
        local IP
        IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        [ -n "$IP" ] && echo "$IP" && return
    fi
    echo "your-ip"
}

# ── Embedding model resolution ────────────────────────────────────
# Looks for a dedicated small embedding model in models/. RAG queries use
# this instead of the chat model — the chat model would take 30s+ per
# embed() call on CPU, the embedding model takes <100ms.
EMBEDDING_FILE_DEFAULT="granite-embedding-30m-english.gguf"
EMBEDDING_PATH=""
EMB_CANDIDATES=$(find "$MODELS_DIR" -maxdepth 2 -iname "*embedding*.gguf" 2>/dev/null | sort)
if [ -n "$EMB_CANDIDATES" ]; then
    EMBEDDING_PATH=$(echo "$EMB_CANDIDATES" | head -1)
    ok "Embedding model: $(basename "$EMBEDDING_PATH")"
else
    warn "No embedding model found in $MODELS_DIR"
    warn "RAG search will not work until you download one."
    warn "Suggested: $EMBEDDING_FILE_DEFAULT (30M params, <50MB)"
    warn "  → bash model_pull.sh --embedding"
fi

# ── Export env vars ────────────────────────────────────────────────
export SKYEAI_MODEL_PATH="$MODEL_PATH"
export SKYEAI_EMBEDDING_MODEL_PATH="$EMBEDDING_PATH"
export SKYEAI_MEMORY_PATH="$MODELS_DIR/memory.md"
export HAVEN_MODEL_PATH="$MODEL_PATH"
export HAVEN_MEMORY_PATH="$MODELS_DIR/memory.md"

# ── Cookie secret ──────────────────────────────────────────────────
COOKIE_SECRET_FILE="$SERVER_DIR/.cookie_secret"
if [ ! -f "$COOKIE_SECRET_FILE" ]; then
    python3 -c "import secrets; print(secrets.token_hex(32))" > "$COOKIE_SECRET_FILE"
    chmod 600 "$COOKIE_SECRET_FILE"
    ok "Cookie secret generated at $COOKIE_SECRET_FILE"
else
    ok "Cookie secret loaded from $COOKIE_SECRET_FILE"
fi
export SKYEAI_COOKIE_SECRET="$(cat "$COOKIE_SECRET_FILE")"

# ── Build uvicorn args ─────────────────────────────────────────────
UVICORN_ARGS=(
    "app:app"
    "--host" "$HOST"
    "--port" "$PORT"
    "--log-level" "$LOG_LEVEL"
    "--workers" "$WORKERS"
)

[ "$RELOAD" = "true" ] && UVICORN_ARGS+=("--reload") && warn "Hot-reload enabled (dev mode)"

# ── Launch info ────────────────────────────────────────────────────
step "Starting server"
echo ""
echo -e "  ${BOLD}Local:${RESET}   http://localhost:$PORT"
if [ "$HOST" = "0.0.0.0" ]; then
    LAN_IP=$(get_lan_ip)
    echo -e "  ${BOLD}Network:${RESET} http://$LAN_IP:$PORT"
fi
echo ""
echo -e "  ${BOLD}Model:${RESET}   $MODEL_FILE"
echo -e "  ${BOLD}Family:${RESET}  $MODEL_FAMILY"
echo -e "  ${BOLD}Venv:${RESET}    $VENV_DIR"
echo ""
echo -e "  Press ${BOLD}Ctrl+C${RESET} to stop"
echo ""
echo -e "${CYAN}────────────────────────────────────────────${RESET}"
echo ""

# ── Clean shutdown trap ────────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down Skye-AI...${RESET}"
    echo "Session memory preserved in server/models/"
    echo ""
}
trap cleanup INT TERM

# ── Launch ────────────────────────────────────────────────────────
cd "$SERVER_DIR"
exec "$PYTHON" -m uvicorn "${UVICORN_ARGS[@]}"
