#!/usr/bin/env bash
#
# extract-subs.sh — pull the embedded English subtitle track out of one or
# more MKV/MP4/M4V files using ffprobe/ffmpeg. Prefers a clean track, but
# falls back to a hearing-impaired/SDH one if that's all a file has (see
# --no-hi).
#
# Usage:
#   extract-subs.sh [-l LANG] [-s SUFFIX] [-o OUTDIR] [-a] [--no-hi] [--force] FILE_OR_DIR...
#
#   -l LANG      ISO 639-2 language code to match in the file (default: eng)
#   -s SUFFIX    filename suffix to use for the output file (default: derived
#                from LANG, e.g. eng -> en, fre -> fr; falls back to LANG itself)
#   -o OUTDIR    write extracted subs here instead of next to the source file
#   -a           recurse into directories looking for *.mkv/*.mp4/*.m4v
#   --no-hi      skip a file entirely if only a hearing-impaired/SDH track
#                exists, instead of falling back to it
#   --force      overwrite existing output files
#
# Text-based subtitle codecs (SubRip/ASS/SSA/MOV_TEXT) are extracted as .srt.
# Image-based codecs (PGS, VobSub/DVD) can't be converted to text by ffmpeg,
# so they're copied out in their native form instead (.sup for PGS; VobSub has
# no standalone muxer in this ffmpeg build, so it's wrapped in a minimal
# Matroska container as .mks, same convention mkvextract uses).

set -euo pipefail

LANG_CODE="eng"
SUFFIX=""
OUTDIR=""
RECURSE=0
ALLOW_HI=1
FORCE=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,20p' | sed 's/^# \{0,1\}//'
    exit 1
}

# ISO 639-2 -> ISO 639-1, for common languages, used as the default filename suffix.
lang_to_suffix() {
    case "$1" in
        eng) echo "en" ;;
        fre|fra) echo "fr" ;;
        ger|deu) echo "de" ;;
        spa) echo "es" ;;
        ita) echo "it" ;;
        heb) echo "he" ;;
        jpn) echo "ja" ;;
        por) echo "pt" ;;
        rus) echo "ru" ;;
        ara) echo "ar" ;;
        *) echo "$1" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l) LANG_CODE="$2"; shift 2 ;;
        -s) SUFFIX="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -a) RECURSE=1; shift ;;
        --no-hi) ALLOW_HI=0; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

for cmd in ffmpeg ffprobe jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found in PATH" >&2; exit 1; }
done

# Expand directories into their *.mkv/*.mp4/*.m4v files.
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

extract_one() {
    local file="$1"
    local dir base outdir
    dir=$(dirname -- "$file")
    base=$(basename -- "$file")
    base="${base%.*}"
    outdir="${OUTDIR:-$dir}"
    mkdir -p "$outdir"

    local probe probe_err
    probe_err=$(mktemp)
    if ! probe=$(ffprobe -v error -select_streams s \
        -show_entries stream=index,codec_name:stream_tags=language,title:stream_disposition=hearing_impaired,forced,default \
        -of json "$file" 2>"$probe_err"); then
        echo "skip: $file — ffprobe failed: $(tr '\n' ' ' <"$probe_err")" >&2
        rm -f "$probe_err"
        return
    fi
    rm -f "$probe_err"

    # Build a flat list of candidate subtitle streams matching the language.
    local candidates
    candidates=$(jq -c --arg lang "$LANG_CODE" '
        [.streams[]? | select((.tags.language // "und") == $lang) | {
            index: .index,
            codec: .codec_name,
            title: (.tags.title // ""),
            hi: ((.disposition.hearing_impaired // 0) == 1
                 or ((.tags.title // "") | ascii_downcase | test("sdh|hearing.?impaired|\\bcc\\b"))),
            forced: ((.disposition.forced // 0) == 1),
            default: ((.disposition.default // 0) == 1)
        }]
    ' <<<"$probe")

    local count
    count=$(jq 'length' <<<"$candidates")
    if [[ "$count" -eq 0 ]]; then
        echo "skip: $file — no '$LANG_CODE' subtitle track found" >&2
        return
    fi

    # Prefer: non-forced, non-HI over HI, default-flagged, lowest index.
    local pick
    pick=$(jq -c --argjson allow_hi "$ALLOW_HI" '
        map(select(.forced == false))
        | (if $allow_hi == 1 then . else map(select(.hi == false)) end)
        | sort_by([.hi, (.default | not), .index])
        | .[0]
    ' <<<"$candidates")

    if [[ "$pick" == "null" || -z "$pick" ]]; then
        if [[ $ALLOW_HI -eq 0 ]]; then
            echo "skip: $file — only hearing-impaired '$LANG_CODE' track(s) found (drop --no-hi to take it anyway)" >&2
        else
            echo "skip: $file — only forced '$LANG_CODE' track(s) found" >&2
        fi
        return
    fi

    local idx codec is_hi
    idx=$(jq -r '.index' <<<"$pick")
    codec=$(jq -r '.codec' <<<"$pick")
    is_hi=$(jq -r '.hi' <<<"$pick")

    local suffix="${SUFFIX:-$(lang_to_suffix "$LANG_CODE")}"
    [[ "$is_hi" == "true" ]] && suffix="${suffix}.hi"

    local out_ext map_codec ff_format=""
    case "$codec" in
        subrip|srt|ass|ssa|mov_text|webvtt)
            out_ext="srt"; map_codec="srt" ;;
        hdmv_pgs_subtitle|pgssub)
            out_ext="sup"; map_codec="copy" ;;
        dvd_subtitle|vobsub)
            # This ffmpeg build has no standalone vobsub muxer, so wrap the
            # image-based subtitle in a minimal Matroska container instead
            # (same convention mkvextract uses for these tracks).
            out_ext="mks"; map_codec="copy"; ff_format="matroska" ;;
        *)
            out_ext="$codec"; map_codec="copy" ;;
    esac

    local outfile="$outdir/${base}.${suffix}.${out_ext}"
    if [[ -e "$outfile" && $FORCE -eq 0 ]]; then
        echo "skip: $outfile already exists (use --force to overwrite)" >&2
        return
    fi

    local ff_overwrite="-n"
    [[ $FORCE -eq 1 ]] && ff_overwrite="-y"

    local -a ff_format_args=()
    [[ -n "$ff_format" ]] && ff_format_args=(-f "$ff_format")

    if ffmpeg -v error $ff_overwrite -i "$file" -map "0:${idx}" -c:s "$map_codec" "${ff_format_args[@]}" "$outfile"; then
        if [[ "$out_ext" == "srt" ]]; then
            # Strip ASS position/style override codes (e.g. {\an8}) and <font ...>
            # wrapper tags some sources bake into the text as literal characters —
            # plain SRT players and translation pipelines (Bazarr) don't understand
            # them and would show or translate the garbage literally. Keep <i>/<b>/<u>.
            sed -i -E -e 's/\{\\[^}]*\}//g' -e 's/<\/?font[^>]*>//gI' "$outfile"
        fi
        echo "ok:   $file -> $outfile"
    else
        echo "fail: $file (stream $idx, codec $codec)" >&2
    fi
}

for f in "${VIDEO_FILES[@]}"; do
    extract_one "$f"
done
