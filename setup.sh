#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Environment Setup
#  Safe to re-run at any time. Self-healing — detects missing
#  system dependencies and prompts before installing them.
#
#  Supports: Ubuntu/Debian, RHEL/CentOS/Fedora, macOS (brew)
#  Usage: bash setup.sh
# ============================================================

set -uo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
MODELS_DIR="$SERVER_DIR/models"
VENV_DIR="$HOME/.skyeai-venv"
SETUP_OK=true

PYTHON_TARGET="3.12"
PYTHON_BIN=""   # resolved later

# ── Helpers ────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║         Skye-AI  —  Setup             ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
}

step()  { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}   $1"; }
die()   { echo -e "\n${RED}✗ Fatal:${RESET} $1\n"; exit 1; }
fail()  { echo -e "  ${RED}✗${RESET}  $1"; SETUP_OK=false; }
ask()   { 
    if [ ! -t 0 ] || [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        return 0  # Auto-yes in CI / non-interactive shells
    fi
    read -rp "    → $1 (y/N): " _REPLY; [[ "$_REPLY" =~ ^[Yy]$ ]]
}

# ── Package manager detection ──────────────────────────────────────
detect_pm() {
    if   command -v apt-get >/dev/null 2>&1; then PM="apt"
    elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
    elif command -v yum     >/dev/null 2>&1; then PM="yum"
    elif command -v brew    >/dev/null 2>&1; then PM="brew"
    elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
    elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
    else PM="unknown"
    fi
    ok "Package manager: $PM"
}

# ── Install a system package (prompts first) ───────────────────────
install_pkg() {
    local DESC="$1"
    local APT_PKG="${2:-}"
    local DNF_PKG="${3:-$APT_PKG}"
    local BREW_PKG="${4:-$APT_PKG}"
    local ZYPPER_PKG="${5:-$DNF_PKG}"
    local PACMAN_PKG="${6:-$APT_PKG}"

    warn "$DESC is not installed."
    if [ -t 0 ]; then
        # Interactive — ask first
        if ! ask "Attempt to install it now?"; then
            fail "$DESC skipped. Some steps may not complete."
            return 1
        fi
    else
        echo -e "  ${CYAN}→${RESET}  Non-interactive environment — installing $DESC automatically..."
    fi

    echo ""
    case "$PM" in
        apt)
            sudo apt-get update -qq \
                && sudo apt-get install -y $APT_PKG \
                && ok "$DESC installed." \
                || { fail "apt install failed for: $APT_PKG"; return 1; }
            ;;
        dnf)
            sudo dnf install -y $DNF_PKG \
                && ok "$DESC installed." \
                || { fail "dnf install failed for: $DNF_PKG"; return 1; }
            ;;
        yum)
            sudo yum install -y $DNF_PKG \
                && ok "$DESC installed." \
                || { fail "yum install failed for: $DNF_PKG"; return 1; }
            ;;
        brew)
            brew install $BREW_PKG \
                && ok "$DESC installed." \
                || { fail "brew install failed for: $BREW_PKG"; return 1; }
            ;;
        zypper)
            sudo zypper install -y $ZYPPER_PKG \
                && ok "$DESC installed." \
                || { fail "zypper install failed for: $ZYPPER_PKG"; return 1; }
            ;;
        pacman)
            sudo pacman -S --noconfirm $PACMAN_PKG \
                && ok "$DESC installed." \
                || { fail "pacman install failed for: $PACMAN_PKG"; return 1; }
            ;;
        *)
            fail "No supported package manager found. Install $DESC manually then re-run."
            return 1
            ;;
    esac
}

# ── Bootstrap pip into a python binary ────────────────────────────
bootstrap_pip() {
    local PY="$1"

    # 1. ensurepip
    if "$PY" -m ensurepip --upgrade 2>/dev/null; then
        ok "pip bootstrapped via ensurepip."
        return 0
    fi

    # 2. get-pip.py
    warn "ensurepip unavailable — trying get-pip.py..."
    local GET_PIP="/tmp/get-pip-$$.py"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$GET_PIP" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q https://bootstrap.pypa.io/get-pip.py -O "$GET_PIP" 2>/dev/null
    fi

    if [ -f "$GET_PIP" ]; then
        "$PY" "$GET_PIP" 2>/dev/null && rm -f "$GET_PIP" \
            && ok "pip installed via get-pip.py." \
            && return 0
        rm -f "$GET_PIP"
    fi

    # 3. System package
    install_pkg "pip" "python3-pip" "python3-pip" "python3-pip" "python3-pip" "python-pip" \
        && return 0

    return 1
}

