#!/usr/bin/env bash
#
# sync-subs.sh — align an existing subtitle sidecar's timing to its actual
# video, using ffsubsync. For subtitles that didn't come from this repo's
# own extract-subs.sh (which is always in sync, since it pulls the track
# straight out of the same file) — typically an externally-sourced or
# independently-translated track (e.g. Bazarr grabbing a Hebrew subtitle
# from a different release than the one on disk) that may run at a
# different offset and/or framerate than the actual video.
#
# ffsubsync aligns the given subtitle against the video's own embedded
# subtitle track if one exists (fast, precise), falling back to the video's
# audio via voice activity detection otherwise. Only timing is touched -
# text content is never modified. Different episodes commonly need
# different corrections (a constant show-wide offset is not a safe
# assumption) - this runs ffsubsync separately per file for that reason.
#
# Usage:
#   sync-subs.sh [-s SUFFIX] [-a] [--vad VAD] [--no-backup] [--force] FILE_OR_DIR...
#
#   -s SUFFIX     subtitle filename suffix to sync, e.g. he in movie.he.srt
#                 (default: he)
#   -a            recurse into directories looking for *.mkv/*.mp4/*.m4v with
#                 a matching <base>.SUFFIX.srt sidecar
#   --vad VAD     force a specific ffsubsync VAD backend (webrtc, auditok,
#                 subs_then_webrtc, ...) instead of letting it choose
#   --no-backup   don't keep a <sub>.bak copy of the pre-sync subtitle
#   --force       re-sync even if a .bak from a previous run already exists
#
# Requires ffsubsync (pipx install ffsubsync - see README) and ffmpeg.
#
# A file with a .bak already next to it is treated as already synced and
# skipped, the same resumable-batch convention extract-subs.sh uses for
# existing output - kill a big run partway through and re-run to pick up
# where it left off, or pass --force to redo everything.

set -euo pipefail

SUFFIX="he"
RECURSE=0
VAD=""
BACKUP=1
FORCE=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,28p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) SUFFIX="$2"; shift 2 ;;
        -a) RECURSE=1; shift ;;
        --vad) VAD="$2"; shift 2 ;;
        --no-backup) BACKUP=0; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found in PATH" >&2; exit 1; }
if ! command -v ffsubsync >/dev/null 2>&1; then
    echo "error: ffsubsync not found in PATH (pipx install ffsubsync)" >&2
    exit 1
fi

# Expand directories into their *.mkv/*.mp4/*.m4v files (same convention as
# extract-subs.sh).
VIDEO_NAME_MATCH=(-iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v')
VIDEO_FILES=()
for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
        if [[ $RECURSE -eq 1 ]]; then
            while IFS= read -r -d '' m; do VIDEO_FILES+=("$m"); done \
                < <(find "$f" -type f \( "${VIDEO_NAME_MATCH[@]}" \) -print0)
        else
            while IFS= read -r -d '' m; do VIDEO_FILES+=("$m"); done \
                < <(find "$f" -maxdepth 1 -type f \( "${VIDEO_NAME_MATCH[@]}" \) -print0)
        fi
    elif [[ -f "$f" ]]; then
        if [[ "$f" == *.[mM][kK][vV] || "$f" == *.[mM][pP]4 || "$f" == *.[mM]4[vV] ]]; then
            VIDEO_FILES+=("$f")
        fi
        # else: silently ignore non-video files (common when a shell glob like `-a *` is used)
    else
        echo "warn: skipping '$f' (not found)" >&2
    fi
done

if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
    echo "error: no .mkv/.mp4/.m4v files to process" >&2
    exit 1
fi

sync_one() {
    local video="$1"
    local base sub
    base="${video%.*}"
    sub="${base}.${SUFFIX}.srt"

    if [[ ! -f "$sub" ]]; then
        echo "skip: $video — no '$SUFFIX' subtitle ($sub) found" >&2
        return
    fi

    if [[ -f "${sub}.bak" && $FORCE -eq 0 ]]; then
        echo "skip: $sub — already synced (--force to redo)" >&2
        return
    fi

    if [[ $BACKUP -eq 1 ]]; then
        cp -p -- "$sub" "${sub}.bak"
    fi

    local -a vad_args=()
    [[ -n "$VAD" ]] && vad_args=(--vad "$VAD")

    local log
    log=$(mktemp)
    if ffsubsync "$video" -i "$sub" --overwrite-input "${vad_args[@]}" >"$log" 2>&1; then
        local offset fps
        offset=$(grep -oE 'offset seconds:\s*-?[0-9.]+' "$log" | grep -oE '\-?[0-9.]+$' || echo "?")
        fps=$(grep -oE 'framerate scale factor:\s*-?[0-9.]+' "$log" | grep -oE '\-?[0-9.]+$' || echo "?")
        echo "ok:   $sub (offset ${offset}s, framerate x${fps})"
    else
        echo "fail: $sub -- $(tail -3 "$log" | tr '\n' ' ')" >&2
        if [[ $BACKUP -eq 1 && -f "${sub}.bak" ]]; then
            cp -p -- "${sub}.bak" "$sub"
        fi
    fi
    rm -f "$log"
}

for f in "${VIDEO_FILES[@]}"; do
    sync_one "$f"
done
