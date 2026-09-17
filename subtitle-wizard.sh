#!/usr/bin/env bash
#
# subtitle-wizard.sh — interactive, step-by-step front end for the rest of
# this repo. Answers a handful of questions (media folder, whether to
# recurse, source/target language, whether to transcribe audio for videos
# with no subtitle at all, whether to clean up a downloaded external
# subtitle first, whether to overwrite existing output, whether to notify
# Jellyfin) and then runs the same underlying scripts
# (clean-subtitle-junk.sh, subs-to-hebrew.sh) a command-line user would run
# by hand. It doesn't do anything the other scripts can't already do - it
# just picks sane defaults (Hebrew as the target language, medium model
# for transcription) and asks instead of requiring you to remember flags.
#
# Usage:
#   subtitle-wizard.sh
#
# No arguments - everything is gathered interactively. Run it from
# anywhere; it locates its sibling scripts next to itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    grep '^#' "$0" | sed -n '2,16p' | sed 's/^# \{0,1\}//'
    exit 0
fi

# --- small prompt helpers -----------------------------------------------

# ask_value PROMPT DEFAULT -> echoes the chosen value
ask_value() {
    local prompt="$1" default="$2" reply
    read -r -p "$prompt [$default]: " reply || true
    echo "${reply:-$default}"
}

# ask_yn PROMPT DEFAULT(y|n) -> returns 0 for yes, 1 for no
ask_yn() {
    local prompt="$1" default="$2" reply hint
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    read -r -p "$prompt [$hint]: " reply || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

echo "=== Subtitle wizard ==="
echo "Extracts/transcribes and translates subtitles for a movie or show,"
echo "step by step. Press Enter at any prompt to accept the default shown"
echo "in brackets."
echo

# --- 1. media path --------------------------------------------------------

MEDIA_PATH=""
while true; do
    read -r -p "Media file or folder to process: " MEDIA_PATH || true
    if [[ -z "$MEDIA_PATH" ]]; then
        echo "  (required - please enter a path)"
        continue
    fi
    if [[ ! -e "$MEDIA_PATH" ]]; then
        echo "  '$MEDIA_PATH' does not exist - try again."
        continue
    fi
    break
done

RECURSE=0
if [[ -d "$MEDIA_PATH" ]]; then
    if ask_yn "Include subfolders too (e.g. all seasons under a show folder)?" "y"; then
        RECURSE=1
    fi
fi

# --- 2. languages ----------------------------------------------------------

SRC_LANG=$(ask_value "Source language of the audio/existing subtitles (ISO 639-1)" "en")
TGT_LANG=$(ask_value "Translate into (ISO 639-1)" "he")

# --- 3. whisper fallback for videos with nothing embedded/external -------

WHISPER_FALLBACK=0
MODEL="medium"
if ask_yn "Transcribe audio with Whisper for videos with no usable subtitle track?" "y"; then
    WHISPER_FALLBACK=1
    MODEL=$(ask_value "Whisper model (small = faster, medium = more accurate, recommended)" "medium")
fi

# --- 4. optional external-subtitle cleanup --------------------------------

CLEAN_JUNK=0
if ask_yn "Clean ad/spam blocks and markup tags from any existing .srt files first (useful for downloaded external subtitles)?" "n"; then
    CLEAN_JUNK=1
fi

# --- 5. overwrite existing output -----------------------------------------

FORCE=0
if ask_yn "Overwrite subtitles that already exist?" "n"; then
    FORCE=1
fi

# --- 6. Jellyfin notification ----------------------------------------------

NOTIFY_JELLYFIN=0
JELLYFIN_TOKEN_FILE="$HOME/.config/jellyfin/token"
if [[ -f "$JELLYFIN_TOKEN_FILE" ]]; then
    if ask_yn "Notify Jellyfin to rescan when done?" "y"; then
        NOTIFY_JELLYFIN=1
        JELLYFIN_URL=$(ask_value "Jellyfin URL" "http://192.168.0.2:8096")
        JELLYFIN_HOST_PREFIX=$(ask_value "Host-side path prefix to remap (leave as-is if unsure)" "/mnt/storage01/media")
        JELLYFIN_CONTAINER_PREFIX=$(ask_value "Container-side replacement prefix" "/data")
    fi
else
    echo "(no Jellyfin token found at $JELLYFIN_TOKEN_FILE - skipping the notify step;"
    echo " Jellyfin will still pick up the change on its own next scheduled scan)"
fi

# --- summary + confirm -----------------------------------------------------

echo
echo "=== Plan ==="
echo "  Path:            $MEDIA_PATH"
echo "  Recurse:         $([[ $RECURSE -eq 1 ]] && echo yes || echo no)"
echo "  Source language: $SRC_LANG"
echo "  Target language: $TGT_LANG"
if [[ $WHISPER_FALLBACK -eq 1 ]]; then
    echo "  Whisper fallback: yes (model: $MODEL)"
else
    echo "  Whisper fallback: no (only translate what's already embedded/external)"
fi
echo "  Clean junk first: $([[ $CLEAN_JUNK -eq 1 ]] && echo yes || echo no)"
echo "  Overwrite existing: $([[ $FORCE -eq 1 ]] && echo yes || echo no)"
echo "  Notify Jellyfin:  $([[ $NOTIFY_JELLYFIN -eq 1 ]] && echo yes || echo no)"
echo

if ! ask_yn "Proceed?" "y"; then
    echo "Aborted - nothing was run."
    exit 0
fi

# --- run ---------------------------------------------------------------

if [[ $CLEAN_JUNK -eq 1 ]]; then
    echo
    echo "==> clean-subtitle-junk.sh"
    ARGS=()
    [[ $RECURSE -eq 1 ]] && ARGS+=(-a)
    "$SCRIPT_DIR/clean-subtitle-junk.sh" "${ARGS[@]}" "$MEDIA_PATH" || \
        echo "warn: clean-subtitle-junk.sh reported nothing to do or failed - continuing" >&2
fi

ARGS=(-s "$SRC_LANG" -t "$TGT_LANG")
[[ $RECURSE -eq 1 ]] && ARGS+=(-a)
[[ $WHISPER_FALLBACK -eq 1 ]] && ARGS+=(--whisper-fallback -m "$MODEL")
[[ $FORCE -eq 1 ]] && ARGS+=(--force)

echo
echo "==> subs-to-hebrew.sh"
if [[ $NOTIFY_JELLYFIN -eq 1 ]]; then
    JELLYFIN_URL="$JELLYFIN_URL" \
    JELLYFIN_TOKEN="$(cat "$JELLYFIN_TOKEN_FILE")" \
    JELLYFIN_HOST_PREFIX="$JELLYFIN_HOST_PREFIX" \
    JELLYFIN_CONTAINER_PREFIX="$JELLYFIN_CONTAINER_PREFIX" \
    "$SCRIPT_DIR/subs-to-hebrew.sh" "${ARGS[@]}" "$MEDIA_PATH"
else
    "$SCRIPT_DIR/subs-to-hebrew.sh" "${ARGS[@]}" "$MEDIA_PATH"
fi

echo
echo "Done."
