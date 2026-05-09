(in-package :mediaserver)

;;; Deep-merge for plists.
;;;
;;; Mirrors Ruby's Mediaserver.deep_merge!:
;;;   plist + plist -> recurse on common keys, append new keys
;;;   list  + list  -> union (in order, deduped)
;;;   else          -> override wins
;;; Used to apply config.local.yml service_overrides onto loaded
;;; service plists.

(defun deep-merge (base overrides)
  "Return a new plist that is BASE deep-merged with OVERRIDES."
  (cond
    ;; Both plists -> recurse on common keys, append unmatched keys.
    ((and (plistp base) (plistp overrides))
     (let ((result (copy-list base)))
       (loop for (k v) on overrides by #'cddr do
         (setf (getf result k)
               (deep-merge (getf result k) v)))
       result))
    ;; Both lists (and not plists) -> union, preserving order.
    ((and (listp base) (listp overrides))
     (append base (remove-if (lambda (x) (member x base :test #'equal))
                             overrides)))
    ;; Otherwise overrides wins.
    (t overrides)))

;;; service.yml is parsed as pure YAML — no ELP preprocessing.
;;;
;;; Any <%= ... %> tags inside service.yml string values flow through to
;;; the merged manifest verbatim. They get resolved later by the manifest
;;; render pass (see manifest-render.lisp), which has globals + the full
;;; service set in scope and can therefore handle cross-service refs that
;;; a per-file pre-pass cannot.

;;; Validation
;;;
;;; Two checks at load time:
;;;   1. Every service has a :name.
;;;   2. No two services share a :port.
;;;
;;; *known-fields* (the typo guard) is set by LOAD-CONFIG, not here.

(defun collect-known-fields (services)
  "Return the union of every keyword key found in SERVICES."
  (let (known)
    (dolist (s services)
      (loop for k in s by #'cddr do (pushnew k known)))
    known))

(defun validate-services (services)
  "Run load-time invariants on SERVICES; signal error on any violation."
  (dolist (s services)
    (unless (getf s :name)
      (error "service missing :name: ~S" s)))
  ;; No host-port collision check: caddy is the only host-facing
  ;; service (publishes 80/443) and the docker-compose template no
  ;; longer auto-publishes :port. :port is now strictly the in-
  ;; container port for caddy upstream lookup. Multiple services
  ;; can share a :port value without conflict (e.g. several services
  ;; whose container listens on 8080).
  services)

;;; Top-level load entry point.

(defparameter *default-globals*
  '(:install_base "/opt/mediaserver"
    :media_path   "/data"
    :hostname     "localhost")
  "Fallback values for globals not set in any config file.")

(defun load-config-from-args (service-paths override-paths)
  "Build a config plist from explicit paths. SERVICE-PATHS is a list
   of service.yml files; OVERRIDE-PATHS is a list of override yamls
   in last-wins order (typically just config.local.yml).

   Each service.yml is ELP-preprocessed with the merged globals as
   bindings, then YAML-parsed. Per-service overrides from any
   :service_overrides key in any override file are deep-merged in
   override-list order."
  (let* (;; Layered globals: defaults < every override (last-wins).
         (elp-globals
          (reduce (lambda (acc path)
                    (let ((y (read-yaml-file path)))
                      (deep-merge acc
                                  (loop for (k v) on y by #'cddr
                                        unless (eq k :service_overrides)
                                        collect k and collect v))))
                  override-paths
                  :initial-value *default-globals*))
         ;; Per-service overrides: union across all override files,
         ;; later files winning on conflict.
         (overrides
          (reduce (lambda (acc path)
                    (deep-merge acc (getf (read-yaml-file path)
                                          :service_overrides)))
                  override-paths
                  :initial-value nil))
         ;; Parse each service.yml as pure YAML. <%= ... %> tags inside
         ;; string values are preserved as text and resolved by the later
         ;; manifest render pass.
         (services
          (remove nil
                  (mapcar (lambda (path)
                            (let ((parsed (cl-yaml:parse (probe-file path))))
                              (and parsed (yaml->plist parsed))))
                          service-paths)))
         ;; Stable sort by :order; missing -> end.
         (services
          (stable-sort services
                       (lambda (a b)
                         (< (or (getf a :order) most-positive-fixnum)
                            (or (getf b :order) most-positive-fixnum)))))
         ;; Apply per-service overrides.
         (services
          (mapcar (lambda (s)
                    (let ((ovr (and overrides
                                    (getf overrides
                                          (alexandria:make-keyword
                                           (string-upcase (getf s :name)))))))
                      (if ovr (deep-merge s ovr) s)))
                  services))
         ;; Compute derived fields into each service plist.
         (services
          (mapcar (lambda (s) (derive-fields s elp-globals)) services)))
    (validate-services services)
    (list :services services :globals elp-globals)))

(defun load-config (&optional (manifest "services/manifest.yaml"))
  "Read the manifest yaml at MANIFEST, set *GLOBALS* and *KNOWN-FIELDS*
   as side effects, return the config plist (:services :globals).

   The manifest is produced by bin/build-service-config — see
   build-cli.lisp."
  (let ((p (probe-file manifest)))
    (unless p
      (error "manifest not found: ~A (run `make ~A`?)" manifest manifest))
    (let* ((parsed (cl-yaml:parse p))
           (cfg    (yaml->plist parsed)))
      (setf *globals*      (getf cfg :globals)
            *known-fields* (collect-known-fields (getf cfg :services)))
      cfg)))
