#!/usr/bin/env python3
"""systemd-journal-gatewayd → JSON-array proxy.

Gatewayd returns newline-delimited JSON (one entry per line) with
Content-Type: application/json. Grafana's Infinity datasource expects
a single JSON document and rejects NDJSON with a parse error, so this
sidecar wraps the response in a JSON array.

Forward path/method/query/headers verbatim, transform the body only.
Stdlib only — no pip deps, runs unmodified in python:3.13-alpine.
"""
from __future__ import annotations

import os
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "http://host.docker.internal:19531")
PORT = int(os.environ.get("PORT", "19532"))
HOP_HEADERS = {"host", "connection", "content-length", "transfer-encoding"}


class JournalProxy(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        req = urllib.request.Request(UPSTREAM + self.path, method="GET")
        for k, v in self.headers.items():
            if k.lower() in HOP_HEADERS:
                continue
            req.add_header(k, v)
        if not any(k.lower() == "accept" for k in self.headers):
            req.add_header("Accept", "application/json")

        try:
            resp = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(e.read())
            return
        except OSError as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"upstream error: {e}\n".encode())
            return

        with resp:
            self.send_response(resp.status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"[")
            first = True
            for line in resp:
                line = line.strip()
                if not line:
                    continue
                if not first:
                    self.wfile.write(b",")
                first = False
                self.wfile.write(line)
            self.wfile.write(b"]")

    def log_message(self, format: str, *args) -> None:
        # Funnel access logs to stderr in a single line so journald keeps
        # them under one journal entry per request rather than splitting.
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), JournalProxy)
    sys.stderr.write(f"journal-proxy listening on :{PORT}, upstream={UPSTREAM}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