# ── Resolve Python ────────────────────────────────────────────────
resolve_python() {
    step "Resolving Python"

    # ── Detect what's currently installed ─────────────────────────
    local FOUND_BIN=""
    local FOUND_VER=""

    for candidate in python3 python python3.12 python3.11 python3.10; do
        if command -v "$candidate" >/dev/null 2>&1; then
            local ver
            ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            local major minor
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)
            # Accept Python 3.8 or higher
            if [ "$major" = "3" ] && [ "${minor:-0}" -ge 8 ] 2>/dev/null; then
                if [ -z "$FOUND_BIN" ]; then
                    FOUND_BIN=$(command -v "$candidate")
                    FOUND_VER="$ver"
                fi
            fi
            # Prefer 3.12 if found
            if [ "$ver" = "3.12" ]; then
                PYTHON_BIN=$(command -v "$candidate")
                ok "Found Python $ver at $PYTHON_BIN"
                return 0
            fi
        fi
    done

    # ── Decision logic ─────────────────────────────────────────────
    if [ -n "$FOUND_BIN" ]; then
        # We have a usable Python but not 3.12
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            # Interactive — ask what to do
            echo ""
            echo -e "  ${YELLOW}⚠${RESET}   Found Python ${FOUND_VER} at ${FOUND_BIN}"
            echo -e "  ${DIM}    Python 3.12 is recommended but ${FOUND_VER} may work.${RESET}"
            echo ""
            if ask "Try with your current Python ${FOUND_VER}?"; then
                PYTHON_BIN="$FOUND_BIN"
                ok "Using Python ${FOUND_VER} at $PYTHON_BIN"
                return 0
            fi
            echo ""
            if ask "Attempt to install Python 3.12 instead?"; then
                _install_python312
                return $?
            fi
            # User said no to both — use what we have
            warn "Proceeding with Python ${FOUND_VER}. Things may or may not work."
            PYTHON_BIN="$FOUND_BIN"
            return 0
        else
            # Non-interactive — try 3.12 first, fall back to whatever is installed
            echo -e "  ${CYAN}→${RESET}  Non-interactive: attempting Python 3.12 install first..."
            if _install_python312; then
                return 0
            fi
            # 3.12 install failed — fall back to current version
            warn "Python 3.12 install failed — falling back to Python ${FOUND_VER}"
            PYTHON_BIN="$FOUND_BIN"
            ok "Using Python ${FOUND_VER} at $PYTHON_BIN"
            return 0
        fi
    else
        # Nothing usable found at all
        warn "No usable Python found on this machine."
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            if ! ask "Attempt to install Python 3.12?"; then
                die "Python is required. Install it manually and re-run."
            fi
        else
            echo -e "  ${CYAN}→${RESET}  Non-interactive: installing Python 3.12..."
        fi
        _install_python312 || die "Could not install Python. Install it manually and re-run."
        return 0
    fi
}


