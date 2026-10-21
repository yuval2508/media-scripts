#!/usr/bin/env bash
#
# strip-hi.sh — convert hearing-impaired (SDH) subtitle sidecars into normal
# ones: <base>.en.hi.srt -> <base>.en.srt, with the sound descriptions and
# speaker labels removed.
#
# Hearing-impaired tracks carry text that isn't speech: sound cues like
# (LAUGHS), (SPEAKING ITALIAN) or [door slams], and speaker labels like
# "BELLA: ...". Fed to translate-srt.sh that text gets translated and shown
# as if it were dialogue, and translate-srt.sh only looks for <base>.SRC.srt
# anyway, so a lone .hi.srt is never picked up at all. This turns the former
# into the latter.
#
# What gets removed (conservative on purpose - a missed annotation is a minor
# annoyance, a deleted line of dialogue is a bug):
#   - [bracketed] groups, any case
#   - (parenthesised) groups whose text is ALL CAPS, or that make up a whole
#     line on their own, e.g. "(LAUGHS)", "(laughs)", "(SPEAKING ITALIAN)"
#   - ALL-CAPS speaker labels at the start of a line ("BELLA: Hi") or right
#     after a sentence ("Yeah. EMMETT: Come on")
#   - cues that are left empty (or only music notes) after the above, which
#     are dropped; the remaining cues are renumbered
# Timing and everything else, including ♪ lyrics and <i> markup, is untouched.
# Known limitation: a line of ALL-CAPS shouting with a colon in it
# ("STOP: THIS IS WRONG") loses its first word - spot-check results.
#
# Usage:
#   strip-hi.sh [-a] [--in-place] [--keep-original] [--force] FILE_OR_DIR...
#
#   -a                recurse into directories looking for *.hi.srt
#   --in-place        clean any .srt in place without renaming it (for a
#                     downloaded SDH subtitle that isn't named .hi.srt)
#   --keep-original   keep the .hi.srt after converting it (default: remove it,
#                     since it has been converted and is just clutter)
#   --force           replace an existing <base>.en.srt. Without it, if a
#                     normal subtitle already exists the .hi.srt is left alone.
#
# A directory argument converts every *.hi.srt in it. Safe to re-run: with no
# .hi.srt files left there is nothing to do. If cleaning would leave a file
# with no cues at all, nothing is written and the original is kept.

set -euo pipefail

RECURSE=0
IN_PLACE=0
KEEP=0
FORCE=0
FILES=()

usage() {
    grep '^#' "$0" | sed -n '2,40p' | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) RECURSE=1; shift ;;
        --in-place) IN_PLACE=1; shift ;;
        --keep-original) KEEP=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift; FILES+=("$@"); break ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    usage
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found in PATH" >&2; exit 1; }

# Directories yield their *.hi.srt files; with --in-place, every *.srt.
if [[ $IN_PLACE -eq 1 ]]; then NAME_MATCH='*.srt'; else NAME_MATCH='*.hi.srt'; fi

SRT_FILES=()
for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
        if [[ $RECURSE -eq 1 ]]; then
            while IFS= read -r -d '' s; do SRT_FILES+=("$s"); done \
                < <(find "$f" -type f -iname "$NAME_MATCH" ! -name '._*' -print0)
        else
            while IFS= read -r -d '' s; do SRT_FILES+=("$s"); done \
                < <(find "$f" -maxdepth 1 -type f -iname "$NAME_MATCH" ! -name '._*' -print0)
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
    echo "error: no ${NAME_MATCH#\*.} files to process" >&2
    exit 1
fi

IN_PLACE="$IN_PLACE" KEEP="$KEEP" FORCE="$FORCE" python3 - "${SRT_FILES[@]}" <<'PYEOF'
import os, re, shutil, sys

sys.stdout.reconfigure(line_buffering=True)
IN_PLACE = os.environ["IN_PLACE"] == "1"
KEEP = os.environ["KEEP"] == "1"
FORCE = os.environ["FORCE"] == "1"

