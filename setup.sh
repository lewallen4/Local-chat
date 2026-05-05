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

# ── Receipt tracker ────────────────────────────────────────────────
# Keys are pretty labels, values are status emoji + text.
# The receipt printer reads these at the end to compose the summary.
declare -A RECEIPT
RECEIPT_ORDER=()

receipt_set() {
    local key="$1"
    local status="$2"  # "ok", "warn", "skip", "fail"
    local detail="${3:-}"
    if [ -z "${RECEIPT[$key]+set}" ]; then
        RECEIPT_ORDER+=("$key")
    fi
    RECEIPT[$key]="${status}|${detail}"
}

# Print the receipt no matter how setup ends — clean exit, die(), or Ctrl-C.
# `_RECEIPT_PRINTED` guards against double-printing when the main flow's
# explicit `finish` call runs to completion.
_RECEIPT_PRINTED=false
_print_receipt_once() {
    if [ "$_RECEIPT_PRINTED" = false ] && type finish >/dev/null 2>&1; then
        _RECEIPT_PRINTED=true
        finish
    fi
}
trap _print_receipt_once EXIT

# PYTHON_TARGET is set dynamically after resolve_python() runs.
# It will reflect whatever version was actually found/installed.
PYTHON_TARGET=""
PYTHON_BIN=""   # resolved later
PM=""           # resolved by detect_pm()

# ── Helpers ────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║         Skye-AI  —  Setup                ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""
}

