"""Tests for the Claude Code hook scripts in scripts/claude/.

These run the real shell scripts as subprocesses against a stub HTTP server and
a fake audio player, so nothing here needs a sound card — which matters, because
the machines that most need these hooks (containers, headless WSL) are exactly
the ones that have no audio device to test against.

The behaviours worth guarding are the ones that only show up when things go
wrong: a stopped backend must cost a turn milliseconds rather than seconds, and
a hook must never exit non-zero, because a failing Stop hook wedges the turn it
was supposed to narrate.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts" / "claude"

pytestmark = pytest.mark.skipif(
    subprocess.run(["which", "jq"], capture_output=True).returncode != 0,
    reason="hooks require jq",
)


# ─── Stub Voicebox ─────────────────────────────────────────────────────────


class _Recorder:
    def __init__(self) -> None:
        self.speaks: list[dict] = []
        self.headers: list[dict] = []
        self.audio_fetches: list[str] = []
        self.status_value = "completed"
        self.speak_status = 200


def _wav_bytes() -> bytes:
    import io

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        w.writeframes(b"\x00\x00" * 2400)
    return buf.getvalue()


@pytest.fixture
def voicebox():
    """A stub of the endpoints the hooks touch: POST /speak, the status SSE,
    and GET /audio/{id}."""
    recorder = _Recorder()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # silence
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            recorder.headers.append(dict(self.headers))
            if recorder.speak_status != 200:
                payload = json.dumps({"detail": "stub error"}).encode()
                self.send_response(recorder.speak_status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            recorder.speaks.append(body)
            payload = json.dumps({"id": "gen-1", "status": "generating"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path.endswith("/status"):
                # Bare `data:` frames with no `event:` line — the real shape.
                frame = (
                    f'data: {{"id": "gen-1", "status": "{recorder.status_value}", '
                    f'"duration": 1.0, "error": null, "source": "rest"}}\n\n'
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(frame)
                return
            if self.path.startswith("/audio/"):
                recorder.audio_fetches.append(self.path)
                data = _wav_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "audio/x-wav")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404)
            self.end_headers()

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    recorder.url = f"http://127.0.0.1:{server.server_port}"
    try:
        yield recorder
    finally:
        server.shutdown()
        server.server_close()


@pytest.fixture
def fake_player(tmp_path: Path) -> Path:
    """A `paplay` on PATH that records its argv instead of making noise."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "played.log"
    player = bindir / "paplay"
    player.write_text(f'#!/bin/sh\necho "$@" >> "{log}"\nexit 0\n')
    player.chmod(0o755)
    return log


@pytest.fixture
def env(tmp_path: Path, voicebox, fake_player):
    state = tmp_path / "state"
    return {
        **os.environ,
        "PATH": f"{fake_player.parent / 'bin'}:{os.environ['PATH']}",
        "VOICEBOX_URL": voicebox.url,
        "VOICEBOX_STATE_DIR": str(state),
    }


def transcript_with(tmp_path: Path, text: str) -> Path:
    """A minimal Claude Code transcript JSONL holding one assistant reply."""
    path = tmp_path / "transcript.jsonl"
    path.write_text(
        json.dumps(
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": text}]},
            }
        )
        + "\n"
    )
    return path


def run_stop_hook(env: dict, transcript: Path, timeout: int = 30):
    return subprocess.run(
        [str(SCRIPTS / "voicebox-speak.sh")],
        input=json.dumps({"transcript_path": str(transcript)}),
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    )


# ─── Endpoint resolution ───────────────────────────────────────────────────
#
# Every other test pins VOICEBOX_URL, which is exactly how the default was
# allowed to be wrong: the hooks shipped pointing at 17600, a port specific to
# one machine's container, so a stock install tripped the circuit breaker on the
# first turn and went quiet with no visible cause.


def _resolved_base(extra_env: dict) -> str:
    common = SCRIPTS / "voicebox-common.sh"
    env = {k: v for k, v in os.environ.items() if not k.startswith("VOICEBOX_")}
    return subprocess.run(
        ["bash", "-c", f'. "{common}"; printf %s "$VB_BASE"'],
        capture_output=True,
        text=True,
        env={**env, **extra_env},
        timeout=30,
    ).stdout.strip()


