"""Tests for the in-memory speak event bus.

This bus is what puts the speaking pill on screen, and its delivery guarantees
are weaker than they look — worth pinning down, because anything built on top
of ``/events/speak`` inherits them:

* no subscribers means the event is discarded, not queued
* a slow subscriber loses events rather than slowing publishers down
* there is no replay, so a consumer that reconnects misses the gap

The dict-copy behaviour is a real bug fix under test: the SSE layer pops
``kind`` off the event it receives, so a shared dict would have the first
consumer strip the field out from under the second.
"""

from __future__ import annotations

import asyncio

import pytest

from backend.mcp_server import events as mcp_events


@pytest.fixture(autouse=True)
def _isolate_subscribers():
    """The subscriber set is module-global; keep tests from leaking into it."""
    saved = set(mcp_events._subscribers)
    mcp_events._subscribers.clear()
    yield
    mcp_events._subscribers.clear()
    mcp_events._subscribers.update(saved)


def drain(queue: asyncio.Queue) -> list[dict]:
    events = []
    while not queue.empty():
        events.append(queue.get_nowait())
    return events


async def test_publish_with_no_subscribers_is_discarded():
    """Not an error, and not queued for later — the event is simply gone. Any
    consumer started after a speak begins will never see it."""
    mcp_events.publish("speak-start", {"generation_id": "gen-1"})

    queue = mcp_events.subscribe()
    try:
        assert drain(queue) == []
    finally:
        mcp_events.unsubscribe(queue)


async def test_subscriber_receives_kind_merged_with_payload():
    queue = mcp_events.subscribe()
    try:
        mcp_events.publish("speak-start", {"generation_id": "gen-1", "source": "mcp"})
        assert drain(queue) == [{"kind": "speak-start", "generation_id": "gen-1", "source": "mcp"}]
    finally:
        mcp_events.unsubscribe(queue)


async def test_each_subscriber_gets_an_independent_dict():
    """The SSE consumer calls event.pop("kind"). With a shared dict the first
    consumer to drain would strip the field from the second one's copy."""
    first = mcp_events.subscribe()
    second = mcp_events.subscribe()
    try:
        mcp_events.publish("speak-start", {"generation_id": "gen-1"})
        a = first.get_nowait()
        b = second.get_nowait()

        assert a is not b
        a.pop("kind")
        assert b["kind"] == "speak-start", "second subscriber lost 'kind'"
    finally:
        mcp_events.unsubscribe(first)
        mcp_events.unsubscribe(second)


async def test_all_subscribers_receive_every_event():
    queues = [mcp_events.subscribe() for _ in range(3)]
    try:
        mcp_events.publish("speak-start", {"generation_id": "gen-1"})
        mcp_events.publish("speak-end", {"generation_id": "gen-1"})
        for queue in queues:
            assert [e["kind"] for e in drain(queue)] == ["speak-start", "speak-end"]
    finally:
        for queue in queues:
            mcp_events.unsubscribe(queue)


async def test_a_full_queue_drops_without_raising():
    """A subscriber that stops draining must never block or break a publisher —
    speaking is on the request path."""
    queue = mcp_events.subscribe()
    try:
        for i in range(queue.maxsize + 10):
            mcp_events.publish("speak-start", {"generation_id": f"gen-{i}"})

        received = drain(queue)
        assert len(received) == queue.maxsize
        # Oldest are kept, later ones dropped — worth stating explicitly, since
        # "drop oldest" would be the more useful behaviour for a pill.
        assert received[0]["generation_id"] == "gen-0"
    finally:
        mcp_events.unsubscribe(queue)


async def test_a_full_subscriber_does_not_starve_a_healthy_one():
    slow = mcp_events.subscribe()
    fast = mcp_events.subscribe()
    try:
        for i in range(slow.maxsize + 5):
            mcp_events.publish("speak-start", {"generation_id": f"gen-{i}"})
            drain(fast)  # fast consumer keeps up

        mcp_events.publish("speak-start", {"generation_id": "final"})
        assert [e["generation_id"] for e in drain(fast)] == ["final"]
    finally:
        mcp_events.unsubscribe(slow)
        mcp_events.unsubscribe(fast)


async def test_unsubscribe_stops_delivery():
    queue = mcp_events.subscribe()
    mcp_events.unsubscribe(queue)
    mcp_events.publish("speak-start", {"generation_id": "gen-1"})
    assert drain(queue) == []


async def test_unsubscribe_is_idempotent():
    """The SSE route unsubscribes in a finally block that can run twice on a
    cancelled request."""
    queue = mcp_events.subscribe()
    mcp_events.unsubscribe(queue)
    mcp_events.unsubscribe(queue)  # must not raise
