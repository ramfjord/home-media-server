"""Unit tests for configure.py.

In-process only: httpx.MockTransport stands in for upstreams, so there
is no network or Docker dependency — the same code path runs host-native
and in CI. Covers the load-bearing claims of the async rewrite:

  * flows actually overlap (a stray blocking sleep would serialize them)
  * exhausting retries logs an explicit give-up ERROR — on BOTH the
    transient-5xx and transport-error paths (the transient path's
    give-up was unreachable in the first cut; this pins it)
  * log records are single-line and per-flow prefixed
  * run_flow is exception-firewalled (TaskGroup must not cross-cancel)
"""
import asyncio
import logging
import os
import sys
import time

import httpx
import pytest

sys.path.insert(0, os.path.dirname(__file__))
import configure  # noqa: E402


@pytest.fixture
def caplog_lines():
    """Replace configure.log's handlers with a buffer formatted exactly
    as production (same _SingleLineFormatter), restore afterwards."""
    buf: list[str] = []

    class _Cap(logging.Handler):
        def emit(self, record):
            buf.append(self.format(record))

    h = _Cap()
    h.setFormatter(
        configure._SingleLineFormatter("[%(upstream)s] %(levelname)s %(message)s")
    )
    saved = configure.log.handlers[:]
    saved_level, saved_prop = configure.log.level, configure.log.propagate
    configure.log.handlers[:] = [h]
    configure.log.setLevel(logging.INFO)
    configure.log.propagate = False
    yield buf
    configure.log.handlers[:] = saved
    configure.log.setLevel(saved_level)
    configure.log.propagate = saved_prop


@pytest.fixture
def fast_backoffs(monkeypatch):
    # 2 entries → 3 attempts, ~0.3s of sleep total per flow.
    monkeypatch.setattr(configure, "RETRY_BACKOFFS", [0.15, 0.15])


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_flows_overlap(fast_backoffs, caplog_lines):
    """Two flows each spend ~0.3s in backoff. Serial ≈ 0.6s; concurrent
    ≈ 0.3s. A blocking time.sleep anywhere collapses this to serial."""
    def busy(_req):
        return httpx.Response(503, text="busy")

    async def flow(name):
        async with _client(busy) as c:
            await configure.request(c, configure.flow_log(name), "GET", "http://x", {})

    t0 = time.monotonic()
    await asyncio.gather(flow("a"), flow("b"))
    elapsed = time.monotonic() - t0
    assert elapsed < 0.5, f"flows serialized ({elapsed:.3f}s ≈ serial 0.6s)"


async def test_transient_exhaustion_logs_giveup(fast_backoffs, caplog_lines):
    def busy(_req):
        return httpx.Response(503)

    async with _client(busy) as c:
        resp = await configure.request(
            c, configure.flow_log("alpha"), "GET", "http://x/h", {}
        )

    assert resp.status_code == 503  # last 5xx returned, not raised
    errs = [l for l in caplog_lines if " ERROR " in l]
    warns = [l for l in caplog_lines if " WARNING " in l]
    assert len(errs) == 1, errs
    assert errs[0].startswith("[alpha]") and "gave up after 3 attempts" in errs[0]
    assert len(warns) == 2  # one per non-final attempt


async def test_transport_exhaustion_logs_and_raises(fast_backoffs, caplog_lines):
    def boom(_req):
        raise httpx.ConnectError("refused")

    with pytest.raises(httpx.ConnectError):
        async with _client(boom) as c:
            await configure.request(
                c, configure.flow_log("beta"), "GET", "http://x", {}
            )

    errs = [l for l in caplog_lines if " ERROR " in l]
    assert len(errs) == 1 and errs[0].startswith("[beta]")
    assert "gave up after 3 attempts" in errs[0]


async def test_single_line_formatter_escapes_newlines(caplog_lines):
    configure.flow_log("gamma").error("multi\nline\rbody")
    assert len(caplog_lines) == 1
    line = caplog_lines[0]
    assert "\n" not in line and "\r" not in line
    assert "\\n" in line and line.startswith("[gamma]")


async def test_run_flow_firewalls_unexpected_error(caplog_lines, monkeypatch):
    """An unexpected exception inside a flow must become a counted
    failure, never propagate (else TaskGroup cross-cancels siblings)."""
    async def kaboom(*_a, **_k):
        raise RuntimeError("kaboom")

    monkeypatch.setattr(configure, "healthcheck", kaboom)
    res = await configure.run_flow("delta", {"base_url": "http://x"}, {})
    assert res == configure.FlowResult(failures=1, skipped=False)
    assert any(l.startswith("[delta]") and "flow aborted" in l for l in caplog_lines)


async def test_steps_carry_upstream_auth(caplog_lines):
    """Regression for f68640f: upstream auth: must be merged into steps:
    requests (trusted-header upstreams like open-webui depend on it),
    and a step's own header must win on collision."""
    seen: dict[str, str | None] = {}

    def capture(req):
        seen["x"] = req.headers.get("Remote-Email")
        return httpx.Response(200, text="ok")

    upstream = {
        "base_url": "http://x",
        "api_version": "v1",
        "auth": {"type": "header", "name": "Remote-Email", "value": "admin@x"},
    }
    async with _client(capture) as c:
        # No step headers → upstream auth is applied.
        await configure.apply_upstream(
            c, configure.flow_log("owui"), upstream,
            {"steps": [{"name": "s1", "request": {"method": "GET", "url": "http://x/a"}}]},
        )
        assert seen["x"] == "admin@x"

        # Step header collides → step wins.
        await configure.apply_upstream(
            c, configure.flow_log("owui"), upstream,
            {"steps": [{"name": "s2", "request": {
                "method": "GET", "url": "http://x/b",
                "headers": {"Remote-Email": "step-wins@x"}}}]},
        )
        assert seen["x"] == "step-wins@x"


async def test_apply_upstream_counts_failure(caplog_lines):
    """A non-transient 500 (not retried) → ConfigureError → one counted
    failure with a per-resource ERROR line."""
    def five_hundred(_req):
        return httpx.Response(500, json={"error": "nope"})

    async with _client(five_hundred) as c:
        n = await configure.apply_upstream(
            c,
            configure.flow_log("eps"),
            {"base_url": "http://x", "api_version": "v1"},
            {"posts": {"thing": {"k": "v"}}},
        )
    assert n == 1
    assert any(" ERROR " in l and "post /thing FAILED" in l for l in caplog_lines)
