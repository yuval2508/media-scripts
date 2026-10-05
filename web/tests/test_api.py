import os

from conftest import wait_for_job


def log_text(client, jid):
    return client.get(f"/api/jobs/{jid}/log").json()["text"]


# --- path safety ---------------------------------------------------------

def test_browse_rejects_paths_outside_media_root(client):
    for bad in ("/etc", "../../../etc", "/"):
        assert client.get("/api/browse", params={"path": bad}).status_code == 400


def test_symlink_escaping_media_root_is_rejected(client, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, client.media / "sneaky")
    assert client.get("/api/browse", params={"path": str(client.media / "sneaky")}).status_code == 400


def test_job_rejects_path_outside_media_root(client):
    r = client.post("/api/jobs", json={"path": "/etc"})
    assert r.status_code == 400


def test_job_rejects_missing_path(client):
    r = client.post("/api/jobs", json={"path": str(client.media / "nope")})
    assert r.status_code == 404


def test_browse_lists_dirs_videos_and_subs_and_hides_dotfiles(client):
    (client.media / "Show").mkdir()
    (client.media / "ep.mkv").write_text("")
    (client.media / "ep.he.srt").write_text("")
    (client.media / "notes.txt").write_text("")
    (client.media / ".hidden").mkdir()
    entries = {e["name"]: e["type"] for e in client.get("/api/browse").json()["entries"]}
    assert entries == {"Show": "dir", "ep.mkv": "video", "ep.he.srt": "sub"}


def test_browse_root_has_no_parent(client):
    assert client.get("/api/browse").json()["parent"] is None


# --- validation ----------------------------------------------------------

def test_bad_language_code_rejected(client):
    r = client.post("/api/jobs", json={"path": str(client.media), "source_lang": "en;rm -rf"})
    assert r.status_code == 400


def test_bad_whisper_model_rejected(client):
    r = client.post("/api/jobs", json={"path": str(client.media), "whisper_model": "huge"})
    assert r.status_code == 400


def test_jellyfin_option_rejected_when_not_configured(client):
    r = client.post("/api/jobs", json={"path": str(client.media), "notify_jellyfin": True})
    assert r.status_code == 400


def test_config_reports_jellyfin_off_by_default(client):
    assert client.get("/api/config").json()["jellyfin"] is False


def test_config_reports_jellyfin_on_when_configured(jf_client):
    assert jf_client.get("/api/config").json()["jellyfin"] is True


# --- auth ----------------------------------------------------------------

def test_auth_required_when_token_set(auth_client):
    assert auth_client.get("/api/jobs").status_code == 401
    assert auth_client.get("/api/jobs", headers={"X-API-Token": "wrong"}).status_code == 401
    assert auth_client.get("/api/jobs", headers={"X-API-Token": "s3cret"}).status_code == 200
    assert auth_client.get("/api/jobs", headers={"Authorization": "Bearer s3cret"}).status_code == 200


def test_health_and_ui_are_open_even_with_auth(auth_client):
    assert auth_client.get("/health").json() == {"ok": True}
    assert auth_client.get("/").status_code == 200


def test_no_auth_when_token_empty(client):
    assert client.get("/api/jobs").status_code == 200


# --- job lifecycle (fake scripts) ---------------------------------------

def test_full_job_runs_translate_script_with_expected_args(client):
    r = client.post("/api/jobs", json={"path": str(client.media), "whisper_fallback": True,
                                       "whisper_model": "tiny", "force": True})
    assert r.status_code == 201
    job = wait_for_job(client, r.json()["id"])
    assert job["status"] == "done"
    text = log_text(client, job["id"])
    assert "FAKE subs-to-hebrew.sh -s en -t he -a --whisper-fallback -m tiny --force -- " in text


def test_failing_script_marks_job_failed(client):
    (client.media / "FAILME").mkdir()
    r = client.post("/api/jobs", json={"path": str(client.media / "FAILME")})
    job = wait_for_job(client, r.json()["id"])
    assert job["status"] == "failed" and job["exit_code"] == 3


def test_rtl_only_runs_only_the_rtl_script(client):
    r = client.post("/api/jobs", json={"path": str(client.media), "rtl_only": True})
    job = wait_for_job(client, r.json()["id"])
    text = log_text(client, job["id"])
    assert job["status"] == "done"
    assert "fix-rtl-subs.sh" in text and "subs-to-hebrew.sh" not in text


def test_steps_run_in_order_and_stop_on_first_failure(client):
    (client.media / "FAILME").mkdir()
    r = client.post("/api/jobs", json={"path": str(client.media / "FAILME"),
                                       "clean_junk": True, "sync_timing": True})
    job = wait_for_job(client, r.json()["id"])
    text = log_text(client, job["id"])
    assert job["status"] == "failed"
    assert "clean-subtitle-junk.sh" in text
    assert "subs-to-hebrew.sh" not in text  # never reached


def test_jellyfin_env_only_passed_when_requested(jf_client):
    mod = jf_client.mod
    job = {"options": {"notify_jellyfin": False}}
    assert not any(k.startswith("JELLYFIN_") for k in mod.job_env(job))
    job["options"]["notify_jellyfin"] = True
    assert mod.job_env(job)["JELLYFIN_URL"] == "http://jf.test:8096"


def test_api_token_is_not_leaked_to_scripts(auth_client):
    env = auth_client.mod.job_env({"options": {"notify_jellyfin": False}})
    assert "API_TOKEN" not in env


def test_clear_finished_keeps_queued_and_removes_logs(client):
    done = client.post("/api/jobs", json={"path": str(client.media)}).json()["id"]
    wait_for_job(client, done)
    removed = client.delete("/api/jobs").json()["removed"]
    assert removed >= 1
    assert client.get(f"/api/jobs/{done}").status_code == 404
    assert not (client.mod.DATA_DIR / "logs" / f"{done}.log").exists()


def test_cannot_cancel_finished_job(client):
    jid = client.post("/api/jobs", json={"path": str(client.media)}).json()["id"]
    wait_for_job(client, jid)
    assert client.delete(f"/api/jobs/{jid}").status_code == 409


def test_unknown_job_is_404(client):
    assert client.get("/api/jobs/nope").status_code == 404


# --- build_steps ---------------------------------------------------------

def test_build_steps_sync_targets_source_for_full_and_target_for_rtl(client):
    mod = client.mod
    base = {"path": str(client.media), "options": {
        "source_lang": "en", "target_lang": "he", "recurse": False, "whisper_fallback": False,
        "whisper_model": "small", "clean_junk": False, "force": False,
        "notify_jellyfin": False, "rtl_only": False, "sync_timing": True}}
    full = mod.build_steps(base)
    assert full[0][1:3] == ["-s", "en"] and full[0][0].endswith("sync-subs.sh")
    base["options"]["rtl_only"] = True
    rtl = mod.build_steps(base)
    assert rtl[0][1:3] == ["-s", "he"] and rtl[1][0].endswith("fix-rtl-subs.sh")


def test_rtl_only_on_a_video_targets_its_sibling_subtitle(client):
    video = client.media / "ep.mkv"
    video.write_text("")
    steps = client.mod.build_steps({"path": str(video), "options": {
        "source_lang": "en", "target_lang": "he", "recurse": False, "whisper_fallback": False,
        "whisper_model": "small", "clean_junk": False, "force": False,
        "notify_jellyfin": False, "rtl_only": True, "sync_timing": False}})
    assert steps[0][-1] == str(client.media / "ep.he.srt")
