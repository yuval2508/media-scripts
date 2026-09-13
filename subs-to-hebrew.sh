#!/usr/bin/env bash
#
# subs-to-hebrew.sh — orchestrate the full pipeline: pull existing embedded
# subtitles (or transcribe from audio), translate to Hebrew, and clean up
# timing/formatting/RTL rendering. A thin sequencer around the other scripts
# in this repo - see README.md for what each stage does on its own.
#
# Usage:
#   subs-to-hebrew.sh [-s SRC] [-t TGT] [-m MODEL] [-a] [--whisper-fallback] [--force] FILE_OR_DIR...
#
#   -s SRC              source language, ISO 639-1 (default: en)
#   -t TGT              target language, ISO 639-1 (default: he)
#   -m MODEL            faster-whisper model size, only used with
#                       --whisper-fallback (default: small)
#   -a                  recurse into directories (forwarded to every stage)
#   --whisper-fallback  for files with no embedded SRC subtitle track,
#                       transcribe the audio with Whisper instead of just
#                       skipping them. Off by default: transcription is slow
#                       and CPU-heavy, so a plain run only translates
#                       whatever's already embedded, at effectively no
#                       compute cost.
#   --force             forwarded to every stage - overwrite existing
#                       outputs and redo every step even if already done
#
# Runs, in order: extract-subs.sh -> [whisper-transcribe.sh] ->
# translate-srt.sh -> cap-subtitle-duration.sh -> wrap-subtitle-lines.sh ->
# fix-rtl-subs.sh -> [notify-jellyfin.sh]. Every stage is independently safe
# to skip files it has nothing to do for, so this is resumable the same way
# each stage is: killing it partway through and re-running picks up wherever
# it left off. fix-rtl-subs.sh always runs last regardless of TGT - it
# no-ops harmlessly on non-RTL output. The final Jellyfin notification only
# runs if JELLYFIN_URL and JELLYFIN_TOKEN are set in the environment - see
# notify-jellyfin.sh for what it does and why it's needed at all (some
# players don't reliably pick up subtitle-only changes on their own).
#
# Examples:
#   # Cheap path: only translate whatever's already embedded, whole library
#   subs-to-hebrew.sh -a /media/tv
#
#   # Also transcribe audio for episodes with nothing embedded
#   subs-to-hebrew.sh -a --whisper-fallback "/media/tv/Some Show"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC="en"
TGT="he"
MODEL="small"
RECURSE=0
WHISPER_FALLBACK=0
FORCE=0
ARGS=()

usage() {
    grep '^#' "$0" | sed -n '2,30p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) SRC="$2"; shift 2 ;;
        -t) TGT="$2"; shift 2 ;;
        -m) MODEL="$2"; shift 2 ;;
        -a) RECURSE=1; shift ;;
        --whisper-fallback) WHISPER_FALLBACK=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift; ARGS+=("$@"); break ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    usage
fi

# extract-subs.sh's -l wants ISO 639-2, everything else here uses 639-1.
iso_639_2() {
    case "$1" in
        en) echo "eng" ;;
        fr) echo "fre" ;;
        de) echo "ger" ;;
        es) echo "spa" ;;
        it) echo "ita" ;;
        he) echo "heb" ;;
        ja) echo "jpn" ;;
        pt) echo "por" ;;
        ru) echo "rus" ;;
        ar) echo "ara" ;;
        *) echo "$1" ;;
    esac
}

FLAGS=()
[[ $RECURSE -eq 1 ]] && FLAGS+=(-a)
[[ $FORCE -eq 1 ]] && FLAGS+=(--force)

# cap-subtitle-duration.sh / wrap-subtitle-lines.sh / fix-rtl-subs.sh expect
# .srt files or directories, not video files. A directory argument passes
# through unchanged (each of those scripts finds its own *.srt within it);
# an individual video file gets translated to its sibling <base>.SRC.srt and
# <base>.TGT.srt paths instead (nonexistent ones - e.g. extraction found
# nothing for that file - are silently skipped by each stage, same as any
# other not-found path).
SRT_ARGS=()
for a in "${ARGS[@]}"; do
    if [[ -d "$a" ]]; then
        SRT_ARGS+=("$a")
    else
        base="${a%.*}"
        SRT_ARGS+=("$base.$SRC.srt" "$base.$TGT.srt")
    fi
done

run_stage() {
    local name="$1" rc=0; shift
    echo "==> $name" >&2
    "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "warn: $name reported nothing to do or failed (exit $rc) - continuing" >&2
    fi
    return 0
}

run_stage "extract-subs.sh" \
    "$SCRIPT_DIR/extract-subs.sh" -l "$(iso_639_2 "$SRC")" -s "$SRC" "${FLAGS[@]}" "${ARGS[@]}"

if [[ $WHISPER_FALLBACK -eq 1 ]]; then
    run_stage "whisper-transcribe.sh" \
        "$SCRIPT_DIR/whisper-transcribe.sh" -l "$SRC" -m "$MODEL" "${FLAGS[@]}" "${ARGS[@]}"
fi

run_stage "translate-srt.sh" \
    "$SCRIPT_DIR/translate-srt.sh" -s "$SRC" -t "$TGT" "${FLAGS[@]}" "${ARGS[@]}"

run_stage "cap-subtitle-duration.sh" \
    "$SCRIPT_DIR/cap-subtitle-duration.sh" "${FLAGS[@]}" "${SRT_ARGS[@]}"

run_stage "wrap-subtitle-lines.sh" \
    "$SCRIPT_DIR/wrap-subtitle-lines.sh" "${FLAGS[@]}" "${SRT_ARGS[@]}"

run_stage "fix-rtl-subs.sh" \
    "$SCRIPT_DIR/fix-rtl-subs.sh" "${FLAGS[@]}" "${SRT_ARGS[@]}"

# Optional: tell Jellyfin to rescan, so it picks up the new subtitles right
# away instead of waiting on its own schedule. Only runs if configured -
# see notify-jellyfin.sh for the JELLYFIN_* environment variables.
if [[ -n "${JELLYFIN_URL:-}" && -n "${JELLYFIN_TOKEN:-}" ]]; then
    NOTIFY_ARGS=()
    for a in "${ARGS[@]}"; do
        if [[ -d "$a" ]]; then
            NOTIFY_ARGS+=("$a")
        else
            NOTIFY_ARGS+=("$(dirname -- "$a")")
        fi
    done
    run_stage "notify-jellyfin.sh" \
        "$SCRIPT_DIR/notify-jellyfin.sh" "${NOTIFY_ARGS[@]}"
fi

echo "done." >&2
