"""Shared fixtures.

The MCP tools each open their own session via ``next(get_db())`` rather than
taking one by dependency injection, so testing them means replacing that
function rather than passing a session in. ``patch_db`` below does that against
an in-memory SQLite database, which keeps the tools' real session lifecycle
(including the ``db.close()`` in their ``finally`` blocks) under test.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from backend.database.models import (
    Base,
    Capture,
    CaptureSettings,
    MCPClientBinding,
    VoiceProfile,
)


@pytest.fixture
def db_session() -> Iterator[Session]:
    """A fresh in-memory database per test.

    StaticPool keeps every connection pointed at the same in-memory database —
    without it each new connection would get its own empty one, and the rows a
    fixture inserts would be invisible to the code under test.
    """
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    # The models declare ForeignKeys, which SQLite ignores unless asked.
    @event.listens_for(engine, "connect")
    def _fk_on(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    factory = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    session = factory()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture
def patch_db(monkeypatch: pytest.MonkeyPatch, db_session: Session):
    """Point the MCP tools at ``db_session``.

    The tools call ``db.close()`` in a finally block, which would end the
    fixture's session for any later assertion, so hand them a proxy whose
    close() is a no-op. Everything else passes straight through.
    """

    class _NoCloseSession:
        def __init__(self, wrapped: Session) -> None:
            self._wrapped = wrapped

        def close(self) -> None:  # the whole point of the proxy
            pass

        def __getattr__(self, item: str):
            return getattr(self._wrapped, item)

    def fake_get_db():
        yield _NoCloseSession(db_session)

    monkeypatch.setattr("backend.mcp_server.tools.get_db", fake_get_db)
    return db_session


@pytest.fixture
def make_profile(db_session: Session):
    """Insert a voice profile and return the ORM row."""

    def _make(
        name: str = "Morgan",
        *,
        personality: str | None = None,
        language: str = "en",
        voice_type: str = "cloned",
        default_engine: str | None = None,
    ) -> VoiceProfile:
        profile = VoiceProfile(
            id=str(uuid.uuid4()),
            name=name,
            language=language,
            voice_type=voice_type,
            default_engine=default_engine,
            personality=personality,
        )
        db_session.add(profile)
        db_session.commit()
        return profile

    return _make


@pytest.fixture
def make_binding(db_session: Session):
    """Insert a per-client binding and return the ORM row."""

    def _make(
        client_id: str = "claude-code",
        *,
        profile_id: str | None = None,
        default_engine: str | None = None,
        default_personality: bool = False,
        label: str | None = None,
    ) -> MCPClientBinding:
        binding = MCPClientBinding(
            client_id=client_id,
            label=label,
            profile_id=profile_id,
            default_engine=default_engine,
            default_personality=default_personality,
        )
        db_session.add(binding)
        db_session.commit()
        return binding

    return _make


@pytest.fixture
def set_default_voice(db_session: Session):
    """Set capture_settings.default_playback_voice_id — the last resort in the
    resolution chain. There is no seed for this row, so tests create it."""

    def _set(profile_id: str | None) -> None:
        settings = db_session.query(CaptureSettings).filter(CaptureSettings.id == 1).first()
        if settings is None:
            settings = CaptureSettings(id=1)
            db_session.add(settings)
        settings.default_playback_voice_id = profile_id
        db_session.commit()

    return _set


@pytest.fixture
def make_capture(db_session: Session):
    def _make(transcript: str = "hello", *, source: str = "dictation") -> Capture:
        capture = Capture(
            id=str(uuid.uuid4()),
            audio_path=f"/tmp/{uuid.uuid4()}.wav",
            source=source,
            transcript_raw=transcript,
        )
        db_session.add(capture)
        db_session.commit()
        return capture

    return _make
