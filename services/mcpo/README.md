# mcpo

MCP-to-OpenAPI proxy from the Open WebUI org. Open WebUI's tool-server
feature consumes OpenAPI; most MCP servers (including
[`mcp-grafana`](../mcp-grafana/)) speak only MCP. mcpo bridges that
gap: it connects to an upstream MCP server (here, `mcp-grafana` over
SSE) and republishes its tools as an OpenAPI spec at `/openapi.json`.

Listens on container port `8000`. Fronted by Caddy on host port
`8003` (dedicated-port site, same pattern as Open WebUI on 8002 and
qBittorrent on 8443 — mcpo's OpenAPI surface is at `/` and doesn't
take a URL prefix). Reachable from the tailnet at
`https://<hostname>:8003`; that's the URL Open WebUI's tool-servers
config wants (OWUI validates the URL from the browser, not its
container, so the internal `mcpo:8000` won't work there).

## More

- Upstream: <https://github.com/open-webui/mcpo>

## Wiring it into Open WebUI

One-time, after first deploy:

1. Open WebUI → top-right user menu → **Admin Panel**.
2. **Settings** → **Tools** → **+** (add tool server).
3. URL: `https://<hostname>:8003` (the tailnet FQDN; same one in the
   browser address bar). Leave auth blank.
4. Save. The grafana tools should appear in the tool picker on the
   chat input row.

If you later add a second MCP server, switch mcpo from CLI args to a
`config.json` listing multiple `mcpServers` entries and mount it in.