step()  { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}   $1"; }
die()   {
    # Hard fatal — record in receipt, then exit. The EXIT trap will still
    # print the receipt before the shell terminates.
    receipt_set "Fatal" "fail" "$1"
    SETUP_OK=false
    echo -e "\n${RED}✗ Fatal:${RESET} $1\n"
    echo -e "${DIM}    The receipt below shows what was installed before this failure.${RESET}"
    exit 1
}
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

    local FOUND_BIN=""
    local FOUND_VER=""
    local PREFERRED_BIN=""

    # Scan installed candidates — prefer 3.12, accept 3.8+
    for candidate in python3.12 python3.11 python3.10 python3.9 python3.8 python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            local ver
            ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || continue
            local major minor
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)

            if [ "$major" = "3" ] && [ "${minor:-0}" -ge 8 ] 2>/dev/null; then
                # Track the first usable one as fallback
                if [ -z "$FOUND_BIN" ]; then
                    FOUND_BIN=$(command -v "$candidate")
                    FOUND_VER="$ver"
                fi
                # Prefer 3.12 if found
                if [ "$ver" = "3.12" ] && [ -z "$PREFERRED_BIN" ]; then
                    PREFERRED_BIN=$(command -v "$candidate")
                fi
            fi
        fi
    done

    # If we found 3.12, use it immediately
    if [ -n "$PREFERRED_BIN" ]; then
        PYTHON_BIN="$PREFERRED_BIN"
        PYTHON_TARGET="3.12"
        ok "Found Python 3.12 at $PYTHON_BIN"
        receipt_set "Python" "ok" "3.12"
        return 0
    fi

    if [ -n "$FOUND_BIN" ]; then
        # We have something usable but not 3.12
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            echo ""
            echo -e "  ${YELLOW}⚠${RESET}   Found Python ${FOUND_VER} at ${FOUND_BIN}"
            echo -e "  ${DIM}    Python 3.12 is recommended but ${FOUND_VER} may work.${RESET}"
            echo ""
            if ask "Try with your current Python ${FOUND_VER}?"; then
                PYTHON_BIN="$FOUND_BIN"
                PYTHON_TARGET="$FOUND_VER"
                ok "Using Python ${FOUND_VER} at $PYTHON_BIN"
                receipt_set "Python" "warn" "$FOUND_VER (3.12 recommended)"
                return 0
            fi
            echo ""
            if ask "Attempt to install Python 3.12 instead?"; then
                if _install_python312; then
                    return 0
                fi
                # Install failed — fall back to what we have
                warn "Python 3.12 install failed — falling back to Python ${FOUND_VER}"
                PYTHON_BIN="$FOUND_BIN"
                PYTHON_TARGET="$FOUND_VER"
                ok "Using Python ${FOUND_VER} at $PYTHON_BIN"
                return 0
            fi
            # User said no to both — use what we have
            warn "Proceeding with Python ${FOUND_VER}."
            PYTHON_BIN="$FOUND_BIN"
            PYTHON_TARGET="$FOUND_VER"
            return 0
        else
            # Non-interactive — try 3.12 first, fall back gracefully
            echo -e "  ${CYAN}→${RESET}  Non-interactive: attempting Python 3.12 install first..."
            if _install_python312; then
                return 0
            fi
            warn "Python 3.12 install failed — falling back to Python ${FOUND_VER}"
            PYTHON_BIN="$FOUND_BIN"
            PYTHON_TARGET="$FOUND_VER"
            ok "Using Python ${FOUND_VER} at $PYTHON_BIN"
            return 0
        fi
    else
        # Nothing usable found at all
        warn "No usable Python (3.8+) found on this machine."
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            if ! ask "Attempt to install Python 3.12?"; then
                receipt_set "Python" "fail" "not found, user declined install"
                die "Python is required. Install it manually and re-run."
            fi
        else
            echo -e "  ${CYAN}→${RESET}  Non-interactive: installing Python 3.12..."
        fi
        if ! _install_python312; then
            receipt_set "Python" "fail" "auto-install failed"
            die "Could not install Python. Install it manually and re-run."
        fi
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
                sudo subscription-manager repos \
                    --enable "codeready-builder-for-rhel-${RHEL_VER}-x86_64-rpms" 2>/dev/null || true
            fi
            sudo dnf config-manager --set-enabled crb 2>/dev/null || \
                sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
            sudo dnf install -y epel-release 2>/dev/null || \
                sudo dnf install -y \
                    "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VER}.noarch.rpm" \
                    2>/dev/null || true
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
            if [ -x "${bin_path:-}" ]; then
                PYTHON_BIN="$bin_path"
                PYTHON_TARGET="3.12"
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
    local INSTALL_PREFIX="$SCRIPT_DIR/.python312"

    echo ""
    echo -e "  ${CYAN}▶${RESET} ${BOLD}Building Python ${PY_VERSION} from source${RESET}"
    echo -e "  ${DIM}  Installs to: ${INSTALL_PREFIX}${RESET}"
    echo -e "  ${DIM}  This takes 5–15 minutes depending on your machine.${RESET}"
    echo ""

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

    echo -e "  ${CYAN}→${RESET}  Extracting..."
    tar -xJf "$BUILD_DIR/$PY_TARBALL" -C "$BUILD_DIR" \
        || { rm -rf "$BUILD_DIR"; return 1; }
    local SRC_DIR="$BUILD_DIR/Python-${PY_VERSION}"

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

    local CORES
    CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    echo -e "  ${CYAN}→${RESET}  Compiling with ${CORES} cores (this takes a while)..."
    make -j"$CORES" --quiet \
        || { cd /; rm -rf "$BUILD_DIR"; return 1; }

    mkdir -p "$INSTALL_PREFIX"
    echo -e "  ${CYAN}→${RESET}  Installing to ${INSTALL_PREFIX}..."
    make altinstall --quiet \
        || { cd /; rm -rf "$BUILD_DIR"; return 1; }
    ok "Python ${PY_VERSION} installed to ${INSTALL_PREFIX}"

    cd /
    rm -rf "$BUILD_DIR"
    ok "Build directory cleaned up"

    local BUILT_BIN="$INSTALL_PREFIX/bin/python3.12"
    if [ -x "$BUILT_BIN" ]; then
        PYTHON_BIN="$BUILT_BIN"
        PYTHON_TARGET="3.12"
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

    if command -v cmake >/dev/null 2>&1; then
        ok "cmake: $(cmake --version | head -1)"
    else
        install_pkg "cmake" "cmake" "cmake" "cmake" "cmake" "cmake" \
            || warn "cmake not installed. llama-cpp-python will try a pre-built wheel."
    fi

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

    if command -v curl >/dev/null 2>&1; then
        ok "curl available"
    elif command -v wget >/dev/null 2>&1; then
        ok "wget available"
    else
        install_pkg "curl" "curl" "curl" "curl" "curl" "curl" \
            || warn "Neither curl nor wget found. model_pull.sh will not work."
    fi
}