def test_default_endpoint_is_the_project_default_port():
    """17493 is the default in package.json, mcp_shim and the Rust SERVER_PORT.
    A deployment-specific port here strands every stock install."""
    assert _resolved_base({}) == "http://127.0.0.1:17493"


def test_voicebox_port_is_honoured():
    """install.sh and the README both tell users to set this."""
    assert _resolved_base({"VOICEBOX_PORT": "17600"}) == "http://127.0.0.1:17600"


def test_voicebox_host_is_honoured():
    """Container clients reach the backend by service DNS, not loopback."""
    assert _resolved_base({"VOICEBOX_HOST": "voicebox"}) == "http://voicebox:17493"


def test_voicebox_url_overrides_host_and_port():
    """Full-URL escape hatch for a path prefix or TLS."""
    resolved = _resolved_base({"VOICEBOX_URL": "https://box.internal/vb", "VOICEBOX_PORT": "17600"})
    assert resolved == "https://box.internal/vb"


# ─── The happy path ────────────────────────────────────────────────────────


def test_speaks_the_last_assistant_message(env, voicebox, tmp_path):
    result = run_stop_hook(env, transcript_with(tmp_path, "The build is green."))
    assert result.returncode == 0
    assert len(voicebox.speaks) == 1
    assert voicebox.speaks[0]["text"] == "The build is green."


def test_sends_the_client_id_header(env, voicebox, tmp_path):
    """Per-client voice bindings are keyed on this header."""
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    assert voicebox.headers[0]["X-Voicebox-Client-Id"] == "claude-code"


def test_client_id_is_overridable_for_containers(env, voicebox, tmp_path):
    run_stop_hook(
        {**env, "VOICEBOX_CLIENT_ID": "claude-code-podman"},
        transcript_with(tmp_path, "hello"),
    )
    assert voicebox.headers[0]["X-Voicebox-Client-Id"] == "claude-code-podman"


def test_audio_is_fetched_and_played(env, voicebox, fake_player, tmp_path):
    """The whole point: generation must end up at a player."""
    run_stop_hook(env, transcript_with(tmp_path, "hello"))

    deadline = time.time() + 20
    while time.time() < deadline and not fake_player.exists():
        time.sleep(0.2)

    assert fake_player.exists(), "audio was never handed to a player"
    assert voicebox.audio_fetches == ["/audio/gen-1"]
    assert fake_player.read_text().strip().endswith(".wav")


# ─── Text handling ─────────────────────────────────────────────────────────


def test_code_blocks_are_dropped(env, voicebox, tmp_path):
    """A fenced diff read aloud is unusable and can run for minutes."""
    reply = "Here is the fix:\n```python\nimport os\nprint(os.getcwd())\n```\nDone."
    run_stop_hook(env, transcript_with(tmp_path, reply))
    spoken = voicebox.speaks[0]["text"]
    assert "import os" not in spoken
    assert "Here is the fix" in spoken
    assert "Done." in spoken


def test_multi_line_reply_is_spoken_in_full(env, voicebox, tmp_path):
    """Regression: jq -r emits the reply with its own newlines intact, so a
    `tail -1` meant to pick the last *message* instead picked the last *line* —
    silently speaking only the final sentence of every multi-line answer."""
    run_stop_hook(env, transcript_with(tmp_path, "First sentence.\nSecond sentence.\nThird."))
    spoken = voicebox.speaks[0]["text"]
    assert "First sentence." in spoken
    assert "Second sentence." in spoken
    assert "Third." in spoken


def test_last_of_several_assistant_messages_wins(env, voicebox, tmp_path):
    """A real transcript holds the whole session, not one reply.

    Pinned to `final`, which is what this behaviour belongs to. The default is
    now `full`, where speaking only the last message is precisely the bug turn
    narration exists to fix.
    """
    env = {**env, "VOICEBOX_VERBOSITY": "final"}
    path = tmp_path / "transcript.jsonl"
    path.write_text(
        "\n".join(
            json.dumps(
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": text}]},
                }
            )
            for text in ["Older reply.", "Middle reply.", "Newest reply."]
        )
        + "\n"
    )
    run_stop_hook(env, path)
    assert voicebox.speaks[0]["text"] == "Newest reply."


