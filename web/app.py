"""Web/API wrapper around the subtitle scripts in this repo.

Runs one job at a time (Whisper/translation are CPU-bound, so parallel jobs
would only slow each other down). Each job shells out to the existing bash
scripts with an argument list - nothing is ever interpolated into a shell
string - and its combined output is written to a log file the API can tail.
"""
import asyncio
import json
import os
import re
import secrets
import signal
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

SCRIPTS_DIR = Path(os.environ.get("SCRIPTS_DIR", "/app/scripts"))
MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/media")).resolve()
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
API_TOKEN = os.environ.get("API_TOKEN", "")

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "")
JELLYFIN_TOKEN = os.environ.get("JELLYFIN_TOKEN", "")
JELLYFIN_HOST_PREFIX = os.environ.get("JELLYFIN_HOST_PREFIX", "")
JELLYFIN_CONTAINER_PREFIX = os.environ.get("JELLYFIN_CONTAINER_PREFIX", "")
JELLYFIN_ENABLED = bool(JELLYFIN_URL and JELLYFIN_TOKEN)

WHISPER_MODELS = {"tiny", "base", "small", "medium", "large-v3"}
LANG_RE = re.compile(r"^[a-z]{2,3}$")
VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv", ".ts"}
LOG_CHUNK = 64 * 1024

if not API_TOKEN:
    print("WARNING: API_TOKEN is not set - the API is open to anyone who can reach this port")

(DATA_DIR / "logs").mkdir(parents=True, exist_ok=True)
JOBS_FILE = DATA_DIR / "jobs.json"

jobs: dict[str, dict] = {}
procs: dict[str, asyncio.subprocess.Process] = {}
queue: "asyncio.Queue[str]" = asyncio.Queue()


# --- persistence ---------------------------------------------------------

def save_jobs() -> None:
    tmp = JOBS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(jobs, indent=1))
    tmp.replace(JOBS_FILE)


def load_jobs() -> None:
    if not JOBS_FILE.exists():
        return
    for jid, job in json.loads(JOBS_FILE.read_text()).items():
        if job["status"] == "running":
            job["status"] = "failed"
            job["error"] = "interrupted by server restart (safe to resubmit - the scripts resume)"
            job["finished"] = time.time()
        jobs[jid] = job


# --- auth / path safety --------------------------------------------------

def require_token(request: Request) -> None:
    if not API_TOKEN:  # auth disabled (trusted internal network)
        return
    supplied = request.headers.get("x-api-token", "")
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        supplied = auth[7:]
    if not secrets.compare_digest(supplied.encode(), API_TOKEN.encode()):
        raise HTTPException(401, "invalid or missing API token")


def safe_path(raw: str) -> Path:
    """Resolve raw to an existing path strictly inside MEDIA_ROOT."""
    p = Path(raw)
    if not p.is_absolute():
        p = MEDIA_ROOT / p
    p = p.resolve()
    if p != MEDIA_ROOT and MEDIA_ROOT not in p.parents:
        raise HTTPException(400, f"path must be inside {MEDIA_ROOT}")
    if not p.exists():
        raise HTTPException(404, f"not found: {p}")
    return p


# --- job runner ----------------------------------------------------------

class JobRequest(BaseModel):
    path: str
    source_lang: str = "en"
    target_lang: str = "he"
    recurse: bool = True
    whisper_fallback: bool = False
    whisper_model: str = "small"
    clean_junk: bool = False
    force: bool = False
    notify_jellyfin: bool = False
    rtl_only: bool = False  # only run fix-rtl-subs.sh on existing .srt files
    sync_timing: bool = False  # align subtitle timing to the video with ffsubsync


