#!/usr/bin/env bash
#
# bridge-subtitle-gaps.sh — fix a Whisper segmentation artifact where one
# continuous spoken sentence gets cut into two subtitle blocks with a blank
# gap between them, even though the speaker never stopped talking.
#
# This is different from missing dialogue (see whisper-transcribe.sh's
# --no-vad) and from overlong lingering lines (see
# cap-subtitle-duration.sh): here, BOTH halves of the sentence do have a
# subtitle, they're just separated by a few seconds of blank screen while
# the audio keeps going, which reads as jarring/broken to a viewer. A real
# observed case: "...good then at last I" / [7.5s blank] / "will get a new
# body and the world will get..." — one uninterrupted sentence, split in
# half by Whisper's segment boundary.
#
# Heuristic: flag a gap between two adjacent blocks in the SOURCE-LANGUAGE
# .srt when it's under --max-gap seconds AND the next block's text starts
# with a lowercase letter - a strong signal it's grammatically continuing
# the previous line rather than starting a new sentence (this transcript
# style capitalizes real sentence starts). When flagged, the first block's
# end time is extended to meet the second block's start time, removing the
# blank gap. Text is never touched, only end timestamps - and only ever
# extended, never shortened.
#
# The lowercase check only makes sense in the source language (English),
# so this script reads the .en.srt (or --source-lang) to decide WHICH
# blocks to bridge, then applies the identical timestamp change (by block
# index) to every sibling <base>.*.srt file next to it, since
# translate-srt.sh preserves the original timestamps 1:1 per block.
#
# Usage:
#   bridge-subtitle-gaps.sh [-a] [--source-lang LANG] [--max-gap SEC] FILE_OR_DIR...
#
#   -a             recurse into directories looking for *.LANG.srt
#   --source-lang  language code of the reference transcript used for the
#                  lowercase heuristic (default: en)
#   --max-gap SEC  only bridge gaps up to this long (default: 10.0) - a
#                  longer gap is more likely a real pause than a
#                  mis-segmented sentence, even if the next line happens to
#                  start lowercase
#
# Run this AFTER cap-subtitle-duration.sh (so the duration cap doesn't clip
# the bridged line right back down) and BEFORE wrap-subtitle-lines.sh /
# fix-rtl-subs.sh. Safe to run repeatedly - it only closes gaps that still
# exist, so a second pass is a no-op once bridged.

set -euo pipefail

RECURSE=0
SRC_LANG="en"
MAX_GAP="10.0"
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,39p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        --source-lang) SRC_LANG="$2"; shift 2 ;;
        --max-gap) MAX_GAP="$2"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found in PATH" >&2; exit 1; }

REF_FILES=()
for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
        if [[ $RECURSE -eq 1 ]]; then
            while IFS= read -r -d '' s; do REF_FILES+=("$s"); done \
                < <(find "$f" -type f -iname "*.${SRC_LANG}.srt" -print0)
        else
            while IFS= read -r -d '' s; do REF_FILES+=("$s"); done \
                < <(find "$f" -maxdepth 1 -type f -iname "*.${SRC_LANG}.srt" -print0)
        fi
    elif [[ -f "$f" ]]; then
        if [[ "$f" == *".${SRC_LANG}.srt" ]] || [[ "$f" == *.[sS][rR][tT] ]]; then
            REF_FILES+=("$f")
        fi
    else
        echo "warn: skipping '$f' (not found)" >&2
    fi
done

if [[ ${#REF_FILES[@]} -eq 0 ]]; then
    echo "error: no .${SRC_LANG}.srt reference files to process" >&2
    exit 1
fi

SRC_LANG="$SRC_LANG" MAX_GAP="$MAX_GAP" python3 - "${REF_FILES[@]}" <<'PYEOF'
import glob, os, re, sys

SRC_LANG = os.environ["SRC_LANG"]
MAX_GAP = float(os.environ["MAX_GAP"])

def ts_to_sec(ts):
    h, m, s_ms = ts.split(":")
    s, ms = s_ms.split(",")
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

def sec_to_ts(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")

def parse_blocks(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    blocks = []
    for b in re.split(r"\n\s*\n", content.strip()):
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        ts = lines[1]
        start_s, end_s = ts.split(" --> ")
        blocks.append({
            "idx": lines[0],
            "start": ts_to_sec(start_s),
            "end": ts_to_sec(end_s),
            "text_lines": lines[2:],
        })
    return blocks

def write_blocks(path, blocks):
    out = []
    for b in blocks:
        out.append(f"{b['idx']}\n{sec_to_ts(b['start'])} --> {sec_to_ts(b['end'])}\n"
                    + "\n".join(b["text_lines"]) + "\n")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, path)

def find_bridges(ref_blocks):
    """Return {block_index (0-based): new_end_seconds} for gaps to close."""
    bridges = {}
    for i in range(len(ref_blocks) - 1):
        cur, nxt = ref_blocks[i], ref_blocks[i + 1]
        gap = nxt["start"] - cur["end"]
        next_text = " ".join(nxt["text_lines"]).strip()
        first_alpha = next((c for c in next_text if c.isalpha()), None)
        if 0 < gap <= MAX_GAP and first_alpha is not None and first_alpha.islower():
            bridges[i] = nxt["start"]
    return bridges

total_episodes = total_bridges = 0
for ref_path in sys.argv[1:]:
    suffix = f".{SRC_LANG}.srt"
    if not ref_path.endswith(suffix):
        print(f"warn: skipping '{ref_path}' (doesn't end in {suffix})", file=sys.stderr)
        continue
    base = ref_path[: -len(suffix)]
    ref_blocks = parse_blocks(ref_path)
    bridges = find_bridges(ref_blocks)
    if not bridges:
        continue

    sibling_paths = sorted(glob.glob(base + ".*.srt"))
    episode_bridged = 0
    for path in sibling_paths:
        blocks = parse_blocks(path)
        if len(blocks) != len(ref_blocks):
            print(f"warn: '{path}' has {len(blocks)} blocks, reference has "
                  f"{len(ref_blocks)} - skipping (structure mismatch)", file=sys.stderr)
            continue
        changed = False
        for i, new_end in bridges.items():
            if blocks[i]["end"] < new_end:
                blocks[i]["end"] = new_end
                changed = True
        if changed:
            write_blocks(path, blocks)
            episode_bridged += 1

    if episode_bridged:
        total_episodes += 1
        total_bridges += len(bridges)
        print(f"bridged {len(bridges)} gap(s) across {episode_bridged} file(s): {base}")

print(f"\nepisodes modified: {total_episodes}  total gaps bridged: {total_bridges}", file=sys.stderr)
PYEOF
