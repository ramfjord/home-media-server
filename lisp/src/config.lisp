(in-package :mediaserver)

;;; YAML -> plist conversion at the load boundary.
;;;
;;; cl-yaml returns hash-tables (EQUALP, string keys), nested maps as
;;; more hash-tables, sequences as conses, atoms as native Lisp types
;;; (booleans -> T/NIL, integers, strings).
;;;
;;; We flatten to plists with keyword keys; YAML keys carry through
;;; verbatim (so "use_vpn" -> :USE_VPN). Underscores match the YAML
;;; convention; the codebase uses :foo_bar uniformly.

(defun yaml->plist (x)
  "Recursively convert cl-yaml output to keyword-keyed plists.
   Hash-tables become plists; conses are mapcar'd; atoms pass through."
  (etypecase x
    (hash-table (loop for k being the hash-keys of x using (hash-value v)
                      collect (alexandria:make-keyword (string-upcase k))
                      collect (yaml->plist v)))
    (cons       (mapcar #'yaml->plist x))
    (t          x)))

;;; Deep-merge for plists.
;;;
;;; Mirrors Ruby's Mediaserver.deep_merge!:
;;;   plist + plist -> recurse on common keys, append new keys
;;;   list  + list  -> union (in order, deduped)
;;;   else          -> override wins
;;; Used to apply config.local.yml service_overrides onto loaded
;;; service plists.

(defun plistp (x)
  "True for proper plists with keyword keys (cheap structural check)."
  (and (consp x)
       (evenp (length x))
       (loop for k in x by #'cddr always (keywordp k))))

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

;;; ELP preprocessing of service.yml.
;;;
;;; Each service.yml is rendered through ELP before YAML parsing:
;;; templates write <%= install_base %> instead of literal paths.
;;; The context-alist binds the same names the YAML files use
;;; (underscored: install_base, media_path, hostname).

(defun globals->elp-context (globals-plist)
  "Build the ELP context-alist from GLOBALS-PLIST: each keyword key
   becomes a same-named symbol in :mediaserver."
  (loop for (k v) on globals-plist by #'cddr
        collect (cons (alexandria:ensure-symbol k :mediaserver) v)))

(defun render-service-yaml (path globals)
  "ELP-render the file at PATH with GLOBALS bound, return the rendered
   YAML string."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (elp:render (pathname path) (globals->elp-context globals) s))))

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
  ;; Host-port conflict check: only services that auto-publish their
  ;; :port to the host can collide. Services with :public_url are
  ;; reached through a proxy and don't bind a host port (see
  ;; emit-compose), so exclude them.
  (let ((ports (remove nil
                       (mapcar (lambda (s)
                                 (and (not (getf s :public_url))
                                      (getf s :port)))
                               services))))
    (dolist (p (remove-duplicates ports))
      (when (> (count p ports) 1)
        (error "duplicate port across services: ~A" p))))
  services)

;;; Top-level load entry point.

(defparameter *default-globals*
  '(:install_base "/opt/mediaserver"
    :media_path   "/data"
    :hostname     "localhost")
  "Fallback values for globals not set in any config file.
   Mirrors Ruby's Mediaserver::DEFAULT_GLOBALS.")

(defun read-yaml-file (path)
  "Read PATH as plain YAML, returning a plist (or NIL for missing file
   or empty contents)."
  (let ((p (probe-file path)))
    (when p
      (let ((parsed (cl-yaml:parse p)))
        (and parsed (yaml->plist parsed))))))

(defun plist->cl-yaml (x)
  "Convert plists/lists/atoms to the hash-table+cons shape cl-yaml's
   emitter expects. Plists become hash-tables (string keys), lists
   recurse, atoms pass through."
  (cond
    ((plistp x)
     (let ((h (make-hash-table :test 'equal)))
       (loop for (k v) on x by #'cddr
             do (setf (gethash (str:downcase (symbol-name k)) h)
                      (plist->cl-yaml v)))
       h))
    ((listp x) (mapcar #'plist->cl-yaml x))
    (t x)))

(defun emit-manifest (cfg stream)
  "Emit CFG (a plist with :globals and :services) as block-style YAML
   to STREAM. The output round-trips back to an equivalent CFG via
   cl-yaml:parse + yaml->plist."
  (yaml:with-emitter-to-stream (em stream)
    (yaml:emit-pretty-as-document em (plist->cl-yaml cfg))))

(defun load-config-from-args (service-paths override-paths)
  "Build a config plist from explicit paths. SERVICE-PATHS is a list
   of service.yml files; OVERRIDE-PATHS is a list of override yamls
   in last-wins order (config.yaml then config.local.yaml).

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
         ;; Render + parse each service.yml.
         (services
          (remove nil
                  (mapcar (lambda (path)
                            (let ((parsed (cl-yaml:parse
                                           (render-service-yaml path elp-globals))))
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
