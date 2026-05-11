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

Each request retries with exponential backoff on transient errors. A failed
healthcheck for an upstream skips its resources with a warning.
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

import httpx
import yaml

# Cumulative ~7.5 min budget — long enough for path-unit-triggered
# container recreates that take a while to come up (qbit in particular).
# The 10s first-retry covers the "deploy → restart → not yet listening"
# window where a tighter budget gives up before the upstream is back.
RETRY_BACKOFFS = [10, 30, 60, 120, 240]
TRANSIENT_STATUS = {502, 503, 504}


class ConfigureError(Exception):
    pass


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


def request(
    client: httpx.Client, method: str, url: str, upstream: dict, **kwargs
) -> httpx.Response:
    """HTTP request with explicit-schedule retry on transient failures.

    Sleep schedule is RETRY_BACKOFFS[attempt-1] between attempts, so a
    failure on the first try waits 10s before retrying (covers post-deploy
    restart races), and a stubborn outage gets ~7.5 min of total budget
    before we give up."""
    headers = {**auth_headers(upstream), **kwargs.pop("headers", {})}
    last_exc: Exception | None = None
    n_attempts = len(RETRY_BACKOFFS) + 1
    for attempt in range(n_attempts):
        try:
            resp = client.request(method, url, headers=headers, **kwargs)
            if resp.status_code in TRANSIENT_STATUS and attempt < n_attempts - 1:
                time.sleep(RETRY_BACKOFFS[attempt])
                continue
            return resp
        except httpx.TransportError as e:
            last_exc = e
            if attempt < n_attempts - 1:
                time.sleep(RETRY_BACKOFFS[attempt])
                continue
            raise
    assert last_exc
    raise last_exc


def healthcheck(client: httpx.Client, name: str, upstream: dict) -> bool:
    path = upstream.get("healthcheck_path")
    if not path:
        return True
    url = f"{upstream['base_url']}{path}"
    try:
        resp = request(client, "GET", url, upstream)
    except httpx.HTTPError as e:
        print(f"[api-configure] {name}: healthcheck {url} failed: {e}",
              file=sys.stderr)
        return False
    if not resp.is_success:
        print(f"[api-configure] {name}: healthcheck {url} → HTTP {resp.status_code}",
              file=sys.stderr)
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


def upsert_resource(
    client: httpx.Client, name: str, upstream: dict, endpoint: str, resource: dict
) -> None:
    """REST-list upsert: GET list, match by name, PUT-by-id or POST."""
    base = f"{upstream['base_url']}/api/{upstream['api_version']}/{endpoint}"
    rname = resource.get("name") or "<unnamed>"
    extra_q = upstream.get("extra_mutate_query")

    list_resp = request(client, "GET", base, upstream)
    list_resp.raise_for_status()
    match = find_by_name(list_resp.json(), rname)
    body_kwargs, body_headers = body_for(upstream, resource)

    if match:
        url = with_query(f"{base}/{match['id']}", extra_q)
        method = "PUT"
    else:
        url = with_query(base, extra_q)
        method = "POST"
    resp = request(client, method, url, upstream, headers=body_headers, **body_kwargs)
    if resp.is_success:
        print(f"  {method:4s} {endpoint:24s} name={rname}"
              f"{' id=' + str(match['id']) if match else ''}")
    else:
        try:
            err = resp.json()
        except json.JSONDecodeError:
            err = resp.text
        raise ConfigureError(f"{method} {url} → HTTP {resp.status_code}: {err}")


def post_resource(
    client: httpx.Client, name: str, upstream: dict, endpoint: str, body: dict
) -> None:
    """Bare POST — for RPC-style endpoints (no list, no name-keyed upsert)."""
    extra_q = upstream.get("extra_mutate_query")
    url = with_query(
        f"{upstream['base_url']}/api/{upstream['api_version']}/{endpoint}",
        extra_q,
    )
    body_kwargs, body_headers = body_for(upstream, body)
    resp = request(client, "POST", url, upstream, headers=body_headers, **body_kwargs)
    if resp.is_success:
        print(f"  POST {endpoint:24s}")
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


