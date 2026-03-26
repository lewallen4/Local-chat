#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Model Acquisition Utility
#  Supported: Meta (Llama), Mistral AI, IBM Granite
#  Quantization: Q4_K_M  |  Usage: bash model_pull.sh
# ============================================================

set -uo pipefail

CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/server/models"

ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n  ${RED}✗${RESET}  $1\n"; exit 1; }
gap()  { echo ""; }
line() { echo -e "${DIM}──────────────────────────────────────────────${RESET}"; }
sec()  { echo -e "\n  ${CYAN}${BOLD}$1${RESET}"; line; }
row()  { echo -e "  ${BLUE}${BOLD}[$1]${RESET} ${BOLD}$2${RESET}  ${DIM}$3  —  $4${RESET}"; }

# ── curl / wget detection ──────────────────────────────────────────
detect_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        die "Neither curl nor wget found. Please install one and re-run."
    fi
}

do_download() {
    local URL="$1"
    local DEST="$2"
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -L --progress-bar -o "$DEST" "$URL"
    else
        wget -q --show-progress -O "$DEST" "$URL"
    fi
}

# ── Model registry ─────────────────────────────────────────────────
declare -A MODEL_LABEL MODEL_SIZE MODEL_RAM MODEL_URL MODEL_OUTPUT

MODEL_LABEL=( [1]="Llama 3.2  1B"           [2]="Llama 3.2  3B"
              [3]="Llama 3.1  8B"           [4]="Llama 3.3  70B"
              [5]="Llama 4 Scout  (pt 1/2)" [6]="Llama 4 Scout  (pt 2/2)"
              [7]="Mistral  7B"             [8]="Mistral Nemo  12B"
              [9]="Mistral Small  22B"      [10]="IBM Granite  3B"
              [11]="IBM Granite  8B"        [12]="IBM Granite  34B" )

MODEL_SIZE=(  [1]="0.8 GB"  [2]="2.0 GB"  [3]="4.7 GB"   [4]="40 GB"
              [5]="49.8 GB" [6]="15.5 GB" [7]="4.1 GB"   [8]="7.1 GB"
              [9]="13 GB"   [10]="1.9 GB" [11]="4.6 GB"  [12]="20 GB" )

MODEL_RAM=(   [1]="4 GB"  [2]="8 GB"  [3]="8 GB"  [4]="48 GB"
              [5]="64 GB" [6]="64 GB" [7]="8 GB"  [8]="16 GB"
              [9]="16 GB" [10]="8 GB" [11]="8 GB" [12]="24 GB" )

MODEL_URL=(
    [1]="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    [2]="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    [3]="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    [4]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
    [5]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00001-of-00002.gguf"
    [6]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00002-of-00002.gguf"
    [7]="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
    [8]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf"
    [9]="https://huggingface.co/bartowski/Mistral-Small-Instruct-2409-GGUF/resolve/main/Mistral-Small-Instruct-2409-Q4_K_M.gguf"
    [10]="https://huggingface.co/bartowski/granite-3.0-3b-a800m-instruct-GGUF/resolve/main/granite-3.0-3b-a800m-instruct-Q4_K_M.gguf"
    [11]="https://huggingface.co/bartowski/granite-3.0-8b-instruct-GGUF/resolve/main/granite-3.0-8b-instruct-Q4_K_M.gguf"
    [12]="https://huggingface.co/bartowski/granite-34b-code-instruct-GGUF/resolve/main/granite-34b-code-instruct-Q4_K_M.gguf"
)

MODEL_OUTPUT=(
    [1]="model.gguf"  [2]="model.gguf"  [3]="model.gguf"  [4]="model.gguf"
    [5]="model-00001-of-00002.gguf"     [6]="model-00002-of-00002.gguf"
    [7]="model.gguf"  [8]="model.gguf"  [9]="model.gguf"
    [10]="model.gguf" [11]="model.gguf" [12]="model.gguf"
)

# ── Detect downloader early ────────────────────────────────────────
detect_downloader

# ── Banner ─────────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║      Skye-AI  —  Model Acquisition        ║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════╝${RESET}"
echo -e "  ${DIM}Q4_K_M  ·  via ${DOWNLOADER}  ·  → ${MODELS_DIR}${RESET}"

