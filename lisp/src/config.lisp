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
                      collect (intern (string-upcase k) :keyword)
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
        collect (cons (intern (symbol-name k) :mediaserver) v)))

(defun render-service-yaml (path globals)
  "ELP-render the file at PATH with GLOBALS bound, return the rendered
   YAML string."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (elp:render path (globals->elp-context globals) s))))

;;; Validation
;;;
;;; Three checks at load time:
;;;   1. Every service has a :name.
;;;   2. No two services share a :port.
;;;   3. Sets *known-fields* so the FIELD accessor errors on typos
;;;      thereafter (union of every key seen in any service plist
;;;      plus the derived-field names).

(defun collect-known-fields (services)
  "Auto-register every keyword key found in SERVICES as a passthrough
   field (if not already declared), then return the resulting field
   list. After this call, every accessible service field has an entry
   in *derived-fields* — the canonical schema."
  (dolist (s services)
    (loop for k in s by #'cddr do
      (let ((field-key k))
        (unless (assoc field-key *derived-fields*)
          (push (cons field-key
                      (lambda (service globals)
                        (declare (ignore globals))
                        (getf service field-key)))
                *derived-fields*)))))
  (mapcar #'car *derived-fields*))

(defun validate-services (services)
  "Run load-time invariants on SERVICES; signal error on any violation.
   Sets *known-fields* on success."
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
  (setf *known-fields* (collect-known-fields services))
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
  (when (probe-file path)
    (let ((parsed (cl-yaml:parse path)))
      (and parsed (yaml->plist parsed)))))

(defun service-files (root)
  "Glob ROOT/services/*/service.yml, sorted lexicographically."
  (sort (directory (merge-pathnames "services/*/service.yml"
                                    (uiop:ensure-directory-pathname root)))
        #'string<
        :key #'namestring))

(defparameter *baked-config* nil
  "Config plist baked into the binary at build time by BAKE-CONFIG.
   Runtime LOAD-CONFIG returns this verbatim — no YAML parsing per call.
   To render a different tree, build a separate binary with that tree
   as the bake-root (see script/build-render.sh).")

(defun bake-config (root)
  "Build-time entry point: load the config at ROOT and freeze it into
   *BAKED-CONFIG*. Called from script/build-render.sh before
   SAVE-LISP-AND-DIE."
  (let ((abs (namestring (truename (uiop:ensure-directory-pathname root)))))
    (setf *baked-config* (load-config-from-disk abs))))

(defun load-config ()
  "Return the baked config plist. Re-establishes *GLOBALS* and
   *KNOWN-FIELDS* as a side effect so FIELD calls resolve derived
   fields like :compose_file."
  (unless *baked-config*
    (error "load-config called but no config was baked into this binary"))
  (setf *globals* (getf *baked-config* :globals)
        *known-fields* (collect-known-fields (getf *baked-config* :services)))
  *baked-config*)

(defun load-config-from-disk (root)
  "Read the config tree at ROOT from disk. Used at build time by
   BAKE-CONFIG; not called at runtime.

   Reads globals.yml + config.local.yml top-level + every
   services/*/service.yml. Service files are ELP-preprocessed with
   the merged globals as bindings, then YAML-parsed. Service overrides
   from config.local.yml are deep-merged afterward."
  (let* ((root         (uiop:ensure-directory-pathname root))
         (globals-yml  (read-yaml-file (merge-pathnames "globals.yml" root)))
         (local-yml    (read-yaml-file (merge-pathnames "config.local.yml" root)))
         (overrides    (getf local-yml :service_overrides))
         (local-no-ovr (loop for (k v) on local-yml by #'cddr
                             unless (eq k :service_overrides)
                             collect k and collect v))
         ;; Layered globals for ELP binding: defaults < globals.yml < local top-level.
         (elp-globals  (deep-merge *default-globals*
                                   (deep-merge globals-yml local-no-ovr)))
         ;; Render + parse each service.yml.
         (services
          (remove nil
                  (mapcar (lambda (path)
                            (let ((parsed (cl-yaml:parse
                                           (render-service-yaml path elp-globals))))
                              (and parsed (yaml->plist parsed))))
                          (service-files root))))
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
                                          (intern (string-upcase (getf s :name))
                                                  :keyword)))))
                      (if ovr (deep-merge s ovr) s)))
                  services)))
    (validate-services services)
    (let ((globals elp-globals))
      (setf *globals* globals)
      (list :services services
            :globals  globals
            :raw      (append local-no-ovr (list :services services))))))
