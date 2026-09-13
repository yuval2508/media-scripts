# media-scripts

Personal shell scripts for managing a media library: pulling embedded
subtitles out of video files, generating subtitles from audio when there's
nothing embedded, machine-translating them, cleaning up common quality
issues, and fixing RTL (Hebrew/Arabic) subtitle rendering issues.

Every script is self-contained bash and prints its own usage with `-h`.
`extract-subs.sh`, `fix-rtl-subs.sh`, `cap-subtitle-duration.sh`, and
`wrap-subtitle-lines.sh` only need tools already common on a media server
(`ffmpeg`, `ffprobe`, `jq`, `python3`). `whisper-transcribe.sh` and
`translate-srt.sh` need the Python venv described below.

For the common case - translating a whole library into Hebrew - use
`subs-to-hebrew.sh` (below), which sequences all of these for you. The
individual scripts are documented here for when you want a single stage on
its own, or a different target language than Hebrew.

## Scripts

| Script | What it does |
| --- | --- |
| [`extract-subs.sh`](#extract-subssh) | Pull an already-embedded subtitle track out of a video file - the cheap, accurate option when one exists |
| [`whisper-transcribe.sh`](#whisper-transcribesh) | Transcribe audio to `.srt` with faster-whisper, for files with nothing embedded |
| [`translate-srt.sh`](#translate-srtsh) | Machine-translate an existing `.srt` into another language, keeping timestamps |
| [`cap-subtitle-duration.sh`](#cap-subtitle-durationsh) | Clip subtitle lines that linger on screen far longer than their text needs |
| [`wrap-subtitle-lines.sh`](#wrap-subtitle-linessh) | Wrap long single-line subtitles into two balanced lines |
| [`fix-rtl-subs.sh`](#fix-rtl-subssh) | Fix Hebrew/Arabic punctuation rendering on players that force LTR paragraph direction |
| [`subs-to-hebrew.sh`](#subs-to-hebrewsh) | Orchestrator - runs all of the above in the right order for a whole show/library in one command |

## Prerequisites

These need to be actual system packages, not assumed present:

```bash
# Debian/Ubuntu
sudo apt install ffmpeg jq python3 python3-venv

# macOS (Homebrew)
brew install ffmpeg jq python3
```

`ffmpeg`/`ffprobe` and `jq` are needed by `extract-subs.sh`,
`cap-subtitle-duration.sh`, `wrap-subtitle-lines.sh`, and `fix-rtl-subs.sh`.
`python3` (with a working `venv` module) is needed by all of those plus the
setup below.

**Gotcha hit while building this**: on Debian/Ubuntu, a plain `python3` can
exist without `venv` actually working — `python3 -m venv` fails with
`ensurepip is not available`, because the distro splits that out into a
separate `python3.N-venv` package (e.g. `python3.12-venv`) that isn't
always installed by default. `apt install python3-venv` (or the
version-pinned name it points you to) fixes it. This is exactly why this
repo's own venv ended up built with a Homebrew-installed Python instead of
the system one on the machine this was first set up on — check
`python3 --version` and `which python3` if venv creation below fails
inexplicably; it may be silently falling back to a different Python than
you expect.

## Setup for the Whisper/translation scripts

```bash
python3 -m venv .venvs/whisper-subs
.venvs/whisper-subs/bin/pip install faster-whisper transformers sentencepiece sacremoses
.venvs/whisper-subs/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch
```

(CPU-only torch; drop the `--index-url` line if the machine has a CUDA GPU
and you want to install the GPU build instead.) `.venvs/` is gitignored —
each machine builds its own, so this step needs to be repeated on a fresh
machine or after losing the local environment; nothing else in this repo
depends on it existing beyond `whisper-transcribe.sh` and `translate-srt.sh`
themselves refusing to run and telling you to create it.

Both scripts download their model from Hugging Face on first use
(`faster-whisper`'s `small` model is roughly 500MB; the `Helsinki-NLP`
translation model is roughly 300MB) and cache it under `~/.cache/huggingface`
- the very first run of each needs internet access and a minute or two;
every run after that is fully offline.

## extract-subs.sh

Pulls the embedded subtitle track out of one or more MKV/MP4/M4V files using
`ffprobe`/`ffmpeg`. Prefers a clean (non hearing-impaired) track, but falls
back to an SDH/HI one if that's all a file has. Always try this before
transcribing audio — it's faster and more accurate than Whisper when a
usable track already exists.

Text-based subtitle codecs (SubRip/ASS/SSA/MOV_TEXT/WebVTT) are converted to
`.srt`. Image-based codecs are copied out in their native form instead
(`.sup` for PGS; VobSub gets wrapped in a minimal Matroska container as
`.mks`, matching `mkvextract`'s own convention, since this ffmpeg build has
no standalone VobSub muxer).

```
extract-subs.sh [-l LANG] [-s SUFFIX] [-o OUTDIR] [-a] [--no-hi] [--force] FILE_OR_DIR...

  -l LANG      ISO 639-2 language code to match in the file (default: eng)
  -s SUFFIX    filename suffix for the output file (default: derived from
               LANG, e.g. eng -> en, fre -> fr; falls back to LANG itself)
  -o OUTDIR    write extracted subs here instead of next to the source file
  -a           recurse into directories looking for *.mkv/*.mp4/*.m4v
  --no-hi      skip a file entirely if only a hearing-impaired/SDH track
               exists, instead of falling back to it
  --force      overwrite existing output files
```

```bash
# Extract English subs from everything under a season folder
extract-subs.sh -a "/media/tv/Some Show/Season 01"

# Extract French subs, custom suffix, into a separate output dir
extract-subs.sh -l fre -s fr -o /tmp/subs -a /media/tv/Some\ Show
```

## whisper-transcribe.sh

For files with no usable embedded track: transcribes the audio into an
`.srt` using `faster-whisper`, forcing the known spoken language (avoids
misdetection from a foreign-language opening theme song before the real
dialogue starts).

```
whisper-transcribe.sh [-l LANG] [-m MODEL] [-o OUTDIR] [-a] [--force] FILE_OR_DIR...

  -l LANG    language spoken in the audio (ISO 639-1, e.g. en, ja; default: en)
  -m MODEL   faster-whisper model size: tiny/base/small/medium/large-v3
             (default: small - ~7-8x realtime on an 8-core CPU)
  -o OUTDIR  write output here instead of next to the source file
  -a         recurse into directories looking for *.mkv/*.mp4/*.m4v
  --force    re-transcribe even if the output .LANG.srt already exists
```

Output goes to `<base>.<LANG>.srt`. Already-transcribed files are skipped,
so a long batch job can be killed and re-run to resume where it left off —
useful since a CPU-only run over a full season/series can take hours.

```bash
# Transcribe every episode in a season, forcing English, small model
whisper-transcribe.sh -a -l en "/media/tv/Some Show/Season 03"
```

**Caveat**: Whisper's own segment timestamps aren't fully reliable on noisy
or music-heavy audio — a short line can occasionally get a wildly inflated
end time (a real observed case: "Gil's unbelievable." displayed for 56
seconds because Whisper's segmentation swallowed a long stretch of
theme-song audio into one segment). Chunked transcription and disabling VAD
were both tried as fixes and only partially helped — accepted as a known
CPU-only-small-model limitation rather than chasing it further with a
bigger, much slower model. Run `cap-subtitle-duration.sh` afterward
regardless of source to clip this down to something reasonable.

## translate-srt.sh

Machine-translates an existing `<base>.SRC.srt` (from either
`extract-subs.sh` or `whisper-transcribe.sh`) into `<base>.TGT.srt`, keeping
timestamps and only translating text.

```
translate-srt.sh -s SRC -t TGT [-a] [--force] [--wait] [--model NAME] FILE_OR_DIR...

  -s SRC       source language code of the existing <base>.SRC.srt
  -t TGT       target language code; output is <base>.TGT.srt
  --model NAME Hugging Face translation model (default:
               Helsinki-NLP/opus-mt-SRC-TGT - small, fast, CPU-friendly for
               that specific pair; use something like
               facebook/nllb-200-distilled-600M when there's no dedicated
               opus-mt model for the pair, or for higher quality at the
               cost of speed)
  -a           recurse into directories looking for *.mkv/*.mp4/*.m4v
  --force      re-translate even if the output already exists
  --wait       poll every 30s for a not-yet-existing source .srt instead of
               skipping - run this concurrently with a whisper-transcribe.sh
               batch job (in a second terminal) so translation keeps pace
               with transcription instead of waiting for it to finish first
```

```bash
# Translate a season's English subs to Hebrew, waiting on transcription
# running concurrently in another terminal
translate-srt.sh -s en -t he -a --wait "/media/tv/Some Show/Season 03"
```

## cap-subtitle-duration.sh

Clips subtitle blocks that display for far longer than their text needs
down to a reading-speed-based maximum. Only ever shortens end times — start
times (sync) are never touched.

```
cap-subtitle-duration.sh [-a] [--min SEC] [--max SEC] [--cps N] FILE_OR_DIR...

  -a        recurse into directories looking for *.srt
  --min SEC minimum display duration regardless of text length (default: 1.2)
  --max SEC maximum display duration regardless of text length (default: 7.0)
  --cps N   assumed reading speed, characters/second (default: 13.3)
```

Safe to re-run — it only ever shortens, so a second pass on already-capped
durations is a no-op.

## wrap-subtitle-lines.sh

Wraps long single-line subtitle text into two balanced lines (finds the
word boundary closest to the middle, rather than greedily filling the first
line). Run this **before** `fix-rtl-subs.sh` if the target language is RTL.

```
wrap-subtitle-lines.sh [-a] [-w MAXWIDTH] FILE_OR_DIR...

  -a          recurse into directories looking for *.srt
  -w MAXWIDTH target max characters per line (default: 42)
```

## fix-rtl-subs.sh

Fixes punctuation/number placement in RTL-language (Hebrew, Arabic, etc.)
`.srt` files for players that force LTR paragraph direction on subtitle
cues — notably Jellyfin's web client, which
[deliberately prepends an LTR mark to every subtitle line](https://github.com/jellyfin/jellyfin-web/issues/4179)
to match a legacy convention where RTL subtitle files were authored in
visual (pre-reversed) order.

Under that forced-LTR behavior, trailing weak characters (`.`, `?`, numbers,
etc.) resolve to the paragraph's forced LTR direction instead of following
the preceding RTL text, so they visually land on the wrong side — e.g. a
Hebrew question ends up with the `?` rendered at the start of the line
instead of the end.

The fix: wrap each subtitle line in an explicit RTL embedding
(`U+202B` RLE ... `U+202C` PDF). That creates a hard directional scope that
resolves correctly regardless of what the outer paragraph is forced to.

Handles legacy single-byte encodings too (many downloaded Hebrew/Arabic
`.srt` files are Windows-1255/1256 or ISO-8859-8, not UTF-8) — decodes with
a fallback chain and always rewrites as UTF-8, since the RLE/PDF marks need
real Unicode.

```
fix-rtl-subs.sh [-a] FILE_OR_DIR...

  -a    recurse into directories looking for *.srt
```

- Only touches files/lines that actually contain RTL-script characters, so
  it's safe to run over a mixed-language subtitle library — non-RTL files
  are left untouched.
- **utf-8 always wins if it decodes cleanly, full stop.** An earlier version
  of this script instead preferred whichever candidate encoding happened to
  produce RTL-looking characters, which was a real, costly bug: a valid
  UTF-8 multi-byte sequence (e.g. the bytes for `™`) reinterpreted
  byte-by-byte under cp1255 can decode to a genuine Hebrew letter by pure
  coincidence, so plain English (or any non-RTL) subtitle files containing
  an ordinary special character got wrongly corrupted. Recovered by
  reversing the deterministic encode/decode round-trip — but the lesson is:
  never let "produces RTL-looking output" outrank a clean UTF-8 decode when
  picking an encoding.
- Idempotent: existing bidi marks (RLM/RLE/PDF/LRM/etc.) are stripped before
  re-wrapping, so re-running it is always safe and never stacks marks.
- One bad/corrupt file doesn't abort the batch — it's reported and skipped.

```bash
# Fix one file
fix-rtl-subs.sh "/media/tv/Some Show/S01E01.he.srt"

# Fix every Hebrew/Arabic .srt under a whole library, recursively
fix-rtl-subs.sh -a /media/tv
```

## subs-to-hebrew.sh

Orchestrates the full pipeline in one command: `extract-subs.sh` →
(optionally `whisper-transcribe.sh`) → `translate-srt.sh` →
`cap-subtitle-duration.sh` → `wrap-subtitle-lines.sh` → `fix-rtl-subs.sh`.
Despite the name, the target language is a flag, not hardcoded — it just
defaults to the case this was built for.

```
subs-to-hebrew.sh [-s SRC] [-t TGT] [-m MODEL] [-a] [--whisper-fallback] [--force] FILE_OR_DIR...

  -s SRC              source language, ISO 639-1 (default: en)
  -t TGT              target language, ISO 639-1 (default: he)
  -m MODEL            faster-whisper model size, only used with
                       --whisper-fallback (default: small)
  -a                  recurse into directories (forwarded to every stage)
  --whisper-fallback  for files with no embedded SRC track, transcribe the
                       audio with Whisper instead of just skipping them.
                       Off by default: transcription is slow and CPU-heavy,
                       so a plain run only translates whatever's already
                       embedded, at effectively no compute cost.
  --force             forwarded to every stage
```

Every stage is independently safe to skip files it has nothing to do for
(no embedded track and no `--whisper-fallback` → nothing to translate →
nothing to clean up → done), so this is resumable the same way each script
already is — kill it partway through a big batch and re-run to pick up
where it left off. `fix-rtl-subs.sh` always runs last regardless of `-t`,
since it harmlessly no-ops on non-RTL output.

```bash
# The common case: whatever's already embedded, translated to Hebrew,
# at no Whisper cost, across the whole library
subs-to-hebrew.sh -a /media/tv

# One show, also transcribing audio for episodes with nothing embedded
subs-to-hebrew.sh -a --whisper-fallback "/media/tv/Some Show"

# A different target language than Hebrew
subs-to-hebrew.sh -a -t fr "/media/tv/Some Show"
```

## Credits

Built by [Yuval Benjamin](https://github.com/yuval2508) working through a
real subtitle pipeline for a personal media library, in collaboration with
Claude (Anthropic) — including catching and fixing a couple of real bugs
along the way (see `fix-rtl-subs.sh`'s and the extension-check note above).
The commit history reflects this as it happened, not after the fact.

MIT licensed - see `LICENSE`.