def test_markdown_and_urls_are_stripped(env, voicebox, tmp_path):
    run_stop_hook(
        env,
        transcript_with(tmp_path, "See **bold** and https://example.com/x for `code`."),
    )
    spoken = voicebox.speaks[0]["text"]
    assert "**" not in spoken
    assert "`" not in spoken
    assert "example.com" not in spoken


def test_long_replies_are_capped(env, voicebox, tmp_path):
    """VOICEBOX_MAXCHARS is the `final` budget and keeps that meaning; turn
    narration has its own, much larger one in VOICEBOX_TURN_MAXCHARS."""
    run_stop_hook(
        {**env, "VOICEBOX_VERBOSITY": "final", "VOICEBOX_MAXCHARS": "20"},
        transcript_with(tmp_path, "x" * 500),
    )
    assert len(voicebox.speaks[0]["text"]) == 20


def test_code_only_reply_says_nothing(env, voicebox, tmp_path):
    run_stop_hook(env, transcript_with(tmp_path, "```\nrm -rf /\n```"))
    assert voicebox.speaks == []


def test_repeated_text_is_spoken_once(env, voicebox, tmp_path):
    """Stop can fire more than once per logical turn."""
    transcript = transcript_with(tmp_path, "Same message.")
    run_stop_hook(env, transcript)
    run_stop_hook(env, transcript)
    assert len(voicebox.speaks) == 1


# ─── Failure modes ─────────────────────────────────────────────────────────


def test_missing_transcript_is_silent_and_clean(env, voicebox, tmp_path):
    result = run_stop_hook(env, tmp_path / "does-not-exist.jsonl")
    assert result.returncode == 0
    assert voicebox.speaks == []


def test_malformed_payload_exits_zero(env):
    result = subprocess.run(
        [str(SCRIPTS / "voicebox-speak.sh")],
        input="not json at all",
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert result.returncode == 0


def test_toggle_off_makes_no_request(env, voicebox, tmp_path):
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "enabled").write_text("0")
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    assert voicebox.speaks == []


def test_open_breaker_short_circuits_fast(env, voicebox, tmp_path):
    """The reason the breaker exists. With Voicebox down, an unguarded hook
    pays a connect timeout on every turn; this must cost near nothing."""
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "down-until").write_text(str(int(time.time()) + 300))

    started = time.time()
    result = run_stop_hook(env, transcript_with(tmp_path, "hello"))
    elapsed = time.time() - started

    assert result.returncode == 0
    assert voicebox.speaks == []
    assert elapsed < 1.0, f"breaker did not short-circuit (took {elapsed:.2f}s)"


def test_unreachable_backend_trips_the_breaker(env, tmp_path):
    """First failure must arm the breaker so the next turns are free."""
    dead = {**env, "VOICEBOX_URL": "http://127.0.0.1:9"}
    result = run_stop_hook(dead, transcript_with(tmp_path, "hello"))
    assert result.returncode == 0
    assert (Path(env["VOICEBOX_STATE_DIR"]) / "down-until").exists()


def test_expired_breaker_allows_requests_again(env, voicebox, tmp_path):
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "down-until").write_text(str(int(time.time()) - 5))
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    assert len(voicebox.speaks) == 1


def test_server_error_trips_the_breaker(env, voicebox, tmp_path):
    """A 5xx is a dead backend: stop calling it. Judging health by 'did a body
    come back' counted an error page as success and reset the breaker."""
    voicebox.speak_status = 503
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    assert (Path(env["VOICEBOX_STATE_DIR"]) / "down-until").exists()


def test_client_error_does_not_trip_the_breaker(env, voicebox, tmp_path):
    """A 400 'No voice profile resolved' means the server is healthy and the
    request was wrong. Marking it down would suppress speech for a minute after
    every such reply."""
    voicebox.speak_status = 400
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    assert not (Path(env["VOICEBOX_STATE_DIR"]) / "down-until").exists()


def test_a_failed_speak_can_be_retried_later(env, voicebox, tmp_path):
    """The de-dup marker used to be written before the speak was attempted, so a
    reply that failed while the backend was down could never be spoken again."""
    transcript = transcript_with(tmp_path, "The build is green.")
    voicebox.speak_status = 503
    run_stop_hook(env, transcript)
    assert voicebox.speaks == []

    voicebox.speak_status = 200
    (Path(env["VOICEBOX_STATE_DIR"]) / "down-until").unlink(missing_ok=True)
    run_stop_hook(env, transcript)
    assert [s["text"] for s in voicebox.speaks] == ["The build is green."]


