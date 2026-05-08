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
   service.yml (data). Strips .elp so the listed name matches the
   deployed file."
  (let ((src (truename (format nil "services/~A/" name))))
    (loop for p in (directory (merge-pathnames "**/*.*" src))
          for r = (enough-namestring p src)
          when (uiop:file-pathname-p p)
          unless (string= r "service.yml")
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
    ;; A service is "displayable" when it has a web UI worth surfacing
    ;; on the homer dashboard and fronting via caddy. Excludes homer
    ;; itself (it's the dashboard, not a card on it) and anything in
    ;; the dashboard partof (caddy). Requires a `port` so there's
    ;; something for caddy to reverse-proxy to.
    (setf (getf s :displayable)
          (and (not (string= name "homer"))
               (not (string= (getf s :partof) "dashboard"))
               (getf s :port)
               t))
    ;; How a displayable service is reached from outside. Three modes,
    ;; controlled by two fields:
    ;;
    ;;   via_caddy: true (default)   — fronted by caddy. public_port
    ;;     defaults to 443 (path-routed under <hostname>/<public_path>
    ;;     in caddy's main site). Set public_port to a non-443 value
    ;;     to get a dedicated caddy site on that host port (for apps
    ;;     like qBittorrent that don't tolerate a path prefix).
    ;;   public_path: "/foo" (default /<name>) — the path slot on the
    ;;     main site, only consulted when public_port=443.
    ;;
    ;;   via_caddy: false             — caddy doesn't know about it.
    ;;     Container reaches the LAN/tailnet directly via its own
    ;;     :port. Typically paired with `network_mode: host` in
    ;;     docker_config so things like SSDP/DLNA discovery work
    ;;     (Jellyfin → Roku). public_url is plain http because there's
    ;;     no caddy doing TLS termination.
    ;;
    ;; A non-default public_port also needs the matching `<p>:<p>`
    ;; entry in services/caddy/service.yml `ports:` so caddy publishes
    ;; the port on the host. Kept manual so the set of ports caddy
    ;; binds is visible in one place.
    (setf (getf s :via_caddy)
          (if (member :via_caddy s) (getf s :via_caddy) t))
    (setf (getf s :public_port) (or (getf s :public_port) 443))
    (setf (getf s :public_path) (or (getf s :public_path)
                                    (format nil "/~A" name)))
    (setf (getf s :public_url)
          (or (getf s :public_url)
              (when (getf s :displayable)
                (let ((host (getf globals :hostname))
                      (port (getf s :public_port))
                      (path (getf s :public_path)))
                  (cond
                    ((not (getf s :via_caddy))
                     (format nil "http://~A:~A/" host (getf s :port)))
                    ((= port 443)
                     (format nil "https://~A~A" host path))
                    (t
                     (format nil "https://~A:~A~A" host port path)))))))
    s))
