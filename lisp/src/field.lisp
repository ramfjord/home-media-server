(in-package :mediaserver)

;;; The single public accessor for service plists.
;;;
;;; Templates write (field :name svc) / (field :use_vpn svc) / etc.
;;; (or `name` / `use_vpn` when in a for-service or loop-services
;;; body). There is no service class. Missing keys return NIL so
;;; template conditionals stay clean.
;;;
;;; All fields are direct plist keys at this layer. Computed fields
;;; (compose_file, dockerized, source_dir, etc.) are pre-resolved into
;;; the plist by the manifest builder (see derive.lisp); the renderer
;;; just looks them up.

(defparameter *globals* nil
  "Plist of host-level config (install_base, media_path, hostname,
   plus anything else from config.local.yml). Set by LOAD-CONFIG.
   Templates that need globals reach in via
   (getf *globals* :install_base) or pass them explicitly.")

(defparameter *known-fields* nil
  "Set by LOAD-CONFIG: the union of every keyword key appearing in
   any loaded service plist. Used by FIELD to detect typos at access
   time. When NIL (e.g. before load), no typo checking happens.")

(defun field (key &optional (service nil service-supplied) (globals *globals*))
  "Look up KEY on SERVICE plist. Errors when *KNOWN-FIELDS* is set
   and KEY isn't a recognized field name (typo guard).

   With only KEY supplied, returns a curried function (lambda (s)
   ...) for use with mapcar/remove-if-not/etc."
  (when (and *known-fields* (not (member key *known-fields*)))
    (error "Unknown field ~S. Known: ~{~S~^ ~}" key *known-fields*))
  (if (not service-supplied)
      (lambda (s) (field key s globals))
      (getf service key)))

(defun %field-binding-symbol (key)
  "Convert :install_base -> install_base (a symbol in :mediaserver).
   Used by WITH-SERVICE-SCOPE's symbol-macrolet, which exposes each
   field as a bare symbol in template bodies — distinct from the
   keyword keys used at the kwarg-dispatch boundary.

   Defined here (not in render.lisp) so config.lisp can attach
   docstrings to these symbols at load time without a forward
   reference; render.lisp's binder macros expand against the same
   symbols."
  (alexandria:ensure-symbol key :mediaserver))

(defun %field-docstring (key services globals)
  "Plain-text docstring describing how KEY appears across SERVICES
   and GLOBALS. Surfaces in editors via swank's documentation-symbol:
   K-hover on `<%= hostname %>` in a template lands here.

   Examples block lists up to three (service . value) pairs so the
   hover stays compact on projects with many services."
  (let* ((global-val (getf globals key))
         (service-vals (loop for s in services
                             for v = (getf s key)
                             when v collect (cons (getf s :name) v)))
         (sample (subseq service-vals 0 (min 3 (length service-vals)))))
    (with-output-to-string (out)
      (format out "Manifest field ~S." key)
      (when global-val
        (format out "~%~%Global value: ~S" global-val))
      (when sample
        (format out "~%~%Examples (~D service~:P declare this field):"
                (length service-vals))
        (dolist (pair sample)
          (format out "~%  ~A: ~S" (car pair) (cdr pair)))
        (when (> (length service-vals) (length sample))
          (format out "~%  ... (~D more)"
                  (- (length service-vals) (length sample))))))))

(defun populate-field-docstrings (services globals)
  "Attach docstrings to the symbols WITH-SERVICE-SCOPE binds. After
   this runs, swank's documentation-symbol returns useful hover
   content for `hostname` / `port` / `name` / etc. in template bodies
   — driving K in any LSP-aware editor.

   Idempotent: setf documentation overwrites. Called from LOAD-CONFIG
   so a fresh dev image (or a re-load after a manifest edit) gets
   up-to-date hovers without a per-symbol manual step."
  (dolist (key *known-fields*)
    (let ((sym (%field-binding-symbol key)))
      (setf (documentation sym 'variable)
            (%field-docstring key services globals))))
  (loop for (k v) on globals by #'cddr
        unless (member k *known-fields*)
        do (setf (documentation (%field-binding-symbol k) 'variable)
                 (format nil "Manifest global ~S.~%~%Value: ~S" k v))))
