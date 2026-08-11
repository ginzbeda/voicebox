"""Behavioural tests for the four MCP tools.

These are the agent-facing surface of Voicebox and they own decisions that are
invisible from the REST API: which voice a nameless request resolves to, whether
a personality rewrite happens, and whether a remote caller can read files off the
host. None of it had coverage.

The tools are exercised through an in-memory ``fastmcp.Client`` rather than by
calling the Python functions directly, so tool registration, argument coercion
and error propagation are covered too — a tool that fails to register would
otherwise still pass every test.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
from typing import Any

import pytest
from fastmcp import Client
from fastmcp.exceptions import ToolError

from backend.mcp_server import events as mcp_events
from backend.mcp_server.server import build_mcp_server

TOOL_NAMES = {
    "voicebox.speak",
    "voicebox.transcribe",
    "voicebox.list_captures",
    "voicebox.list_profiles",
}


@pytest.fixture
def mcp_server():
    return build_mcp_server()


@pytest.fixture
def client(mcp_server):
    return Client(mcp_server)


@pytest.fixture
def as_client(monkeypatch: pytest.MonkeyPatch):
    """Impersonate an MCP client id, the way ClientIdMiddleware would.

    Swaps the ContextVar for a stub rather than calling ``.set()``. A real
    ``set()`` happens inside the test coroutine's context, and its token cannot
    be reset from pytest's synchronous teardown — "created in a different
    Context". Patching the module attribute sidesteps contexts entirely and
    monkeypatch undoes it deterministically.
    """

    class _StubVar:
        def __init__(self, value: str | None) -> None:
            self._value = value

        def get(self, default: str | None = None) -> str | None:
            return self._value

    def _set(client_id: str | None):
        monkeypatch.setattr("backend.mcp_server.tools.current_client_id", _StubVar(client_id))

    return _set


@pytest.fixture
def captured_speaks(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, Any]]:
    """Replace the real generate_speech with a recorder.

    Patching the module attribute works because tools._speak imports it lazily
    inside the function body, so the lookup happens per call.
    """
    calls: list[dict[str, Any]] = []

    class _FakeGeneration:
        def model_dump(self, mode: str = "python") -> dict[str, Any]:
            return {"id": "gen-123", "status": "generating"}

    async def fake_generate_speech(req, db):
        calls.append(
            {
                "profile_id": req.profile_id,
                "text": req.text,
                "engine": req.engine,
                "language": req.language,
                "personality": req.personality,
            }
        )
        return _FakeGeneration()

    monkeypatch.setattr("backend.routes.generations.generate_speech", fake_generate_speech)
    return calls


@contextlib.contextmanager
def subscribed():
    """Drain the speak event bus for the duration of a block."""
    queue = mcp_events.subscribe()
    try:
        yield queue
    finally:
        mcp_events.unsubscribe(queue)


def drain(queue: asyncio.Queue) -> list[dict[str, Any]]:
    events = []
    while not queue.empty():
        events.append(queue.get_nowait())
    return events


# ─── Registration ──────────────────────────────────────────────────────────


async def test_exactly_the_four_tools_are_registered(client):
    """Tool names are API. Renaming one silently breaks every agent config,
    so this is the tripwire for a rename (e.g. dropping the dots for clients
    that reject them)."""
    async with client:
        names = {t.name for t in await client.list_tools()}
    assert names == TOOL_NAMES


async def test_every_tool_has_a_description(client):
    """The description is how an agent decides to call the tool at all."""
    async with client:
        tools = await client.list_tools()
    missing = [t.name for t in tools if not (t.description or "").strip()]
    assert not missing, f"tools without a description: {missing}"


# ─── voicebox.speak — profile resolution ───────────────────────────────────


async def test_speak_uses_explicit_profile_by_name(client, patch_db, make_profile, captured_speaks):
    target = make_profile("Morgan")
    make_profile("Scarlett")
    async with client:
        result = await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Morgan"})
    assert result.data["profile"] == "Morgan"
    assert captured_speaks[0]["profile_id"] == target.id


async def test_speak_matches_profile_name_case_insensitively(client, patch_db, make_profile, captured_speaks):
    target = make_profile("Morgan")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "profile": "mOrGaN"})
    assert captured_speaks[0]["profile_id"] == target.id


async def test_speak_accepts_a_profile_id(client, patch_db, make_profile, captured_speaks):
    target = make_profile("Morgan")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "profile": target.id})
    assert captured_speaks[0]["profile_id"] == target.id


async def test_speak_falls_back_to_the_client_binding(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    bound = make_profile("Morgan")
    make_profile("Scarlett")
    make_binding("claude-code", profile_id=bound.id)
    as_client("claude-code")
    async with client:
        result = await client.call_tool("voicebox.speak", {"text": "hi"})
    assert result.data["profile"] == "Morgan"
    assert captured_speaks[0]["profile_id"] == bound.id


async def test_speak_falls_back_to_the_global_default(
    client, patch_db, make_profile, captured_speaks, set_default_voice, as_client
):
    fallback = make_profile("Morgan")
    set_default_voice(fallback.id)
    as_client("some-unbound-client")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi"})
    assert captured_speaks[0]["profile_id"] == fallback.id


async def test_binding_beats_the_global_default(
    client, patch_db, make_profile, make_binding, captured_speaks, set_default_voice, as_client
):
    bound = make_profile("Morgan")
    other = make_profile("Scarlett")
    make_binding("claude-code", profile_id=bound.id)
    set_default_voice(other.id)
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi"})
    assert captured_speaks[0]["profile_id"] == bound.id


async def test_explicit_profile_beats_the_binding(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    bound = make_profile("Morgan")
    explicit = make_profile("Scarlett")
    make_binding("claude-code", profile_id=bound.id)
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Scarlett"})
    assert captured_speaks[0]["profile_id"] == explicit.id


async def test_unknown_profile_errors_rather_than_falling_back(
    client, patch_db, make_profile, captured_speaks, set_default_voice, as_client
):
    """A typo'd profile must not silently speak in someone else's voice."""
    fallback = make_profile("Morgan")
    set_default_voice(fallback.id)
    as_client("claude-code")
    async with client:
        with pytest.raises(ToolError):
            await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Nonexistent"})
    assert captured_speaks == []


async def test_speak_with_nothing_resolvable_explains_the_fix(client, patch_db, captured_speaks):
    async with client:
        with pytest.raises(ToolError, match="Settings"):
            await client.call_tool("voicebox.speak", {"text": "hi"})
    assert captured_speaks == []


# ─── voicebox.speak — engine and personality precedence ────────────────────


async def test_binding_engine_applies_when_arg_omitted(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    profile = make_profile("Morgan")
    make_binding("claude-code", profile_id=profile.id, default_engine="kokoro")
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi"})
    assert captured_speaks[0]["engine"] == "kokoro"


async def test_explicit_engine_beats_the_binding(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    profile = make_profile("Morgan")
    make_binding("claude-code", profile_id=profile.id, default_engine="kokoro")
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "engine": "luxtts"})
    assert captured_speaks[0]["engine"] == "luxtts"


async def test_binding_personality_applies_when_arg_omitted(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    profile = make_profile("Morgan", personality="a laconic pirate")
    make_binding("claude-code", profile_id=profile.id, default_personality=True)
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi"})
    assert captured_speaks[0]["personality"] is True


async def test_explicit_personality_false_beats_the_binding(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    """``personality`` is a tri-state: None means defer, False means override."""
    profile = make_profile("Morgan", personality="a laconic pirate")
    make_binding("claude-code", profile_id=profile.id, default_personality=True)
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "personality": False})
    assert captured_speaks[0]["personality"] is False


async def test_personality_is_off_when_the_profile_has_no_prompt(
    client, patch_db, make_profile, make_binding, captured_speaks, as_client
):
    """Asking for a persona a profile does not have must not reach the LLM."""
    profile = make_profile("Morgan", personality=None)
    make_binding("claude-code", profile_id=profile.id, default_personality=True)
    as_client("claude-code")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "personality": True})
    assert captured_speaks[0]["personality"] is False


async def test_language_defaults_to_english(client, patch_db, make_profile, captured_speaks):
    make_profile("Morgan")
    async with client:
        await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Morgan"})
    assert captured_speaks[0]["language"] == "en"


# ─── voicebox.speak — the response and the pill event ──────────────────────


async def test_speak_returns_a_pollable_generation(client, patch_db, make_profile, captured_speaks):
    make_profile("Morgan")
    async with client:
        result = await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Morgan"})
    assert result.data == {
        "generation_id": "gen-123",
        "status": "generating",
        "profile": "Morgan",
        "source": "mcp",
        "poll_url": "/generate/gen-123/status",
    }


async def test_speak_publishes_exactly_one_speak_start(client, patch_db, make_profile, captured_speaks, as_client):
    """The pill is the only signal the user gets that an agent is talking. One
    speak means one event — no duplicates, and never zero."""
    make_profile("Morgan")
    as_client("claude-code")
    with subscribed() as queue:
        async with client:
            await client.call_tool("voicebox.speak", {"text": "hi", "profile": "Morgan"})
        events = drain(queue)
    assert len(events) == 1
    assert events[0] == {
        "kind": "speak-start",
        "generation_id": "gen-123",
        "profile_name": "Morgan",
        "source": "mcp",
        "client_id": "claude-code",
    }


async def test_failed_speak_publishes_nothing(client, patch_db, captured_speaks):
    """A pill for speech that never happens would be a lie."""
    with subscribed() as queue:
        async with client:
            with pytest.raises(ToolError):
                await client.call_tool("voicebox.speak", {"text": "hi"})
        assert drain(queue) == []


# ─── voicebox.transcribe ───────────────────────────────────────────────────


async def test_transcribe_rejects_both_arguments(client):
    async with client:
        with pytest.raises(ToolError, match="exactly one"):
            await client.call_tool(
                "voicebox.transcribe",
                {"audio_base64": "AAA=", "audio_path": "/tmp/a.wav"},
            )


async def test_transcribe_rejects_neither_argument(client):
    async with client:
        with pytest.raises(ToolError, match="exactly one"):
            await client.call_tool("voicebox.transcribe", {})


async def test_transcribe_path_denied_to_remote_callers(client, monkeypatch, tmp_path):
    """audio_path on a non-loopback caller would make a Voicebox bound to
    0.0.0.0 an unauthenticated arbitrary-file-read primitive."""
    target = tmp_path / "secret.wav"
    target.write_bytes(b"RIFF")
    monkeypatch.setattr("backend.mcp_server.tools.request_is_loopback", lambda: False)
    async with client:
        with pytest.raises(ToolError, match="loopback"):
            await client.call_tool("voicebox.transcribe", {"audio_path": str(target)})


async def test_transcribe_rejects_relative_paths(client, monkeypatch):
    monkeypatch.setattr("backend.mcp_server.tools.request_is_loopback", lambda: True)
    async with client:
        with pytest.raises(ToolError, match="absolute"):
            await client.call_tool("voicebox.transcribe", {"audio_path": "relative/a.wav"})


async def test_transcribe_reports_a_missing_file(client, monkeypatch, tmp_path):
    monkeypatch.setattr("backend.mcp_server.tools.request_is_loopback", lambda: True)
    async with client:
        with pytest.raises(ToolError, match="not found"):
            await client.call_tool("voicebox.transcribe", {"audio_path": str(tmp_path / "nope.wav")})


async def test_transcribe_enforces_the_size_ceiling(client, monkeypatch, tmp_path):
    """Checked without writing 200 MB to disk."""
    from backend.mcp_server import tools

    target = tmp_path / "big.wav"
    target.write_bytes(b"RIFF")
    monkeypatch.setattr(tools, "request_is_loopback", lambda: True)
    monkeypatch.setattr(tools, "MAX_TRANSCRIBE_BYTES", 2)
    async with client:
        with pytest.raises(ToolError, match="limit"):
            await client.call_tool("voicebox.transcribe", {"audio_path": str(target)})


async def test_transcribe_rejects_malformed_base64(client):
    async with client:
        with pytest.raises(ToolError, match="Invalid audio_base64"):
            await client.call_tool("voicebox.transcribe", {"audio_base64": "not valid base64!!"})


async def test_transcribe_base64_cleans_up_its_temp_file(client, monkeypatch):
    """The temp file holds user audio; it must not survive the call, including
    when transcription raises."""
    from backend.mcp_server import tools

    seen: list[str] = []

    async def boom(path, language, model):
        seen.append(str(path))
        raise RuntimeError("whisper unavailable")

    monkeypatch.setattr(tools, "_transcribe_file", boom)

    async with client:
        with pytest.raises(ToolError):
            await client.call_tool(
                "voicebox.transcribe",
                {"audio_base64": base64.b64encode(b"RIFFdata").decode()},
            )

    assert seen, "the temp path never reached the transcriber"
    from pathlib import Path

    assert not Path(seen[0]).exists(), "temp audio file was left on disk"


# ─── voicebox.list_captures ────────────────────────────────────────────────


async def test_list_captures_returns_items_and_total(client, patch_db, make_capture):
    make_capture("first")
    make_capture("second")
    async with client:
        result = await client.call_tool("voicebox.list_captures", {})
    assert result.data["total"] == 2
    assert len(result.data["captures"]) == 2


@pytest.mark.parametrize("limit", [0, 201, -1])
async def test_list_captures_rejects_out_of_range_limits(client, patch_db, limit):
    async with client:
        with pytest.raises(ToolError, match="between 1 and 200"):
            await client.call_tool("voicebox.list_captures", {"limit": limit})


async def test_list_captures_rejects_negative_offset(client, patch_db):
    async with client:
        with pytest.raises(ToolError, match="offset"):
            await client.call_tool("voicebox.list_captures", {"offset": -1})


async def test_list_captures_honours_limit(client, patch_db, make_capture):
    for i in range(5):
        make_capture(f"capture {i}")
    async with client:
        result = await client.call_tool("voicebox.list_captures", {"limit": 2})
    assert len(result.data["captures"]) == 2
    assert result.data["total"] == 5


# ─── voicebox.list_profiles ────────────────────────────────────────────────


async def test_list_profiles_reports_personality_as_a_boolean(client, patch_db, make_profile):
    """Agents branch on this to decide whether personality=True is meaningful,
    so it must be a bool and never leak the prompt text itself."""
    make_profile("Morgan", personality="a laconic pirate")
    make_profile("Scarlett", personality=None)
    async with client:
        result = await client.call_tool("voicebox.list_profiles", {})
    by_name = {p["name"]: p for p in result.data["profiles"]}
    assert by_name["Morgan"]["has_personality"] is True
    assert by_name["Scarlett"]["has_personality"] is False
    assert "personality" not in by_name["Morgan"]


async def test_list_profiles_exposes_the_documented_fields(client, patch_db, make_profile):
    make_profile("Morgan", language="fr", voice_type="preset")
    async with client:
        result = await client.call_tool("voicebox.list_profiles", {})
    profile = result.data["profiles"][0]
    assert set(profile) == {"id", "name", "voice_type", "language", "has_personality"}
    assert profile["language"] == "fr"
    assert profile["voice_type"] == "preset"


async def test_list_profiles_on_an_empty_install(client, patch_db):
    """Nothing is seeded on a fresh install, so this is the first-run case."""
    async with client:
        result = await client.call_tool("voicebox.list_profiles", {})
    assert result.data["profiles"] == []