# ── Install Python 3.12 via package manager, then source fallback ──
_install_python312() {
    local _pm_success=false
    echo ""

    case "$PM" in
        apt)
            sudo apt-get update -qq 2>/dev/null
            if sudo apt-get install -y python3.12 python3.12-venv python3.12-dev 2>/dev/null; then
                ok "Python 3.12 installed via apt."
                _pm_success=true
            else
                warn "apt install failed — will try source build."
            fi
            ;;
        dnf)
            local RHEL_VER
            RHEL_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "0")
            if command -v subscription-manager >/dev/null 2>&1; then
                sudo subscription-manager repos --enable "codeready-builder-for-rhel-${RHEL_VER}-x86_64-rpms" 2>/dev/null || true
            fi
            sudo dnf config-manager --set-enabled crb 2>/dev/null || \
                sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
            sudo dnf install -y epel-release 2>/dev/null || \
                sudo dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VER}.noarch.rpm" 2>/dev/null || true
            sudo dnf update -y 2>/dev/null || true
            if sudo dnf install -y python3.12 python3.12-devel 2>/dev/null \
                || sudo dnf install -y python3.12 2>/dev/null; then
                ok "Python 3.12 installed via dnf."
                _pm_success=true
            else
                warn "dnf install failed — will try source build."
            fi
            ;;
        yum)
            local RHEL_VER
            RHEL_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "0")
            sudo yum install -y epel-release 2>/dev/null || true
            if sudo yum install -y python3.12 python3.12-devel 2>/dev/null; then
                ok "Python 3.12 installed via yum."
                _pm_success=true
            else
                warn "yum install failed — will try source build."
            fi
            ;;
        brew)
            if brew install python@3.12 2>/dev/null; then
                ok "Python 3.12 installed via brew."
                _pm_success=true
            else
                warn "brew install failed — will try source build."
            fi
            ;;
        *)
            warn "No supported package manager — will try source build."
            ;;
    esac

    # Re-check PATH after package manager attempt
    if [ "$_pm_success" = true ]; then
        for bin_path in \
            "$(command -v python3.12 2>/dev/null)" \
            /usr/bin/python3.12 \
            /opt/homebrew/bin/python3.12; do
            if [ -x "$bin_path" ]; then
                PYTHON_BIN="$bin_path"
                ok "Python 3.12 ready at $PYTHON_BIN"
                return 0
            fi
        done
        warn "Package manager reported success but binary not found — trying source build."
    fi

    # Source build as last resort
    _build_python_from_source
    return $?
}


