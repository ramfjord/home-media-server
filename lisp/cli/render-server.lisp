(defpackage :mediaserver/render-server
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/render-server)

;;; Long-lived render daemon.
;;;
;;; The ELP-side machinery (HTTP listener, request lifecycle, error →
;;; 500 translation) lives in elp/server. This file supplies the
;;; project-specific render handler and main entry point — the make
;;; target dispatching to this daemon is `render-server` in the root
;;; Makefile.

(defparameter *port* 7890)
(defparameter *pidfile* "lisp/.render-server.pid")

(defstruct config-cache-entry mtime globals known-fields plist)

(defvar *configs* (make-hash-table :test 'equal)
  "Manifest-path → config-cache-entry. Lets one daemon serve multiple
   trees (root, test/) without re-parsing on every request. Each entry
   captures the manifest's mtime + the side-effect state that
   MEDIASERVER:LOAD-CONFIG sets on *globals* / *known-fields*, so
   switching between trees restores the right state.")

(defun ensure-config (manifest-path)
  "Return the cached config for MANIFEST-PATH, reloading on mtime
   change. Re-primes MEDIASERVER:*GLOBALS* and *KNOWN-FIELDS* from
   the cache entry on every call — they're side-effect-set by
   LOAD-CONFIG and the render macros read them at expand time."
  (let* ((mtime (file-write-date manifest-path))
         (entry (gethash manifest-path *configs*)))
    (when (or (null entry) (> mtime (config-cache-entry-mtime entry)))
      (let ((plist (mediaserver:load-config manifest-path)))
        (setf entry (make-config-cache-entry
                     :mtime mtime
                     :globals mediaserver:*globals*
                     :known-fields mediaserver:*known-fields*
                     :plist plist)
              (gethash manifest-path *configs*) entry)))
    (setf mediaserver:*globals*      (config-cache-entry-globals entry)
          mediaserver:*known-fields* (config-cache-entry-known-fields entry))
    (config-cache-entry-plist entry)))

(defun render-from-params (params)
  "Render the template at SRC against the optional SERVICE, writing
   output to DST. Opens DST directly so the mmap-source write(2) fast
   path in elp can fire — rendered content never goes through the
   socket."
  (let* ((src (cdr (assoc "src" params :test #'string=)))
         (dst (cdr (assoc "dst" params :test #'string=)))
         (svc-name (cdr (assoc "service" params :test #'string=)))
         (manifest (or (cdr (assoc "manifest" params :test #'string=))
                       "services/manifest.yaml"))
         (cfg (ensure-config manifest))
         (svc (when (and svc-name (plusp (length svc-name)))
                (or (find svc-name (getf cfg :services)
                          :key (lambda (s) (getf s :name)) :test #'equal)
                    (error "service not found: ~A" svc-name)))))
    (unless (and src dst)
      (error "src and dst are required"))
    (with-open-file (out dst :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
      (let ((*standard-output* out)
            (*package* (find-package :mediaserver)))
        (apply #'elp:render (elp:filepath-source (probe-file src)) out
               (mediaserver::service-render-context svc cfg))))))

(defun write-pidfile ()
  (with-open-file (s *pidfile* :direction :output :if-exists :supersede)
    (format s "~D~%" (sb-posix:getpid))))

(defun main (&optional args)
  (declare (ignore args))
  (write-pidfile)
  ;; Manifest is loaded lazily on first /render — when this main runs
  ;; (under `make render-server`), the manifest may not exist yet
  ;; because `make clean` removes it. The first /render request's
  ;; make prereq chain guarantees the manifest by the time curl fires.
  (elp.server:start-render-server :port *port* :handler #'render-from-params)
  (loop (sleep 3600)))
