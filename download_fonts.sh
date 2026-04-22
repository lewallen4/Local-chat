#!/usr/bin/env bash
# ============================================================
#  Skye-AI — Font Downloader
#  Downloads all UI fonts locally so the app works fully offline.
#  Safe to re-run — skips files already present.
#
#  Sources: Official googlefonts GitHub repos (open source, OFL)
#    github.com/googlefonts/lexend
#    github.com/googlefonts/syne
#    github.com/JetBrains/JetBrainsMono
#
#  All three are variable fonts — one woff2 file covers all weights.
#
#  Usage: bash download_fonts.sh
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
FONT_DIR="$SCRIPT_DIR/server/static/fonts"

ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n  ${RED}✗${RESET}  $1\n"; exit 1; }

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║       Skye-AI  —  Font Download          ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Variable woff2 fonts — one file per family covers all weights.${RESET}"
echo ""

mkdir -p "$FONT_DIR"

# Detect downloader
if command -v curl >/dev/null 2>&1; then
    dl() { curl -fL --progress-bar -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    dl() { wget -q --show-progress -O "$1" "$2"; }
else
    die "Neither curl nor wget found."
fi

download_font() {
    local FILE="$1"
    local URL="$2"
    local DEST="$FONT_DIR/$FILE"
    if [ -f "$DEST" ] && [ -s "$DEST" ]; then
        ok "Already present: $FILE ($(du -k "$DEST" | cut -f1) KB)"
        return 0
    fi
    echo -e "  ${CYAN}→${RESET}  Downloading $FILE..."
    dl "$DEST" "$URL" \
        && ok "$FILE ($(du -k "$DEST" | cut -f1) KB)" \
        || { warn "Failed to download $FILE"; return 1; }
}

# ── Lexend (variable) ─────────────────────────────────────────────
# Source: github.com/googlefonts/lexend — OFL license
echo -e "  ${BOLD}Lexend${RESET}"
download_font "Lexend-variable.woff2" \
    "https://github.com/googlefonts/lexend/raw/main/fonts/lexend/webfonts/Lexend%5BHEXP%2Cwght%5D.woff2"

# ── Syne (variable) ───────────────────────────────────────────────
# Source: github.com/googlefonts/syne — OFL license
echo ""
echo -e "  ${BOLD}Syne${RESET}"
download_font "Syne-variable.woff2" \
    "https://github.com/googlefonts/syne/raw/main/fonts/variable/Syne%5Bwght%5D.woff2"

# ── JetBrains Mono (variable) ─────────────────────────────────────
# Source: github.com/JetBrains/JetBrainsMono — OFL license
echo ""
echo -e "  ${BOLD}JetBrains Mono${RESET}"
download_font "JetBrainsMono-variable.woff2" \
    "https://github.com/JetBrains/JetBrainsMono/raw/master/fonts/variable/JetBrainsMono%5Bwght%5D.woff2"

# ── Summary ───────────────────────────────────────────────────────
echo ""
TOTAL=0
for f in "$FONT_DIR"/*.woff2; do
    [ -f "$f" ] && TOTAL=$(( TOTAL + $(du -k "$f" | cut -f1) ))
done

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║        Font download complete  ✓        ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo "  Location: server/static/fonts/"
echo "  Total:    ${TOTAL} KB"
echo ""
echo "  The app will now serve all fonts locally — no internet required."
echo ""