# ── Create the virtualenv — with self-healing ──────────────────────
_create_venv() {
    # First attempt — straightforward
    if "$PYTHON_BIN" -m venv "$VENV_DIR" 2>/dev/null; then
        ok "Virtualenv created at $VENV_DIR"
        receipt_set "Virtualenv" "ok" "$VENV_DIR"
        return 0
    fi

    # ensurepip / venv module is missing — install the right package and retry
    local MINOR
    MINOR=$(echo "$PYTHON_TARGET" | cut -d. -f2)
    warn "venv creation failed — attempting to install python3.${MINOR}-venv..."

    case "$PM" in
        apt)
            sudo apt-get update -qq 2>/dev/null
            sudo apt-get install -y "python3.${MINOR}-venv" 2>/dev/null \
                && ok "python3.${MINOR}-venv installed" \
                || { fail "Could not install python3.${MINOR}-venv"; return 1; }
            ;;
        dnf|yum)
            sudo "$PM" install -y "python3.${MINOR}" 2>/dev/null \
                || { fail "Could not install python3 venv support via $PM"; return 1; }
            ;;
        brew)
            # Homebrew Python always includes venv — if we're here something else is wrong
            warn "brew Python should include venv; attempting reinstall..."
            brew reinstall "python@${PYTHON_TARGET}" 2>/dev/null || true
            ;;
        *)
            fail "Unknown package manager — install python3-venv manually and re-run."
            return 1
            ;;
    esac

    # Second attempt after installing venv package
    if "$PYTHON_BIN" -m venv "$VENV_DIR" 2>/dev/null; then
        ok "Virtualenv created at $VENV_DIR (after installing venv package)"
        return 0
    fi

    # Last resort: try the virtualenv PyPI package
    if command -v virtualenv >/dev/null 2>&1; then
        virtualenv -p "$PYTHON_BIN" "$VENV_DIR" \
            && ok "Virtualenv created via 'virtualenv' at $VENV_DIR" \
            && return 0
    else
        # Try to pip-install virtualenv into the system Python and retry
        if "$PYTHON_BIN" -m pip install --user virtualenv --quiet 2>/dev/null; then
            local VENV_BIN
            VENV_BIN=$("$PYTHON_BIN" -m site --user-base 2>/dev/null)/bin/virtualenv
            if [ -x "$VENV_BIN" ]; then
                "$VENV_BIN" -p "$PYTHON_BIN" "$VENV_DIR" \
                    && ok "Virtualenv created via pip-installed virtualenv at $VENV_DIR" \
                    && return 0
            fi
        fi
    fi

    fail "All venv creation methods exhausted for Python ${PYTHON_TARGET}."
    return 1
}