def run_step(client: httpx.Client, name: str, step: dict, ctx: dict) -> bool:
    """Execute one step; return True to continue the sequence, False to
    stop. Honors success_when / extract / on_success / on_failure /
    retry_budget_seconds. Raises ConfigureError if the step fails and
    on_failure is the default (raise)."""
    step_name = step.get("name") or step["request"].get("url", "?")
    budget_s = step.get("retry_budget_seconds", 0)
    deadline = time.monotonic() + budget_s if budget_s > 0 else None
    poll_s = 10
    last_summary = ""
    while True:
        req = substitute(step["request"], ctx)
        method, url, kwargs = step_request_kwargs(req)
        try:
            resp = client.request(method, url, **kwargs)
        except httpx.TransportError as e:
            last_summary = f"transport error: {e}"
            if deadline is None or time.monotonic() >= deadline:
                break
            time.sleep(poll_s)
            continue
        body_ok = step_response_ok(resp, step.get("success_when"))
        extract_ok = body_ok and step_extract(resp, step.get("extract"), ctx)
        if body_ok and extract_ok:
            print(f"  [{step_name}] ok (HTTP {resp.status_code})")
            return step.get("on_success", "continue") != "stop"
        last_summary = (
            f"HTTP {resp.status_code} body={resp.text[:200]!r} "
            f"(body_ok={body_ok}, extract_ok={extract_ok})"
        )
        if deadline is None or time.monotonic() >= deadline:
            break
        time.sleep(poll_s)
    # Failure path.
    if step.get("on_failure") == "continue":
        print(f"  [{step_name}] failed (continuing): {last_summary}",
              file=sys.stderr)
        return True
    raise ConfigureError(f"[{step_name}] {last_summary}")


def apply_steps(
    client: httpx.Client, name: str, upstream: dict, steps: list
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
        print(f"[api-configure] {name} step {i}/{len(steps)}: "
              f"{step.get('name') or step['request'].get('url', '?')}")
        cont = run_step(client, name, step, ctx)
        if not cont:
            return


# ---------------------------------------------------------------------------


def apply_upstream(
    client: httpx.Client, name: str, upstream: dict, resources: dict
) -> int:
    """Apply all upserts/posts/steps for one upstream. Returns count of failures."""
    failures = 0
    if resources.get("steps"):
        print(f"[api-configure] {name} steps ({len(resources['steps'])})")
        try:
            apply_steps(client, name, upstream, resources["steps"])
        except (httpx.HTTPError, ConfigureError) as e:
            print(f"  FAILED: {e}", file=sys.stderr)
            failures += 1
    for endpoint, items in (resources.get("upserts") or {}).items():
        if not isinstance(items, list):
            items = [items]
        print(f"[api-configure] {name} /{endpoint} (upsert, {len(items)} item(s))")
        for r in items:
            try:
                upsert_resource(client, name, upstream, endpoint, r)
            except (httpx.HTTPError, ConfigureError) as e:
                print(f"  FAILED name={r.get('name', '<unnamed>')}: {e}",
                      file=sys.stderr)
                failures += 1
    for endpoint, body in (resources.get("posts") or {}).items():
        print(f"[api-configure] {name} /{endpoint} (POST)")
        try:
            post_resource(client, name, upstream, endpoint, body)
        except (httpx.HTTPError, ConfigureError) as e:
            print(f"  FAILED: {e}", file=sys.stderr)
            failures += 1
    return failures


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    upstreams = yaml.safe_load(Path(argv[1]).read_text()) or {}
    resources = yaml.safe_load(Path(argv[2]).read_text()) or {}
    failures = 0
    skipped = 0
    with httpx.Client(timeout=30.0) as client:
        for name in sorted(resources):
            if name not in upstreams:
                print(f"[api-configure] {name}: no matching upstream entry, skipping",
                      file=sys.stderr)
                skipped += 1
                continue
            upstream = upstreams[name]
            if not healthcheck(client, name, upstream):
                skipped += 1
                continue
            failures += apply_upstream(client, name, upstream, resources[name])
    if skipped:
        print(f"[api-configure] {skipped} upstream(s) skipped (healthcheck/missing)",
              file=sys.stderr)
    if failures:
        print(f"[api-configure] {failures} failure(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
