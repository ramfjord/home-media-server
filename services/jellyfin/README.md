# Jellyfin

The media server itself — indexes the movie and TV libraries on disk,
exposes a web UI and apps for browsing them, and streams (or
transcodes) the files to client devices. The "actually watch a movie"
end of the stack; everything else exists to feed it.

Optional NVIDIA GPU passthrough is available via `service_overrides`
for hardware-accelerated transcoding.

## More

- Upstream: <https://github.com/jellyfin/jellyfin>
- Docs: <https://jellyfin.org/docs/>
