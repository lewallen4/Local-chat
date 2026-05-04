#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Model Puller
#  Default: IBM Granite 4.0 H Small Q4_K_M (~19GB)
#  Use --embedding to fetch granite-embedding-30m-english (~25MB)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/server/models"
mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

PULL_EMBEDDING=false
PULL_BOTH=false

usage() {
    cat <<EOF

Usage: bash model_pull.sh [OPTIONS]

  (no flags)        Pull chat model only (Granite 4.0 H Small Q4_K_M)
  --embedding       Pull embedding model only (granite-embedding-30m-english)
  --both            Pull both chat and embedding models
  --help            Show this message

The chat model is large (~19GB) — be patient. The embedding model is tiny.

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --embedding) PULL_EMBEDDING=true; shift ;;
        --both)      PULL_BOTH=true; shift ;;
        --help)      usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

pull_chat() {
    echo ""
    echo "▶ Pulling IBM Granite 4.0 H Small (Q4_K_M, ~19GB)..."
    echo "  This will take a while."
    echo ""
    curl -L --progress-bar -o model.gguf \
        "https://huggingface.co/ibm-granite/granite-4.0-h-small-GGUF/resolve/main/granite-4.0-h-small-Q4_K_M.gguf"
    echo ""
    echo "  ✓ Saved to $MODELS_DIR/model.gguf"
}

pull_embedding() {
    echo ""
    echo "▶ Pulling Granite Embedding 30M English (Q4_K_M, ~25MB)..."
    echo ""
    curl -L --progress-bar -o granite-embedding-30m-english.gguf \
        "https://huggingface.co/lmstudio-community/granite-embedding-30m-english-GGUF/resolve/main/granite-embedding-30m-english-Q4_K_M.gguf"
    echo ""
    echo "  ✓ Saved to $MODELS_DIR/granite-embedding-30m-english.gguf"
}

if [ "$PULL_BOTH" = true ]; then
    pull_chat
    pull_embedding
elif [ "$PULL_EMBEDDING" = true ]; then
    pull_embedding
else
    pull_chat
fi

echo ""
echo "Done."
echo ""

# ── Reference: alternate models (uncomment as needed) ─────────
# Granite 4.0 H Tiny (7B/1B-active, much faster on CPU):
# curl -L --progress-bar -o model.gguf \
#     "https://huggingface.co/ibm-granite/granite-4.0-h-tiny-GGUF/resolve/main/granite-4.0-h-tiny-Q4_K_M.gguf"
#
# Granite 4.0 H 1B (smallest, fastest, lower quality):
# curl -L --progress-bar -o model.gguf \
#     "https://huggingface.co/ibm-granite/granite-4.0-h-1b-GGUF/resolve/main/granite-4.0-h-1b-Q4_K_M.gguf"
