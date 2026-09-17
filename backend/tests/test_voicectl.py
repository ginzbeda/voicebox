"""Tests for scripts/claude/voicectl.sh, the script behind /say.

The one that matters most is the merge behaviour of `profile`. PUT /mcp/bindings
is a full replace — backend/routes/mcp_bindings.py assigns label, profile_id,
default_engine and default_personality unconditionally from the request body —
so a naive "set the voice" would silently wipe this client's engine and
personality settings. There is nothing in the endpoint's name to warn you.
"""

from __future__ import annotations

import contextlib
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
VOICECTL = REPO_ROOT / "scripts" / "claude" / "voicectl.sh"

pytestmark = pytest.mark.skipif(
    subprocess.run(["which", "jq"], capture_output=True).returncode != 0,
    reason="voicectl requires jq",
)


PROFILES = [
    {"id": "id-morgan", "name": "Morgan", "voice_type": "cloned", "default_engine": None},
    {"id": "id-scarlett", "name": "Scarlett", "voice_type": "preset", "default_engine": "kokoro"},
]


class _Recorder:
    def __init__(self) -> None:
        self.puts: list[dict] = []
        self.speaks: list[dict] = []
        self.bindings: list[dict] = []
        # When set, GET /mcp/bindings answers with this status and no JSON body.
        self.bindings_error: int | None = None
        self.url = ""


@pytest.fixture
def voicebox():
    recorder = _Recorder()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _json(self, payload, code=200):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read(self):
            length = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(length) or b"{}")

        def do_GET(self):
            if self.path == "/profiles":
                return self._json(PROFILES)
            if self.path == "/mcp/bindings":
                if recorder.bindings_error:
                    self.send_response(recorder.bindings_error)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return None
                return self._json({"items": recorder.bindings})
            if self.path == "/health":
                return self._json({"status": "healthy", "gpu_type": "CUDA"})
            return self._json({"detail": "not found"}, 404)

        def do_PUT(self):
            body = self._read()
            recorder.puts.append(body)
            self._json({**body, "last_seen_at": None})

        def do_POST(self):
            body = self._read()
            recorder.speaks.append(body)
            self._json({"id": "gen-1", "status": "generating"})

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    recorder.url = f"http://127.0.0.1:{server.server_port}"
    try:
        yield recorder
    finally:
        server.shutdown()
        server.server_close()


@pytest.fixture
def env(tmp_path: Path, voicebox):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    # A no-op player so `test`/text paths never touch a real device.
    player = bindir / "paplay"
    player.write_text("#!/bin/sh\nexit 0\n")
    player.chmod(0o755)
    return {
        **os.environ,
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "VOICEBOX_URL": voicebox.url,
        "VOICEBOX_STATE_DIR": str(tmp_path / "state"),
    }


def run(env: dict, *args: str, cwd: Path | None = None):
    return subprocess.run(
        [str(VOICECTL), *args], capture_output=True, text=True, env=env, timeout=30, cwd=cwd
    )


# ─── profile: the full-replace footgun ─────────────────────────────────────


def test_profile_preserves_other_binding_fields(env, voicebox):
    """PUT is a full replace. Setting a voice must not wipe the engine and
    personality this client already had."""
    voicebox.bindings = [
        {
            "client_id": "claude-code",
            "label": "Claude Code",
            "profile_id": "id-scarlett",
            "default_engine": "kokoro",
            "default_personality": True,
        }
    ]
    result = run(env, "profile", "Morgan")
    assert result.returncode == 0, result.stdout + result.stderr

    assert len(voicebox.puts) == 1
    put = voicebox.puts[0]
    assert put["profile_id"] == "id-morgan"
    assert put["default_engine"] == "kokoro", "engine was clobbered"
    assert put["default_personality"] is True, "personality was clobbered"
    assert put["label"] == "Claude Code", "label was clobbered"


def test_profile_creates_a_binding_when_none_exists(env, voicebox):
    voicebox.bindings = []
    result = run(env, "profile", "Morgan")
    assert result.returncode == 0
    put = voicebox.puts[0]
    assert put == {
        "client_id": "claude-code",
        "profile_id": "id-morgan",
        "label": None,
        "default_engine": None,
        "default_personality": False,
    }


def test_profile_ignores_other_clients_bindings(env, voicebox):
    """Merging from the wrong row would hand this client someone else's voice."""
    voicebox.bindings = [
        {
            "client_id": "cursor",
            "label": "Cursor",
            "profile_id": "id-scarlett",
            "default_engine": "luxtts",
            "default_personality": True,
        }
    ]
    run(env, "profile", "Morgan")
    put = voicebox.puts[0]
    assert put["client_id"] == "claude-code"
    assert put["default_engine"] is None
    assert put["default_personality"] is False


def test_profile_matches_case_insensitively(env, voicebox):
    run(env, "profile", "mOrGaN")
    assert voicebox.puts[0]["profile_id"] == "id-morgan"


