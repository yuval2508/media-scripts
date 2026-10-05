"""Shared fixtures. app.py reads its configuration from the environment at
import time, so each client fixture sets the environment and (re)imports it.
Scripts are replaced by tiny fakes that echo their arguments, so the whole
job path (queue -> subprocess -> log -> status) is exercised without ffmpeg,
Whisper or a media library."""
import importlib
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

FAKE_SCRIPTS = ["subs-to-hebrew.sh", "fix-rtl-subs.sh", "clean-subtitle-junk.sh",
                "sync-subs.sh", "notify-jellyfin.sh"]


def _make_env(tmp_path, monkeypatch, token, jellyfin):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    for name in FAKE_SCRIPTS:
        f = scripts / name
        # Exits 3 when any argument contains FAILME, so failure paths are testable.
        f.write_text('#!/bin/sh\necho "FAKE $(basename "$0") $*"\n'
                     'case "$*" in *FAILME*) exit 3;; esac\n')
        f.chmod(0o755)
    media = tmp_path / "media"
    media.mkdir()
    monkeypatch.setenv("SCRIPTS_DIR", str(scripts))
    monkeypatch.setenv("MEDIA_ROOT", str(media))
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("API_TOKEN", token)
    monkeypatch.setenv("JELLYFIN_URL", "http://jf.test:8096" if jellyfin else "")
    monkeypatch.setenv("JELLYFIN_TOKEN", "k" if jellyfin else "")
    return media


def _load_app():
    import app as app_module
    return importlib.reload(app_module)


@pytest.fixture
def media(tmp_path, monkeypatch):
    return _make_env(tmp_path, monkeypatch, token="", jellyfin=False)


@pytest.fixture
def client(media):
    """No-auth app (the default for a trusted network)."""
    mod = _load_app()
    with TestClient(mod.app) as c:
        c.mod = mod
        c.media = media
        yield c


@pytest.fixture
def auth_client(tmp_path, monkeypatch):
    media = _make_env(tmp_path, monkeypatch, token="s3cret", jellyfin=False)
    mod = _load_app()
    with TestClient(mod.app) as c:
        c.mod, c.media = mod, media
        yield c


@pytest.fixture
def jf_client(tmp_path, monkeypatch):
    media = _make_env(tmp_path, monkeypatch, token="", jellyfin=True)
    mod = _load_app()
    with TestClient(mod.app) as c:
        c.mod, c.media = mod, media
        yield c


def wait_for_job(client, jid, timeout=15):
    """Poll until the job leaves queued/running; returns the final job dict."""
    end = time.time() + timeout
    while time.time() < end:
        job = client.get(f"/api/jobs/{jid}").json()
        if job["status"] not in ("queued", "running"):
            return job
        time.sleep(0.1)
    raise AssertionError(f"job {jid} still {job['status']} after {timeout}s")