# ── Build Python 3.12.13 from source ──────────────────────────────
_build_python_from_source() {
    local PY_VERSION="3.12.13"
    local PY_TARBALL="Python-${PY_VERSION}.tar.xz"
    local PY_URL="https://www.python.org/ftp/python/${PY_VERSION}/${PY_TARBALL}"
    local BUILD_DIR="/tmp/python-src-$$"
    local INSTALL_PREFIX="$SCRIPT_DIR/.python312"   # project-local, never touches the OS

    echo ""
    echo -e "  ${CYAN}▶${RESET} ${BOLD}Building Python ${PY_VERSION} from source${RESET}"
    echo -e "  ${DIM}  Installs to: ${INSTALL_PREFIX}${RESET}"
    echo -e "  ${DIM}  This takes 5–15 minutes depending on your machine.${RESET}"
    echo ""

    # Install build dependencies (system packages only — compilers/headers, not Python itself)
    echo -e "  ${CYAN}→${RESET}  Installing build dependencies..."
    case "$PM" in
        apt)
            sudo apt-get install -y \
                build-essential gcc make \
                zlib1g-dev libffi-dev libssl-dev \
                libbz2-dev libreadline-dev libsqlite3-dev \
                liblzma-dev libncurses-dev uuid-dev \
                --quiet 2>/dev/null \
                && ok "Build deps installed" \
                || warn "Some build deps may be missing — continuing anyway"
            ;;
        dnf|yum)
            sudo "${PM}" install -y \
                gcc make \
                zlib-devel libffi-devel openssl-devel \
                bzip2-devel readline-devel sqlite-devel \
                xz-devel ncurses-devel uuid-devel \
                2>/dev/null \
                && ok "Build deps installed" \
                || warn "Some build deps may be missing — continuing anyway"
            ;;
        brew)
            brew install openssl readline xz zlib 2>/dev/null \
                && ok "Build deps installed" \
                || warn "Some brew deps may be missing — continuing anyway"
            ;;
    esac

    # Download
    mkdir -p "$BUILD_DIR"
    echo -e "  ${CYAN}→${RESET}  Downloading ${PY_TARBALL}..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$BUILD_DIR/$PY_TARBALL" "$PY_URL" \
            || { rm -rf "$BUILD_DIR"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$BUILD_DIR/$PY_TARBALL" "$PY_URL" \
            || { rm -rf "$BUILD_DIR"; return 1; }
    else
        warn "Neither curl nor wget found — cannot download Python source."
        rm -rf "$BUILD_DIR"
        return 1
    fi
    ok "Downloaded ${PY_TARBALL}"

    # Extract
    echo -e "  ${CYAN}→${RESET}  Extracting..."
    tar -xJf "$BUILD_DIR/$PY_TARBALL" -C "$BUILD_DIR" \
        || { rm -rf "$BUILD_DIR"; return 1; }
    local SRC_DIR="$BUILD_DIR/Python-${PY_VERSION}"

    # Configure — prefix is project-local, rpath baked in so shared lib is found at runtime
    echo -e "  ${CYAN}→${RESET}  Configuring..."
    cd "$SRC_DIR"
    ./configure \
        --prefix="$INSTALL_PREFIX" \
        --enable-optimizations \
        --with-ensurepip=install \
        --enable-shared \
        LDFLAGS="-Wl,-rpath,${INSTALL_PREFIX}/lib" \
        --quiet \
        || { cd /; rm -rf "$BUILD_DIR"; return 1; }

    # Build
    local CORES
    CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    echo -e "  ${CYAN}→${RESET}  Compiling with ${CORES} cores (this takes a while)..."
    make -j"$CORES" --quiet \
        || { cd /; rm -rf "$BUILD_DIR"; return 1; }

    # Install — no sudo needed since we own the project directory
    mkdir -p "$INSTALL_PREFIX"
    echo -e "  ${CYAN}→${RESET}  Installing to ${INSTALL_PREFIX}..."
    make altinstall --quiet \
        || { cd /; rm -rf "$BUILD_DIR"; return 1; }
    ok "Python ${PY_VERSION} installed to ${INSTALL_PREFIX}"

    # Cleanup
    cd /
    rm -rf "$BUILD_DIR"
    ok "Build directory cleaned up"

    # Verify
    local BUILT_BIN="$INSTALL_PREFIX/bin/python3.12"
    if [ -x "$BUILT_BIN" ]; then
        PYTHON_BIN="$BUILT_BIN"
        ok "Python 3.12 ready at $PYTHON_BIN"
        return 0
    fi

    warn "Source build completed but binary not found at $BUILT_BIN"
    return 1
}


# ── Prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    step "Checking prerequisites"
    detect_pm

    # cmake
    if command -v cmake >/dev/null 2>&1; then
        ok "cmake: $(cmake --version | head -1)"
    else
        install_pkg "cmake" "cmake" "cmake" "cmake" "cmake" "cmake" \
            || warn "cmake not installed. llama-cpp-python will try a pre-built wheel."
    fi

    # C++ compiler
    if command -v g++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; then
        local CXX_VER
        CXX_VER=$(g++ --version 2>/dev/null | head -1 || c++ --version 2>/dev/null | head -1)
        ok "C++ compiler: $CXX_VER"
    else
        install_pkg "g++ / C++ compiler" \
            "g++ build-essential" \
            "gcc-c++ make" \
            "gcc" \
            "gcc-c++ make" \
            "gcc" \
            || warn "C++ compiler not installed. llama-cpp-python source build will fail."
    fi

    # curl or wget
    if command -v curl >/dev/null 2>&1; then
        ok "curl available"
    elif command -v wget >/dev/null 2>&1; then
        ok "wget available"
    else
        install_pkg "curl" "curl" "curl" "curl" "curl" "curl" \
            || warn "Neither curl nor wget found. model_pull.sh will not work."
    fi
}