def test_dedup_is_scoped_per_session(env, voicebox, tmp_path):
    """Two concurrent sessions ending on the same short reply must both speak.
    A single global marker silenced the second."""
    first = tmp_path / "a.jsonl"
    second = tmp_path / "b.jsonl"
    for path in (first, second):
        path.write_text(
            json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "Done."}]}}) + "\n"
        )

    for path, session in ((first, "session-a"), (second, "session-b")):
        subprocess.run(
            [str(SCRIPTS / "voicebox-speak.sh")],
            input=json.dumps({"transcript_path": str(path), "session_id": session}),
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )

    assert len(voicebox.speaks) == 2, "second session was wrongly de-duplicated"


def test_dedup_still_suppresses_within_one_session(env, voicebox, tmp_path):
    transcript = transcript_with(tmp_path, "Same message.")
    payload = json.dumps({"transcript_path": str(transcript), "session_id": "session-a"})
    for _ in range(2):
        subprocess.run(
            [str(SCRIPTS / "voicebox-speak.sh")],
            input=payload,
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )
    assert len(voicebox.speaks) == 1


def test_failed_generation_is_not_played(env, voicebox, fake_player, tmp_path):
    voicebox.status_value = "failed"
    run_stop_hook(env, transcript_with(tmp_path, "hello"))
    time.sleep(2)
    assert voicebox.audio_fetches == []
    assert not fake_player.exists()


# ─── Turn narration ────────────────────────────────────────────────────────
#
# The hook used to speak the last assistant text block and nothing else, so a
# turn that read six files, ran the tests and fixed a bug was announced as one
# sentence. These cover reconstructing the whole turn instead.


def _entry(kind: str, **kw) -> dict:
    if kind == "user":
        return {"type": "user", "message": {"content": kw["text"]}}
    if kind == "tool_result":
        return {
            "type": "user",
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": kw["id"],
                        "is_error": kw.get("error", False),
                        "content": kw.get("content", "ok"),
                    }
                ]
            },
        }
    return {"type": "assistant", "message": {"content": kw["blocks"]}, **kw.get("extra", {})}


def text_block(text: str) -> dict:
    return {"type": "text", "text": text}


def tool_block(name: str, tid: str = "t1", **inp) -> dict:
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def transcript_of(tmp_path: Path, entries: list[dict], name: str = "turn.jsonl") -> Path:
    path = tmp_path / name
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
    return path


def narration(voicebox) -> str:
    """Everything spoken this turn, in order."""
    return " ".join(s["text"] for s in voicebox.speaks)


def preview(env: dict, transcript: Path, verbosity: str = "full") -> str:
    """The narration the hook would speak, without a backend or a sound card.
    This is also the loop used to tune phrasing against real transcripts."""
    return subprocess.run(
        [str(SCRIPTS / "voicebox-speak.sh")],
        input=json.dumps({"transcript_path": str(transcript), "session_id": "preview"}),
        capture_output=True,
        text=True,
        env={**env, "VOICEBOX_DRY_RUN": "1", "VOICEBOX_VERBOSITY": verbosity},
        timeout=30,
    ).stdout


def test_turn_speaks_every_text_block_not_just_the_last(env, voicebox, tmp_path):
    """The whole point of the change."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="fix the build"),
            _entry("assistant", blocks=[text_block("Looking at the failure now.")]),
            _entry("assistant", blocks=[text_block("The import was circular.")]),
            _entry("assistant", blocks=[text_block("Fixed and the tests pass.")]),
        ],
    )
    run_stop_hook(env, transcript)
    spoken = narration(voicebox)
    assert "Looking at the failure" in spoken
    assert "import was circular" in spoken
    assert "Fixed and the tests pass" in spoken


def test_turn_starts_after_the_last_user_prompt(env, voicebox, tmp_path):
    """Narrating the whole session instead of the whole turn would replay every
    reply the user has already heard."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="first question"),
            _entry("assistant", blocks=[text_block("Answer to the old question.")]),
            _entry("user", text="second question"),
            _entry("assistant", blocks=[text_block("Answer to the new question.")]),
        ],
    )
    run_stop_hook(env, transcript)
    spoken = narration(voicebox)
    assert "new question" in spoken
    assert "old question" not in spoken


