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
          (and (getf s :unit) t))))
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

;;; File-walking helpers used by the service.path template.
;;; Walk SERVICE's source-dir relative to *default-pathname-defaults*
;;; (render-tree binds this to the source root before invoking
;;; templates). .erb files are skipped — during the Ruby/Lisp
;;; transition they live alongside .elp siblings; only one of the two
;;; deploys, and the .elp is canonical for the Lisp engine.

(defun %has-suffix-p (string suffix)
  (and (>= (length string) (length suffix))
       (string= suffix string :start2 (- (length string) (length suffix)))))

(defun %walk-files (dir)
  "Recursively collect every regular file under DIR (a directory pathname)."
  (append (uiop:directory-files dir)
          (mapcan #'%walk-files (uiop:subdirectories dir))))

(defun service-source-files (service)
  "Return a list of pathnames (relative to SERVICE's source-dir) for
   every regular file there, excluding service.yml and *.erb. The
   walk is rooted at SERVICE's :source-dir, resolved relative to
   *default-pathname-defaults* (typically the repo root, since Make
   invokes the renderer from there).

   Used by the systemd `service.path` template to enumerate which
   deployed config files the .path unit should watch."
  (let* ((dir (uiop:ensure-directory-pathname (field service :source-dir)))
         (abs-dir (probe-file dir)))
    (unless abs-dir (return-from service-source-files nil))
    (let* ((root  (uiop:ensure-directory-pathname abs-dir))
           (kept  (remove-if (lambda (f)
                               (let ((b (file-namestring f)))
                                 (or (string= "service.yml" b)
                                     (%has-suffix-p b ".erb"))))
                             (%walk-files root))))
      (mapcar (lambda (f) (uiop:enough-pathname f root)) kept))))

(defun installed-path (relative-file service install-base)
  "Compute the deployed config path for RELATIVE-FILE under SERVICE.
   Strips any .elp suffix on the way (the deployed name is the
   pre-rendered name)."
  (let* ((s (uiop:native-namestring relative-file))
         (clean (if (%has-suffix-p s ".elp")
                    (subseq s 0 (- (length s) 4))
                    s)))
    (format nil "~A/config/~A/~A" install-base (field service :name) clean)))
