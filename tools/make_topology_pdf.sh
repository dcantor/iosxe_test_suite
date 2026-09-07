#!/usr/bin/env bash
# Renders the topology diagram to PDF with headless Chrome.
#   usage: ./tools/make_topology_pdf.sh [output.pdf]
# Chrome prints the real page, so the PDF matches the published artifact exactly
# rather than being a second, drifting drawing. docs/topology.html carries an
# A3-landscape print stylesheet so the wide diagram is not clipped.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD/docs/topology.html"
OUT="${1:-results/topology.pdf}"
# Chrome needs an absolute destination; accept either form from the caller.
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
mkdir -p "$(dirname "$OUT")"
[[ -f "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }

CHROME=$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)
[[ -n "$CHROME" ]] || { echo "ERROR: no Chrome/Chromium to render with" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$CHROME" --headless --disable-gpu --no-sandbox \
  --user-data-dir="$tmp" \
  --no-pdf-header-footer \
  --virtual-time-budget=15000 \
  --print-to-pdf="$OUT" \
  "file://$SRC" >/dev/null 2>&1

[[ -s "$OUT" ]] || { echo "ERROR: Chrome produced no PDF" >&2; exit 1; }
echo "Wrote $OUT ($(stat -c%s "$OUT") bytes)"