def test_tool_results_are_not_turn_boundaries(env, voicebox, tmp_path):
    """tool_result entries are user-typed messages structurally but not in
    meaning. Treating one as a boundary truncates the turn to its last tool
    call — the classic off-by-one here."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("Checking the config first.")]),
            _entry("assistant", blocks=[tool_block("Read", file_path="/etc/app/config.yaml")]),
            _entry("tool_result", id="t1"),
            _entry("assistant", blocks=[text_block("The config was fine.")]),
        ],
    )
    run_stop_hook(env, transcript)
    spoken = narration(voicebox)
    assert "Checking the config first" in spoken
    assert "config was fine" in spoken


def test_meta_entries_are_not_turn_boundaries(env, voicebox, tmp_path):
    """Injected reminders and command plumbing arrive as user strings but are
    not the user speaking, and cut the turn short if trusted."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("Starting the work.")]),
            {"type": "user", "isMeta": True, "message": {"content": "<system-reminder>noise"}},
            _entry("assistant", blocks=[text_block("Finished the work.")]),
        ],
    )
    run_stop_hook(env, transcript)
    spoken = narration(voicebox)
    assert "Starting the work" in spoken
    assert "Finished the work" in spoken


def test_subagent_traffic_is_excluded(env, voicebox, tmp_path):
    """Sidechain entries are a subagent's own transcript. They have their own
    hook, and folding them in doubles the narration."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("Main line reply.")]),
            {
                "type": "assistant",
                "isSidechain": True,
                "message": {"content": [{"type": "text", "text": "Subagent chatter."}]},
            },
        ],
    )
    run_stop_hook(env, transcript)
    assert "Subagent chatter" not in narration(voicebox)


def test_tool_calls_are_spoken_as_phrases(env, voicebox, tmp_path):
    """What Claude *did*, which is most of what the user wants to hear."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry(
                "assistant",
                blocks=[
                    tool_block("Read", tid="a", file_path="/home/me/project/server.py"),
                    tool_block("Bash", tid="b", command="pytest -q", description="Run the test suite"),
                    tool_block("Edit", tid="c", file_path="/home/me/project/server.py"),
                ],
            ),
        ],
    )
    run_stop_hook(env, transcript)
    spoken = narration(voicebox)
    assert "Read server.py" in spoken
    assert "Run the test suite" in spoken
    assert "Edited server.py" in spoken
    # The absolute path is what makes a phrase unlistenable.
    assert "/home/me" not in spoken


def test_failed_tools_are_reported(env, voicebox, tmp_path):
    """Whether it broke is the one outcome worth interrupting for."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[tool_block("Bash", tid="x", description="Run the migration")]),
            _entry("tool_result", id="x", error=True, content="permission denied"),
        ],
    )
    run_stop_hook(env, transcript)
    assert "but that failed" in narration(voicebox)


def test_regex_patterns_are_not_read_aloud(env, voicebox, tmp_path):
    """"caret backslash d plus dollar" is the weirdest-sounding failure mode
    there is, so an unspeakable pattern degrades to a generic phrase."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[tool_block("Grep", pattern=r"^\s*def\s+(\w+)\(.*\)$")]),
        ],
    )
    out = preview(env, transcript)
    assert "Searched the code" in out
    assert "\\s" not in out and "\\w" not in out


def test_word_patterns_are_kept(env, voicebox, tmp_path):
    """The gate must not be so strict that it throws away useful detail.

    The underscore becomes a space on the way out: vb_clean_text strips
    underscores as markdown emphasis, which would otherwise leave the
    unpronounceable "resolveprofile".
    """
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[tool_block("Grep", pattern="resolve_profile")]),
        ],
    )
    assert "resolve profile" in preview(env, transcript)


def test_urls_are_never_spoken(env, voicebox, tmp_path):
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry(
                "assistant",
                blocks=[
                    tool_block("WebFetch", url="https://example.com/docs/api"),
                    text_block("See https://example.com/docs/api for details."),
                ],
            ),
        ],
    )
    assert "example.com" not in preview(env, transcript)


