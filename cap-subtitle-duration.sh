#!/usr/bin/env bash
#
# cap-subtitle-duration.sh — clip subtitle blocks that display for far
# longer than their text needs, down to a reading-speed-based maximum.
#
# Whisper's segment timestamps aren't fully reliable on noisy or
# music-heavy audio: a short line can occasionally get a wildly inflated
# end time (a real observed case: "Gil's unbelievable." displayed for 56
# seconds), leaving the line lingering on screen long after the speaker
# stopped talking. This never touches start times (i.e. never affects when
# a line first appears - sync is untouched), it only ever shortens an
# unnecessarily long end time.
#
# Usage:
#   cap-subtitle-duration.sh [-a] [--min SEC] [--max SEC] [--cps N] FILE_OR_DIR...
#
#   -a        recurse into directories looking for *.srt
#   --min SEC minimum display duration regardless of text length (default: 1.2)
#   --max SEC maximum display duration regardless of text length (default: 7.0,
#             matching the common professional-subtitling convention)
#   --cps N   assumed reading speed in characters/second used to compute the
#             target duration for a given line length (default: 13.3)
#
# Safe to run repeatedly - it only ever shortens, so a second pass is a
# no-op once durations are already within bounds.

set -euo pipefail

RECURSE=0
MIN_DUR="1.2"
MAX_DUR="7.0"
CPS="13.3"
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,20p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        --min) MIN_DUR="$2"; shift 2 ;;
        --max) MAX_DUR="$2"; shift 2 ;;
        --cps) CPS="$2"; shift 2 ;;
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
        if [[ "$f" == *.[sS][rR][tT] ]]; then
            SRT_FILES+=("$f")
        fi
        # else: silently ignore non-.srt files
    else
        echo "warn: skipping '$f' (not found)" >&2
    fi
done

if [[ ${#SRT_FILES[@]} -eq 0 ]]; then
    echo "error: no .srt files to process" >&2
    exit 1
fi

MIN_DUR="$MIN_DUR" MAX_DUR="$MAX_DUR" CPS="$CPS" python3 - "${SRT_FILES[@]}" <<'PYEOF'
import os, re, sys

MIN_DUR = float(os.environ["MIN_DUR"])
MAX_DUR = float(os.environ["MAX_DUR"])
CPS = float(os.environ["CPS"])

def ts_to_sec(ts):
    h, m, s_ms = ts.split(":")
    s, ms = s_ms.split(",")
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

def sec_to_ts(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")

def process(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    blocks = re.split(r"\n\s*\n", content.strip())
    out = []
    capped = 0
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        idx, ts = lines[0], lines[1]
        text = " ".join(lines[2:])
        start_s, end_s = ts.split(" --> ")
        start, end = ts_to_sec(start_s), ts_to_sec(end_s)
        target = max(MIN_DUR, min(MAX_DUR, len(text) / CPS))
        if end - start > target:
            end = start + target
            capped += 1
        out.append(f"{idx}\n{sec_to_ts(start)} --> {sec_to_ts(end)}\n" + "\n".join(lines[2:]) + "\n")
    if capped:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        os.replace(tmp, path)
    return capped

total_files = total_blocks = 0
for path in sys.argv[1:]:
    n = process(path)
    if n:
        total_files += 1
        total_blocks += n
        print(f"capped {n} block(s): {path}")

print(f"\nfiles modified: {total_files}  blocks capped: {total_blocks}", file=sys.stderr)
PYEOF
