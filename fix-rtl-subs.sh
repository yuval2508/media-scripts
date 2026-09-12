#!/usr/bin/env bash
#
# fix-rtl-subs.sh — fix punctuation/number placement in RTL-language (Hebrew,
# Arabic, etc.) .srt subtitle files for players that force LTR paragraph
# direction on subtitle cues (notably Jellyfin's web client, which prepends
# an LTR mark to every line by design — see jellyfin/jellyfin-web#4179).
#
# Under that forced-LTR behavior, trailing weak characters (., ?, numbers,
# etc.) resolve to the paragraph's forced LTR direction instead of following
# the preceding RTL text, so they visually land on the wrong side. Wrapping
# each line in an explicit RTL embedding (U+202B RLE ... U+202C PDF) creates
# a hard directional scope that resolves correctly regardless of what the
# outer paragraph is forced to.
#
# Only touches files/lines that actually contain RTL-script characters
# (Hebrew or Arabic block), so it's safe to run over a mixed-language
# subtitle library. Re-running is safe/idempotent — existing bidi marks
# (RLM/RLE/PDF/LRM/etc.) are stripped before re-wrapping, never stacked.
#
# Usage:
#   fix-rtl-subs.sh [-a] FILE_OR_DIR...
#
#   -a    recurse into directories looking for *.srt

set -euo pipefail

RECURSE=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,20p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found in PATH" >&2; exit 1; }

SRT_FILES=()
for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
        if [[ $RECURSE -eq 1 ]]; then
            while IFS= read -r -d '' s; do SRT_FILES+=("$s"); done \
                < <(find "$f" -type f -iname '*.srt' -print0)
        else
            while IFS= read -r -d '' s; do SRT_FILES+=("$s"); done \
                < <(find "$f" -maxdepth 1 -type f -iname '*.srt' -print0)
        fi
    elif [[ -f "$f" ]]; then
        SRT_FILES+=("$f")
    else
        echo "warn: skipping '$f' (not found)" >&2
    fi
done

if [[ ${#SRT_FILES[@]} -eq 0 ]]; then
    echo "error: no .srt files to process" >&2
    exit 1
fi

python3 - "${SRT_FILES[@]}" <<'PYEOF'
import os, re, sys

# Hebrew (U+0590-05FF), Arabic (U+0600-06FF), Arabic Supplement (U+0750-077F),
# Arabic Extended-A (U+08A0-08FF), Arabic Presentation Forms A/B
# (U+FB50-FDFF, U+FE70-FEFF).
RTL_CHAR = re.compile(
    "[֐-׿؀-ۿݐ-ݿࢠ-ࣿ"
    "ﭐ-﷿ﹰ-﻿]"
)
# Existing bidi control/format characters to strip before re-wrapping:
# LRM, RLM, ALM, LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI
BIDI_MARKS = (
    "‎‏؜‪‫‬‭‮"
    "⁦⁧⁨⁩"
)
RLE, PDF = "‫", "‬"

def fix_file(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    if not RTL_CHAR.search(content):
        return None  # not an RTL subtitle, leave untouched

    blocks = re.split(r"\n\s*\n", content.strip())
    changed = False
    out = []
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        idx, ts = lines[0], lines[1]
        new_text_lines = []
        for tl in lines[2:]:
            stripped = tl.strip(BIDI_MARKS)
            if RTL_CHAR.search(stripped):
                new_tl = RLE + stripped + PDF
            else:
                new_tl = stripped
            if new_tl != tl:
                changed = True
            new_text_lines.append(new_tl)
        out.append(f"{idx}\n{ts}\n" + "\n".join(new_text_lines) + "\n")

    if not changed:
        return False
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, path)
    return True

fixed = already_ok = skipped_not_rtl = 0
for path in sys.argv[1:]:
    result = fix_file(path)
    if result is None:
        skipped_not_rtl += 1
    elif result is False:
        already_ok += 1
        print(f"ok:    {path} (already fixed)")
    else:
        fixed += 1
        print(f"fixed: {path}")

print(
    f"\nfixed: {fixed}  already-ok: {already_ok}  "
    f"not-rtl: {skipped_not_rtl}  total: {len(sys.argv)-1}",
    file=sys.stderr,
)
PYEOF
