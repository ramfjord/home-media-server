(in-package :mediaserver)

;;; Compute derived fields into a service plist at manifest-build time.
;;;
;;; This file is the only place that resolves "this service's
;;; <derived-field> is computed from <these inputs>". Render-time
;;; field access is plain getf — by the time the manifest reaches the
;;; renderer, every accessible field is a literal value in the plist.
;;;
;;; Adding a derived field = adding a SETF line. Order entries by
;;; data dependency (later ones can reference earlier ones via getf).

(defun config-files-for (name)
  "Files under services/<NAME>/ that get deployed verbatim. Skips
   service.yml.elp (input data, not a deploy artifact). Strips .elp
   so the listed name matches the deployed file."
  (let ((src (truename (format nil "services/~A/" name))))
    (loop for p in (directory (merge-pathnames "**/*.*" src))
          for r = (enough-namestring p src)
          when (uiop:file-pathname-p p)
          unless (string= r "service.yml.elp")
          collect (if (str:ends-with? ".elp" r)
                      (subseq r 0 (- (length r) 4)) r))))

(defun derive-fields (service globals)
  "Return SERVICE with computed fields filled in. Pure transformation:
   no shelling out, no target-side state. Walks the local filesystem
   under services/<name>/ for :config_files."
  (let* ((s    (copy-list service))
         (name (getf s :name)))
    (setf (getf s :compose_file)
          (format nil "~A/config/~A/docker-compose.yml"
                  (getf globals :install_base) name))
    (setf (getf s :source_dir)    (format nil "services/~A" name))
    (setf (getf s :dockerized)    (and (getf s :docker_config) t))
    (setf (getf s :has_unit)      (and (getf s :unit) t))
    (setf (getf s :config_files)  (config-files-for name))
    (setf (getf s :group)         (getf s :group))
    ;; A service is "displayable" when it's a user-facing surface —
    ;; appears on the dashboard, gets public-probed. Curator-driven:
    ;; drop a tile asset at services/homer/assets/tools/<name>.png to
    ;; opt in. Plumbing services (mcpo, mcp-grafana) ship no asset
    ;; and are auto-excluded. Still requires a port so there's
    ;; something to link to.
    (setf (getf s :displayable)
          (and (getf s :port)
               (probe-file (format nil "services/homer/assets/tools/~A.png" name))
               t))
    ;; How a service is reached from outside. Two modes:
    ;;
    ;;   proxied: true (default for any docker-networked service)
    ;;     — sits behind the reverse proxy. public_port defaults to
    ;;     443, path-routed under <hostname>/<public_path> on the
    ;;     main TLS site. Set public_port to a non-443 value to get
    ;;     a dedicated site on that host port (for apps like
    ;;     qBittorrent that don't tolerate a path prefix).
    ;;     public_path: "/foo" (default /<name>) — path slot on the
    ;;     main site, only consulted when public_port=443.
    ;;
    ;;   proxied: false (`network_mode: host`) — container reaches
    ;;     the LAN/tailnet directly via its own :port. Used when the
    ;;     container needs to broadcast on the LAN (SSDP/DLNA, mDNS),
    ;;     since host networking has no container IP under docker DNS
    ;;     for the proxy to target. public_url is plain http — no TLS
    ;;     terminator in the path.
    ;;
    ;; A non-default public_port also needs the matching `<p>:<p>`
    ;; entry in services/caddy/service.yml.elp `ports:` so the proxy
    ;; publishes the port on the host. Kept manual so the set of
    ;; bound host ports is visible in one place.
    ;;
    ;; `proxied` — "caddy reverse-proxies this service". Derived, not
    ;; declared: it's exactly the set caddy can route to, which needs
    ;; (a) a docker DNS name to target → dockerized, (b) an upstream
    ;; port → port, (c) not host-networked (host networking has no
    ;; container IP under docker DNS). Caddy itself has no port, so
    ;; this auto-excludes it — no name-check needed anywhere. Jellyfin
    ;; is the lone host-networked service today; it's the only one
    ;; with a port that lands `proxied: false`.
    (setf (getf s :proxied)
          (and (getf s :dockerized)
               (getf s :port)
               (not (equal (getf (getf s :docker_config) :network_mode) "host"))
               t))
    (setf (getf s :public_port) (or (getf s :public_port) 443))
    (setf (getf s :public_path) (or (getf s :public_path)
                                    (format nil "/~A" name)))
    (setf (getf s :public_url)
          (or (getf s :public_url)
              (when (getf s :port)
                (let ((host (getf globals :hostname))
                      (port (getf s :public_port))
                      (path (getf s :public_path)))
                  (cond
                    ;; This branch is the not-proxied-but-has-port
                    ;; case = host-networked (jellyfin). A non-
                    ;; dockerized service with a port would also land
                    ;; here, but none exist; revisit the URL shape if
                    ;; one ever does.
                    ((not (getf s :proxied))
                     (format nil "http://~A:~A/" host (getf s :port)))
                    ((= port 443)
                     (format nil "https://~A~A" host path))
                    (t
                     (format nil "https://~A:~A~A" host port path)))))))
    ;; How another container on the mediaserver-network reaches this
    ;; service's API root. Mirror of public_url for the inside-the-host
    ;; perspective. Only computed for dockerized services with a port.
    ;;
    ;; `internal_path` (default "") declares any --web.route-prefix the
    ;; service binary uses to shift its routes under (prometheus,
    ;; alertmanager, blackbox-exporter all do this). Composing it here
    ;; gives every consumer a single value to interpolate — no more
    ;; hand-coded "http://prometheus:9090/prometheus" sprinkled across
    ;; configs that silently 404 when missed.
    ;;
    ;; VPN services share wireguard's netns, so they're not addressable
    ;; under their own container name on the mediaserver-network — the
    ;; URL routes through wireguard:<port> instead.
    (setf (getf s :internal_path) (or (getf s :internal_path) ""))
    (setf (getf s :internal_url)
          (or (getf s :internal_url)
              (when (and (getf s :dockerized) (getf s :port))
                (format nil "http://~A:~A~A"
                        (if (getf s :use_vpn) "wireguard" name)
                        (getf s :port)
                        (getf s :internal_path)))))
    ;; Route-prefixed services (internal_path set) canonicalize
    ;; <prefix> -> <prefix>/ with a 301, so both the Homer click and the
    ;; blackbox probe eat a needless redirect. Slash public_url to skip
    ;; that hop. (Any app-level root->landing redirect still happens and
    ;; is still followed; probe_success verified unaffected for every
    ;; internal_path service.) Plain append: no public_url carries a
    ;; query string today — switch to quri path-component editing if one
    ;; ever does. public_path is left unslashed: caddy routes on it.
    (let ((u (getf s :public_url))
          (ip (getf s :internal_path)))
      (when (and u (not (string= ip "")) (not (str:ends-with? "/" u)))
        (setf (getf s :public_url) (concatenate 'string u "/"))))
    ;; Whether/how this service sits behind the auth gateway. Declared
    ;; per service; which gateway enforces it lives entirely in that
    ;; gateway's own config template, never here — this stays
    ;; implementation-agnostic so lisp/ could template a different
    ;; stack. Surface forms:
    ;;
    ;;   (absent)            not gated; reached directly as today.
    ;;   gateway_auth: true  gated, default policy (any one-factor
    ;;                       authenticated user).
    ;;   gateway_auth:       gated with overrides. Recognized keys:
    ;;     policy: two_factor  policy       — "one_factor" (default)
    ;;     public_paths:                      or "two_factor".
    ;;     - "/api"          public_paths — path prefixes that bypass
    ;;                       the gate, e.g. an app's machine-consumed
    ;;                       API while its UI stays gated.
    ;;
    ;; Normalized to a canonical plist so consumers (the gateway's
    ;; route + access-control templates) read uniform fields instead
    ;; of re-parsing the surface form. Two consumers are designed in
    ;; from the start, so this is a derive default rather than
    ;; per-template getf (see CONTRIBUTING "single-consumer optional
    ;; fields"). `gateway_protected` mirrors `proxied`: a derived
    ;; boolean for cheap (service-where gateway_protected) filtering.
    (let* ((raw  (getf s :gateway_auth))
           (spec (when (listp raw) raw)))
      (setf (getf s :gateway_auth)
            (when raw
              (list :policy        (or (getf spec :policy) "one_factor")
                    :public_paths  (getf spec :public_paths))))
      (setf (getf s :gateway_protected) (and (getf s :gateway_auth) t)))
    s))