# ── Virtual environment ────────────────────────────────────────────
setup_venv() {
    step "Setting up virtual environment (Python $PYTHON_TARGET)"

    if [ ! -d "$VENV_DIR" ]; then
        if ! _create_venv; then
            receipt_set "Virtualenv" "fail" "could not create"
            die "Failed to create virtualenv. See warnings above."
        fi
    else
        local venv_ver
        venv_ver=$("$VENV_DIR/bin/python" -c \
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" \
            2>/dev/null || echo "unknown")

        if [ "$venv_ver" = "$PYTHON_TARGET" ]; then
            ok "Reusing existing virtualenv at $VENV_DIR (Python $venv_ver)"
        else
            warn "Existing venv is Python $venv_ver, target is $PYTHON_TARGET. Recreating..."
            rm -rf "$VENV_DIR"
            if ! _create_venv; then
                receipt_set "Virtualenv" "fail" "recreate failed"
                die "Failed to recreate virtualenv."
            fi
        fi
    fi

    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"

    if [ ! -f "$PIP" ]; then
        warn "pip missing from virtualenv — bootstrapping..."
        bootstrap_pip "$PYTHON" \
            || { receipt_set "pip bootstrap" "fail" "could not install pip"; die "Could not bootstrap pip. Delete $VENV_DIR and re-run."; }
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
        && { ok "FastAPI stack installed"; receipt_set "FastAPI stack" "ok"; } \
        || { fail "FastAPI stack installation failed. Check your network connection."; receipt_set "FastAPI stack" "fail"; }

    # llama-cpp-python
    if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
        ok "llama-cpp-python already installed — skipping"
        receipt_set "llama-cpp-python" "ok" "already installed"
    else
        echo ""
        echo -e "  ${CYAN}→${RESET}  Installing llama-cpp-python..."
        echo -e "  ${YELLOW}This may take several minutes if building from source.${RESET}"
        echo ""
        if "$PIP" install llama-cpp-python --quiet 2>/dev/null; then
            ok "llama-cpp-python installed (pre-built wheel)"
            receipt_set "llama-cpp-python" "ok" "pre-built wheel"
        else
            warn "Pre-built wheel unavailable — building from source (requires cmake + g++)."
            echo ""
            CMAKE_ARGS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS" \
                "$PIP" install llama-cpp-python --no-cache-dir \
                && { ok "llama-cpp-python built from source"; receipt_set "llama-cpp-python" "ok" "built from source w/ OpenBLAS"; } \
                || { fail "llama-cpp-python installation failed."; \
                     warn "Ensure cmake and g++ are installed, then re-run."; \
                     receipt_set "llama-cpp-python" "fail" "build failed (need cmake + g++)"; }
        fi
    fi

    "$PIP" install sentencepiece --quiet 2>/dev/null \
        && { ok "sentencepiece installed"; receipt_set "sentencepiece" "ok"; } \
        || { warn "sentencepiece skipped (optional)"; receipt_set "sentencepiece" "skip" "optional"; }

    # numpy is required by knowledge_base.py vectorized search
    "$PIP" install "numpy>=1.26.0" --quiet 2>/dev/null \
        && { ok "numpy installed"; receipt_set "numpy" "ok"; } \
        || { fail "numpy install failed — RAG search will be slow"; receipt_set "numpy" "fail"; }

    # ── Optional: TTS + STT ────────────────────────────────────────
    echo ""
    echo -e "  ${CYAN}→${RESET}  Optional: TTS (Kokoro) + STT (Whisper)"
    echo -e "  ${DIM}     Adds voice input/output to the chat UI. ~450MB of models.${RESET}"
    echo ""

    _INSTALL_TTS=true
    if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
        if ! ask "Install voice support (TTS + STT + ffmpeg)?"; then
            _INSTALL_TTS=false
            warn "Skipped — run bash tts_model_pull.sh any time to add voice support."
            receipt_set "Voice (TTS/STT)" "skip" "user declined"
        fi
    else
        echo -e "  ${CYAN}→${RESET}  Non-interactive shell — installing TTS/STT automatically..."
    fi

    if [ "$_INSTALL_TTS" = true ]; then
        echo ""
        echo -e "  ${CYAN}→${RESET}  Installing all voice dependencies..."

        # ffmpeg — system package, install silently
        if command -v ffmpeg >/dev/null 2>&1; then
            ok "ffmpeg already installed"
            receipt_set "ffmpeg" "ok" "already installed"
        else
            case "$PM" in
                apt)
                    sudo apt-get update -qq 2>/dev/null
                    if sudo apt-get install -y ffmpeg --quiet 2>/dev/null; then
                        ok "ffmpeg installed"
                        receipt_set "ffmpeg" "ok"
                    else
                        warn "ffmpeg install failed — STT may not work. Try: sudo apt install ffmpeg"
                        receipt_set "ffmpeg" "warn" "install failed (STT will not work)"
                    fi
                    ;;
                dnf|yum)
                    if sudo "$PM" install -y ffmpeg 2>/dev/null; then
                        ok "ffmpeg installed"
                        receipt_set "ffmpeg" "ok"
                    else
                        warn "ffmpeg install failed — STT may not work."
                        receipt_set "ffmpeg" "warn" "install failed"
                    fi
                    ;;
                brew)
                    if brew install ffmpeg 2>/dev/null; then
                        ok "ffmpeg installed"
                        receipt_set "ffmpeg" "ok"
                    else
                        warn "ffmpeg install failed — STT may not work."
                        receipt_set "ffmpeg" "warn" "install failed"
                    fi
                    ;;
                *)
                    warn "Could not auto-install ffmpeg — install it manually for STT support."
                    receipt_set "ffmpeg" "warn" "no supported package manager"
                    ;;
            esac
        fi

        # Python voice packages — all in one pip call for speed
        "$PIP" install \
            kokoro \
            soundfile \
            openai-whisper \
            numpy \
            --quiet \
            && { ok "Voice packages installed (kokoro, soundfile, whisper, numpy)"; receipt_set "Voice (TTS/STT)" "ok"; } \
            || {
                warn "Batch install failed — retrying packages individually..."
                _voice_partial=true
                "$PIP" install kokoro    --quiet 2>/dev/null && ok "kokoro installed"    || { warn "kokoro install failed"; _voice_partial=false; }
                "$PIP" install soundfile --quiet 2>/dev/null && ok "soundfile installed" || { warn "soundfile install failed"; _voice_partial=false; }
                "$PIP" install openai-whisper --quiet 2>/dev/null && ok "openai-whisper installed" || { warn "openai-whisper install failed"; _voice_partial=false; }
                "$PIP" install numpy     --quiet 2>/dev/null && ok "numpy installed"     || { warn "numpy install failed"; _voice_partial=false; }
                if [ "$_voice_partial" = true ]; then
                    receipt_set "Voice (TTS/STT)" "ok" "individual installs"
                else
                    receipt_set "Voice (TTS/STT)" "warn" "some packages missing"
                fi
            }

        # Pre-cache Whisper base model now so it never downloads at runtime.
        # Without this, Whisper silently phones home to HF Hub on first use.
        echo ""
        echo -e "  ${CYAN}→${RESET}  Pre-caching Whisper 'base' model (~140 MB from openai/whisper)..."
        echo -e "  ${DIM}     This is the only external call Skye-AI makes to Hugging Face.${RESET}"
        "$PYTHON" -c "import whisper; whisper.load_model('base')" 2>/dev/null \
            && { ok "Whisper base model cached (~/.cache/whisper/)"; receipt_set "Whisper cache" "ok" "base model"; } \
            || { warn "Whisper pre-cache failed — model will download on first voice use instead."; receipt_set "Whisper cache" "warn" "deferred"; }

        ok "TTS/STT setup complete"
    fi
}

