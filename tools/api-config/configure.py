#!/usr/bin/env python3
"""Apply declared config to upstream HTTP APIs (idempotent).

Usage:
    configure.py <upstreams.yaml> <resources.yaml>

upstreams.yaml — per-upstream connection + auth metadata:
    base_url:           HTTP base
    api_version:        path segment after /api/   (e.g. v3, v1, v2)
    healthcheck_path:   optional, GET'd before reconcile (skip on 5xx)
    auth:               optional. {type: header|bearer, name, value}
    body_format:        json (default) | qbit-form
                          qbit-form: send body as form-encoded `json=<JSON>`
                          (qBittorrent's RPC-style API expects this)
    extra_mutate_query: optional, query params on POST/PUT only

resources.yaml — declarative endpoint configs, keyed by upstream:
    <upstream>:
      upserts:                # GET-list-then-PUT-by-name-else-POST
        <endpoint>: [{body}, ...]   # for REST-list endpoints with stable
                                    # name fields. <endpoint> is appended
                                    # to /api/<api_version>/.
      posts:                  # bare POST, no upsert dance
        <endpoint>: {body}          # for RPC-style endpoints
      steps:                  # ordered sequence of arbitrary requests with
        - request:                  # value extraction + control flow. For
            method: POST            # bootstraps that need to chain requests
            url: $base_url/...      # together: login → fetch X → log in with
            form: {...}             # X → POST something. The upstream's
            headers: {...}          # cookie jar persists across steps so a
          success_when:             # /auth/login SID cookie is auto-attached
            body_equals: "Ok."      # on subsequent calls to the same host.
          on_success: stop          # control flow (default: continue)
          on_failure: continue      # control flow (default: raise)
          retry_budget_seconds: 300 # retry within budget if success_when
          extract:                  # not met (default: no per-step retry)
            regex: '... (\\S+)'     # regex pulls group 1 from response body,
            store_as: temp_pw       # subsequent steps see it as $temp_pw.

Step request bodies: one of `json: <obj>` (JSON body), `form: <obj>`
(application/x-www-form-urlencoded), or `qbit_form: <obj>` (form-encoded
with body=`json=<JSON>`, qBittorrent's RPC quirk). Strings inside any
step field undergo $var substitution: `$base_url` is always set to the
upstream's base_url; `$<name>` references variables captured by an
earlier step's `extract.store_as`.

Concurrency & logging: each upstream is an independent *flow* — a
coroutine that runs its healthcheck + steps + upserts + posts strictly
in sequence. All flows run concurrently (one asyncio task each, its own
httpx.AsyncClient so cookie jars never cross), so total runtime is
~max(flow) not sum(flow): one unreachable upstream burns its retry
budget alongside the others, not serialized ahead of them. Every log
line is single-line and prefixed `[<upstream>]` so concurrent flows
stay attributable under `grep`. Each request retries with exponential
backoff on transient errors; exhausting the retries logs an explicit
ERROR naming attempts + elapsed. A failed healthcheck skips that
upstream's resources with a warning.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import sys
import time
from pathlib import Path
from typing import NamedTuple

import httpx
import yaml

# Cumulative ~7.5 min budget — long enough for path-unit-triggered
# container recreates that take a while to come up (qbit in particular).
# The 10s first-retry covers the "deploy → restart → not yet listening"
# window where a tighter budget gives up before the upstream is back.
# This is now a *per-flow* budget paid concurrently, not serially.
RETRY_BACKOFFS = [10, 30, 60, 120, 240]
TRANSIENT_STATUS = {502, 503, 504}

log = logging.getLogger("api-configure")


class ConfigureError(Exception):
    pass


class FlowResult(NamedTuple):
    # `failures` = upstream reconcile failures (a resource/step didn't
    # apply). These do NOT fail the unit — they're surfaced per-target
    # via the [<upstream>] ERROR log lines (Alloy config_target → a
    # per-service Prometheus alert). `engine_error` = api-config itself
    # broke (flow-firewall caught an unexpected exception): that, and
    # top-level parse/IO, are the only things that exit nonzero ->
    # SystemdUnitFailed under service=api-config. Keeping the two
    # distinct is what lets "radarr didn't reconcile" page radarr while
    # "the reconcile engine is down" pages api-config.
    failures: int
    skipped: bool
    engine_error: bool = False


# ---------------------------------------------------------------------------
# Logging: one stdout stream, every record prefixed `[<upstream>]` and
# squashed to a single physical line so concurrently-interleaved flows
# stay grep-attributable (the multi-line body/traceback case is the only
# thing that would otherwise splice un-prefixed across flows).
# ---------------------------------------------------------------------------


# syslog severities systemd's journal-stream parser reads from a leading
# `<N>` (SyslogLevelPrefix=yes, the default) and strips before storing —
# so the entry's journald PRIORITY is set, Alloy's relabel derives
# `level` from it, and ServiceLogErrors sees api-config errors. Only
# sound because the unit runs `compose run` (not `up`, which prepends
# `api-config | ` and would push the `<N>` off line-start where systemd
# won't parse it).
_SYSLOG_SEVERITY = {
    logging.CRITICAL: 2,  # LOG_CRIT
    logging.ERROR:    3,  # LOG_ERR
    logging.WARNING:  4,  # LOG_WARNING
    logging.INFO:     6,  # LOG_INFO
    logging.DEBUG:    7,  # LOG_DEBUG
}


class _SingleLineFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        if not hasattr(record, "upstream"):
            record.upstream = "api-config"
        s = super().format(record)
        return s.replace("\r", "\\r").replace("\n", "\\n")


class _JournalPriorityFormatter(_SingleLineFormatter):
    """Production formatter: `_SingleLineFormatter` + a leading `<N>` so
    systemd tags the journal entry's PRIORITY. Kept separate from
    `_SingleLineFormatter` (which the tests pin as the human/grep form)
    so the `<N>` never leaks into assertions or non-systemd runs."""
    def format(self, record: logging.LogRecord) -> str:
        sev = _SYSLOG_SEVERITY.get(record.levelno, 6)
        return f"<{sev}>{super().format(record)}"


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        _JournalPriorityFormatter("[%(upstream)s] %(levelname)s %(message)s")
    )
    log.addHandler(handler)
    log.setLevel(logging.INFO)
    log.propagate = False  # our handler is terminal; don't double-emit via root


def flow_log(name: str) -> logging.LoggerAdapter:
    """A logger bound to one upstream flow — every record carries `upstream`
    so the formatter can prefix it and a reader can `grep '\\[name\\]'`."""
    return logging.LoggerAdapter(log, {"upstream": name})


# ---------------------------------------------------------------------------


def auth_headers(upstream: dict) -> dict[str, str]:
    auth = upstream.get("auth") or {}
    if not auth:
        return {}
    if auth.get("type") == "header":
        return {auth["name"]: auth["value"]}
    if auth.get("type") == "bearer":
        return {"Authorization": f"Bearer {auth['value']}"}
    raise ConfigureError(f"unsupported auth type: {auth.get('type')}")


def body_for(upstream: dict, body: dict) -> tuple[dict, dict]:
    """Returns (httpx-kwargs, content-type-headers) for the given body."""
    fmt = upstream.get("body_format", "json")
    if fmt == "json":
        return {"json": body}, {"Content-Type": "application/json"}
    if fmt == "qbit-form":
        # qBittorrent's setPreferences expects:
        #   Content-Type: application/x-www-form-urlencoded
        #   body: json=<URL-encoded JSON string>
        return {"data": {"json": json.dumps(body)}}, {}
    raise ConfigureError(f"unsupported body_format: {fmt}")


async def request(
    client: httpx.AsyncClient,
    log: logging.LoggerAdapter,
    method: str,
    url: str,
    upstream: dict,
    context: str = "",
    **kwargs,
) -> httpx.Response:
    """HTTP request with explicit-schedule retry on transient failures.

    Sleep schedule is RETRY_BACKOFFS[attempt-1] between attempts, so a
    failure on the first try waits 10s before retrying (covers post-deploy
    restart races), and a stubborn outage gets ~7.5 min of total budget
    before we give up. On final give-up an ERROR is logged naming the
    attempt count and elapsed wall time, so an exhausted retry is never
    silent.

    `context` is a stable token prepended to the give-up ERROR (e.g.
    "healthcheck") so the observability layer can match it precisely —
    a healthcheck give-up means "upstream unreachable, will skip", not
    a config failure, and is excluded from alerting via api-config's
    log_metric_exclude_regex (same mechanism as the r8169 NIC noise).
    A real reconcile give-up has no context and stays page-worthy."""
    ctx = f"{context}: " if context else ""
    headers = {**auth_headers(upstream), **kwargs.pop("headers", {})}
    n_attempts = len(RETRY_BACKOFFS) + 1
    t0 = time.monotonic()
    for attempt in range(n_attempts):
        is_last = attempt == n_attempts - 1
        try:
            resp = await client.request(method, url, headers=headers, **kwargs)
        except httpx.TransportError as e:
            if is_last:
                elapsed = int(time.monotonic() - t0)
                log.error(
                    "%sgave up after %d attempts / %ds: %s %s: %s: %s",
                    ctx, n_attempts, elapsed, method, url, type(e).__name__, e,
                )
                raise
            backoff = RETRY_BACKOFFS[attempt]
            log.warning(
                "attempt %d/%d %s %s failed (%s: %s); retrying in %ds",
                attempt + 1, n_attempts, method, url, type(e).__name__, e, backoff,
            )
            await asyncio.sleep(backoff)
            continue
        if resp.status_code in TRANSIENT_STATUS:
            if is_last:
                # Give-up surfaced explicitly; the caller still turns the
                # 5xx into a resource-level failure (complementary signal).
                elapsed = int(time.monotonic() - t0)
                log.error(
                    "%sgave up after %d attempts / %ds: %s %s → HTTP %d (transient)",
                    ctx, n_attempts, elapsed, method, url, resp.status_code,
                )
                return resp
            backoff = RETRY_BACKOFFS[attempt]
            log.warning(
                "attempt %d/%d %s %s → HTTP %d (transient); retrying in %ds",
                attempt + 1, n_attempts, method, url, resp.status_code, backoff,
            )
            await asyncio.sleep(backoff)
            continue
        return resp
    raise AssertionError("unreachable: loop always returns or raises")


async def healthcheck(
    client: httpx.AsyncClient, log: logging.LoggerAdapter, upstream: dict
) -> bool:
    path = upstream.get("healthcheck_path")
    if not path:
        return True
    url = f"{upstream['base_url']}{path}"
    try:
        resp = await request(client, log, "GET", url, upstream,
                             context="healthcheck")
    except httpx.HTTPError as e:
        log.warning("healthcheck %s failed: %s", url, e)
        return False
    if not resp.is_success:
        log.warning("healthcheck %s → HTTP %d", url, resp.status_code)
        return False
    return True


def find_by_name(items: list[dict], name: str) -> dict | None:
    return next((i for i in items if i.get("name") == name), None)


def with_query(url: str, params: dict | None) -> str:
    if not params:
        return url
    sep = "&" if "?" in url else "?"
    qs = "&".join(f"{k}={str(v).lower() if isinstance(v, bool) else v}"
                  for k, v in params.items())
    return f"{url}{sep}{qs}"


async def upsert_resource(
    client: httpx.AsyncClient,
    log: logging.LoggerAdapter,
    upstream: dict,
    endpoint: str,
    resource: dict,
) -> None:
    """REST-list upsert: GET list, match by name, PUT-by-id or POST."""
    base = f"{upstream['base_url']}/api/{upstream['api_version']}/{endpoint}"
    rname = resource.get("name") or "<unnamed>"
    extra_q = upstream.get("extra_mutate_query")

    list_resp = await request(client, log, "GET", base, upstream)
    list_resp.raise_for_status()
    match = find_by_name(list_resp.json(), rname)
    body_kwargs, body_headers = body_for(upstream, resource)

    if match:
        url = with_query(f"{base}/{match['id']}", extra_q)
        method = "PUT"
    else:
        url = with_query(base, extra_q)
        method = "POST"
    resp = await request(
        client, log, method, url, upstream, headers=body_headers, **body_kwargs
    )
    if resp.is_success:
        log.info("%s %s name=%s%s", method, endpoint, rname,
                 f" id={match['id']}" if match else "")
    else:
        try:
            err = resp.json()
        except json.JSONDecodeError:
            err = resp.text
        raise ConfigureError(f"{method} {url} → HTTP {resp.status_code}: {err}")


async def post_resource(
    client: httpx.AsyncClient,
    log: logging.LoggerAdapter,
    upstream: dict,
    endpoint: str,
    body: dict,
) -> None:
    """Bare POST — for RPC-style endpoints (no list, no name-keyed upsert)."""
    extra_q = upstream.get("extra_mutate_query")
    url = with_query(
        f"{upstream['base_url']}/api/{upstream['api_version']}/{endpoint}",
        extra_q,
    )
    body_kwargs, body_headers = body_for(upstream, body)
    resp = await request(
        client, log, "POST", url, upstream, headers=body_headers, **body_kwargs
    )
    if resp.is_success:
        log.info("POST %s", endpoint)
    else:
        try:
            err = resp.json()
        except json.JSONDecodeError:
            err = resp.text
        raise ConfigureError(f"POST {url} → HTTP {resp.status_code}: {err}")


# ---------------------------------------------------------------------------
# Steps engine — sequence of arbitrary requests with $var substitution,
# regex extraction, and small amount of control flow. Stays out of any
# specific upstream's quirks; per-service logic lives in each
# service.yml.elp's api_resources `steps:` block.
# ---------------------------------------------------------------------------

# `$varname` references in any string field of a step. Stops at any
# non-identifier character (so `$base_url/api/v2/login` interpolates
# `$base_url` and leaves the rest of the path alone).
_VAR_RE = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)")


def substitute(value, ctx: dict) -> object:
    """Recursively replace `$var` in any string inside `value` with ctx[var].
    Unknown $vars are left as-is so missing extractions surface as visibly
    wrong URLs/bodies rather than silently empty strings."""
    if isinstance(value, str):
        return _VAR_RE.sub(lambda m: str(ctx.get(m.group(1), m.group(0))), value)
    if isinstance(value, dict):
        return {k: substitute(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, ctx) for v in value]
    return value


def step_request_kwargs(req: dict) -> tuple[str, str, dict]:
    """Translate a step's `request:` block to (method, url, httpx-kwargs)."""
    method = req["method"]
    url = req["url"]
    kwargs: dict = {}
    if "params" in req:
        kwargs["params"] = req["params"]
    if "headers" in req:
        kwargs["headers"] = req["headers"]
    if "json" in req:
        kwargs["json"] = req["json"]
    elif "form" in req:
        kwargs["data"] = req["form"]
    elif "qbit_form" in req:
        # qBittorrent's RPC encoding: form body with one field `json=<json>`.
        kwargs["data"] = {"json": json.dumps(req["qbit_form"])}
    return method, url, kwargs