TAG_RE = re.compile(r"</?[A-Za-z][^>]*>")
BRACKET_RE = re.compile(r"\[[^\]]*\]")
PAREN_RE = re.compile(r"\(([^)]*)\)")
# Whole line is just a parenthetical, e.g. "(laughs)" or "- (GASPS)".
WHOLE_PAREN_RE = re.compile(r"^(?:\s|<[^>]*>|[-–])*\([^)]*\)[\s.!?]*(?:<[^>]*>)*\s*$")
LABEL = r"[A-Z][A-Z0-9 .'’\-]{1,24}"
LABEL_START_RE = re.compile(r"^((?:\s|<[^>]*>|[-–])*)" + LABEL + r"\s*:(?:\s+|$)")
LABEL_MID_RE = re.compile(r"(?<=[.!?…] )" + LABEL + r"\s*:\s+")
MUSIC_ONLY_RE = re.compile(r"^[\s♪♫♬#\-–]*$")


def paren_repl(m):
    # Only drop a parenthetical that has no lowercase letters; "(sic)" or an
    # aside in real dialogue stays.
    return "" if not any(c.islower() for c in m.group(1)) else m.group(0)


def clean_cue(text_lines):
    """Returns (new_lines, annotations_removed, labels_removed)."""
    annotations = labels = 0
    # Drop whole-line parentheticals first, then work on the joined text so
    # groups that wrap across two lines "(MAN SPEAKING\nINDISTINCTLY)" match.
    kept = []
    for l in text_lines:
        if WHOLE_PAREN_RE.match(l):
            annotations += 1
        else:
            kept.append(l)
    joined = "\n".join(kept)

    joined, n = BRACKET_RE.subn("", joined)
    annotations += n
    before = joined
    joined = PAREN_RE.sub(paren_repl, joined)
    annotations += before.count("(") - joined.count("(")

    out = []
    for l in joined.split("\n"):
        l, n1 = LABEL_START_RE.subn(r"\1", l, count=1)
        l, n2 = LABEL_MID_RE.subn("", l)
        labels += n1 + n2
        l = re.sub(r"[ \t]{2,}", " ", l).strip()
        visible = TAG_RE.sub("", l).strip()
        if not visible or MUSIC_ONLY_RE.match(visible):
            continue
        out.append(l)
    # A lone remaining line doesn't need a speaker dash any more.
    if len(out) == 1:
        out[0] = re.sub(r"^((?:<[^>]*>)*)[-–]\s+", r"\1", out[0])
    return out, annotations, labels


def convert(path):
    with open(path, encoding="utf-8-sig") as f:
        content = f.read().replace("\r\n", "\n")
    blocks = re.split(r"\n\s*\n", content.strip())
    cues = []
    dropped = annotations = labels = 0
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        ts, text = lines[1], lines[2:]
        new, a, lb = clean_cue(text)
        annotations += a
        labels += lb
        if not new:
            dropped += 1
            continue
        cues.append((ts, new))
    return cues, dropped, annotations, labels


def write_srt(path, cues, like):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for i, (ts, lines) in enumerate(cues, 1):
            f.write(f"{i}\n{ts}\n" + "\n".join(lines) + "\n\n")
    shutil.copymode(like, tmp)
    os.replace(tmp, path)


converted = skipped = failed = 0
for path in sys.argv[1:]:
    if IN_PLACE:
        out = path
    else:
        m = re.search(r"\.hi\.srt$", path, re.I)
        if not m:
            print(f"skip: {path} - not a .hi.srt (use --in-place to clean it in place)", file=sys.stderr)
            skipped += 1
            continue
        out = path[:m.start()] + ".srt"
        if os.path.exists(out) and not FORCE:
            print(f"skip: {out} already exists - leaving {path} alone (--force to replace it)", file=sys.stderr)
            skipped += 1
            continue
    try:
        cues, dropped, annotations, labels = convert(path)
    except (OSError, UnicodeDecodeError) as e:
        print(f"fail: {path} - {e}", file=sys.stderr)
        failed += 1
        continue
    if not cues:
        print(f"fail: {path} - nothing left after cleaning, original kept", file=sys.stderr)
        failed += 1
        continue
    write_srt(out, cues, like=path)
    if not IN_PLACE and not KEEP:
        os.remove(path)
    converted += 1
    print(f"ok: {path} -> {out} ({len(cues)} cues kept, {dropped} dropped, "
          f"{annotations} annotations and {labels} speaker labels removed)")

print(f"\nconverted: {converted}  skipped: {skipped}  failed: {failed}", file=sys.stderr)
sys.exit(1 if failed else 0)
PYEOF
