#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Model Acquisition Utility
#
#  Sources (all URLs live-verified):
#    Meta Llama       → unsloth
#    Mistral Small    → unsloth
#    IBM Granite 3.3  → ibm-granite (official)
#    IBM Granite 4    → ibm-granite (official)  ★ recommended for RAG
#    IBM Granite 4.1  → unsloth
#    IBM Embeddings   → bartowski / ibm-granite (official)
#
#  Quant: Q4_K_M  |  Llama 3.1 8B + Mistral Small → UD-Q4_K_XL
#  Usage: bash gui_model_pull.sh
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

# ── Downloader detection ───────────────────────────────────────────
detect_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        die "Neither curl nor wget found. Please install one and re-run."
    fi
}

# ── Get remote file size (bytes) ───────────────────────────────────
get_remote_size() {
    local URL="$1"
    local BYTES=0
    if [ "$DOWNLOADER" = "curl" ]; then
        BYTES=$(curl -sI -L "$URL" | grep -i content-length | tail -1 | tr -d '\r' | awk '{print $2}')
    else
        BYTES=$(wget -q --spider --server-response "$URL" 2>&1 | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r')
    fi
    echo "${BYTES:-0}"
}

# ── Human-readable bytes ───────────────────────────────────────────
human_bytes() {
    local BYTES="$1"
    if   [ "$BYTES" -ge 1073741824 ]; then awk "BEGIN{printf \"%.1f GB\", $BYTES/1073741824}"
    elif [ "$BYTES" -ge 1048576 ];    then awk "BEGIN{printf \"%.1f MB\", $BYTES/1048576}"
    elif [ "$BYTES" -ge 1024 ];       then awk "BEGIN{printf \"%.1f KB\", $BYTES/1024}"
    else echo "${BYTES} B"
    fi
}

# ── Pretty progress bar ────────────────────────────────────────────
draw_progress() {
    local DEST="$1"
    local TOTAL="$2"
    local WIDTH=38

    if [ "$TOTAL" -eq 0 ]; then
        local SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local I=0
        while kill -0 "$DL_PID" 2>/dev/null; do
            printf "\r  ${CYAN}${SPIN[$I]}${RESET}  Downloading...  ${DIM}(size unknown)${RESET}   "
            I=$(( (I+1) % ${#SPIN[@]} ))
            sleep 0.15
        done
        printf "\r%-60s\r" " "
        return
    fi

    local TOTAL_HR
    TOTAL_HR=$(human_bytes "$TOTAL")

    while kill -0 "$DL_PID" 2>/dev/null; do
        local CURRENT=0
        [ -f "$DEST" ] && CURRENT=$(stat -c%s "$DEST" 2>/dev/null || stat -f%z "$DEST" 2>/dev/null || echo 0)
        CURRENT="${CURRENT:-0}"

        local PCT=0
        [ "$TOTAL" -gt 0 ] && PCT=$(( CURRENT * 100 / TOTAL ))
        [ "$PCT" -gt 100 ] && PCT=100

        local FILLED=$(( PCT * WIDTH / 100 ))
        local EMPTY=$(( WIDTH - FILLED ))

        local BAR="${GREEN}"
        for ((i=0; i<FILLED; i++)); do BAR="${BAR}█"; done
        BAR="${BAR}${DIM}"
        for ((i=0; i<EMPTY; i++)); do BAR="${BAR}░"; done
        BAR="${BAR}${RESET}"

        local CURRENT_HR
        CURRENT_HR=$(human_bytes "$CURRENT")

        printf "\r  ${BAR}  ${BOLD}%3d%%${RESET}  ${DIM}%s / %s${RESET}  " \
            "$PCT" "$CURRENT_HR" "$TOTAL_HR"

        sleep 0.5
    done

    local FINAL_BAR="${GREEN}"
    for ((i=0; i<WIDTH; i++)); do FINAL_BAR="${FINAL_BAR}█"; done
    FINAL_BAR="${FINAL_BAR}${RESET}"
    printf "\r  ${FINAL_BAR}  ${BOLD}100%%${RESET}  ${DIM}%s / %s${RESET}  \n" \
        "$TOTAL_HR" "$TOTAL_HR"
}

# ── Download + progress ────────────────────────────────────────────
do_download() {
    local URL="$1"
    local DEST="$2"

    echo -e "  ${DIM}Retrieving file info...${RESET}"
    local TOTAL
    TOTAL=$(get_remote_size "$URL")
    gap

    if [ "$DOWNLOADER" = "curl" ]; then
        curl -sS -L -o "$DEST" "$URL" &
    else
        wget -q -O "$DEST" "$URL" &
    fi
    DL_PID=$!

    draw_progress "$DEST" "$TOTAL"

    wait "$DL_PID"
    return $?
}

# ── Model registry ─────────────────────────────────────────────────
declare -A MODEL_LABEL MODEL_SIZE MODEL_RAM MODEL_URL MODEL_OUTPUT

MODEL_LABEL=(
    [1]="IBM Granite 4.0 H Tiny  (7B/1B-active MoE)  ★ RAG-optimized, fast"
    [2]="IBM Granite 4.0 H Small  (32B/9B-active MoE)"
    [3]="IBM Granite 4.0 H 1B  (dense)"
    [4]="IBM Granite Embedding 30M English  (RAG companion)"
    [5]="IBM Granite 3.3  8B"
    [6]="IBM Granite 4.1  30B  (UD-Q4_K_XL)"
    [7]="Llama 3.2  1B"
    [8]="Llama 3.2  3B"
    [9]="Llama 3.1  8B"
    [10]="Llama 3.3  70B"
    [11]="Llama 4 Scout  (pt 1/2)"
    [12]="Llama 4 Scout  (pt 2/2)"
    [13]="Mistral Small 3.1  24B"
    [14]="Gemma 4  26B (Q4_K_M)"
    [15]="Gemma 4  31B  (Q4_K_M)"
    [16]="DeepSeek R1 Distill  14B  (Qwen)"
    [17]="DeepSeek R1 Distill  32B  (Qwen)"
    [18]="DeepSeek V3.2  671B  (UD-Q4_K_XL)  ★ multi-file"
    [19]="DeepSeek R1  671B  (Q4_K_M)  ★ multi-file"
    [20]="NVIDIA Nemotron 3 Nano  (30B/3.5B-active MoE)  ★ NEW"
)

MODEL_SIZE=(
    [1]="4.4 GB"
    [2]="19.5 GB"
    [3]="0.9 GB"
    [4]="0.025 GB"
    [5]="4.6 GB"
    [6]="18.5 GB"
    [7]="0.8 GB"
    [8]="2.0 GB"
    [9]="5.0 GB"
    [10]="42.5 GB"
    [11]="49.8 GB"
    [12]="15.5 GB"
    [13]="14.5 GB"
    [14]="16.9 GB"
    [15]="18.3 GB"
    [16]="9.0 GB"
    [17]="19.9 GB"
    [18]="~400 GB (8 parts)"
    [19]="~404 GB (9 parts)"
    [20]="22.8 GB"
)

MODEL_RAM=(
    [1]="6 GB"
    [2]="24 GB"
    [3]="4 GB"
    [4]="<1 GB"
    [5]="8 GB"
    [6]="24 GB"
    [7]="4 GB"
    [8]="8 GB"
    [9]="8 GB"
    [10]="48 GB"
    [11]="64 GB"
    [12]="64 GB"
    [13]="20 GB"
    [14]="24 GB"
    [15]="24 GB"
    [16]="12 GB"
    [17]="24 GB"
    [18]="256+ GB"
    [19]="256+ GB"
    [20]="32 GB"
)

MODEL_URL=(
    [1]="https://huggingface.co/ibm-granite/granite-4.0-h-tiny-GGUF/resolve/main/granite-4.0-h-tiny-Q4_K_M.gguf"
    [2]="https://huggingface.co/ibm-granite/granite-4.0-h-small-GGUF/resolve/main/granite-4.0-h-small-Q4_K_M.gguf"
    [3]="https://huggingface.co/ibm-granite/granite-4.0-h-1b-GGUF/resolve/main/granite-4.0-h-1b-Q4_K_M.gguf"
    [4]="https://huggingface.co/lmstudio-community/granite-embedding-30m-english-GGUF/resolve/main/granite-embedding-30m-english-Q4_K_M.gguf"
    [5]="https://huggingface.co/ibm-granite/granite-3.3-8b-instruct-GGUF/resolve/main/granite-3.3-8b-instruct-Q4_K_M.gguf"
    [6]="https://huggingface.co/unsloth/granite-4.1-30b-GGUF/resolve/main/granite-4.1-30b-UD-Q4_K_XL.gguf"
    [7]="https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    [8]="https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    [9]="https://huggingface.co/unsloth/Llama-3.1-8B-Instruct-GGUF/resolve/main/Llama-3.1-8B-Instruct-UD-Q4_K_XL.gguf"
    [10]="https://huggingface.co/unsloth/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
    [11]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00001-of-00002.gguf"
    [12]="https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF/resolve/main/Q4_K_M/Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00002-of-00002.gguf"
    [13]="https://huggingface.co/unsloth/Mistral-Small-3.1-24B-Instruct-2503-GGUF/resolve/main/Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL.gguf"
    [14]="https://huggingface.co/mradermacher/gemma-4-26B-A4B-GGUF/resolve/main/gemma-4-26B-A4B.Q4_K_M.gguf"
    [15]="https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/gemma-4-31B-it-Q4_K_M.gguf"
    [16]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
    [17]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
    [18]="MULTI_FILE"
    [19]="MULTI_FILE"
    [20]="https://huggingface.co/unsloth/Nemotron-3-Nano-30B-A3B-GGUF/resolve/main/Nemotron-3-Nano-30B-A3B-UD-Q4_K_XL.gguf"
)

MODEL_OUTPUT=(
    [1]="granite-4.0-h-tiny-Q4_K_M.gguf"
    [2]="granite-4.0-h-small-Q4_K_M.gguf"
    [3]="granite-4.0-h-1b-Q4_K_M.gguf"
    [4]="granite-embedding-30m-english-Q4_K_M.gguf"
    [5]="granite-3.3-8b-instruct-Q4_K_M.gguf"
    [6]="granite-4.1-30b-UD-Q4_K_XL.gguf"
    [7]="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    [8]="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    [9]="Llama-3.1-8B-Instruct-UD-Q4_K_XL.gguf"
    [10]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
    [11]="Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00001-of-00002.gguf"
    [12]="Llama-4-Scout-17B-16E-Instruct-Q4_K_M-00002-of-00002.gguf"
    [13]="Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL.gguf"
    [14]="gemma-4-26B-A4B.Q4_K_M.gguf"
    [15]="gemma-4-31B-it-Q4_K_M.gguf"
    [16]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
    [17]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
    [18]="MULTI_FILE"
    [19]="MULTI_FILE"
    [20]="Nemotron-3-Nano-30B-A3B-UD-Q4_K_XL.gguf"
)

# ── Detect downloader ──────────────────────────────────────────────
detect_downloader

# ── Banner ─────────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║      Skye-AI  —  Model Acquisition         ║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════╝${RESET}"
echo -e "  ${DIM}Q4_K_M  ·  via ${DOWNLOADER}  ·  → ${MODELS_DIR}${RESET}"

# ── Menu ───────────────────────────────────────────────────────────
sec "NVIDIA  —  Nemotron 3 Nano  [unsloth]  ★ RECOMMENDED"
row 20 "${MODEL_LABEL[20]}" "${MODEL_SIZE[20]}" "${MODEL_RAM[20]}"

sec "IBM  —  Embeddings  [official]  ★ REQUIRED for RAG"
row  4 "${MODEL_LABEL[4]}"  "${MODEL_SIZE[4]}"  "${MODEL_RAM[4]}"

sec "IBM  —  Granite 4  [ibm-granite official]"
row  1 "${MODEL_LABEL[1]}"  "${MODEL_SIZE[1]}"  "${MODEL_RAM[1]}"
row  2 "${MODEL_LABEL[2]}"  "${MODEL_SIZE[2]}"  "${MODEL_RAM[2]}"
row  3 "${MODEL_LABEL[3]}"  "${MODEL_SIZE[3]}"  "${MODEL_RAM[3]}"

sec "IBM  —  Granite 3.3  [ibm-granite official]"
row  5 "${MODEL_LABEL[5]}"  "${MODEL_SIZE[5]}"  "${MODEL_RAM[5]}"

sec "IBM  —  Granite 4.1  [unsloth]"
row  6 "${MODEL_LABEL[6]}"  "${MODEL_SIZE[6]}"  "${MODEL_RAM[6]}"

sec "META  —  Llama  [unsloth]"
row  7 "${MODEL_LABEL[7]}"  "${MODEL_SIZE[7]}"  "${MODEL_RAM[7]}"
row  8 "${MODEL_LABEL[8]}"  "${MODEL_SIZE[8]}"  "${MODEL_RAM[8]}"
row  9 "${MODEL_LABEL[9]}"  "${MODEL_SIZE[9]}"  "${MODEL_RAM[9]}"
row 10 "${MODEL_LABEL[10]}" "${MODEL_SIZE[10]}" "${MODEL_RAM[10]}"
row 11 "${MODEL_LABEL[11]}" "${MODEL_SIZE[11]}" "${MODEL_RAM[11]}"
row 12 "${MODEL_LABEL[12]}" "${MODEL_SIZE[12]}" "${MODEL_RAM[12]}"

sec "MISTRAL AI  [unsloth]"
row 13 "${MODEL_LABEL[13]}" "${MODEL_SIZE[13]}" "${MODEL_RAM[13]}"

sec "GOOGLE  —  Gemma 4  [mradermacher - unsloth]"
row 14 "${MODEL_LABEL[14]}" "${MODEL_SIZE[14]}" "${MODEL_RAM[14]}"
row 15 "${MODEL_LABEL[15]}" "${MODEL_SIZE[15]}" "${MODEL_RAM[15]}"

sec "DEEPSEEK  [unsloth]"
row 16 "${MODEL_LABEL[16]}" "${MODEL_SIZE[16]}" "${MODEL_RAM[16]}"
row 17 "${MODEL_LABEL[17]}" "${MODEL_SIZE[17]}" "${MODEL_RAM[17]}"
row 18 "${MODEL_LABEL[18]}" "${MODEL_SIZE[18]}" "${MODEL_RAM[18]}"
row 19 "${MODEL_LABEL[19]}" "${MODEL_SIZE[19]}" "${MODEL_RAM[19]}"

gap
line
echo -e "  ${DIM}Select a number  |  q to quit${RESET}"
line
gap
read -rp "  → " CHOICE
gap

# ── Validate ───────────────────────────────────────────────────────
case "$CHOICE" in
    [1-9]|1[0-9]|20) ;;
    q|Q) echo -e "  ${DIM}Exiting.${RESET}\n"; exit 0 ;;
    *) die "Invalid selection. Enter 1–20 or q." ;;
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

if [[ "$KEY" == "20" ]]; then
    warn "Nemotron 3 Nano — NVIDIA's December 2025 hybrid Mamba-2 + transformer MoE."
    warn "30B total / 3.5B active. UD-Q4_K_XL ~22.8 GB on disk, ~32 GB RAM at 32K context."
    warn "Released Dec 2025 — beats Qwen3-30B-A3B and GPT-OSS-20B on Arena-Hard chat."
    warn "Reasoning is on by default; this server disables it for fast RAG-grounded Q&A."
    warn "Pair with option [4] (granite-embedding-30m) for the full RAG stack."
    gap
fi

if [[ "$KEY" == "1" ]]; then
    warn "Granite 4.0 H Tiny — MoE w/ Mamba-2 + transformer hybrid."
    warn "Validated to 128K context. Best speed/quality tradeoff for RAG on CPU."
    warn "Pair with option [4] (granite-embedding-30m) for the full RAG stack."
    gap
fi

if [[ "$KEY" == "2" || "$KEY" == "3" ]]; then
    warn "Granite 4 uses hybrid Mamba architecture. Requires a recent llama.cpp build."
    gap
fi

if [[ "$KEY" == "4" ]]; then
    warn "Embedding model — NOT a chat model. Used by the RAG pipeline to vectorize"
    warn "Confluence chunks and queries. Saves to granite-embedding-30m-english-Q4_K_M.gguf"
    warn "run.sh auto-detects it via the *embedding*.gguf filename pattern."
    gap
fi

if [[ "$KEY" == "6" ]]; then
    warn "Unsloth GGUF — not IBM's official upload. Uses Unsloth Dynamic quant (UD-Q4_K_XL)."
    warn "Dense 30B model with 128K context. Strong tool-calling and instruction following."
    gap
fi

if [[ "$KEY" == "9" || "$KEY" == "13" ]]; then
    warn "Uses Unsloth Dynamic quant (UD-Q4_K_XL) — higher quality than standard Q4_K_M."
    gap
fi

if [[ "$KEY" == "11" || "$KEY" == "12" ]]; then
    warn "Llama 4 Scout requires both parts (11 + 12) in the same folder."
    gap
fi

if [[ "$KEY" == "14" ]]; then
    warn "mradermacher made this, definitely the more economical option..."
    warn "Gemma 4 26B uses 256K context. At 8K context: ~22 GB VRAM with llama.cpp."
    gap
fi

if [[ "$KEY" == "15" ]]; then
    warn "Gemma 4 31B uses 256K context. At 8K context: ~22-28 GB VRAM with llama.cpp."
    gap
fi

if [[ "$KEY" == "16" || "$KEY" == "17" ]]; then
    warn "DeepSeek R1 distilled into Qwen — strong reasoning with <think> blocks."
    warn "Use temperature 0.5–0.7 (0.6 recommended) to reduce repetition."
    gap
fi

if [[ "$KEY" == "18" || "$KEY" == "19" ]]; then
    warn "This is a 671B MoE model split across multiple files (~400 GB total)."
    warn "Cannot be downloaded with this tool — use huggingface-cli instead:"
    gap
    if [[ "$KEY" == "18" ]]; then
        echo -e "  ${DIM}pip install huggingface_hub${RESET}"
        echo -e "  ${DIM}huggingface-cli download unsloth/DeepSeek-V3.2-GGUF \\${RESET}"
        echo -e "  ${DIM}  --include \"UD-Q4_K_XL/*\" --local-dir $MODELS_DIR${RESET}"
    else
        echo -e "  ${DIM}pip install huggingface_hub${RESET}"
        echo -e "  ${DIM}huggingface-cli download unsloth/DeepSeek-R1-GGUF \\${RESET}"
        echo -e "  ${DIM}  --include \"DeepSeek-R1-Q4_K_M/*\" --local-dir $MODELS_DIR${RESET}"
    fi
    gap
    warn "Requires 256+ GB combined RAM+VRAM. See unsloth.ai for hardware guide."
    gap
    echo -e "  ${DIM}Exiting — use the commands above to download.${RESET}\n"
    exit 0
fi

# Multi-part Scout note
if [[ "$KEY" == "11" || "$KEY" == "12" ]]; then
    : # already warned above
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
echo -e "  ${CYAN}${BOLD}$LABEL${RESET}"
gap

if do_download "$URL" "$DEST"; then
    gap
    ACTUAL=$(du -sh "$DEST" | cut -f1)
    ok "Transfer complete  —  $ACTUAL on disk"
    echo -e "  ${DIM}$DEST${RESET}"
    gap
    if [[ "$KEY" == "11" || "$KEY" == "12" ]]; then
        echo -e "  ${DIM}Download the other Scout part, then:  bash run.sh${RESET}"
    elif [[ "$KEY" == "4" ]]; then
        echo -e "  ${DIM}Embedding model installed. Now pull a chat model (option 1 recommended).${RESET}"
    else
        echo -e "  ${DIM}Start the server:  bash run.sh${RESET}"
    fi
else
    gap
    [ -f "$DEST" ] && rm -f "$DEST" && warn "Partial file removed."
    die "Download failed. Check your connection and try again."
fi

gap
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║           Transfer Complete  ✓             ║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════╝${RESET}"
gap
