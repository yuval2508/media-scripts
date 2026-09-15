#!/usr/bin/env bash
#
# translate-srt.sh — machine-translate an existing .srt subtitle (produced by
# extract-subs.sh or whisper-transcribe.sh) into another language, keeping
# the original timestamps and only translating the text.
#
# Each subtitle block is split into individual sentences before translation
# and rejoined after. This works around a real MarianMT (opus-mt) behavior:
# given a multi-sentence input, it silently drops an entire sentence about
# half the time instead of translating all of it - e.g. "Everything's
# ready, Yukimaru. Time to go?" translated to just "Everything's ready,
# Yukimaru." with the second sentence gone, no error, no truncation
# warning. Translating one sentence at a time avoids feeding it
# multi-sentence input in the first place.
#
# Usage:
#   translate-srt.sh -s SRC -t TGT [-a] [--force] [--wait] [--model NAME] FILE_OR_DIR...
#
#   -s SRC       source language code of the existing <base>.SRC.srt
#   -t TGT       target language code to translate into; output is written
#                to <base>.TGT.srt
#   --model NAME Hugging Face translation model to use (default:
#                Helsinki-NLP/opus-mt-SRC-TGT - a small, fast, CPU-friendly
#                model for that specific language pair; swap in something
#                like facebook/nllb-200-distilled-600M for a language pair
#                with no dedicated opus-mt model, or for higher quality at
#                the cost of speed)
#   -a           recurse into directories looking for *.mkv/*.mp4/*.m4v
#   --force      re-translate even if the output <base>.TGT.srt already exists
#   --wait       if a file's <base>.SRC.srt doesn't exist yet, poll for it
#                every 30s instead of skipping - use this to run alongside
#                a concurrent whisper-transcribe.sh batch job so translation
#                keeps pace with transcription instead of running after it
#
# Requires the venv at .venvs/whisper-subs (next to this script, shared with
# whisper-transcribe.sh) with transformers/torch/sentencepiece installed.
# Create it with:
#   python3 -m venv .venvs/whisper-subs
#   .venvs/whisper-subs/bin/pip install transformers sentencepiece sacremoses \
#       --index-url https://download.pytorch.org/whl/cpu torch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/.venvs/whisper-subs/bin/python3"

SRC=""
TGT=""
MODEL=""
RECURSE=0
FORCE=0
WAIT=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,40p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) SRC="$2"; shift 2 ;;
        -t) TGT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        -a) RECURSE=1; shift ;;
        --force) FORCE=1; shift ;;
        --wait) WAIT=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ -z "$SRC" || -z "$TGT" || ${#FILES[@]} -eq 0 ]]; then
    usage
fi

if [[ -z "$MODEL" ]]; then
    MODEL="Helsinki-NLP/opus-mt-${SRC}-${TGT}"
fi

if [[ ! -x "$VENV_PY" ]]; then
    echo "error: venv not found at $SCRIPT_DIR/.venvs/whisper-subs" >&2
    echo "       create it with:" >&2
    echo "         python3 -m venv '$SCRIPT_DIR/.venvs/whisper-subs'" >&2
    echo "         '$VENV_PY' -m pip install transformers sentencepiece sacremoses \\" >&2
    echo "             --index-url https://download.pytorch.org/whl/cpu torch" >&2
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

export TS_SRC="$SRC"
export TS_TGT="$TGT"
export TS_MODEL="$MODEL"
export TS_FORCE="$FORCE"
export TS_WAIT="$WAIT"

"$VENV_PY" - "${VIDEO_FILES[@]}" <<'PYEOF'
import os, re, sys, time
from transformers import MarianMTModel, MarianTokenizer

src = os.environ["TS_SRC"]
tgt = os.environ["TS_TGT"]
model_name = os.environ["TS_MODEL"]
force = os.environ.get("TS_FORCE") == "1"
wait = os.environ.get("TS_WAIT") == "1"
BATCH = 16
POLL_INTERVAL = 30

print(f"loading translation model '{model_name}'...", file=sys.stderr)
tok = MarianTokenizer.from_pretrained(model_name)
model = MarianMTModel.from_pretrained(model_name)

def parse_srt(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    entries = []
    for b in re.split(r"\n\s*\n", content.strip()):
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        entries.append((lines[0], lines[1], " ".join(lines[2:])))
    return entries

def translate_batch(texts):
    out = []
    for i in range(0, len(texts), BATCH):
        chunk = texts[i:i + BATCH]
        enc = tok(chunk, return_tensors="pt", padding=True, truncation=True)
        gen = model.generate(**enc, max_new_tokens=128)
        out.extend(tok.batch_decode(gen, skip_special_tokens=True))
    return out

SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")

def split_sentences(text):
    """Split a block's text into individual sentences. MarianMT silently
    drops whole sentences from multi-sentence input about half the time, so
    translating one sentence at a time (and rejoining after) avoids ever
    handing it more than one."""
    text = text.strip()
    if not text:
        return [""]
    parts = [p for p in SENTENCE_SPLIT_RE.split(text) if p]
    return parts or [text]

def translate_entries(entries):
    """Translate a list of (idx, ts, text) entries sentence-by-sentence,
    batched across the whole file, then rejoin each entry's sentences."""
    sentence_lists = [split_sentences(e[2]) for e in entries]
    flat = [s for lst in sentence_lists for s in lst]
    translated_flat = translate_batch(flat) if flat else []
    out = []
    pos = 0
    for lst in sentence_lists:
        n = len(lst)
        out.append(" ".join(translated_flat[pos:pos + n]))
        pos += n
    return out

videos = sys.argv[1:]
total = len(videos)
done = skipped = failed = 0
pending = list(videos)

while pending:
    next_pending = []
    for i, video in enumerate(pending, 1):
        base = os.path.splitext(video)[0]
        src_srt = f"{base}.{src}.srt"
        tgt_srt = f"{base}.{tgt}.srt"
        tmp = tgt_srt + ".tmp"

        if os.path.exists(tgt_srt) and not force:
            skipped += 1
            continue
        if not os.path.exists(src_srt):
            if wait:
                next_pending.append(video)
            else:
                skipped += 1
                print(f"skip: {video} -- no {src_srt}", file=sys.stderr)
            continue

        t0 = time.time()
        try:
            entries = parse_srt(src_srt)
            translated = translate_entries(entries) if entries else []
            with open(tmp, "w", encoding="utf-8") as f:
                for (idx, ts, _), text in zip(entries, translated):
                    f.write(f"{idx}\n{ts}\n{text}\n\n")
            os.replace(tmp, tgt_srt)
            done += 1
            print(f"ok ({time.time()-t0:.0f}s, {len(entries)} lines): {video} -> {tgt_srt}")
        except Exception as e:
            failed += 1
            if os.path.exists(tmp):
                os.remove(tmp)
            print(f"FAIL: {video} -- {e}", file=sys.stderr)

    pending = next_pending
    if pending:
        time.sleep(POLL_INTERVAL)

print(f"\ndone: {done}  skipped: {skipped}  failed: {failed}  total: {total}", file=sys.stderr)
PYEOF