# ── Virtual environment ────────────────────────────────────────────
setup_venv() {
    step "Setting up virtual environment (Python $PYTHON_TARGET)"

    if [ ! -d "$VENV_DIR" ]; then
        if "$PYTHON_BIN" -m venv "$VENV_DIR" 2>/dev/null; then
            ok "Virtualenv created at $VENV_DIR"
        elif command -v virtualenv >/dev/null 2>&1; then
            virtualenv -p "$PYTHON_BIN" "$VENV_DIR" \
                && ok "Virtualenv created via virtualenv at $VENV_DIR" \
                || die "Failed to create virtualenv. Check python3.12-venv is installed."
        else
            die "Failed to create virtualenv at $VENV_DIR."
        fi
    else
        local venv_ver
        venv_ver=$("$VENV_DIR/bin/python" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "unknown")
        if [ "$venv_ver" = "$PYTHON_TARGET" ]; then
            ok "Reusing existing virtualenv at $VENV_DIR (Python $venv_ver)"
        else
            warn "Existing venv is Python $venv_ver, not $PYTHON_TARGET. Recreating..."
            rm -rf "$VENV_DIR"
            "$PYTHON_BIN" -m venv "$VENV_DIR" \
                && ok "Virtualenv recreated at $VENV_DIR (Python $PYTHON_TARGET)" \
                || die "Failed to recreate virtualenv."
        fi
    fi

    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"

    if [ ! -f "$PIP" ]; then
        warn "pip missing from virtualenv — bootstrapping..."
        bootstrap_pip "$PYTHON" \
            || die "Could not bootstrap pip into the virtualenv. Delete $VENV_DIR and re-run."
    fi

    "$PIP" install --upgrade pip --quiet 2>/dev/null \
        && ok "pip upgraded" \
        || warn "pip upgrade failed — continuing with existing version."
}

# ── Python dependencies ────────────────────────────────────────────
install_deps() {
    step "Installing Python dependencies"

    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"

    "$PIP" install --upgrade \
        fastapi \
        "uvicorn[standard]" \
        "jinja2>=3.1.4" \
        "python-multipart>=0.0.9" \
        "httpx>=0.27.0" \
        aiofiles \
        itsdangerous \
        --quiet \
        && ok "FastAPI stack installed" \
        || fail "FastAPI stack installation failed. Check your network connection."

    # llama-cpp-python
    if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
        ok "llama-cpp-python already installed — skipping"
    else
        echo ""
        echo -e "  ${CYAN}→${RESET}  Installing llama-cpp-python..."
        echo -e "  ${YELLOW}This may take several minutes if building from source.${RESET}"
        echo ""
        if "$PIP" install llama-cpp-python --quiet 2>/dev/null; then
            ok "llama-cpp-python installed (pre-built wheel)"
        else
            warn "Pre-built wheel unavailable — building from source (requires cmake + g++)."
            echo ""
            CMAKE_ARGS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS" \
                "$PIP" install llama-cpp-python --no-cache-dir \
                && ok "llama-cpp-python built from source" \
                || { fail "llama-cpp-python installation failed."; \
                     warn "Ensure cmake and g++ are installed, then re-run."; }
        fi
    fi

    "$PIP" install sentencepiece --quiet 2>/dev/null \
        && ok "sentencepiece installed" \
        || warn "sentencepiece skipped (optional)"

    # ── Optional: TTS + STT ────────────────────────────────────────
    echo ""
    echo -e "  ${CYAN}→${RESET}  Optional: TTS (Kokoro) + STT (Whisper)"
    echo -e "  ${DIM}     Adds voice input/output to the chat UI. ~450MB of models.${RESET}"
    echo ""

    _INSTALL_TTS=true
    if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
        # Interactive — ask first
        if ! ask "Install TTS/STT support now?"; then
            _INSTALL_TTS=false
            warn "Skipped — run bash tts_model_pull.sh any time to add voice support."
        fi
    else
        echo -e "  ${CYAN}→${RESET}  Non-interactive shell — installing TTS/STT automatically..."
    fi

    if [ "$_INSTALL_TTS" = true ]; then

        # ffmpeg — required for Whisper STT, install before whisper
        if command -v ffmpeg >/dev/null 2>&1; then
            ok "ffmpeg already installed"
        else
            echo -e "  ${CYAN}→${RESET}  Installing ffmpeg (required for Whisper STT)..."
            if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
                if ask "Install ffmpeg now?"; then
                    install_pkg "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" \
                        && ok "ffmpeg installed" \
                        || warn "ffmpeg install failed — STT may not work. Try: sudo apt install ffmpeg"
                else
                    warn "Skipped ffmpeg — voice input will not work without it."
                fi
            else
                install_pkg "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" "ffmpeg" \
                    && ok "ffmpeg installed" \
                    || warn "ffmpeg install failed — STT may not work."
            fi
        fi

        echo -e "  ${CYAN}→${RESET}  Installing kokoro (TTS engine)..."
        "$PIP" install kokoro --quiet \
            && ok "kokoro installed" \
            || warn "kokoro install failed"

        echo -e "  ${CYAN}→${RESET}  Installing soundfile..."
        "$PIP" install soundfile --quiet \
            && ok "soundfile installed" \
            || warn "soundfile install failed"

        echo -e "  ${CYAN}→${RESET}  Installing openai-whisper (STT engine — may take a moment)..."
        "$PIP" install openai-whisper --quiet \
            && ok "openai-whisper installed" \
            || warn "openai-whisper install failed"

        echo -e "  ${CYAN}→${RESET}  Installing numpy..."
        "$PIP" install numpy --quiet \
            && ok "numpy installed" \
            || warn "numpy install failed"

        ok "TTS/STT setup complete"
    fi
}