def step_response_ok(resp: httpx.Response, success_when: dict | None) -> bool:
    """Did this response meet the step's success criteria?"""
    if success_when:
        if "body_equals" in success_when:
            return resp.text.strip() == success_when["body_equals"]
        if "status" in success_when:
            return resp.status_code == success_when["status"]
    return resp.is_success


def step_extract(resp: httpx.Response, extract: dict | None, ctx: dict) -> bool:
    """Pull a regex group from the response body and store it in ctx.
    Returns True if there was no extract, or extraction succeeded; False if
    extraction was requested but the regex didn't match (causes the step to
    be treated as a failure → retry within budget)."""
    if not extract:
        return True
    pattern = re.compile(extract["regex"])
    m = pattern.search(resp.text)
    if not m:
        return False
    ctx[extract["store_as"]] = m.group(1)
    return True


async def run_step(
    client: httpx.AsyncClient,
    log: logging.LoggerAdapter,
    step: dict,
    ctx: dict,
    upstream: dict,
) -> bool:
    """Execute one step; return True to continue the sequence, False to
    stop. Honors success_when / extract / on_success / on_failure /
    retry_budget_seconds. Raises ConfigureError if the step fails and
    on_failure is the default (raise) — and logs an ERROR naming the
    exhausted budget before it does."""
    step_name = step.get("name") or step["request"].get("url", "?")
    budget_s = step.get("retry_budget_seconds", 0)
    deadline = time.monotonic() + budget_s if budget_s > 0 else None
    poll_s = 10
    last_summary = ""
    while True:
        req = substitute(step["request"], ctx)
        method, url, kwargs = step_request_kwargs(req)
        # Upstream-level auth applies to steps too (mirrors request());
        # a step's own headers win on collision. Dropping this silently
        # breaks trusted-header upstreams (e.g. open-webui's Remote-Email
        # signin → 401 → retry-budget churn).
        kwargs["headers"] = {**auth_headers(upstream),
                             **kwargs.get("headers", {})}
        try:
            resp = await client.request(method, url, **kwargs)
        except httpx.TransportError as e:
            last_summary = f"transport error: {e}"
            if deadline is None or time.monotonic() >= deadline:
                break
            log.warning("[%s] %s; retrying in %ds (within budget)",
                        step_name, last_summary, poll_s)
            await asyncio.sleep(poll_s)
            continue
        body_ok = step_response_ok(resp, step.get("success_when"))
        extract_ok = body_ok and step_extract(resp, step.get("extract"), ctx)
        if body_ok and extract_ok:
            log.info("[%s] ok (HTTP %d)", step_name, resp.status_code)
            return step.get("on_success", "continue") != "stop"
        last_summary = (
            f"HTTP {resp.status_code} body={resp.text[:200]!r} "
            f"(body_ok={body_ok}, extract_ok={extract_ok})"
        )
        if deadline is None or time.monotonic() >= deadline:
            break
        log.warning("[%s] not ready (%s); retrying in %ds (within budget)",
                    step_name, last_summary, poll_s)
        await asyncio.sleep(poll_s)
    # Failure path: retry budget (if any) is exhausted.
    if step.get("on_failure") == "continue":
        log.warning("[%s] failed (continuing): %s", step_name, last_summary)
        return True
    log.error("[%s] failed after retry budget: %s", step_name, last_summary)
    raise ConfigureError(f"[{step_name}] {last_summary}")