def test_unknown_profile_lists_the_options(env, voicebox):
    result = run(env, "profile", "Nonexistent")
    assert result.returncode == 1
    assert "Morgan" in result.stdout
    assert "Scarlett" in result.stdout
    assert voicebox.puts == []


def test_profile_aborts_when_existing_bindings_cannot_be_read(env, voicebox):
    """Treating a failed GET as "no binding yet" would PUT nulls over the very
    fields the merge exists to preserve."""
    voicebox.bindings_error = 500
    result = run(env, "profile", "Morgan")
    assert result.returncode == 1
    assert voicebox.puts == [], "a PUT was sent without the existing binding"


def test_profile_requires_a_name(env):
    result = run(env, "profile")
    assert result.returncode == 2


# ─── toggle ────────────────────────────────────────────────────────────────


def test_off_then_on_round_trips(env):
    state = Path(env["VOICEBOX_STATE_DIR"])

    assert run(env, "off").returncode == 0
    assert (state / "enabled").read_text().strip() == "0"

    assert run(env, "on").returncode == 0
    assert not (state / "enabled").exists(), "absent means on, so the file should go"


def test_on_clears_the_circuit_breaker(env):
    """Turning speech back on after the backend was down must not wait out the
    breaker window."""
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "down-until").write_text("99999999999")
    run(env, "on")
    assert not (state / "down-until").exists()


# ─── status ────────────────────────────────────────────────────────────────


def test_status_reports_the_bound_voice(env, voicebox):
    voicebox.bindings = [
        {
            "client_id": "claude-code",
            "label": None,
            "profile_id": "id-morgan",
            "default_engine": "kokoro",
            "default_personality": False,
        }
    ]
    result = run(env, "status")
    assert "Morgan" in result.stdout
    assert "on" in result.stdout


def test_status_says_when_the_backend_is_unreachable(env):
    result = run({**env, "VOICEBOX_URL": "http://127.0.0.1:9"}, "status")
    assert result.returncode == 0
    assert "UNREACHABLE" in result.stdout


def test_status_warns_when_no_player_is_installed(env, voicebox, tmp_path):
    """Silence with no explanation is the worst outcome, so an install with no
    player at all has to say so.

    Simulated by mirroring the real PATH minus the player binaries — the script
    still needs curl, jq and coreutils to run at all.
    """
    players = {"paplay", "pw-play", "aplay", "afplay", "ffplay", "play"}
    fake_bin = tmp_path / "noplayers"
    fake_bin.mkdir()
    for directory in ("/usr/bin", "/bin"):
        source = Path(directory)
        if not source.is_dir():
            continue
        for entry in source.iterdir():
            if entry.name in players or (fake_bin / entry.name).exists():
                continue
            with contextlib.suppress(OSError):
                (fake_bin / entry.name).symlink_to(entry)

    result = run({**env, "PATH": str(fake_bin)}, "status")
    assert "NONE installed" in result.stdout, result.stdout + result.stderr


# ─── speaking ──────────────────────────────────────────────────────────────


def test_bare_text_is_spoken(env, voicebox):
    result = run(env, "the", "build", "is", "green")
    assert result.returncode == 0
    assert voicebox.speaks[0]["text"] == "the build is green"


def test_text_is_spoken_even_when_toggled_off(env, voicebox):
    """Explicit intent overrides the toggle — otherwise /say off would make
    /say <text> mysteriously do nothing."""
    run(env, "off")
    run(env, "hello there")
    assert voicebox.speaks[-1]["text"] == "hello there"


def test_text_is_cleaned_before_speaking(env, voicebox):
    run(env, "see **this** and https://example.com/x")
    spoken = voicebox.speaks[0]["text"]
    assert "**" not in spoken
    assert "example.com" not in spoken


def test_test_subcommand_speaks_and_reports(env, voicebox):
    result = run(env, "test")
    assert result.returncode == 0
    assert voicebox.speaks[0]["text"].startswith("Voicebox is connected")
    assert "check-wsl-audio" in result.stdout


def test_list_prints_profile_names(env, voicebox):
    result = run(env, "list")
    assert "Morgan" in result.stdout
    assert "Scarlett" in result.stdout


def test_help_is_available(env):
    result = run(env, "--help")
    assert result.returncode == 0
    assert "profile <name>" in result.stdout


# ─── Argument handling ─────────────────────────────────────────────────────
#
# /say hands the whole argument string over as ONE shell-quoted argument, so
# arbitrary prose is never re-parsed by a shell. That means voicectl has to do
# the splitting, and has to tell a subcommand apart from prose that merely
# starts with the same word.


def test_single_combined_argument_is_split(env, voicebox):
    """The form /say actually uses."""
    result = run(env, "profile Morgan")
    assert result.returncode == 0
    assert voicebox.puts[0]["profile_id"] == "id-morgan"