# ── Directory structure ────────────────────────────────────────────
setup_dirs() {
    step "Verifying directory structure"

    mkdir -p "$MODELS_DIR"          && ok "server/models/ ready"
    mkdir -p "$SERVER_DIR/sessions" && ok "server/sessions/ ready"
    mkdir -p "$SERVER_DIR/users"    && ok "server/users/ ready"

    if [ ! -f "$MODELS_DIR/memory.md" ]; then
        cat > "$MODELS_DIR/memory.md" << 'EOF'
# Skye-AI Memory

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
        echo "  Run the model acquisition utility:"
        echo "  → bash model_pull.sh"
        echo ""
    fi
}

# ── Finish ─────────────────────────────────────────────────────────
finish() {
    echo ""
    if [ "$SETUP_OK" = true ]; then
        echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
        echo -e "${GREEN}${BOLD}║           Setup complete!  ✓             ║${RESET}"
        echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
        echo ""
        echo "  Python:     $PYTHON_TARGET"
        echo "  Virtualenv: $VENV_DIR"
        echo ""
        echo "  Next steps:"
        echo "  1. bash model_pull.sh   — download a model"
        echo "  2. bash run.sh          — start the server"
    else
        echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}${BOLD}║      Setup completed with warnings  ⚠    ║${RESET}"
        echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════╝${RESET}"
        echo ""
        echo "  One or more steps did not complete."
        echo "  Review the warnings above and re-run:  bash setup.sh"
        echo "  Completed steps will be skipped automatically."
    fi
    echo ""
}

# ── Progress bar ────────────────────────────────────────────────────
# Called between steps. Args: current step (1-based), total steps, label.
progress() {
    local CURRENT="$1"
    local TOTAL="$2"
    local LABEL="$3"
    local BAR_WIDTH=40
    local FILLED=$(( CURRENT * BAR_WIDTH / TOTAL ))
    local EMPTY=$(( BAR_WIDTH - FILLED ))
    local BAR=""
    local i
    for i in $(seq 1 $FILLED); do BAR="${BAR}█"; done
    for i in $(seq 1 $EMPTY);  do BAR="${BAR}░"; done
    local PCT=$(( CURRENT * 100 / TOTAL ))
    echo ""
    echo -e "  ${CYAN}${BAR}${RESET}  ${BOLD}${PCT}%${RESET}  ${DIM}${LABEL}${RESET}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────
TOTAL_STEPS=6

banner
progress 0 $TOTAL_STEPS "starting up"

check_prereqs
progress 1 $TOTAL_STEPS "prerequisites done"

resolve_python
progress 2 $TOTAL_STEPS "python resolved"

setup_venv
progress 3 $TOTAL_STEPS "virtualenv ready"

install_deps
progress 4 $TOTAL_STEPS "dependencies installed"

setup_dirs
progress 5 $TOTAL_STEPS "directories ready"

check_model
finish
progress 6 $TOTAL_STEPS "complete"
