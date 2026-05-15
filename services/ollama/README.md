# Ollama

Local LLM server — runs open-weight models (Llama, Qwen, etc.) on the
host and exposes them over a simple HTTP API, so other services
(Open WebUI, aider, scripts) can talk to a local model instead of a
hosted API.

Speaks the standard Ollama HTTP API on port `11434`. Reachable from
the tailnet at `http://<hostname>:11434/` — no caddy route, no auth
(tailnet gating is the auth boundary for v1).

## More

- Upstream: <https://github.com/ollama/ollama>
- Docs: <https://github.com/ollama/ollama/tree/main/docs>

## What's mounted

| Container path | Host path | Mode | Purpose |
|---|---|---|---|
| `/root/.ollama` | `<install_base>/config/ollama/models` | rw | Model storage + ollama state |

## Usage from a shell client

From any tailnet machine with the `ollama` CLI installed:

```sh
ollama --host <hostname>:11434 pull llama3.2:1b
ollama --host <hostname>:11434 run llama3.2:1b
```

Or raw HTTP:

```sh
curl http://<hostname>:11434/api/tags
curl -X POST http://<hostname>:11434/api/pull -d '{"name":"llama3.2:1b"}'
```

## GPU passthrough (optional)

Off by default — runs CPU-only. To enable NVIDIA passthrough, add to
your `config.local.yml`:

```yaml
service_overrides:
  ollama:
    docker_config:
      deploy:
        resources:
          reservations:
            devices:
              - driver: nvidia
                count: all
                capabilities: [gpu]
      environment:
        - NVIDIA_VISIBLE_DEVICES=all
```

Requires `nvidia-container-toolkit` on the host. Same pattern Jellyfin
uses for HW transcode.

VRAM sizing: a Q4 1B model is ~0.7 GB on-card; a Q4 3B is ~2 GB. On a
3 GB card shared with Jellyfin transcoding you'll OOM if both load at
once — ollama falls back to CPU in that case rather than failing.

## Choosing a model

The model isn't baked into the service config; ollama pulls on demand.
Conventional pick for "play with it" on a small GPU:

- `llama3.2:1b` — ~0.7 GB, fast, weak at reasoning
- `qwen2.5:3b` — ~2 GB, noticeably better, still tight on a 3 GB card
- `qwen2.5-coder:7b` — ~4.5 GB, won't fit on a 3 GB card; CPU only

## Tuning idle behavior

`OLLAMA_KEEP_ALIVE` (set in `service.yml.elp`, override via
`service_overrides.ollama.docker_config.environment`) controls how long
a model stays loaded after the last request:

- `0` — unload immediately after each response
- `5m` (default) — unload after 5 min idle
- `-1` — pin in RAM/VRAM forever

The ollama server process itself stays running regardless; only the
*model weights* get unloaded. Idle cost when no model is loaded is
~tens of MB of RAM.
