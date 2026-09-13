#!/usr/bin/env bash
#
# wrap-subtitle-lines.sh — wrap long single-line subtitle text into two
# balanced lines, the way properly-authored subtitles are formatted.
#
# Whisper's output (and some machine translation output) puts a whole
# subtitle event's text on one line regardless of length, which reads
# poorly once it runs past 40-something characters. This finds the word
# boundary that splits the text into the most evenly-balanced two lines,
# rather than greedily filling the first line to the width limit (which
# tends to produce a short, cramped first line and a long, still-too-wide
# second line).
#
# Run this BEFORE fix-rtl-subs.sh if the target language is RTL - wrap on
# plain text first, then let fix-rtl-subs.sh apply the bidi marks to each
# final line.
#
# Usage:
#   wrap-subtitle-lines.sh [-a] [-w MAXWIDTH] FILE_OR_DIR...
#
#   -a          recurse into directories looking for *.srt
#   -w MAXWIDTH target max characters per line (default: 42, the common
#               subtitling convention). Text that can't fit two lines at
#               this width even at the best balance point is still split
#               at the most-balanced point available - it just runs a bit
#               wider than MAXWIDTH per line, rather than being left as an
#               unreadable single very long line.
#
# Safe to run repeatedly: an already-wrapped (or already-short) block is
# left untouched.

set -euo pipefail

RECURSE=0
MAX_LINE=42
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,24p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        -w) MAX_LINE="$2"; shift 2 ;;
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

MAX_LINE="$MAX_LINE" python3 - "${SRT_FILES[@]}" <<'PYEOF'
import os, re, sys

MAX_LINE = int(os.environ["MAX_LINE"])

def wrap_text(text, max_len):
    if len(text) <= max_len:
        return text
    words = text.split(" ")
    if len(words) == 1:
        return text  # unbreakable single word
    prefix_lens = []
    running = ""
    for w in words:
        running = (running + " " + w).strip()
        prefix_lens.append(len(running))
    total = prefix_lens[-1]
    best_i, best_score = None, None
    for i in range(1, len(words)):
        l1 = prefix_lens[i - 1]
        l2 = total - l1 - 1
        score = max(l1, l2)
        if best_score is None or score < best_score:
            best_score, best_i = score, i
    return " ".join(words[:best_i]) + "\n" + " ".join(words[best_i:])

def process(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    blocks = re.split(r"\n\s*\n", content.strip())
    out = []
    changed = 0
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        idx, ts = lines[0], lines[1]
        text = " ".join(lines[2:])
        wrapped = wrap_text(text, MAX_LINE)
        if wrapped != "\n".join(lines[2:]):
            changed += 1
        out.append(f"{idx}\n{ts}\n{wrapped}\n")
    if changed:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        os.replace(tmp, path)
    return changed

total_files = total_blocks = 0
for path in sys.argv[1:]:
    n = process(path)
    if n:
        total_files += 1
        total_blocks += n
        print(f"wrapped {n} block(s): {path}")

print(f"\nfiles modified: {total_files}  blocks wrapped: {total_blocks}", file=sys.stderr)
PYEOF
