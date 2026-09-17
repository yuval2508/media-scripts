#!/usr/bin/env bash
#
# clean-subtitle-junk.sh — strip ad/spam blocks and inline markup tags from
# a downloaded external .srt before feeding it into the rest of the
# pipeline (translate-srt.sh etc.).
#
# Subtitles pulled from download sites routinely carry junk that doesn't
# belong in the actual content: a block or two advertising the site itself
# ("For best IPTV provider, please visit: WWW...."), a sync/rip credit
# line, or <i>/<b>/<u>/<font> markup around narration and thoughts. The
# markup isn't just cosmetic clutter - fed straight into translate-srt.sh,
# a tag like <i>Hear now the song of Troy,</i> gets tokenized and
# translated as literal text along with the words, and MarianMT mangles it
# unpredictably. Spam blocks get "translated" into Hebrew ad copy for a
# website nobody asked for, and (being ordinary blocks) shift the numbering
# of everything downstream once removed, which is why this renumbers what's
# left rather than just blanking the dropped blocks.
#
# This is a targeted, pattern-based cleaner, not a general profanity/ad
# filter - it only drops a block when it matches an unambiguous marker
# (a URL, a known download-site name, or an English credit/ad phrase like
# "synced by" or "please rate"). It will not catch spam in other phrasings,
# and in principle could drop a real line that happens to contain one of
# these markers - spot-check the result, especially near the start/end of
# the file where this junk almost always lives.
#
# Usage:
#   clean-subtitle-junk.sh [-a] [--keep-markup] FILE_OR_DIR...
#
#   -a             recurse into directories looking for *.srt
#   --keep-markup  don't strip <i>/<b>/<u>/<font...> tags, only drop spam
#                  blocks
#
# Modifies the given .srt file(s) in place (same convention as
# cap-subtitle-duration.sh / wrap-subtitle-lines.sh). Safe to run
# repeatedly - a file with nothing to clean is left untouched. Run this
# BEFORE translate-srt.sh.

set -euo pipefail

RECURSE=0
KEEP_MARKUP=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,36p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        --keep-markup) KEEP_MARKUP=1; shift ;;
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

KEEP_MARKUP="$KEEP_MARKUP" python3 - "${SRT_FILES[@]}" <<'PYEOF'
import os, re, sys

KEEP_MARKUP = os.environ["KEEP_MARKUP"] == "1"

# Unambiguous spam/credit markers only - a URL, a known download-site
# name, or a stock English ad/credit phrase. Deliberately conservative:
# missing some spam is a minor annoyance, dropping a real line of dialogue
# is a real bug.
SPAM_PATTERNS = [
    re.compile(r"https?://", re.I),
    re.compile(r"\bwww\.", re.I),
    re.compile(r"\b(?:iptv|opensubtitles|subscene|addic7ed|yifysubtitles|subs4free)\b", re.I),
    re.compile(r"\bsync(?:ed)?\s+(?:and\s+)?correct(?:ed|ions?)?\s+by\b", re.I),
    re.compile(r"\bsubtitles?\s+(?:ripped|created|provided)?\s*by\b", re.I),
    re.compile(r"\b(?:ripped|encoded)\s+by\b", re.I),
    re.compile(r"\bsupport\s+us\b", re.I),
    re.compile(r"\bplease\s+rate\s+(?:this|these)\s+subtitles?\b", re.I),
    re.compile(r"\bdownload\s+(?:from|at)\b", re.I),
    re.compile(r"\badvertise\s+your\s+product\b", re.I),
    re.compile(r"\bfor\s+more\s+info(?:rmation)?\s*,?\s*visit\b", re.I),
]

MARKUP_RE = re.compile(r"</?(?:i|b|u|font[^>]*)>", re.I)

def is_spam(text):
    return any(p.search(text) for p in SPAM_PATTERNS)

def process(path):
    with open(path, encoding="utf-8-sig") as f:
        content = f.read()
    blocks = re.split(r"\n\s*\n", content.strip())
    kept = []
    dropped = 0
    markup_stripped = 0
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        ts = lines[1]
        text_lines = lines[2:]
        joined = " ".join(text_lines)
        if is_spam(joined):
            dropped += 1
            continue
        if not KEEP_MARKUP:
            new_lines = [MARKUP_RE.sub("", l).strip() for l in text_lines]
            if new_lines != text_lines:
                markup_stripped += 1
            text_lines = new_lines
        kept.append((ts, text_lines))

    if not dropped and not markup_stripped:
        return 0, 0

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for i, (ts, text_lines) in enumerate(kept, 1):
            f.write(f"{i}\n{ts}\n" + "\n".join(text_lines) + "\n\n")
    os.replace(tmp, path)
    return dropped, markup_stripped

total_files = total_dropped = total_markup = 0
for path in sys.argv[1:]:
    dropped, markup_stripped = process(path)
    if dropped or markup_stripped:
        total_files += 1
        total_dropped += dropped
        total_markup += markup_stripped
        print(f"dropped {dropped} spam block(s), stripped markup in "
              f"{markup_stripped} block(s): {path}")

print(f"\nfiles modified: {total_files}  spam blocks dropped: {total_dropped}  "
      f"blocks with markup stripped: {total_markup}", file=sys.stderr)
PYEOF
