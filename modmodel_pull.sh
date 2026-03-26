#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Model Acquisition Utility
#  Pulls a selected GGUF model into server/models/
#
#  Supported families: Meta (Llama), Mistral, IBM (Granite)
#  Quantization: Q4_K_M across all models
#  Usage: bash model_pull.sh
# ============================================================

set -euo pipefail

# ── Palette ────────────────────────────────────────────────────────
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/server/models"

# ── Helpers ────────────────────────────────────────────────────────
line()    { echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"; }
header()  { echo -e "\n${CYAN}${BOLD}  $1${RESET}"; }
item()    { echo -e "  ${BLUE}${BOLD}[$1]${RESET}  ${BOLD}$2${RESET}  ${DIM}$3${RESET}"; }
detail()  { echo -e "       ${DIM}$1${RESET}"; }
ok()      { echo -e "\n  ${GREEN}✓${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}   $1"; }
die()     { echo -e "\n  ${RED}✗${RESET}  $1\n"; exit 1; }
gap()     { echo ""; }

# ── Model registry ─────────────────────────────────────────────────
# Format: NAME | SIZE | RAM | DESCRIPTION | URL
# All models are Q4_K_M quantization

declare -a MODEL_KEYS=(
    "llama_32_1b"
    "llama_32_3b"
    "llama_31_8b"
    "llama_33_70b"
    "llama4_scout_1"
    "llama4_scout_2"
    "mistral_7b"
    "mistral_small_22b"
    "mistral_nemo_12b"
    "granite_3b"
    "granite_8b"
    "granite_34b"
)

declare -A MODEL_LABEL=(
    [llama_32_1b]="Llama 3.2  1B Instruct"
    [llama_32_3b]="Llama 3.2  3B Instruct"
    [llama_31_8b]="Llama 3.1  8B Instruct"
    [llama_33_70b]="Llama 3.3  70B Instruct"
    [llama4_scout_1]="Llama 4 Scout  109B  (Part 1 of 2)"
    [llama4_scout_2]="Llama 4 Scout  109B  (Part 2 of 2)"
    [mistral_7b]="Mistral  7B Instruct v0.2"
    [mistral_small_22b]="Mistral Small  22B Instruct"
    [mistral_nemo_12b]="Mistral Nemo  12B Instruct"
    [granite_3b]="IBM Granite  3B Instruct"
    [granite_8b]="IBM Granite  8B Instruct"
    [granite_34b]="IBM Granite  34B Instruct"
)

declare -A MODEL_SIZE=(
    [llama_32_1b]="~0.8 GB"
    [llama_32_3b]="~2.0 GB"
    [llama_31_8b]="~4.7 GB"
    [llama_33_70b]="~40 GB"
    [llama4_scout_1]="~49.8 GB"
    [llama4_scout_2]="~15.5 GB"
    [mistral_7b]="~4.1 GB"
    [mistral_small_22b]="~13 GB"
    [mistral_nemo_12b]="~7.1 GB"
    [granite_3b]="~1.9 GB"
    [granite_8b]="~4.6 GB"
    [granite_34b]="~20 GB"
)

declare -A MODEL_RAM=(
    [llama_32_1b]="4 GB RAM"
    [llama_32_3b]="8 GB RAM"
    [llama_31_8b]="8 GB RAM"
    [llama_33_70b]="48 GB RAM"
    [llama4_scout_1]="64 GB RAM"
    [llama4_scout_2]="64 GB RAM"
    [mistral_7b]="8 GB RAM"
    [mistral_small_22b]="16 GB RAM"
    [mistral_nemo_12b]="16 GB RAM"
    [granite_3b]="8 GB RAM"
    [granite_8b]="8 GB RAM"
    [granite_34b]="24 GB RAM"
)

declare -A MODEL_URL=(
    [llama_32_1b]="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    [llama_32_3b]="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    [llama_31_8b]="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    [llama_33_70b]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
    [llama4_scout_1]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00001-of-00002.gguf"
    [llama4_scout_2]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00002-of-00002.gguf"
    [mistral_7b]="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
    [mistral_small_22b]="https://huggingface.co/bartowski/Mistral-Small-Instruct-2409-GGUF/resolve/main/Mistral-Small-Instruct-2409-Q4_K_M.gguf"
    [mistral_nemo_12b]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf"
    [granite_3b]="https://huggingface.co/bartowski/granite-3.0-3b-a800m-instruct-GGUF/resolve/main/granite-3.0-3b-a800m-instruct-Q4_K_M.gguf"
    [granite_8b]="https://huggingface.co/bartowski/granite-3.0-8b-instruct-GGUF/resolve/main/granite-3.0-8b-instruct-Q4_K_M.gguf"
    [granite_34b]="https://huggingface.co/bartowski/granite-34b-code-instruct-GGUF/resolve/main/granite-34b-code-instruct-Q4_K_M.gguf"
)

declare -A MODEL_OUTPUT=(
    [llama_32_1b]="model.gguf"
    [llama_32_3b]="model.gguf"
    [llama_31_8b]="model.gguf"
    [llama_33_70b]="model.gguf"
    [llama4_scout_1]="model-00001-of-00002.gguf"
    [llama4_scout_2]="model-00002-of-00002.gguf"
    [mistral_7b]="model.gguf"
    [mistral_small_22b]="model.gguf"
    [mistral_nemo_12b]="model.gguf"
    [granite_3b]="model.gguf"
    [granite_8b]="model.gguf"
    [granite_34b]="model.gguf"
)

# ── Banner ─────────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║               Skye-AI  —  Model Acquisition             ║${RESET}"
echo -e "${CYAN}${BOLD}║           Enterprise Local Inference Utility             ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}All models delivered in GGUF format, Q4_K_M quantization.${RESET}"
echo -e "  ${DIM}Destination: ${MODELS_DIR}${RESET}"
gap

# ── Model menu ─────────────────────────────────────────────────────
line
header "META  —  Llama Family"
line
item  " 1" "${MODEL_LABEL[llama_32_1b]}"   "${MODEL_SIZE[llama_32_1b]}"
detail "Lightweight edge model. Ideal for constrained environments.  Req: ${MODEL_RAM[llama_32_1b]}"
gap
item  " 2" "${MODEL_LABEL[llama_32_3b]}"   "${MODEL_SIZE[llama_32_3b]}"
detail "Compact general-purpose assistant. Fast, low overhead.       Req: ${MODEL_RAM[llama_32_3b]}"
gap
item  " 3" "${MODEL_LABEL[llama_31_8b]}"   "${MODEL_SIZE[llama_31_8b]}"
detail "Strong everyday reasoning and instruction following.         Req: ${MODEL_RAM[llama_31_8b]}"
gap
item  " 4" "${MODEL_LABEL[llama_33_70b]}"  "${MODEL_SIZE[llama_33_70b]}"
detail "Production-grade. Near-frontier quality on CPU inference.    Req: ${MODEL_RAM[llama_33_70b]}"
gap
item  " 5" "${MODEL_LABEL[llama4_scout_1]}" "${MODEL_SIZE[llama4_scout_1]}"
item  " 6" "${MODEL_LABEL[llama4_scout_2]}" "${MODEL_SIZE[llama4_scout_2]}"
detail "MoE architecture. 10M context. Download both parts (5+6).   Req: ${MODEL_RAM[llama4_scout_1]}"

gap
line
header "MISTRAL AI  —  Mistral Family"
line
item  " 7" "${MODEL_LABEL[mistral_7b]}"        "${MODEL_SIZE[mistral_7b]}"
detail "Reliable 7B baseline. Efficient and widely tested.          Req: ${MODEL_RAM[mistral_7b]}"
gap
item  " 8" "${MODEL_LABEL[mistral_nemo_12b]}"  "${MODEL_SIZE[mistral_nemo_12b]}"
detail "Multilingual, 128K context. Versatile mid-size option.      Req: ${MODEL_RAM[mistral_nemo_12b]}"
gap
item  " 9" "${MODEL_LABEL[mistral_small_22b]}" "${MODEL_SIZE[mistral_small_22b]}"
detail "Best-in-class at 22B. Strong reasoning and instruction work. Req: ${MODEL_RAM[mistral_small_22b]}"

gap
line
header "IBM  —  Granite Family"
line
item  "10" "${MODEL_LABEL[granite_3b]}"   "${MODEL_SIZE[granite_3b]}"
detail "IBM enterprise-grade compact model. Efficient and reliable.  Req: ${MODEL_RAM[granite_3b]}"
gap
item  "11" "${MODEL_LABEL[granite_8b]}"   "${MODEL_SIZE[granite_8b]}"
detail "Balanced performance for business and analytical tasks.      Req: ${MODEL_RAM[granite_8b]}"
gap
item  "12" "${MODEL_LABEL[granite_34b]}"  "${MODEL_SIZE[granite_34b]}"
detail "IBM's largest local model. Code and enterprise reasoning.    Req: ${MODEL_RAM[granite_34b]}"

gap
line
echo -e "  ${DIM}Enter a number to select a model, or ${BOLD}q${RESET}${DIM} to quit.${RESET}"
line
gap

# ── Selection ──────────────────────────────────────────────────────
read -rp "  Selection: " CHOICE
gap

case "$CHOICE" in
    1)  KEY="llama_32_1b" ;;
    2)  KEY="llama_32_3b" ;;
    3)  KEY="llama_31_8b" ;;
    4)  KEY="llama_33_70b" ;;
    5)  KEY="llama4_scout_1" ;;
    6)  KEY="llama4_scout_2" ;;
    7)  KEY="mistral_7b" ;;
    8)  KEY="mistral_nemo_12b" ;;
    9)  KEY="mistral_small_22b" ;;
    10) KEY="granite_3b" ;;
    11) KEY="granite_8b" ;;
    12) KEY="granite_34b" ;;
    q|Q)
        echo -e "  ${DIM}Exiting.${RESET}\n"
        exit 0
        ;;
    *)
        die "Invalid selection: '$CHOICE'. Please enter a number between 1 and 12."
        ;;
