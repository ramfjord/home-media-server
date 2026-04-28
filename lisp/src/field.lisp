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

(defparameter *derived-fields* nil
  "Alist of (KEY . FN) entries for computed service fields. FN takes
   (service-plist globals-plist) and returns the value. Populated by
   DEFINE-SERVICE-FIELD forms below.")

(defmacro define-service-field (key &body body)
  "Declare KEY as a known service field. Without BODY, the field is a
   passthrough that returns (getf service KEY). With BODY, the body
   computes the value with these lexical bindings:
     SERVICE        the service plist
     GLOBALS        the globals plist
     (svc-field K)  shorthand for (FIELD service K globals); resolves
                    through *derived-fields*, so composites of other
                    declared fields work naturally."
  `(setf *derived-fields*
         (append (remove ,key *derived-fields* :key #'car)
                 (list (cons ,key
                             (lambda (service globals)
                               (declare (ignorable globals))
                               (flet ((svc-field (k) (field service k globals)))
                                 (declare (ignorable (function svc-field)))
                                 ,@(or body `((getf service ,key))))))))))

(define-service-field :unit)
(define-service-field :groups)
(define-service-field :compose-file
  (format nil "~A/config/~A/docker-compose.yml"
          (getf globals :install-base) (svc-field :name)))
(define-service-field :source-dir
  (format nil "services/~A" (svc-field :name)))
(define-service-field :dockerized
  (and (getf service :docker-config) t))
(define-service-field :has-unit
  (and (svc-field :unit) t))
(define-service-field :user-id
  ;; Mirrors Ruby's user_id: hardcoded skip for wireguard (which runs
  ;; as root for the network namespace), else shell out to `id -u
  ;; <name>`. Empty string for unknown users — assigned verbatim into
  ;; compose under user:, where YAML emits as ''.
  (let ((name (svc-field :name)))
    (unless (string= name "wireguard")
      (string-trim '(#\Space #\Tab #\Newline)
                   (uiop:run-program (list "id" "-u" name)
                                     :output :string
                                     :ignore-error-status t)))))
(define-service-field :config-files
  ;; Deployed-config filenames under services/<name>/, relative to
  ;; that dir. Skips service.yml (data) and *.erb (legacy shadows).
  ;; Strips .elp so the listed name matches the deployed file. Used
  ;; by the systemd .path watcher template both as predicate (skip if
  ;; empty) and as the watch list.
  (let ((src (truename (format nil "services/~A/" (svc-field :name)))))
    (loop for p in (directory (merge-pathnames "**/*.*" src))
          for r = (enough-namestring p src)
          ;; CL's DIRECTORY returns both file- and dir-pathnames;
          ;; filter file-pathnames so subdirs don't leak in as bogus
          ;; PathChanged= entries.
          when (uiop:file-pathname-p p)
          unless (or (string= r "service.yml") (uiop:string-suffix-p r ".erb"))
          collect (if (uiop:string-suffix-p r ".elp")
                      (subseq r 0 (- (length r) 4)) r))))

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