def test_inline_code_keeps_short_identifiers(env, voicebox, tmp_path):
    """Deleting spans outright decapitated sentences — "isn't installed" with
    no subject — which is harder to follow than hearing the identifier."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("`bun` isn't installed, so I used npm.")]),
        ],
    )
    out = preview(env, transcript)
    assert "bun isn't installed" in out


def test_long_code_spans_are_dropped(env, voicebox, tmp_path):
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry(
                "assistant",
                blocks=[text_block("I ran `for f in $(ls -1 /tmp/*.log); do rm -f $f; done` to clear them.")],
            ),
        ],
    )
    out = preview(env, transcript)
    assert "rm -f" not in out
    assert "to clear them" in out


def test_markdown_tables_are_dropped(env, voicebox, tmp_path):
    """Stripping the pipes leaves the cells, and a comparison table read as a
    run of unattached values is worse than silence."""
    reply = (
        "Here is the comparison.\n"
        "| metric | before | after |\n"
        "| --- | --- | --- |\n"
        "| memory | 2293 MB | 3378 MB |\n"
        "So it grew.\n"
    )
    transcript = transcript_of(
        tmp_path, [_entry("user", text="go"), _entry("assistant", blocks=[text_block(reply)])]
    )
    out = preview(env, transcript)
    assert "Here is the comparison" in out
    assert "So it grew" in out
    assert "3378" not in out


def test_attribute_references_do_not_glue_to_the_previous_word(env, voicebox, tmp_path):
    """`.thinking` loses its backticks, and closing the space before what looks
    like a full stop produced "encrypted.thinking is empty"."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("They are encrypted — `.thinking` is empty.")]),
        ],
    )
    out = preview(env, transcript)
    assert "encrypted.thinking" not in out
    assert "thinking is empty" in out


def test_narration_is_chunked_for_playback(env, voicebox, tmp_path):
    """One long utterance cannot be interrupted; chunks bound how much of a
    silenced narration still gets spoken."""
    sentences = " ".join(f"This is sentence number {i} of the reply." for i in range(40))
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block(sentences)])],
    )
    out = preview(env, transcript).strip().splitlines()
    assert len(out) > 1, "a long narration was not chunked"
    assert all(len(line) <= 500 for line in out)


def test_chunks_are_spoken_in_order(env, voicebox, tmp_path):
    """The lock in voicebox-play.sh is a mutex, not a queue: firing every chunk
    at once lets chunk four win the race and be spoken before chunk two. This
    fails loudly if the sequential narrator is ever replaced with a fan-out."""
    sentences = " ".join(f"Sentence {i} alpha bravo charlie delta echo foxtrot." for i in range(30))
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block(sentences)])],
    )
    run_stop_hook(env, transcript)

    deadline = time.time() + 40
    while time.time() < deadline and len(voicebox.speaks) < 3:
        time.sleep(0.2)

    spoken = [s["text"] for s in voicebox.speaks]
    assert len(spoken) >= 3, f"expected several chunks, got {spoken}"
    indices = [int(w) for t in spoken for w in t.replace(".", " ").split() if w.isdigit()]
    assert indices == sorted(indices), f"chunks were spoken out of order: {indices}"


def test_turn_budget_caps_the_narration(env, voicebox, tmp_path):
    """Voicebox generates in real time, so an uncapped turn is minutes of speech
    that outlives the work it describes."""
    sentences = " ".join(f"This is sentence number {i} of a very long reply." for i in range(200))
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block(sentences)])],
    )
    out = preview({**env, "VOICEBOX_TURN_MAXCHARS": "600"}, transcript)
    assert len(out.replace("\n", " ")) <= 800, "budget was not applied"


def test_budget_trims_at_a_sentence_end(env, voicebox, tmp_path):
    """Cutting mid-word sounds like the process crashed."""
    sentences = " ".join(f"Sentence number {i} of the reply." for i in range(100))
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block(sentences)])],
    )
    out = preview({**env, "VOICEBOX_TURN_MAXCHARS": "300"}, transcript).strip()
    assert out.endswith((".", "!", "?"))


