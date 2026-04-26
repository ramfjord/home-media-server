# mediaserver (Lisp)

Lisp implementation of the config renderer. Currently scoped to the
fixture tree under `test/fixtures/`; the Ruby renderer
(`render.rb` + `lib/mediaserver/`) still drives all real services.

See `../plans/lisp-render.md` for scope and design decisions.

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
