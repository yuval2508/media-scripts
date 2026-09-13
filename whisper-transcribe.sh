#!/usr/bin/env bash
#
# whisper-transcribe.sh — transcribe the audio track of one or more video
# files into an .srt subtitle using faster-whisper. For files that already
# have a usable embedded subtitle track, use extract-subs.sh instead - it's
# faster and more accurate than transcribing audio from scratch.
#
# Usage:
#   whisper-transcribe.sh [-l LANG] [-m MODEL] [-o OUTDIR] [-a] [--force] FILE_OR_DIR...
#
#   -l LANG    language spoken in the audio, forced rather than auto-detected
#              (ISO 639-1, e.g. en, ja, es; default: en). Forcing the known
#              language avoids misdetection from a foreign-language opening
#              theme song or intro music before the real dialogue starts.
#   -m MODEL   faster-whisper model size: tiny/base/small/medium/large-v3
#              (default: small - a reasonable CPU speed/accuracy tradeoff;
#              on an ~20min episode this runs at roughly 7-8x realtime on an
#              8-core CPU)
#   -o OUTDIR  write output here instead of next to the source file
#   -a         recurse into directories looking for *.mkv/*.mp4/*.m4v
#   --force    re-transcribe even if the output .LANG.srt already exists
#
# Output is written to <base>.<LANG>.srt next to the source file (or in
# OUTDIR). Already-transcribed files are skipped, so a batch job can be
# safely killed and re-run to resume where it left off.
#
# Requires the venv at .venvs/whisper-subs (next to this script). Create it
# with:
#   python3 -m venv .venvs/whisper-subs
#   .venvs/whisper-subs/bin/pip install faster-whisper
#
# CAVEAT: Whisper's own segment timestamps aren't fully reliable on noisy or
# music-heavy audio - a short line can occasionally get a wildly inflated
# end time, making it linger on screen long after the speaker stopped. Run
# cap-subtitle-duration.sh on the output afterward to clip that down to a
# sane reading-speed-based duration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/.venvs/whisper-subs/bin/python3"

LANG_CODE="en"
MODEL="small"
OUTDIR=""
RECURSE=0
FORCE=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,26p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l) LANG_CODE="$2"; shift 2 ;;
        -m) MODEL="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -a) RECURSE=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

if [[ ! -x "$VENV_PY" ]]; then
    echo "error: venv not found at $SCRIPT_DIR/.venvs/whisper-subs" >&2
    echo "       create it with:" >&2
    echo "         python3 -m venv '$SCRIPT_DIR/.venvs/whisper-subs'" >&2
    echo "         '$VENV_PY' -m pip install faster-whisper" >&2
    exit 1
fi

VIDEO_FILES=()
for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
        if [[ $RECURSE -eq 1 ]]; then
            while IFS= read -r -d '' m; do VIDEO_FILES+=("$m"); done \
                < <(find "$f" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) -print0)
        else
            while IFS= read -r -d '' m; do VIDEO_FILES+=("$m"); done \
                < <(find "$f" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) -print0)
        fi
    elif [[ -f "$f" ]]; then
        VIDEO_FILES+=("$f")
    else
        echo "warn: skipping '$f' (not found)" >&2
    fi
done

if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
    echo "error: no .mkv/.mp4/.m4v files to process" >&2
    exit 1
fi

export WT_LANG="$LANG_CODE"
export WT_MODEL="$MODEL"
export WT_OUTDIR="$OUTDIR"
export WT_FORCE="$FORCE"

"$VENV_PY" - "${VIDEO_FILES[@]}" <<'PYEOF'
import os, sys, time
from faster_whisper import WhisperModel

lang = os.environ["WT_LANG"]
model_size = os.environ["WT_MODEL"]
outdir = os.environ.get("WT_OUTDIR") or None
force = os.environ.get("WT_FORCE") == "1"

def fmt(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace('.', ',')

print(f"loading faster-whisper model '{model_size}'...", file=sys.stderr)
model = WhisperModel(model_size, device="cpu", compute_type="int8")

done = skipped = failed = 0
videos = sys.argv[1:]
total = len(videos)

for i, video in enumerate(videos, 1):
    base = os.path.splitext(video)[0]
    out_dir = outdir or os.path.dirname(video)
    out = os.path.join(out_dir, os.path.basename(base) + f".{lang}.srt")
    if os.path.exists(out) and not force:
        skipped += 1
        print(f"skip: {out} already exists (use --force to overwrite)", file=sys.stderr)
        continue
    os.makedirs(out_dir, exist_ok=True)
    tmp = out + ".tmp"
    t0 = time.time()
    try:
        segments, info = model.transcribe(video, beam_size=5, vad_filter=True, language=lang)
        with open(tmp, "w", encoding="utf-8") as f:
            for j, seg in enumerate(segments, 1):
                f.write(f"{j}\n{fmt(seg.start)} --> {fmt(seg.end)}\n{seg.text.strip()}\n\n")
        os.replace(tmp, out)
        done += 1
        print(f"[{i}/{total}] ok ({time.time()-t0:.0f}s): {video} -> {out}")
    except Exception as e:
        failed += 1
        if os.path.exists(tmp):
            os.remove(tmp)
        print(f"[{i}/{total}] FAIL: {video} -- {e}", file=sys.stderr)

print(f"\ndone: {done}  skipped: {skipped}  failed: {failed}  total: {total}", file=sys.stderr)
PYEOF
