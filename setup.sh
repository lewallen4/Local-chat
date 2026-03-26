#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Environment Setup
#  Safe to re-run at any time. Self-healing — detects and
#  offers to install any missing system dependencies before
#  proceeding. Never requires a manual retry.
#  Usage: bash setup.sh
# ============================================================

# Note: we intentionally do NOT use set -e here so that
# individual failures can be caught and recovered from
# rather than aborting the whole script.
set -uo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
MODELS_DIR="$SERVER_DIR/models"
VENV_DIR="$HOME/.localchat-venv"

# Track whether anything failed so we can report at the end
SETUP_OK=true

# ── Helpers ────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║          Skye-AI  —  Setup               ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
}

step()    { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}   $1"; }
die()     { echo -e "\n${RED}✗ Fatal:${RESET} $1\n"; exit 1; }
fail()    { echo -e "  ${RED}✗${RESET}  $1"; SETUP_OK=false; }
ask()     { read -rp "    → $1 (y/N): " _REPLY; [[ "$_REPLY" =~ ^[Yy]$ ]]; }

# Detect the system package manager once
detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    elif command -v brew >/dev/null 2>&1; then
        PM="brew"
    else
        PM="unknown"
    fi
}

# Install a system package, prompting first
install_pkg() {
    local DESC="$1"
    local APT_PKG="${2:-}"
    local DNF_PKG="${3:-$APT_PKG}"
    local BREW_PKG="${4:-$APT_PKG}"

    warn "$DESC is not installed."
    if ask "Attempt to install it now?"; then
        echo ""
        case "$PM" in
            apt)
                sudo apt-get update -qq && sudo apt-get install -y $APT_PKG \
                    && ok "$DESC installed successfully." \
                    || { fail "Failed to install $DESC via apt."; return 1; }
                ;;
            dnf)
                sudo dnf install -y $DNF_PKG \
                    && ok "$DESC installed successfully." \
                    || { fail "Failed to install $DESC via dnf."; return 1; }
                ;;
            yum)
                sudo yum install -y $DNF_PKG \
                    && ok "$DESC installed successfully." \
                    || { fail "Failed to install $DESC via yum."; return 1; }
                ;;
            brew)
                brew install $BREW_PKG \
                    && ok "$DESC installed successfully." \
                    || { fail "Failed to install $DESC via brew."; return 1; }
                ;;
            *)
                fail "No supported package manager found. Please install $DESC manually."
                return 1
                ;;
        esac
    else
        fail "$DESC skipped. Some steps may not complete successfully."
        return 1
    fi
}

# ── Prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    step "Checking prerequisites"
    detect_pm

    # ── Python 3 ──────────────────────────────────────────────────
    if command -v python3 >/dev/null 2>&1; then
        ok "Python found: $(python3 --version)"
    else
        install_pkg "Python 3" "python3 python3-dev" "python3 python3-devel" "python3" \
            || die "Python 3 is required and could not be installed. Please install it manually and re-run."
    fi

    # ── pip ───────────────────────────────────────────────────────
    if python3 -m pip --version >/dev/null 2>&1; then
        ok "pip found: $(python3 -m pip --version | cut -d' ' -f1-2)"
    else
        warn "pip is not available for python3."
        if ask "Attempt to install pip now?"; then
            echo ""
            # Try ensurepip first (built into Python 3.4+)
            if python3 -m ensurepip --upgrade 2>/dev/null; then
                ok "pip installed via ensurepip."
            else
                # Fall back to get-pip.py
                warn "ensurepip unavailable. Trying get-pip.py..."
                if command -v curl >/dev/null 2>&1; then
                    curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
                        && python3 /tmp/get-pip.py \
                        && rm -f /tmp/get-pip.py \
                        && ok "pip installed via get-pip.py." \
                        || install_pkg "pip" \
                               "python3-pip" \
                               "python3-pip" \
                               "python3-pip"
                else
                    install_pkg "pip" "python3-pip" "python3-pip" "python3-pip" \
                        || fail "pip could not be installed. Dependency installation will fail."
                fi
            fi
        else
            fail "pip skipped. Python dependencies cannot be installed."
        fi
    fi

    # ── python3-venv ──────────────────────────────────────────────
    if python3 -m venv --help >/dev/null 2>&1; then
        ok "python3-venv available"
    else
        install_pkg "python3-venv" \
            "python3-venv python3-full" \
            "python3-virtualenv" \
            "python3" \
            || fail "python3-venv unavailable. Virtual environment creation will fail."
    fi

    # ── cmake ─────────────────────────────────────────────────────
    if command -v cmake >/dev/null 2>&1; then
        ok "cmake found: $(cmake --version | head -1)"
    else
        install_pkg "cmake (required for llama-cpp-python)" \
            "cmake build-essential" \
            "cmake gcc-c++ make" \
            "cmake" \
            || warn "cmake not installed. llama-cpp-python will attempt a pre-built wheel instead."
    fi
}