async def apply_steps(
    client: httpx.AsyncClient, log: logging.LoggerAdapter, upstream: dict, steps: list
) -> None:
    """Execute an ordered sequence of HTTP steps. ctx starts with $base_url
    + a small set of time vars pre-bound; steps' extract.store_as populate
    additional vars as the sequence runs."""
    now_ns = int(time.time() * 1e9)
    ctx: dict = {
        "base_url":    upstream["base_url"].rstrip("/"),
        "now_ns":      now_ns,
        # Convenience time anchors for log-store queries that need a
        # `start`/`end` window (Loki's `query_range` defaults to a 1h
        # lookback, which is usually too narrow for "find the temp pw
        # logged at last boot").
        "past_24h_ns": now_ns - 24 * 3600 * 10**9,
        "past_30d_ns": now_ns - 30 * 24 * 3600 * 10**9,
    }
    for i, step in enumerate(steps, start=1):
        log.info("step %d/%d: %s", i, len(steps),
                 step.get("name") or step["request"].get("url", "?"))
        cont = await run_step(client, log, step, ctx, upstream)
        if not cont:
            return


# ---------------------------------------------------------------------------


async def apply_upstream(
    client: httpx.AsyncClient,
    log: logging.LoggerAdapter,
    upstream: dict,
    resources: dict,
) -> int:
    """Apply all upserts/posts/steps for one upstream, in order. Returns
    count of failures (does not raise — the caller's TaskGroup must not be
    cross-cancelled by one upstream's failure)."""
    failures = 0
    if resources.get("steps"):
        log.info("steps (%d)", len(resources["steps"]))
        try:
            await apply_steps(client, log, upstream, resources["steps"])
        except (httpx.HTTPError, ConfigureError) as e:
            log.error("steps FAILED: %s", e)
            failures += 1
    for endpoint, items in (resources.get("upserts") or {}).items():
        if not isinstance(items, list):
            items = [items]
        log.info("/%s (upsert, %d item(s))", endpoint, len(items))
        for r in items:
            try:
                await upsert_resource(client, log, upstream, endpoint, r)
            except (httpx.HTTPError, ConfigureError) as e:
                log.error("upsert /%s name=%s FAILED: %s",
                          endpoint, r.get("name", "<unnamed>"), e)
                failures += 1
    for endpoint, body in (resources.get("posts") or {}).items():
        log.info("/%s (POST)", endpoint)
        try:
            await post_resource(client, log, upstream, endpoint, body)
        except (httpx.HTTPError, ConfigureError) as e:
            log.error("post /%s FAILED: %s", endpoint, e)
            failures += 1
    return failures


