# Contributing

Thanks for helping out. This project is a set of small bash scripts for
subtitle work (extract, transcribe, translate, clean, sync, fix RTL) plus a
FastAPI web UI that runs them in Docker. It started as a personal tool for
translating a media library into Hebrew, so contributions that make it work
better for other languages and setups are especially welcome.

## Layout

| Path | What |
| --- | --- |
| `*.sh` | The pipeline stages. Each is self-contained, prints usage with `-h`, and is safe to re-run (resumable). `subs-to-hebrew.sh` sequences them. |
| `web/app.py` | FastAPI app: job queue, folder browser, log tailing. Shells out to the scripts with argument lists. |
| `web/static/index.html` | The whole UI - one file, no build step. |
| `web/tests/` | pytest suite for the web app. Uses fake scripts, so it needs no ffmpeg, models or media. |
| `web/Dockerfile`, `web/docker-compose.yml` | The packaged deployment. |

## Running the tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r web/requirements-dev.txt
.venv/bin/python -m pytest web/tests
```

CI also runs `shellcheck --severity=error *.sh` and a Docker build on every pull
request. If you have shellcheck installed, run it before pushing.

## Running the app from source

```bash
cd web
cp .env.example .env            # set MEDIA_DIR
docker compose up -d --build    # builds from your checkout
```

The scripts are copied into the image, so rebuild after changing any `*.sh`.

## Guidelines

- **Safety first.** Anything that writes to a media library must be resumable
  and must not overwrite existing output without `--force`. Never build shell
  strings from user input; pass argument lists.
- **Pilot before wide runs.** If you change a stage, try it on one file before a
  whole library, and say in the PR what you tried.
- **Match the existing style** in the files you touch - comment density, naming,
  `set -euo pipefail`, usage text at the top of each script.
- **Add a test** for web/API changes (see `web/tests/test_api.py` for the
  pattern). Script changes are checked by hand; describe what you ran.
- **No personal data in the repo.** No tokens, IP addresses or paths from your
  own setup - use `.env` (gitignored) and placeholders in docs.

## Good first issues

- Source/target language pairs beyond en/he: model selection per language pair
  in `translate-srt.sh`, and RTL handling for other scripts (Arabic, Persian).
- Tests for the shell scripts (e.g. with [bats](https://github.com/bats-core/bats-core)).
- A "post-process only" mode in the UI (skip translation but still clean, sync,
  fix RTL and notify Jellyfin) for people who translate elsewhere.
- Auth beyond a shared token; HTTPS guidance for reverse proxies.
- Multi-arch image builds (arm64) and a slimmer image.

## Security

The web API has no login unless `API_TOKEN` is set and can write into the media
folder you mount. Don't expose it to the internet. Report anything that lets a
request escape `MEDIA_ROOT` or run arbitrary commands privately to the
maintainer rather than in a public issue.