esac

# ── Confirm ────────────────────────────────────────────────────────
LABEL="${MODEL_LABEL[$KEY]}"
SIZE="${MODEL_SIZE[$KEY]}"
RAM="${MODEL_RAM[$KEY]}"
URL="${MODEL_URL[$KEY]}"
OUTFILE="${MODEL_OUTPUT[$KEY]}"
DEST="$MODELS_DIR/$OUTFILE"

echo -e "  ${BOLD}Selected:${RESET}  $LABEL"
echo -e "  ${BOLD}Size:${RESET}      $SIZE"
echo -e "  ${BOLD}Requires:${RESET}  $RAM"
echo -e "  ${BOLD}Output:${RESET}    $DEST"
gap

# Warn if Llama 4 Scout part selected individually
if [[ "$KEY" == "llama4_scout_1" || "$KEY" == "llama4_scout_2" ]]; then
    warn "Llama 4 Scout is split across two files."
    warn "You must download both Part 1 (option 5) and Part 2 (option 6)"
    warn "into the same folder for the model to load correctly."
    gap
fi

# Warn if file already exists
if [ -f "$DEST" ]; then
    warn "A file already exists at: $DEST"
    read -rp "  Overwrite? (y/N): " CONFIRM
    gap
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "  ${DIM}Download cancelled.${RESET}\n"
        exit 0
    fi
fi

read -rp "  Proceed with download? (y/N): " CONFIRM
gap
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "  ${DIM}Download cancelled.${RESET}\n"
    exit 0
fi

# ── Download ────────────────────────────────────────────────────────
mkdir -p "$MODELS_DIR"

echo -e "  ${CYAN}${BOLD}Downloading...${RESET}"
gap

if curl -L --progress-bar -o "$DEST" "$URL"; then
    gap
    ACTUAL_SIZE=$(du -sh "$DEST" | cut -f1)
    ok "Download complete."
    echo -e "  ${BOLD}File:${RESET}  $DEST"
    echo -e "  ${BOLD}Size:${RESET}  $ACTUAL_SIZE on disk"
    gap
    if [[ "$KEY" != "llama4_scout_1" && "$KEY" != "llama4_scout_2" ]]; then
        echo -e "  ${DIM}Run the server with:  ${BOLD}bash run.sh${RESET}"
    else
        echo -e "  ${DIM}Download the other Scout part, then run:  ${BOLD}bash run.sh${RESET}"
    fi
else
    gap
    die "Download failed. Check your network connection and try again."
fi

gap
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║                    Transfer Complete                     ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
gap
