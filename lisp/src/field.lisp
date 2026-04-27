(in-package :mediaserver)

;;; The single public accessor for service plists.
;;;
;;; Templates write (field s :name) / (field s :use-vpn) / etc.
;;; There is no service class. Missing keys return NIL so template
;;; conditionals stay clean.
;;;
;;; Computed values (e.g. :compose-file derived from install-base
;;; and name) live in *derived-fields*. The accessor falls through
;;; to that alist after a literal lookup miss, so callers can't
;;; tell direct fields from derived ones.

(defparameter *globals* nil
  "Plist of host-level config (install-base, media-path, hostname,
   plus anything else from globals.yml + config.local.yml). Set by
   LOAD-CONFIG. Templates that need globals reach in via
   (getf *globals* :install-base) or pass them explicitly.")

(defparameter *derived-fields*
  `((:compose-file
     . ,(lambda (s g)
          (format nil "~A/config/~A/docker-compose.yml"
                  (getf g :install-base) (getf s :name))))
    (:source-dir
     . ,(lambda (s g)
          (declare (ignore g))
          (format nil "services/~A" (getf s :name))))
    (:dockerized
     . ,(lambda (s g)
          (declare (ignore g))
          (and (getf s :docker-config) t)))
    (:has-unit
     . ,(lambda (s g)
          (declare (ignore g))
          (and (getf s :unit) t)))
    (:groups
     . ,(lambda (s g)
          (declare (ignore g))
          ;; Always-known: templates ask for :groups even on services
          ;; that don't set it. Return literal value if present, else
          ;; NIL — this keeps the typo guard meaningful for fixtures
          ;; that intentionally omit :groups (per BRANCHES.md, no
          ;; fixture sets groups: to avoid getent non-determinism).
          (getf s :groups)))
    (:user-id
     . ,(lambda (s g)
          (declare (ignore g))
          ;; Mirrors Ruby's user_id: hardcoded skip for wireguard (which
          ;; runs as root for the network namespace), else shell out to
          ;; `id -u <name>`. Empty string for unknown users — assigned
          ;; verbatim into compose under user:, where YAML emits as ''.
          (let ((name (getf s :name)))
            (if (string= name "wireguard")
                nil
                (string-trim
                 '(#\Space #\Tab #\Newline)
                 (uiop:run-program (list "id" "-u" name)
                                   :output :string
                                   :ignore-error-status t)))))))
  "Alist of (KEY . FN) entries for computed service fields.
   FN takes (service-plist globals-plist), returns the value.")

(defparameter *known-fields* nil
  "Set by VALIDATE-SERVICES at load time: union of every keyword key
   appearing in any loaded service plist + the keys of
   *DERIVED-FIELDS*. Used by FIELD to detect typos at access time.
   When NIL (e.g. before load), no typo checking happens.")

(defun field (service key &optional (globals *globals*))
  "Look up KEY on SERVICE plist. Falls through to *DERIVED-FIELDS*
   when KEY is absent. Errors when *KNOWN-FIELDS* is set and KEY
   isn't a recognized field name (typo guard)."
  (when (and *known-fields* (not (member key *known-fields*)))
    (error "Unknown field ~S. Known: ~{~S~^ ~}" key *known-fields*))
  (let ((direct (getf service key 'no)))
    (if (eq direct 'no)
        (let ((derived (cdr (assoc key *derived-fields*))))
          (and derived (funcall derived service globals)))
        direct)))

;;; Note: target-specific helpers (file enumeration, deploy-path
;;; computation, etc.) belong with the templates that need them, not
;;; in this engine library. Make is the dispatcher and knows which
;;; files exist for each service; the systemd `service.path`
;;; template receives that list via context (e.g. SERVICE_FILES)
;;; rather than walking the filesystem itself. Other targets
;;; (NixOS, k8s, ...) won't share these conventions.