def test_turn_mode_summarises_the_tool_work(env, voicebox, tmp_path):
    """`turn` is the quieter setting: what was said, plus an accounting of what
    was done, rather than a phrase per tool call."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry(
                "assistant",
                blocks=[
                    text_block("Done."),
                    tool_block("Read", tid="a", file_path="/x/one.py"),
                    tool_block("Read", tid="b", file_path="/x/two.py"),
                    tool_block("Edit", tid="c", file_path="/x/one.py"),
                ],
            ),
        ],
    )
    out = preview(env, transcript, verbosity="turn")
    assert "read 2 files" in out
    assert "made 1 edit" in out
    assert "one.py" not in out, "turn mode should summarise, not enumerate"


def test_dedup_covers_the_whole_narration(env, voicebox, tmp_path):
    """Hashing one chunk would let a re-fired Stop hook replay half a turn."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry("assistant", blocks=[text_block("A first sentence. A second sentence.")]),
        ],
    )
    run_stop_hook(env, transcript)
    first = len(voicebox.speaks)
    run_stop_hook(env, transcript)
    assert len(voicebox.speaks) == first, "the turn was narrated twice"


def test_a_flushed_narration_stops_early(env, voicebox, fake_player, tmp_path):
    """`/say stop` during a narration must silence the chunks that have not been
    generated yet — they are most of what the user is silencing."""
    sentences = " ".join(f"Sentence {i} alpha bravo charlie delta echo." for i in range(12))
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block(sentences)])],
    )
    run_stop_hook(env, transcript)

    state = Path(env["VOICEBOX_STATE_DIR"])
    deadline = time.time() + 15
    while time.time() < deadline and not voicebox.speaks:
        time.sleep(0.1)

    subprocess.run([str(SCRIPTS / "voicectl.sh"), "stop"], capture_output=True, env=env, timeout=30)
    spoken_at_stop = len(voicebox.speaks)
    assert (state / "epoch").exists(), "stop did not bump the flush epoch"

    time.sleep(4)
    assert len(voicebox.speaks) <= spoken_at_stop + 1, "narration continued past stop"


def test_dry_run_speaks_nothing(env, voicebox, tmp_path):
    """The tuning loop must not cost a GPU-minute or make a sound."""
    transcript = transcript_of(
        tmp_path,
        [_entry("user", text="go"), _entry("assistant", blocks=[text_block("Something to say.")])],
    )
    out = preview(env, transcript)
    assert "Something to say" in out
    assert voicebox.speaks == []


def test_a_schema_change_does_not_produce_silence(env, voicebox, tmp_path):
    """Claude Code's JSONL is not a public contract. A transcript with no
    recognisable user entry must still narrate rather than go quiet."""
    transcript = transcript_of(
        tmp_path,
        [{"type": "assistant", "message": {"content": [{"type": "text", "text": "Still audible."}]}}],
    )
    run_stop_hook(env, transcript)
    assert "Still audible" in narration(voicebox)


def test_encrypted_thinking_blocks_are_skipped(env, voicebox, tmp_path):
    """Claude Code stores thinking encrypted — .thinking is always empty
    locally. Rendering it would emit a stream of blank phrases."""
    transcript = transcript_of(
        tmp_path,
        [
            _entry("user", text="go"),
            _entry(
                "assistant",
                blocks=[
                    {"type": "thinking", "thinking": "", "signature": "x" * 80},
                    text_block("The visible answer."),
                ],
            ),
        ],
    )
    out = preview(env, transcript)
    assert "The visible answer" in out
    assert "x" * 20 not in out


# ─── Notification hook ─────────────────────────────────────────────────────


