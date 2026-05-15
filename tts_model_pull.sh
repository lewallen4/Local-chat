#!/usr/bin/env bash
# ============================================================
#  Skye-AI — TTS / STT Model Acquisition
#
#  Downloads:
#    Kokoro v1.0  — af_heart voice (American English female)
#    Whisper base — offline speech-to-text (OpenAI, ~145MB)
#
#  All models are stored locally. No cloud API keys required.
#  Usage: bash tts_model_pull.sh
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
VENV_DIR="$HOME/.skyeai-venv"
PIP="$VENV_DIR/bin/pip"
PYTHON="$VENV_DIR/bin/python"

ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n  ${RED}✗${RESET}  $1\n"; exit 1; }
step() { echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"; }

# Non-interactive safe ask
ask() {
    if [ ! -t 0 ] || [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        return 0  # Auto-yes in CI / non-interactive
    fi
    read -rp "    → $1 (y/N): " _REPLY
    [[ "$_REPLY" =~ ^[Yy]$ ]]
}

# ── Banner ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║      Skye-AI  —  TTS/STT Setup          ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Kokoro TTS (af_heart) + Whisper STT (base)${RESET}"
echo ""

# ── Check virtualenv ────────────────────────────────────────────────
step "Checking virtualenv"

if [ ! -f "$PYTHON" ]; then
    die "Virtualenv not found at $VENV_DIR. Run bash setup.sh first."
fi
ok "Virtualenv found at $VENV_DIR"

# ── Install Python packages ─────────────────────────────────────────
step "Installing Python packages"

echo -e "  ${DIM}→ kokoro, soundfile, openai-whisper, ffmpeg-python${RESET}"

"$PIP" install --upgrade kokoro soundfile --quiet \
    && ok "kokoro + soundfile installed" \
    || { warn "kokoro install failed — TTS will be unavailable"; }

# Whisper also needs ffmpeg on the system
if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found on system PATH — Whisper STT may fail"
    echo ""
    echo -e "  Install it with:"
    if command -v apt-get >/dev/null 2>&1; then
        echo -e "    sudo apt-get install -y ffmpeg"
    elif command -v brew >/dev/null 2>&1; then
        echo -e "    brew install ffmpeg"
    else
        echo -e "    Install ffmpeg for your OS (https://ffmpeg.org/download.html)"
    fi
    echo ""
fi

"$PIP" install --upgrade openai-whisper --quiet \
    && ok "openai-whisper installed" \
    || { warn "openai-whisper install failed — STT will be unavailable"; }

# numpy is needed for audio concatenation (Kokoro returns numpy arrays)
"$PIP" install --upgrade numpy --quiet \
    && ok "numpy installed" \
    || warn "numpy install failed"

# ── Download Whisper base model ─────────────────────────────────────
step "Downloading Whisper 'base' model (~145 MB)"

echo ""
echo -e "  ${DIM}Model will be cached in: ~/.cache/whisper/${RESET}"
echo ""

if [ ! -f "$HOME/.cache/whisper/base.pt" ]; then
    if ask "Download Whisper base model now?"; then
        "$PYTHON" -c "import whisper; whisper.load_model('base')" \
            && ok "Whisper base model downloaded" \
            || warn "Whisper model download failed — will retry on first server start"
    else
        warn "Skipped — model will download automatically on first server start"
    fi
else
    ok "Whisper base model already cached"
fi

# ── Kokoro voice model ──────────────────────────────────────────────
step "Checking Kokoro voice model (af_heart)"

echo ""
echo -e "  ${DIM}Kokoro downloads voice weights automatically on first use.${RESET}"
echo -e "  ${DIM}Voice: af_heart (American English female, ~300MB)${RESET}"
echo ""

if ask "Pre-download af_heart voice now? (recommended)"; then
    "$PYTHON" -c "
from kokoro import KPipeline
import sys
try:
    print('  Initialising Kokoro pipeline and downloading af_heart...')
    pipe = KPipeline(lang_code='a')
    # Run a short synthesis to force weight download
    for _, _, audio in pipe('Hello.', voice='af_heart'):
        break
    print('  Voice model ready.')
except Exception as e:
    print(f'  Warning: {e}', file=sys.stderr)
    sys.exit(1)
" && ok "af_heart voice model downloaded" \
    || warn "Voice pre-download failed — will download automatically on first TTS request"
else
    warn "Skipped — voice will download automatically on first TTS request"
fi

# ── Done ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║        TTS/STT setup complete  ✓        ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo "  TTS voice:   af_heart (Kokoro)"
echo "  STT model:   base (Whisper)"
echo ""
echo "  Both are offline — no API keys required."
echo "  Enable TTS in the Skye-AI settings panel."
echo ""
