(in-package :mediaserver)

;;; The single public accessor for service plists.
;;;
;;; Templates write (field :name svc) / (field :use_vpn svc) / etc.
;;; (or `name` / `use_vpn` when in a with-service-scope or loopservices
;;; body). There is no service class. Missing keys return NIL so
;;; template conditionals stay clean.
;;;
;;; All fields are direct plist keys at this layer. Computed fields
;;; (compose_file, dockerized, source_dir, etc.) are pre-resolved into
;;; the plist by the manifest builder (see derive.lisp); the renderer
;;; just looks them up.

(defparameter *globals* nil
  "Plist of host-level config (install_base, media_path, hostname,
   plus anything else from globals.yml + config.local.yml). Set by
   LOAD-CONFIG. Templates that need globals reach in via
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
