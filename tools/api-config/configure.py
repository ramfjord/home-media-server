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

Each request retries with exponential backoff on transient errors. A failed
healthcheck for an upstream skips its resources with a warning.
"""
from __future__ import annotations

import json
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


def apply_upstream(
    client: httpx.Client, name: str, upstream: dict, resources: dict
) -> int:
    """Apply all upserts/posts for one upstream. Returns count of failures."""
    failures = 0
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
