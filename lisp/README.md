# mediaserver (Lisp)

Lisp implementation of the config renderer — the only renderer.
Drives all real services. Built as `bin/render`; sources under `src/`.

See `../plans/lisp-render.md` for the original scope and design decisions
that shaped the port from the (now removed) Ruby renderer.

## Loading

The system depends on `cl-yaml` (Quicklisp) and `elp` (vendored at
`../elp/`). To load it from a fresh SBCL:

```lisp
(push #p"/path/to/home-media-server/elp/"  asdf:*central-registry*)
(push #p"/path/to/home-media-server/lisp/" asdf:*central-registry*)
(ql:quickload :mediaserver)
```

`cl-yaml` requires `libyaml` at the system level (Arch:
`pacman -S libyaml`).

## Layout

- `src/package.lisp` — package definition
- `src/config.lisp` — YAML loader, plist conversion, expand-vars,
  validation (TODO)
- `test/` — FiveAM test suite
- `mediaserver.asd` — ASDF system definition