def build_steps(job: dict) -> list[list[str]]:
    o = job["options"]
    steps = []

    def sync_step(suffix: str) -> list[str]:
        cmd = [str(SCRIPTS_DIR / "sync-subs.sh"), "-s", suffix]
        if o["recurse"]:
            cmd.append("-a")
        return cmd + ["--", job["path"]]

    if o["rtl_only"]:
        if o["sync_timing"]:  # sync before the RTL marks are added
            steps.append(sync_step(o["target_lang"]))
        target = job["path"]
        p = Path(target)
        if p.is_file() and p.suffix.lower() != ".srt":  # video -> its sibling subtitle
            target = str(p.with_suffix("")) + f".{o['target_lang']}.srt"
        cmd = [str(SCRIPTS_DIR / "fix-rtl-subs.sh")]
        if o["recurse"]:
            cmd.append("-a")
        steps.append(cmd + ["--", target])
        if o["notify_jellyfin"]:
            d = p if p.is_dir() else p.parent
            steps.append([str(SCRIPTS_DIR / "notify-jellyfin.sh"), str(d)])
        return steps
    if o["clean_junk"]:
        cmd = [str(SCRIPTS_DIR / "clean-subtitle-junk.sh")]
        if o["recurse"]:
            cmd.append("-a")
        steps.append(cmd + ["--", job["path"]])
    if o["sync_timing"]:  # sync the source subtitle; the translation inherits its timing
        steps.append(sync_step(o["source_lang"]))
    cmd = [str(SCRIPTS_DIR / "subs-to-hebrew.sh"),
           "-s", o["source_lang"], "-t", o["target_lang"]]
    if o["recurse"]:
        cmd.append("-a")
    if o["whisper_fallback"]:
        cmd += ["--whisper-fallback", "-m", o["whisper_model"]]
    if o["force"]:
        cmd.append("--force")
    steps.append(cmd + ["--", job["path"]])
    return steps


def job_env(job: dict) -> dict:
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("JELLYFIN_") and k != "API_TOKEN"}
    if job["options"]["notify_jellyfin"] and JELLYFIN_ENABLED:
        env["JELLYFIN_URL"] = JELLYFIN_URL
        env["JELLYFIN_TOKEN"] = JELLYFIN_TOKEN
        if JELLYFIN_HOST_PREFIX and JELLYFIN_CONTAINER_PREFIX:
            env["JELLYFIN_HOST_PREFIX"] = JELLYFIN_HOST_PREFIX
            env["JELLYFIN_CONTAINER_PREFIX"] = JELLYFIN_CONTAINER_PREFIX
    return env


async def run_job(jid: str) -> None:
    job = jobs[jid]
    if job["status"] != "queued":  # cancelled while waiting
        return
    job["status"] = "running"
    job["started"] = time.time()
    save_jobs()
    rc = 0
    with open(DATA_DIR / "logs" / f"{jid}.log", "ab") as log:
        for cmd in build_steps(job):
            log.write(f"$ {' '.join(cmd)}\n".encode())
            log.flush()
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=log, stderr=asyncio.subprocess.STDOUT,
                env=job_env(job), start_new_session=True)
            procs[jid] = proc
            rc = await proc.wait()
            procs.pop(jid, None)
            if job.get("cancel_requested") or rc != 0:
                break
    job["finished"] = time.time()
    job["exit_code"] = rc
    if job.get("cancel_requested"):
        job["status"] = "cancelled"
    elif rc != 0:
        job["status"] = "failed"
        job["error"] = f"exit code {rc}"
    else:
        job["status"] = "done"
    save_jobs()


async def worker() -> None:
    while True:
        jid = await queue.get()
        try:
            await run_job(jid)
        except Exception as e:  # keep the worker alive whatever one job does
            jobs[jid].update(status="failed", error=repr(e), finished=time.time())
            save_jobs()


async def lifespan(app: FastAPI):
    load_jobs()
    for jid, job in jobs.items():
        if job["status"] == "queued":
            queue.put_nowait(jid)
    task = asyncio.create_task(worker())
    yield
    task.cancel()


