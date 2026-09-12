# media-scripts

Personal shell scripts for managing a media library: pulling embedded
subtitles out of video files, and fixing RTL (Hebrew/Arabic) subtitle
rendering issues.

Both scripts are self-contained bash, print their own usage with `-h`, and
only depend on tools already common on a media server (`ffmpeg`, `ffprobe`,
`jq`, `python3`).

## extract-subs.sh

Pulls the embedded subtitle track out of one or more MKV/MP4/M4V files using
`ffprobe`/`ffmpeg`. Prefers a clean (non hearing-impaired) track, but falls
back to an SDH/HI one if that's all a file has.

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

Examples:

```bash
# Extract English subs from everything under a season folder
extract-subs.sh -a "/media/tv/Some Show/Season 01"

# Extract French subs, custom suffix, into a separate output dir
extract-subs.sh -l fre -s fr -o /tmp/subs -a /media/tv/Some\ Show
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

```
fix-rtl-subs.sh [-a] FILE_OR_DIR...

  -a    recurse into directories looking for *.srt
```

- Only touches files/lines that actually contain RTL-script characters
  (Hebrew or Arabic block), so it's safe to run over a mixed-language
  subtitle library — non-RTL files are left untouched.
- Idempotent: existing bidi marks (RLM/RLE/PDF/LRM/etc.) are stripped before
  re-wrapping, so re-running it is always safe and never stacks marks.

Examples:

```bash
# Fix one file
fix-rtl-subs.sh "/media/tv/Some Show/S01E01.he.srt"

# Fix every Hebrew/Arabic .srt under a whole library, recursively
fix-rtl-subs.sh -a /media/tv
```

## Typical pipeline

For a show whose files have no embedded subtitles and need translated
subtitles generated (e.g. via Whisper + a translation model), the general
approach used to build these subtitles was:

1. `extract-subs.sh` first, for any files that already carry an embedded
   track — cheaper and more accurate than transcribing audio.
2. For files with nothing embedded, transcribe the audio (e.g.
   `faster-whisper`, forcing the known source language) to produce an
   `.en.srt`.
3. Machine-translate the resulting `.en.srt` text into the target language,
   keeping the original timestamps.
4. If the target language is RTL (Hebrew/Arabic), run `fix-rtl-subs.sh` over
   the output before it ever reaches a player.

Whisper's segment timestamps aren't perfectly reliable on noisy/musical
audio (occasional segments span far longer than the spoken line, or a
following line's start timestamp lands a little early) — worth a
reading-speed-based max-duration cap (~1.2s-7s per line, trimming end times
only) and a long-line word-wrap (~42 chars/line, split at the most balanced
word boundary) as post-processing steps regardless of source.
