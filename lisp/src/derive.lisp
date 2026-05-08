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
    ;; How a displayable service is reached from outside. Defaults
    ;; route every service through caddy's main FQDN site on 443 at
    ;; /<name>. Override either to reshape:
    ;;   public_port: 8443    (own caddy site on a dedicated host port,
    ;;                         e.g. for apps like qBittorrent that
    ;;                         can't be served under a path prefix)
    ;;   public_path: "/"     (skip the /<name> path component)
    ;; A service that opts into a non-default public_port must also
    ;; have that port published on caddy's container — see
    ;; services/caddy/service.yml `ports:`. Kept manual so the set of
    ;; ports caddy binds is visible at one glance in one file.
    (setf (getf s :public_port) (or (getf s :public_port) 443))
    (setf (getf s :public_path) (or (getf s :public_path)
                                    (format nil "/~A" name)))
    (setf (getf s :public_url)
          (or (getf s :public_url)
              (when (getf s :displayable)
                (let ((host (getf globals :hostname))
                      (port (getf s :public_port))
                      (path (getf s :public_path)))
                  (if (= port 443)
                      (format nil "https://~A~A" host path)
                      (format nil "https://~A:~A~A" host port path))))))
    s))