async def run_flow(name: str, upstream: dict, resources: dict) -> FlowResult:
    """One upstream's whole reconcile: its own AsyncClient (isolated cookie
    jar), healthcheck gate, then sequential apply. Exception-firewalled so
    nothing escapes into the TaskGroup and cross-cancels sibling flows."""
    flog = flow_log(name)
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            if not await healthcheck(client, flog, upstream):
                flog.warning("skipped (healthcheck failed)")
                return FlowResult(failures=0, skipped=True)
            failures = await apply_upstream(client, flog, upstream, resources)
            return FlowResult(failures=failures, skipped=False)
    except Exception as e:  # firewall: a flow must never raise out
        # An unexpected exception is an api-config *engine* defect, not
        # an upstream reconcile failure — attribute it to api-config
        # (config_target=api-config, page api-config, exit nonzero), not
        # to the upstream whose flow happened to be running.
        flow_log("api-config").error(
            "engine error in %s flow (unexpected %s): %s",
            name, type(e).__name__, e,
        )
        return FlowResult(failures=0, skipped=False, engine_error=True)


async def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    setup_logging()
    mlog = flow_log("api-config")
    upstreams = yaml.safe_load(Path(argv[1]).read_text()) or {}
    resources = yaml.safe_load(Path(argv[2]).read_text()) or {}

    tasks: dict[str, asyncio.Task] = {}
    skipped_no_upstream = 0
    async with asyncio.TaskGroup() as tg:
        for name in sorted(resources):
            if name not in upstreams:
                flow_log(name).warning("no matching upstream entry, skipping")
                skipped_no_upstream += 1
                continue
            tasks[name] = tg.create_task(
                run_flow(name, upstreams[name], resources[name])
            )

    results = {name: t.result() for name, t in tasks.items()}
    failures = sum(r.failures for r in results.values())
    engine_errors = sum(1 for r in results.values() if r.engine_error)
    skipped = skipped_no_upstream + sum(1 for r in results.values() if r.skipped)

    if skipped:
        mlog.warning("%d upstream(s) skipped (healthcheck/missing)", skipped)
    if failures:
        # WARNING, not ERROR: an upstream that didn't reconcile is paged
        # per-target (its own [<upstream>] ERROR lines → service=<that>),
        # NOT under service=api-config. Logging this at ERROR would
        # re-page api-config for every upstream failure — exactly the
        # double-attribution this design removes.
        mlog.warning("%d upstream reconcile failure(s) (alerted per-target)",
                     failures)
    if engine_errors:
        # The only nonzero exit: api-config itself broke → unit enters
        # failed → SystemdUnitFailed under service=api-config.
        mlog.error("%d engine error(s)", engine_errors)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv)))
