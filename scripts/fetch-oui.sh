#!/bin/sh
# Download the official IEEE OUI database and convert it to the compact
# "AABBCC<TAB>Vendor" format NetRadar reads. Run once; requires network.
# Output: ~/Library/Application Support/NetRadar/oui.txt
set -e

DEST="$HOME/Library/Application Support/NetRadar"
mkdir -p "$DEST"
OUT="$DEST/oui.txt"
URL="https://standards-oui.ieee.org/oui/oui.csv"

echo "Downloading IEEE OUI database (a few MB)…"
TMP="$(mktemp)"
curl -fsSL "$URL" -o "$TMP"

echo "Converting…"
python3 - "$TMP" "$OUT" <<'PY'
import csv, sys
src, dst = sys.argv[1], sys.argv[2]
n = 0
with open(src, newline="", encoding="utf-8", errors="replace") as f, open(dst, "w", encoding="utf-8") as o:
    r = csv.reader(f)
    header = next(r, None)
    for row in r:
        if len(row) < 3:
            continue
        assignment = row[1].strip().upper()          # e.g. 001122
        org = row[2].strip()
        if len(assignment) == 6 and org:
            o.write(f"{assignment}\t{org}\n")
            n += 1
print(f"Wrote {n} vendor prefixes -> {dst}")
PY

rm -f "$TMP"
echo "Done. Restart NetRadar (or click Refresh) to see vendor names."
