# Dev environment

How to start a Lisp image with `:mediaserver` loaded, the manifest read, and (when available) `swank-lsp` listening so editors with LSP support can attach.

## The launcher

Single entry point:

```sh
script/start-image.sh
```

Drops you in an SBCL REPL with `:mediaserver` loaded, `*known-fields*` populated from `services/manifest.yaml`, and — if `swank-lsp` is installed — an LSP server listening on a published port (`.swank-lsp-port` at the project root).

Two env vars control optional behavior:

| Var | Default | Purpose |
|---|---|---|
| `LISP_LAUNCHER` | `qlot exec sbcl` | How SBCL is invoked. Override for container or nix-shell users. |
| `SWANK_PORT` | unset | When set, also start a regular swank server on that port for vlime / `M-x slime-connect`. Leave unset if SLIME is spawning the image (it'll start its own). |
| `SWANK_LSP_DIR` | `~/projects/swank-lsp/` | Where to find swank-lsp. Override if installed elsewhere. |

### Container users

```sh
LISP_LAUNCHER='script/dev sbcl' script/start-image.sh
```

Routes the launch through the dev container (`script/dev` already wraps `docker compose run --rm dev`). The image loads inside the container; `.swank-lsp-port` lands on the host via the volume mount.

### Nix users

Same idea — set `LISP_LAUNCHER` to whatever wrapper invokes SBCL with the right deps available.

## Editors

### Emacs (SLIME)

The repo's `.dir-locals.el` configures `slime-lisp-implementations` to invoke `script/start-image.sh`. So:

1. Open any file in this project.
2. First time: Emacs prompts to trust `.dir-locals.el` — choose `!` to remember.
3. `M-x slime` (or `C-c M-j` to pick the impl): SLIME spawns the launcher, you land in a REPL with `:mediaserver` loaded.

If `LISP_LAUNCHER` needs to differ (container, nix, …), set it in your shell *before* launching Emacs — `.dir-locals.el` doesn't override env, so per-user customization stays out of the checked-in file.

### Vim (vlime)

No equivalent of `.dir-locals.el` for vim. Two approaches:

**Hotkey to launch in a terminal split:**

```vim
" In your vimrc or .nvim.lua per-project override
nnoremap <leader>rs :term ./script/start-image.sh<CR>
```

Then `:VlimeConnect 127.0.0.1 4005` (after setting `SWANK_PORT=4005`) attaches vlime.

**Use the swank-image skill (Claude / parallel-agent flow):**

For multi-tool, multi-agent work, the [swank-image skill](https://github.com/...) handles tmux session management, port allocation, and `.mcp.json` for Claude. That flow doesn't go through `start-image.sh` — they're independent paths. See `CLAUDE.md` for the bootstrap convention.

### nvim with swank-lsp (LSP integration)

If you have [swank-lsp](https://github.com/...) installed, `start-image.sh` publishes `.swank-lsp-port` on launch. Configure your nvim swank-lsp client to discover that file at the project root (in addition to its default `~/projects/swank-lsp/.swank-lsp-port` location). On a project-local discovery hit, the LSP attaches to the running image — your `(defmacro …)` and `(defun …)` definitions are visible to `gd`/`K`/completion immediately.

## What the image does at startup

`script/dev-image.lisp` is the init form `start-image.sh` loads:

1. Loads qlot's setup (so pinned deps resolve).
2. Pushes `lisp/` onto `asdf:*central-registry*`.
3. `(asdf:load-system :mediaserver)`.
4. `(mediaserver:load-config)` if the manifest exists.
5. Starts swank if `$SWANK_PORT` is set.
6. Loads `:swank-lsp` (probing `$SWANK_LSP_DIR` then `~/projects/swank-lsp/`) and calls `start-and-publish`.
7. Registers an exit hook to remove `.swank-lsp-port` on shutdown.

Adjust as needed — it's plain Lisp.

## Reloading the manifest

`*known-fields*` is a snapshot from manifest-load time. If you add a service or change field names, re-run `(mediaserver:load-config)` in the REPL — `for-service`, `loop-services`, and `service-where` will see the updated set on the next macroexpansion.