def run_notify(env: dict, message: str):
    return subprocess.run(
        [str(SCRIPTS / "voicebox-notify.sh")],
        input=json.dumps({"message": message}),
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def test_notification_is_spoken(env, voicebox):
    result = run_notify(env, "Claude needs your permission to run npm test")
    assert result.returncode == 0
    assert "permission" in voicebox.speaks[0]["text"]


def test_notification_uses_its_own_client_id(env, voicebox):
    """A separate binding lets notifications use a shorter, distinct voice."""
    run_notify(env, "waiting for input")
    assert voicebox.headers[0]["X-Voicebox-Client-Id"] == "claude-code-notify"


def test_notifications_are_rate_limited(env, voicebox):
    """A burst of permission prompts must not queue a minute of speech."""
    for i in range(4):
        run_notify(env, f"prompt number {i}")
    assert len(voicebox.speaks) == 1


def test_empty_notification_says_nothing(env, voicebox):
    result = run_notify(env, "")
    assert result.returncode == 0
    assert voicebox.speaks == []


# ─── SubagentStop hook ─────────────────────────────────────────────────────


def run_subagent(env: dict, payload: dict):
    return subprocess.run(
        [str(SCRIPTS / "voicebox-subagent.sh")],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def test_subagent_hook_is_off_by_default(env, voicebox):
    """Parallel agents would otherwise queue minutes of speech."""
    result = run_subagent(env, {"subagent_type": "code-reviewer"})
    assert result.returncode == 0
    assert voicebox.speaks == []


def test_subagent_hook_speaks_when_enabled(env, voicebox):
    run_subagent({**env, "VOICEBOX_SPEAK_SUBAGENTS": "1"}, {"subagent_type": "code-reviewer"})
    assert "code-reviewer" in voicebox.speaks[0]["text"]


def test_subagent_hook_falls_back_to_a_generic_phrase(env, voicebox):
    run_subagent({**env, "VOICEBOX_SPEAK_SUBAGENTS": "1"}, {})
    assert voicebox.speaks[0]["text"] == "A subagent finished."


def test_subagent_announcements_are_rate_limited(env, voicebox):
    enabled = {**env, "VOICEBOX_SPEAK_SUBAGENTS": "1"}
    for i in range(3):
        run_subagent(enabled, {"subagent_type": f"agent-{i}"})
    assert len(voicebox.speaks) == 1


# ─── Playback script in isolation ──────────────────────────────────────────


def test_play_script_does_not_release_a_lock_it_never_took(env, voicebox, tmp_path):
    """The EXIT trap is installed before the lock is acquired. Releasing
    unconditionally let an instance that bailed early — bad audio fetch, no
    player — delete the lock held by an instance mid-sentence, so a third
    talked over it."""
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    lock = state / "play.lock"
    lock.mkdir()  # stand in for another instance currently speaking

    # No player on PATH, so this instance bails before ever taking the lock.
    empty = tmp_path / "noplayer"
    empty.mkdir()
    result = subprocess.run(
        [str(SCRIPTS / "voicebox-play.sh"), "gen-1"],
        capture_output=True,
        text=True,
        env={**env, "PATH": f"{empty}:/usr/bin:/bin", "VOICEBOX_LOCK_WAIT": "1"},
        timeout=60,
    )

    assert result.returncode == 0
    assert lock.exists(), "an instance that never held the lock deleted it"


def test_play_script_skips_rather_than_overlapping_when_the_lock_is_held(env, voicebox, fake_player, tmp_path):
    """Falling through to play anyway after the wait expired produced exactly
    the overlapping speech the lock exists to prevent."""
    state = Path(env["VOICEBOX_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "play.lock").mkdir()

    result = subprocess.run(
        [str(SCRIPTS / "voicebox-play.sh"), "gen-1"],
        capture_output=True,
        text=True,
        env={**env, "VOICEBOX_LOCK_WAIT": "2", "VOICEBOX_LOCK_STALE_MIN": "60"},
        timeout=60,
    )

    assert result.returncode == 0
    assert "skipping" in result.stderr
    assert not fake_player.exists(), "played while another utterance held the lock"


def test_play_script_requires_an_id(env):
    result = subprocess.run(
        [str(SCRIPTS / "voicebox-play.sh")],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert result.returncode == 2


def test_play_script_removes_its_temp_file(env, voicebox, fake_player):
    subprocess.run(
        [str(SCRIPTS / "voicebox-play.sh"), "gen-1"],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    assert fake_player.exists()
    played = Path(fake_player.read_text().strip())
    assert not played.exists(), "temp wav was left behind"


def test_play_script_reports_a_player_that_cannot_open_the_device(env, voicebox, tmp_path):
    """ffplay exits 0 even when it cannot open the audio device, so stderr has
    to be treated as authoritative or a dead sink looks like success."""
    bindir = tmp_path / "badbin"
    bindir.mkdir()
    bad = bindir / "paplay"
    bad.write_text('#!/bin/sh\necho "ALSA: Couldn\'t open audio device" >&2\nexit 0\n')
    bad.chmod(0o755)

    result = subprocess.run(
        [str(SCRIPTS / "voicebox-play.sh"), "gen-1"],
        capture_output=True,
        text=True,
        env={**env, "PATH": f"{bindir}:{env['PATH']}"},
        timeout=60,
    )
    assert result.returncode == 0
    assert "failed" in result.stderr