# ── Menu ───────────────────────────────────────────────────────────
sec "META  —  Llama"
row  1 "${MODEL_LABEL[1]}"  "${MODEL_SIZE[1]}"  "${MODEL_RAM[1]}"
row  2 "${MODEL_LABEL[2]}"  "${MODEL_SIZE[2]}"  "${MODEL_RAM[2]}"
row  3 "${MODEL_LABEL[3]}"  "${MODEL_SIZE[3]}"  "${MODEL_RAM[3]}"
row  4 "${MODEL_LABEL[4]}"  "${MODEL_SIZE[4]}"  "${MODEL_RAM[4]}"
row  5 "${MODEL_LABEL[5]}"  "${MODEL_SIZE[5]}"  "${MODEL_RAM[5]}"
row  6 "${MODEL_LABEL[6]}"  "${MODEL_SIZE[6]}"  "${MODEL_RAM[6]}"

sec "MISTRAL AI"
row  7 "${MODEL_LABEL[7]}"  "${MODEL_SIZE[7]}"  "${MODEL_RAM[7]}"
row  8 "${MODEL_LABEL[8]}"  "${MODEL_SIZE[8]}"  "${MODEL_RAM[8]}"
row  9 "${MODEL_LABEL[9]}"  "${MODEL_SIZE[9]}"  "${MODEL_RAM[9]}"

sec "IBM  —  Granite"
row 10 "${MODEL_LABEL[10]}" "${MODEL_SIZE[10]}" "${MODEL_RAM[10]}"
row 11 "${MODEL_LABEL[11]}" "${MODEL_SIZE[11]}" "${MODEL_RAM[11]}"
row 12 "${MODEL_LABEL[12]}" "${MODEL_SIZE[12]}" "${MODEL_RAM[12]}"

gap
line
echo -e "  ${DIM}Select a number  |  q to quit${RESET}"
line
gap
read -rp "  → " CHOICE
gap

# ── Validate ───────────────────────────────────────────────────────
case "$CHOICE" in
    [1-9]|1[0-2]) ;;
    q|Q) echo -e "  ${DIM}Exiting.${RESET}\n"; exit 0 ;;
    *) die "Invalid selection. Enter 1–12 or q." ;;
esac

KEY="$CHOICE"
LABEL="${MODEL_LABEL[$KEY]}"
SIZE="${MODEL_SIZE[$KEY]}"
RAM="${MODEL_RAM[$KEY]}"
URL="${MODEL_URL[$KEY]}"
DEST="$MODELS_DIR/${MODEL_OUTPUT[$KEY]}"

# ── Summary ────────────────────────────────────────────────────────
line
echo -e "  ${BOLD}Model:${RESET}   $LABEL"
echo -e "  ${BOLD}Size:${RESET}    $SIZE  (${RAM} required)"
echo -e "  ${BOLD}Output:${RESET}  $DEST"
echo -e "  ${BOLD}Via:${RESET}     $DOWNLOADER"
line

if [[ "$KEY" == "5" || "$KEY" == "6" ]]; then
    warn "Llama 4 Scout requires both parts (5 + 6) in the same folder."
    gap
fi

if [ -f "$DEST" ]; then
    warn "File already exists: $(basename "$DEST")"
    read -rp "  Overwrite? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "\n  ${DIM}Cancelled.${RESET}\n"; exit 0; }
    gap
fi

read -rp "  Proceed? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "\n  ${DIM}Cancelled.${RESET}\n"; exit 0; }

# ── Download ───────────────────────────────────────────────────────
gap
mkdir -p "$MODELS_DIR"
echo -e "  ${CYAN}${BOLD}Downloading $LABEL...${RESET}"
gap

if do_download "$URL" "$DEST"; then
    gap
    ACTUAL=$(du -sh "$DEST" | cut -f1)
    ok "Transfer complete  —  $ACTUAL on disk"
    echo -e "  ${DIM}$DEST${RESET}"
    gap
    if [[ "$KEY" == "5" || "$KEY" == "6" ]]; then
        echo -e "  ${DIM}Download the other Scout part, then:  bash run.sh${RESET}"
    else
        echo -e "  ${DIM}Start the server:  bash run.sh${RESET}"
    fi
else
    gap
    die "Download failed. Check your connection and try again."
fi

gap
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║           Transfer Complete  ✓             ║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════╝${RESET}"
gap
