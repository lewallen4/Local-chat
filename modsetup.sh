#!/usr/bin/env bash
# ============================================================
#  Local Chat LLM — Setup Script (system‑wide pip3 version)
#  Run once to prepare your environment.
#  Usage: sudo bash setup.sh
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

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        Local Chat LLM — Setup            ║${RESET}"
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
    ok "Python found: $(python3 --version)"

    # Check that pip3 is available
    command -v pip3 >/dev/null 2>&1 || die "pip3 not found. Install pip for Python 3."
    ok "pip3 found: $(pip3 --version)"

    if command -v cmake >/dev/null 2>&1; then
        ok "cmake found: $(cmake --version | head -1)"
    else
        warn "cmake not found — llama-cpp-python may fail to build."
        warn "  On RHEL: sudo dnf install cmake gcc-c++"
    fi
}

# ── Python dependencies ────────────────────────────────────────────
install_deps() {
    step "Installing Python dependencies system‑wide"

    # Upgrade pip itself (system-wide because of sudo)
    pip3 install --upgrade pip --quiet
    ok "pip upgraded"

    pip3 install fastapi "uvicorn[standard]" jinja2 python-multipart httpx aiofiles --quiet
    ok "FastAPI stack installed"

    # Only build llama-cpp-python if it isn't already importable
    if python3 -c "import llama_cpp" 2>/dev/null; then
        ok "llama-cpp-python already installed — skipping"
    else
        echo "  Installing llama-cpp-python (building from source, please wait)..."
        if pip3 install llama-cpp-python --quiet 2>/dev/null; then
            ok "llama-cpp-python installed (pre‑built wheel)"
        else
            warn "Pre‑built wheel unavailable. Building from source..."
            CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS" \
                pip3 install llama-cpp-python --no-cache-dir
            ok "llama-cpp-python built from source"
        fi
    fi

    pip3 install sentencepiece --quiet 2>/dev/null \
        && ok "sentencepiece installed" \
        || warn "sentencepiece skipped (optional)"
}

# ── Directory structure ────────────────────────────────────────────
setup_dirs() {
    step "Verifying directory structure"

    mkdir -p "$MODELS_DIR"
    ok "server/models/ ready"

    mkdir -p "$SERVER_DIR/sessions"
    ok "server/sessions/ ready"

    if [ ! -f "$MODELS_DIR/memory.md" ]; then
        cat > "$MODELS_DIR/memory.md" << 'EOF'
# Local Chat Memory

## FACTS
<!-- Add persistent facts here. This section is never auto-modified. -->

## RECENT SESSIONS
<!-- Auto-managed. Newest entries appear first. Capped at 10 sessions. -->
EOF
        ok "Created server/models/memory.md"
    else
        ok "memory.md already exists"
    fi
}

# ── Model check ────────────────────────────────────────────────────
check_model() {
    step "Checking for model file"

    FOUND=0
    for f in "$MODELS_DIR"/*.gguf "$MODELS_DIR"/*.model; do
        [ -f "$f" ] && FOUND=1 && ok "Model found: $(basename "$f")" && break
    done

    if [ "$FOUND" -eq 0 ]; then
        echo ""
        echo -e "  ${YELLOW}⚠  No model file found in server/models/${RESET}"
        echo ""
        echo "  Download a GGUF model and place it at:"
        echo "  → $MODELS_DIR/model.gguf"
        echo ""
        echo "  Recommended options:"
        echo ""
        echo "  1) TinyLlama 1.1B Q4 (~660 MB) — fastest:"
        echo "     https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF"
        echo "     File: tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
        echo ""
        echo "  2) Phi-2 Q4 (~1.5 GB) — good middle ground:"
        echo "     https://huggingface.co/TheBloke/phi-2-GGUF"
        echo "     File: phi-2.Q4_K_M.gguf"
        echo ""
        echo "  3) Mistral 7B Q4 (~4 GB) — best quality:"
        echo "     https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF"
        echo "     File: mistral-7b-instruct-v0.2.Q4_0.gguf"
        echo ""
    fi
}

# ── Done ───────────────────────────────────────────────────────────
finish() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║           Setup complete! ✓              ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  Next steps:"
    echo "  1. Place your .gguf model in server/models/"
    echo "  2. Run:  bash run.sh"
    echo ""
    echo "  (All packages were installed system‑wide with pip3.)"
}

# ── Main ───────────────────────────────────────────────────────────
banner
check_prereqs
install_deps
setup_dirs
check_model
finish