@pytest.mark.parametrize(
    "prose",
    [
        "stop the build and tell me why",
        "on second thought, revert it",
        "list of failing tests",
        "test the retry path",
        "status of the deploy",
    ],
)
def test_prose_beginning_with_a_subcommand_word_is_spoken(env, voicebox, prose):
    """`/say stop the build` is a request to speak, not to stop playback.
    Every one of these is ordinary phrasing a user would hit by accident."""
    result = run(env, prose)
    assert result.returncode == 0
    assert voicebox.speaks[0]["text"] == prose


def test_bare_subcommand_still_acts_as_a_subcommand(env, voicebox):
    assert run(env, "off").returncode == 0
    assert voicebox.speaks == []


def test_text_with_shell_metacharacters_is_spoken_literally(env, voicebox):
    """The reason /say passes one quoted argument: this text used to reach a
    shell, where it was a syntax error at best and command execution at worst."""
    hostile = "don't stop; echo $(whoami) `id` && rm -rf /tmp/nope"
    result = run(env, hostile)
    assert result.returncode == 0
    spoken = voicebox.speaks[0]["text"]
    # Backticks are stripped as markdown, but nothing was evaluated.
    assert "don't stop" in spoken
    assert "whoami" in spoken
    assert "rm -rf /tmp/nope" in spoken


def _spawn(argv: list[str], **kwargs) -> subprocess.Popen:
    return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)


def _reap(proc: subprocess.Popen) -> None:
    import signal

    if proc.poll() is None:
        proc.send_signal(signal.SIGKILL)
    proc.wait(timeout=5)


def test_stop_does_not_kill_unrelated_audio_players(env, tmp_path):
    """`pkill -x ffplay` matched every such process for the user, so /say stop
    also killed music playing in another window. The bystander really is named
    ffplay, so a regression to name-based killing fails here."""
    import time

    ffplay = tmp_path / "ffplay"
    ffplay.symlink_to(subprocess.run(["which", "sleep"], capture_output=True, text=True).stdout.strip())
    bystander = _spawn([str(ffplay), "30"], start_new_session=True)
    try:
        time.sleep(0.2)
        assert subprocess.run(["pgrep", "-x", "ffplay"], capture_output=True).returncode == 0
        run(env, "stop")
        time.sleep(0.5)
        assert bystander.poll() is None, "an unrelated ffplay was killed"
    finally:
        _reap(bystander)


def test_stop_ignores_processes_that_merely_mention_the_play_script(env, tmp_path):
    """`vim voicebox-play.sh` is not playback. Its command line names the script
    but carries no generation id."""
    import time

    # The trailing `; :` stops bash exec-ing sleep directly, which would drop
    # "voicebox-play.sh" from the command line and make this test pass vacuously.
    editor = _spawn(["bash", "-c", "sleep 30; :", "voicebox-play.sh"], start_new_session=True)
    try:
        time.sleep(0.2)
        assert subprocess.run(
            ["pgrep", "-f", "voicebox-play.sh"], capture_output=True
        ).returncode == 0, "bystander does not look like the script; test would be vacuous"
        run(env, "stop")
        time.sleep(0.5)
        assert editor.poll() is None, "a process that only named the script was killed"
    finally:
        _reap(editor)


def test_stop_kills_a_real_play_script_and_its_player(env, tmp_path):
    """The positive case: without it, a stop that kills nothing passes both
    tests above."""
    import time

    script = tmp_path / "voicebox-play.sh"
    child_pid = tmp_path / "child.pid"
    script.write_text(f"#!/usr/bin/env bash\nsleep 30 &\necho $! > {child_pid}\nwait\n")
    script.chmod(0o755)
    play = _spawn([str(script), "0f8e2c1a-1b2c-4d5e-8f90-123456789abc"], start_new_session=True)
    try:
        for _ in range(50):
            if child_pid.exists() and child_pid.read_text().strip():
                break
            time.sleep(0.05)
        player = int(child_pid.read_text())
        run(env, "stop")
        play.wait(timeout=5)
        time.sleep(0.2)
        with pytest.raises(ProcessLookupError):
            os.kill(player, 0)
    finally:
        _reap(play)


def test_text_with_glob_characters_is_not_expanded(env, voicebox, tmp_path):
    """The single argument used to be split with an unquoted `set -- $1`, which
    also glob-expands: `?` and `[...]` matched files in the working directory and
    their names were spoken instead."""
    (tmp_path / "ready1").write_text("")
    (tmp_path / "d").write_text("")
    result = run(env, "is it ready? see [draft]", cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    assert voicebox.speaks[0]["text"] == "is it ready? see [draft]"


def test_prose_starting_with_speak_keeps_every_word(env, voicebox):
    """`speak` used to be an internal marker, so it was silently dropped from
    the front of anything the user said."""
    result = run(env, "speak up please")
    assert result.returncode == 0
    assert voicebox.speaks[0]["text"] == "speak up please"