# ── Directory structure ────────────────────────────────────────────
setup_dirs() {
    step "Verifying directory structure"

    mkdir -p "$MODELS_DIR"          && ok "server/models/ ready"
    mkdir -p "$SERVER_DIR/sessions" && ok "server/sessions/ ready"
    mkdir -p "$SERVER_DIR/users"    && ok "server/users/ ready"
    receipt_set "Directories" "ok"

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

# ── Model acquisition ─────────────────────────────────────────────
# Default: IBM Granite 4.0 H Tiny (chat) + Granite Embedding 30M (RAG).
# Both are pulled from official IBM repos. Skipped if files already exist.
CHAT_MODEL_URL="https://huggingface.co/ibm-granite/granite-4.0-h-tiny-GGUF/resolve/main/granite-4.0-h-tiny-Q4_K_M.gguf"
CHAT_MODEL_FILE="model.gguf"
CHAT_MODEL_LABEL="Granite 4.0 H Tiny (Q4_K_M, ~4.4 GB)"

EMB_MODEL_URL="https://huggingface.co/lmstudio-community/granite-embedding-30m-english-GGUF/resolve/main/granite-embedding-30m-english-Q4_K_M.gguf"
EMB_MODEL_FILE="granite-embedding-30m-english.gguf"
EMB_MODEL_LABEL="Granite Embedding 30M English (~25 MB)"

_download() {
    # $1 = URL, $2 = destination path, $3 = pretty label
    local URL="$1"
    local DEST="$2"
    local LABEL="$3"

    if command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "$DEST" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress -q -O "$DEST" "$URL"
    else
        return 99
    fi
}

check_model() {
    step "Acquiring models"

    # Detect any existing chat model — accept any .gguf that isn't the embedding file
    EXISTING_CHAT=""
    for f in "$MODELS_DIR"/*.gguf; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *embedding*) continue ;;
            *) EXISTING_CHAT="$f"; break ;;
        esac
    done

    if [ -n "$EXISTING_CHAT" ]; then
        ok "Chat model present: $(basename "$EXISTING_CHAT")"
        receipt_set "Chat model" "ok" "$(basename "$EXISTING_CHAT")"
    else
        echo ""
        echo -e "  ${CYAN}→${RESET}  No chat model found. Recommended: ${BOLD}${CHAT_MODEL_LABEL}${RESET}"
        echo -e "  ${DIM}     RAG-optimized hybrid Mamba MoE — fast on CPU, validated to 128K context.${RESET}"
        echo ""
        local DO_PULL=true
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            if ! ask "Download it now? (~4.4 GB)"; then
                DO_PULL=false
                warn "Skipped chat model. Run bash gui_model_pull.sh later."
                receipt_set "Chat model" "skip" "user declined"
            fi
        else
            echo -e "  ${CYAN}→${RESET}  Non-interactive shell — downloading automatically..."
        fi

        if [ "$DO_PULL" = true ]; then
            echo ""
            if _download "$CHAT_MODEL_URL" "$MODELS_DIR/$CHAT_MODEL_FILE" "$CHAT_MODEL_LABEL"; then
                local SIZE=$(du -h "$MODELS_DIR/$CHAT_MODEL_FILE" 2>/dev/null | cut -f1)
                ok "Chat model downloaded: $CHAT_MODEL_FILE ($SIZE)"
                receipt_set "Chat model" "ok" "Granite 4.0 H Tiny"
            else
                local rc=$?
                rm -f "$MODELS_DIR/$CHAT_MODEL_FILE"
                if [ "$rc" -eq 99 ]; then
                    fail "No downloader available — install curl or wget"
                    receipt_set "Chat model" "fail" "no curl/wget"
                else
                    fail "Chat model download failed"
                    receipt_set "Chat model" "fail" "download error"
                fi
            fi
        fi
    fi

    # Embedding model
    if [ -f "$MODELS_DIR/$EMB_MODEL_FILE" ]; then
        ok "Embedding model present: $EMB_MODEL_FILE"
        receipt_set "Embedding model" "ok" "$EMB_MODEL_FILE"
    else
        echo ""
        echo -e "  ${CYAN}→${RESET}  No embedding model found. Required for RAG: ${BOLD}${EMB_MODEL_LABEL}${RESET}"
        echo ""
        local DO_PULL=true
        if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
            if ! ask "Download it now? (~25 MB, fast)"; then
                DO_PULL=false
                warn "Skipped embedding model. RAG will not work until installed."
                receipt_set "Embedding model" "skip" "user declined"
            fi
        else
            echo -e "  ${CYAN}→${RESET}  Non-interactive shell — downloading automatically..."
        fi

        if [ "$DO_PULL" = true ]; then
            echo ""
            if _download "$EMB_MODEL_URL" "$MODELS_DIR/$EMB_MODEL_FILE" "$EMB_MODEL_LABEL"; then
                ok "Embedding model downloaded: $EMB_MODEL_FILE"
                receipt_set "Embedding model" "ok" "Granite Embedding 30M"
            else
                rm -f "$MODELS_DIR/$EMB_MODEL_FILE"
                fail "Embedding model download failed"
                receipt_set "Embedding model" "fail" "download error"
            fi
        fi
    fi
}

# ── Receipt ────────────────────────────────────────────────────────
# Prints a cute itemized receipt of everything that was attempted,
# with status icons and any details. Reads from the RECEIPT array
# populated throughout setup.
finish() {
    _RECEIPT_PRINTED=true
    local W=58  # receipt width

    # Decide overall status from the receipt
    local total=0 ok_count=0 warn_count=0 fail_count=0 skip_count=0
    local key status detail
    for key in "${RECEIPT_ORDER[@]}"; do
        total=$((total + 1))
        status="${RECEIPT[$key]%%|*}"
        case "$status" in
            ok)   ok_count=$((ok_count + 1)) ;;
            warn) warn_count=$((warn_count + 1)) ;;
            fail) fail_count=$((fail_count + 1)) ;;
            skip) skip_count=$((skip_count + 1)) ;;
        esac
    done

    local TIMESTAMP
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    local HOSTNAME_SHORT
    HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d. -f1)

    # ── Header ────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}      .---------------------------------------------.${RESET}"
    echo -e "${CYAN}${BOLD}     ( ~ ~ ~ ~ ~ ~  Skye-AI  ~ ~ ~ ~ ~ ~ ~ ~ ~ ~  )${RESET}"
    echo -e "${CYAN}${BOLD}      \`---------------------------------------------'${RESET}"
    echo -e "${DIM}                ☕  setup receipt  ☕${RESET}"
    echo -e "${DIM}                  ${TIMESTAMP}${RESET}"
    if [ -n "$HOSTNAME_SHORT" ]; then
        echo -e "${DIM}                  host: ${HOSTNAME_SHORT}${RESET}"
    fi
    echo ""
    echo -e "${DIM}      ─────────────────────────────────────────${RESET}"

    # ── Itemized list ─────────────────────────────────
    for key in "${RECEIPT_ORDER[@]}"; do
        status="${RECEIPT[$key]%%|*}"
        detail="${RECEIPT[$key]#*|}"

        local icon color label_text
        case "$status" in
            ok)   icon="✓"; color="$GREEN";  label_text="installed" ;;
            warn) icon="!"; color="$YELLOW"; label_text="warning  " ;;
            fail) icon="✗"; color="$RED";    label_text="failed   " ;;
            skip) icon="-"; color="$DIM";    label_text="skipped  " ;;
            *)    icon="?"; color="$DIM";    label_text="unknown  " ;;
        esac

        # Compose: " icon  Label .................. status"
        local left="  ${color}${icon}${RESET}  ${BOLD}${key}${RESET}"
        local right="${color}${label_text}${RESET}"

        # Compute padding for dot-leader between label and status
        local plain_left_len=$(( ${#key} + 5 ))   # "  X  " = 5 chars
        local plain_right_len=9                    # status word
        local dots_len=$(( W - plain_left_len - plain_right_len - 2 ))
        [ "$dots_len" -lt 2 ] && dots_len=2
        local dots=""
        local i
        for i in $(seq 1 $dots_len); do dots="${dots}."; done

        echo -e "${left} ${DIM}${dots}${RESET} ${right}"

        if [ -n "$detail" ]; then
            echo -e "      ${DIM}↳ ${detail}${RESET}"
        fi
    done

    echo -e "${DIM}      ─────────────────────────────────────────${RESET}"

    # ── Totals ────────────────────────────────────────
    printf "      ${BOLD}%-12s${RESET} ${GREEN}%2d${RESET} ok   ${YELLOW}%2d${RESET} warn   ${RED}%2d${RESET} fail   ${DIM}%2d skip${RESET}\n" \
        "subtotal:" "$ok_count" "$warn_count" "$fail_count" "$skip_count"
    echo ""

    # ── Footer ────────────────────────────────────────
    if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}      ┌─────────────────────────────────────────┐${RESET}"
        echo -e "${GREEN}${BOLD}      │  all good — start the server: ${RESET}${DIM}bash run.sh${RESET}${GREEN}${BOLD}  │${RESET}"
        echo -e "${GREEN}${BOLD}      └─────────────────────────────────────────┘${RESET}"
        echo ""
        echo -e "${DIM}                 ♡  thanks for setting up  ♡${RESET}"
    elif [ "$fail_count" -eq 0 ]; then
        echo -e "${YELLOW}${BOLD}      ┌─────────────────────────────────────────┐${RESET}"
        echo -e "${YELLOW}${BOLD}      │  ready, with caveats — see warnings    │${RESET}"
        echo -e "${YELLOW}${BOLD}      └─────────────────────────────────────────┘${RESET}"
        echo ""
        echo -e "${DIM}        Start anyway:  bash run.sh${RESET}"
        echo -e "${DIM}        Re-run setup:  bash setup.sh${RESET}"
    else
        echo -e "${RED}${BOLD}      ┌─────────────────────────────────────────┐${RESET}"
        echo -e "${RED}${BOLD}      │  some steps failed — check the list    │${RESET}"
        echo -e "${RED}${BOLD}      └─────────────────────────────────────────┘${RESET}"
        echo ""
        echo -e "${DIM}        Re-run after fixing:  bash setup.sh${RESET}"
    fi
    echo ""

    # Internal flag stays in sync with what the receipt shows
    if [ "$fail_count" -gt 0 ]; then
        SETUP_OK=false
    fi
}

# ── Progress bar ───────────────────────────────────────────────────
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
TOTAL_STEPS=7

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
progress 6 $TOTAL_STEPS "models ready"

progress 7 $TOTAL_STEPS "complete"
finish