# ── Virtual environment ────────────────────────────────────────────
setup_venv() {
    step "Setting up virtual environment"

    # ── Create venv if missing ─────────────────────────────────────
    if [ ! -d "$VENV_DIR" ]; then
        if python3 -m venv "$VENV_DIR"; then
            ok "Created virtualenv at $VENV_DIR"
        else
            die "Failed to create virtualenv at $VENV_DIR. Check that python3-venv is installed."
        fi
    else
        ok "Reusing existing virtualenv at $VENV_DIR"
    fi

    # ── Verify pip exists inside the venv ─────────────────────────
    # A venv can be created without pip if ensurepip is missing on the
    # system. Detect this and repair it before proceeding.
    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"

    if [ ! -f "$PIP" ]; then
        warn "pip is missing from the virtualenv (was it created without it?)."
        if ask "Attempt to bootstrap pip into the virtualenv now?"; then
            echo ""
            # Try ensurepip directly into the venv
            if "$PYTHON" -m ensurepip --upgrade 2>/dev/null; then
                ok "pip bootstrapped into virtualenv via ensurepip."
            elif command -v curl >/dev/null 2>&1; then
                warn "ensurepip unavailable. Trying get-pip.py..."
                curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
                    && "$PYTHON" /tmp/get-pip.py \
                    && rm -f /tmp/get-pip.py \
                    && ok "pip installed into virtualenv via get-pip.py." \
                    || die "Could not bootstrap pip into the virtualenv. Try deleting $VENV_DIR and re-running setup.sh."
            else
                die "Cannot bootstrap pip — curl is not available. Delete $VENV_DIR and re-run after installing pip system-wide."
            fi
        else
            die "pip is required inside the virtualenv. Cannot continue without it."
        fi
    fi

    # ── Upgrade pip ───────────────────────────────────────────────
    if "$PIP" install --upgrade pip --quiet; then
        ok "pip upgraded"
    else
        warn "pip upgrade failed — continuing with existing version."
    fi
}

# ── Python dependencies ────────────────────────────────────────────
install_deps() {
    step "Installing Python dependencies"

    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"

    if "$PIP" install --upgrade \
            fastapi \
            "uvicorn[standard]" \
            "jinja2>=3.1.4" \
            "python-multipart>=0.0.9" \
            "httpx>=0.27.0" \
            aiofiles \
            --quiet; then
        ok "FastAPI stack installed"
    else
        fail "FastAPI stack installation failed. Check your network connection."
    fi

    # llama-cpp-python — skip if already importable
    if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
        ok "llama-cpp-python already installed — skipping"
    else
        echo ""
        echo -e "  Installing llama-cpp-python..."
        echo -e "  ${YELLOW}This may take several minutes if building from source.${RESET}"
        echo ""
        if "$PIP" install llama-cpp-python --quiet 2>/dev/null; then
            ok "llama-cpp-python installed (pre-built wheel)"
        else
            warn "Pre-built wheel unavailable — building from source."
            warn "cmake and a C++ compiler are required for this step."
            echo ""
            if CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS" \
                    "$PIP" install llama-cpp-python --no-cache-dir; then
                ok "llama-cpp-python built and installed from source"
            else
                fail "llama-cpp-python installation failed."
                warn "Ensure cmake and build-essential (or gcc-c++) are installed, then re-run."
            fi
        fi
    fi

    if "$PIP" install sentencepiece --quiet 2>/dev/null; then
        ok "sentencepiece installed"
    else
        warn "sentencepiece skipped (optional — not required for core functionality)"
    fi
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
# Local-chat Memory

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
        echo "  Run the model acquisition utility to download one:"
        echo "  → bash model_pull.sh"
        echo ""
    fi
}

# ── Done ───────────────────────────────────────────────────────────
finish() {
    echo ""
    if [ "$SETUP_OK" = true ]; then
        echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
        echo -e "${GREEN}${BOLD}║           Setup complete!  ✓             ║${RESET}"
        echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
        echo ""
        echo "  Virtualenv: $VENV_DIR"
        echo ""
        echo "  Next steps:"
        echo "  1. Run:  bash model_pull.sh   (to download a model)"
        echo "  2. Run:  bash run.sh           (to start the server)"
    else
        echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}${BOLD}║      Setup completed with warnings  ⚠    ║${RESET}"
        echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════╝${RESET}"
        echo ""
        echo "  One or more steps did not complete successfully."
        echo "  Review the warnings above, resolve any issues,"
        echo "  and re-run:  bash setup.sh"
        echo ""
        echo "  The script is safe to re-run — completed steps"
        echo "  will be skipped automatically."
    fi
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────
banner
check_prereqs
setup_venv
install_deps
setup_dirs
check_model
finish