app = FastAPI(title="Subtitle translation API", lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/api/config", dependencies=[Depends(require_token)])
def config():
    return {"media_root": str(MEDIA_ROOT), "jellyfin": JELLYFIN_ENABLED,
            "whisper_models": sorted(WHISPER_MODELS)}


@app.get("/api/browse", dependencies=[Depends(require_token)])
def browse(path: str = Query("")):
    p = safe_path(path or str(MEDIA_ROOT))
    if not p.is_dir():
        raise HTTPException(400, "not a directory")
    entries = []
    for child in sorted(p.iterdir(), key=lambda c: c.name.lower()):
        if child.name.startswith("."):
            continue
        if child.is_dir():
            entries.append({"name": child.name, "type": "dir"})
        elif child.suffix.lower() in VIDEO_EXTS:
            entries.append({"name": child.name, "type": "video"})
        elif child.suffix.lower() == ".srt":
            entries.append({"name": child.name, "type": "sub"})
    parent = str(p.parent) if p != MEDIA_ROOT else None
    return {"path": str(p), "parent": parent, "entries": entries}


@app.post("/api/jobs", status_code=201, dependencies=[Depends(require_token)])
def create_job(req: JobRequest):
    p = safe_path(req.path)
    for lang in (req.source_lang, req.target_lang):
        if not LANG_RE.match(lang):
            raise HTTPException(400, f"bad language code: {lang!r} (use ISO 639-1, e.g. en)")
    if req.whisper_model not in WHISPER_MODELS:
        raise HTTPException(400, f"whisper_model must be one of {sorted(WHISPER_MODELS)}")
    if req.notify_jellyfin and not JELLYFIN_ENABLED:
        raise HTTPException(400, "Jellyfin notification is not configured on this server")
    options = req.model_dump(exclude={"path"})
    options["recurse"] = req.recurse and p.is_dir()
    jid = uuid.uuid4().hex[:12]
    jobs[jid] = {"id": jid, "path": str(p), "options": options, "status": "queued",
                 "created": time.time(), "started": None, "finished": None,
                 "exit_code": None, "error": None}
    save_jobs()
    queue.put_nowait(jid)
    return jobs[jid]


@app.get("/api/jobs", dependencies=[Depends(require_token)])
def list_jobs():
    return sorted(jobs.values(), key=lambda j: j["created"], reverse=True)


def get_job(jid: str) -> dict:
    if jid not in jobs:
        raise HTTPException(404, "no such job")
    return jobs[jid]


@app.get("/api/jobs/{jid}", dependencies=[Depends(require_token)])
def job_detail(jid: str):
    return get_job(jid)


@app.get("/api/jobs/{jid}/log", dependencies=[Depends(require_token)])
def job_log(jid: str, offset: int = Query(0, ge=0)):
    get_job(jid)
    f = DATA_DIR / "logs" / f"{jid}.log"
    if not f.exists():
        return {"offset": 0, "text": ""}
    with open(f, "rb") as fh:
        size = f.stat().st_size
        if offset == 0 and size > LOG_CHUNK:  # first load: just the tail
            offset = size - LOG_CHUNK
        fh.seek(offset)
        data = fh.read(LOG_CHUNK)
    return {"offset": offset + len(data), "text": data.decode("utf-8", "replace")}


@app.delete("/api/jobs", dependencies=[Depends(require_token)])
def clear_finished():
    """Remove every done/failed/cancelled job (and its log); queued/running stay."""
    gone = [jid for jid, j in jobs.items() if j["status"] in ("done", "failed", "cancelled")]
    for jid in gone:
        del jobs[jid]
        (DATA_DIR / "logs" / f"{jid}.log").unlink(missing_ok=True)
    save_jobs()
    return {"removed": len(gone)}


@app.delete("/api/jobs/{jid}", dependencies=[Depends(require_token)])
def cancel_job(jid: str):
    job = get_job(jid)
    if job["status"] == "queued":
        job.update(status="cancelled", finished=time.time())
    elif job["status"] == "running":
        job["cancel_requested"] = True
        proc = procs.get(jid)
        if proc and proc.returncode is None:
            os.killpg(proc.pid, signal.SIGTERM)
    else:
        raise HTTPException(409, f"job already {job['status']}")
    save_jobs()
    return job


@app.get("/")
def index():
    return FileResponse(Path(__file__).parent / "static" / "index.html")


app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")
