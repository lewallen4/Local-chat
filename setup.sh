#!/usr/bin/env bash
# ============================================================
#  Haven Local AI — Setup Script
#  Run once to prepare your environment.
#  Usage: bash setup.sh
# ============================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
MODELS_DIR="$SERVER_DIR/models"
VENV_DIR="$SCRIPT_DIR/.venv"

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║           Haven Local AI Setup           ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
}

step() { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n${RED}✗ Error:${RESET} $1"; exit 1; }

# ── Prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    step "Checking prerequisites"

    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install Python 3.9+."
    PY_VERSION=$(python3 -c 'import sys; print(sys.version_info[:2])')
    ok "Python found: $(python3 --version)"

    command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1 || \
        die "pip not found. Install pip first."
    ok "pip found"

    # Check cmake (needed for llama-cpp-python build)
    if command -v cmake >/dev/null 2>&1; then
        ok "cmake found: $(cmake --version | head -1)"
    else
        warn "cmake not found — llama-cpp-python may fail to build."
        warn "  On Ubuntu/Debian: sudo apt install cmake build-essential"
        warn "  On macOS:         brew install cmake"
        warn "  On Windows:       choco install cmake"
    fi
}

# ── Virtual environment ────────────────────────────────────────────
setup_venv() {
    step "Setting up virtual environment"

    if [ -d "$VENV_DIR" ]; then
        warn "Virtual environment already exists at .venv — skipping creation."
    else
        python3 -m venv "$VENV_DIR"
        ok "Created virtual environment at .venv"
    fi

    # Activate
    # shellcheck disable=SC1091
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        VENV_ACTIVATE="$VENV_DIR/Scripts/activate"
    else
        VENV_ACTIVATE="$VENV_DIR/bin/activate"
    fi

    source "$VENV_ACTIVATE"
    ok "Virtual environment activated"

    pip install --upgrade pip --quiet
    ok "pip upgraded"
}

# ── Python dependencies ────────────────────────────────────────────
install_deps() {
    step "Installing Python dependencies"

    # Core web framework
    pip install fastapi uvicorn[standard] jinja2 python-multipart httpx aiofiles --quiet
    ok "FastAPI stack installed"

    # llama-cpp-python — try pre-built wheel first, fall back to source build
    echo "  Installing llama-cpp-python (may take a minute if building from source)..."
    if pip install llama-cpp-python --quiet 2>/dev/null; then
        ok "llama-cpp-python installed (pre-built)"
    else
        warn "Pre-built wheel failed. Building from source..."
        CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS" \
            pip install llama-cpp-python --no-cache-dir
        ok "llama-cpp-python built from source"
    fi

    # Optional: sentencepiece
    pip install sentencepiece --quiet 2>/dev/null && ok "sentencepiece installed" || \
        warn "sentencepiece skipped (optional)"
}

# ── Directory structure ────────────────────────────────────────────
setup_dirs() {
    step "Verifying directory structure"

    mkdir -p "$MODELS_DIR"
    ok "models/ directory ready"

    mkdir -p "$SERVER_DIR/sessions"
    ok "sessions/ directory ready"

    # Create memory.md if missing
    if [ ! -f "$MODELS_DIR/memory.md" ]; then
        cat > "$MODELS_DIR/memory.md" <<'EOF'
# Session Memory

## Lessons Learned

This file stores accumulated knowledge from past conversations.
Each new session will have access to this memory.

## Initial Setup
- Memory persistence enabled
- Sessions auto-summarized on close

## Guidelines
- Memories are appended automatically
- Each session gets a timestamped entry
EOF
        ok "Created models/memory.md"
    else
        ok "memory.md already exists"
    fi
}

# ── Model check ────────────────────────────────────────────────────
check_model() {
    step "Checking for model file"

    # Accept any .gguf file in models/
    GGUF_FILES=("$MODELS_DIR"/*.gguf "$MODELS_DIR"/*.model 2>/dev/null)
    FOUND=0
    for f in "${GGUF_FILES[@]}"; do
        [ -f "$f" ] && FOUND=1 && ok "Model found: $(basename "$f")" && break
    done

    if [ "$FOUND" -eq 0 ]; then
        echo ""
        echo -e "  ${YELLOW}⚠  No model file found in server/models/${RESET}"
        echo ""
        echo "  Download a GGUF model and place it at:"
        echo "  → $MODELS_DIR/model.gguf"
        echo ""
        echo "  Recommended options (small & fast on CPU):"
        echo ""
        echo "  1) TinyLlama 1.1B (Q4, ~660 MB):"
        echo "     https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF"
        echo "     File: tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
        echo ""
        echo "  2) Phi-2 (Q4, ~1.5 GB):"
        echo "     https://huggingface.co/TheBloke/phi-2-GGUF"
        echo "     File: phi-2.Q4_K_M.gguf"
        echo ""
        echo "  3) Mistral 7B Instruct (Q4, ~4 GB):"
        echo "     https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF"
        echo "     File: mistral-7b-instruct-v0.2.Q4_0.gguf"
        echo ""
        echo "  After downloading, rename or update MODEL_FILE in run.sh."
    fi
}

# ── Write activation helper ────────────────────────────────────────
write_env_helper() {
    step "Writing environment activation helper"
    cat > "$SCRIPT_DIR/.env.sh" <<EOF
#!/usr/bin/env bash
# Source this to activate Haven's environment:  source .env.sh
source "$VENV_ACTIVATE"
export PYTHONPATH="$SERVER_DIR:\$PYTHONPATH"
echo "Haven environment active. Run: bash run.sh"
EOF
    chmod +x "$SCRIPT_DIR/.env.sh"
    ok "Created .env.sh — source it to activate the environment manually"
}

# ── Done ───────────────────────────────────────────────────────────
finish() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║            Setup complete! ✓             ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  Next steps:"
    echo "  1. Place your .gguf model in server/models/"
    echo "  2. Edit MODEL_FILE in run.sh if the filename differs"
    echo "  3. Run:  bash run.sh"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────
banner
check_prereqs
setup_venv
install_deps
setup_dirs
check_model
write_env_helper
finish
