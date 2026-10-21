"""strip-hi.sh needs only bash + python3, so these run against the real script."""
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "strip-hi.sh"


def srt(*cues):
    return "".join(f"{i}\n00:00:{i:02d},000 --> 00:00:{i:02d},500\n{c}\n\n"
                   for i, c in enumerate(cues, 1))


def text_of(path):
    """Cue texts only, as a list of strings."""
    blocks = path.read_text(encoding="utf-8").strip().split("\n\n")
    return [b.split("\n", 2)[2] for b in blocks]


def run(*args):
    return subprocess.run(["bash", str(SCRIPT), *map(str, args)], capture_output=True, text=True)


def convert(tmp_path, *cues, extra=()):
    hi = tmp_path / "Movie.en.hi.srt"
    hi.write_text(srt(*cues), encoding="utf-8")
    r = run(*extra, hi)
    return r, tmp_path / "Movie.en.srt", hi


def test_converts_hi_to_normal_and_removes_original(tmp_path):
    r, out, hi = convert(tmp_path, "BELLA: Hello.", "(LAUGHS)", "See you.")
    assert r.returncode == 0
    assert text_of(out) == ["Hello.", "See you."]
    assert not hi.exists()


def test_cues_are_renumbered_and_timing_kept(tmp_path):
    _, out, _ = convert(tmp_path, "(DOOR SLAMS)", "Hi.")
    assert out.read_text(encoding="utf-8").startswith("1\n00:00:02,000 --> 00:00:02,500\nHi.")


def test_annotation_kinds(tmp_path):
    _, out, _ = convert(
        tmp_path,
        "[door slams]",                       # bracket, any case
        "(laughs)",                           # whole line, lower case
        "- (GASPS)\n- Oh my gosh!",           # dash + annotation on its own line
        "(MAN SPEAKING\nINDISTINCTLY)",       # wraps two lines
        "<i>(SIGHS)</i>",                     # inside markup
        "♪ (SOFT MUSIC) ♪",                   # leaves only notes
        "(EMMETT WHISTLES) What is that?",    # inline
        "Real line.",
    )
    assert text_of(out) == ["Oh my gosh!", "What is that?", "Real line."]


def test_speaker_labels(tmp_path):
    _, out, _ = convert(tmp_path, "JACOB: Hey.", "- ALICE: Yes.\n- EDWARD: No.",
                        "Yeah. EMMETT: Come on.", "<i>BELLA: Thinking.</i>", "MAN ON TV: News.")
    assert text_of(out) == ["Hey.", "- Yes.\n- No.", "Yeah. Come on.", "<i>Thinking.</i>", "News."]


def test_real_dialogue_is_left_alone(tmp_path):
    keep = ["Time: 10:30", "Note: bring a coat", "He said (sic) it twice.",
            "I told you so.", "♪ la la la ♪", "- Yes.\n- No."]
    _, out, _ = convert(tmp_path, *keep)
    assert text_of(out) == keep


def test_existing_normal_subtitle_is_not_overwritten(tmp_path):
    normal = tmp_path / "Movie.en.srt"
    normal.write_text(srt("Good original."), encoding="utf-8")
    hi = tmp_path / "Movie.en.hi.srt"
    hi.write_text(srt("BELLA: Other."), encoding="utf-8")
    r = run(hi)
    assert r.returncode == 0 and "already exists" in r.stderr
    assert text_of(normal) == ["Good original."] and hi.exists()


def test_force_replaces_existing(tmp_path):
    (tmp_path / "Movie.en.srt").write_text(srt("Old."), encoding="utf-8")
    hi = tmp_path / "Movie.en.hi.srt"
    hi.write_text(srt("BELLA: New."), encoding="utf-8")
    assert run("--force", hi).returncode == 0
    assert text_of(tmp_path / "Movie.en.srt") == ["New."]


def test_keep_original(tmp_path):
    _, out, hi = convert(tmp_path, "BELLA: Hi.", extra=["--keep-original"])
    assert out.exists() and hi.exists()


def test_file_that_cleans_to_nothing_is_kept_untouched(tmp_path):
    r, out, hi = convert(tmp_path, "(LAUGHS)", "[music]")
    assert r.returncode == 1
    assert not out.exists() and hi.exists()


def test_directory_argument_only_picks_hi_files(tmp_path):
    (tmp_path / "A.en.hi.srt").write_text(srt("MAN: a"), encoding="utf-8")
    (tmp_path / "B.en.srt").write_text(srt("MAN: b"), encoding="utf-8")
    assert run(tmp_path).returncode == 0
    assert text_of(tmp_path / "A.en.srt") == ["a"]
    assert text_of(tmp_path / "B.en.srt") == ["MAN: b"]   # normal subs untouched


def test_in_place_cleans_a_normal_named_file(tmp_path):
    f = tmp_path / "Movie.en.srt"
    f.write_text(srt("(LAUGHS) Hi.", "BELLA: Bye."), encoding="utf-8")
    assert run("--in-place", f).returncode == 0
    assert text_of(f) == ["Hi.", "Bye."]


def test_rerun_is_a_no_op(tmp_path):
    convert(tmp_path, "BELLA: Hi.")
    assert run(tmp_path).returncode == 1       # no .hi.srt files left
    assert text_of(tmp_path / "Movie.en.srt") == ["Hi."]


def test_non_hi_file_argument_is_skipped(tmp_path):
    f = tmp_path / "Movie.en.srt"
    f.write_text(srt("BELLA: Hi."), encoding="utf-8")
    r = run(f)
    assert "not a .hi.srt" in r.stderr and text_of(f) == ["BELLA: Hi."]
