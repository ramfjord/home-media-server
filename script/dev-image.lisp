;;;; Dev-image init: load the project, populate the manifest, optionally
;;;; start swank-lsp for editor LSP integration.
;;;;
;;;; Loaded by `script/start-image.sh` (or by SLIME via the project's
;;;; .dir-locals.el — see slime-lisp-implementations there). The script
;;;; controls *where* SBCL runs (host, container, qlot, …); this file
;;;; controls *what* gets loaded into the image once it's running.
;;;;
;;;; Side effects on a fresh image:
;;;;   1. ASDF system :mediaserver is loaded.
;;;;   2. If services/manifest.yaml is present, LOAD-CONFIG runs so
;;;;      *known-fields* is populated. FOR-SERVICE/LOOP-SERVICES
;;;;      can macroexpand against real fields from then on.
;;;;   3. If :swank-lsp is loadable, START-AND-PUBLISH writes
;;;;      .swank-lsp-port at the project root for nvim's swank-lsp
;;;;      to discover.
;;;;
;;;; What this file does NOT do:
;;;;   - Start a regular swank server. SLIME starts its own when it
;;;;     spawns SBCL; vim+vlime users who want one should run
;;;;     `(swank:create-server :port 4005 :dont-close t)` after
;;;;     launch, or set $SWANK_PORT to have this file do it.
;;;;   - Manage tmux sessions / per-directory port allocation. That's
;;;;     the swank-image skill's job, for parallel-agent workflows.

(in-package :cl-user)

;; Project root is two levels up from this file (script/dev-image.lisp).
;; Computed at load time, so the script can be invoked from any cwd.
(defparameter *project-root*
  (truename (make-pathname :defaults *load-pathname*
                           :directory (butlast (pathname-directory *load-pathname*))
                           :name nil :type nil)))

;; Load qlot's setup if present, so the project's pinned deps resolve
;; through .qlot/ rather than the global ~/quicklisp/.
(let ((qlot-setup (merge-pathnames "lisp/.qlot/setup.lisp" *project-root*)))
  (when (probe-file qlot-setup)
    (load qlot-setup)))

;; Make sure ASDF can find :mediaserver.
(pushnew (merge-pathnames "lisp/" *project-root*) asdf:*central-registry*
         :test #'equal)

(format t "~&;; dev-image: loading :mediaserver~%")
(asdf:load-system :mediaserver)

(let ((manifest (merge-pathnames "services/manifest.yaml" *project-root*)))
  (cond
    ((probe-file manifest)
     (let ((*default-pathname-defaults* *project-root*))
       (mediaserver:load-config))
     (format t ";; dev-image: manifest loaded; *known-fields* populated (~D fields)~%"
             (length mediaserver:*known-fields*)))
    (t
     (format t ";; dev-image: services/manifest.yaml missing — run `make all` ~
                  to build it; FOR-SERVICE and LOOP-SERVICES will error until ~
                  then.~%"))))

(let ((swank-port (uiop:getenv "SWANK_PORT")))
  (when swank-port
    (ql:quickload :swank :silent t)
    (funcall (read-from-string "swank:create-server")
             :port (parse-integer swank-port) :dont-close t)
    (format t ";; dev-image: swank listening on ~A~%" swank-port)))

;; swank-lsp lives outside this project (one image, many consumers).
;; Probe $SWANK_LSP_DIR first, then ~/projects/swank-lsp/ — either is
;; added to ASDF's central-registry so :swank-lsp loads. Users without
;; it installed get the rest of the dev image without LSP integration.
(let* ((env-dir (uiop:getenv "SWANK_LSP_DIR"))
       (default-dir (merge-pathnames "projects/swank-lsp/" (user-homedir-pathname)))
       (candidate (cond ((and env-dir (probe-file (merge-pathnames "swank-lsp.asd" env-dir)))
                         (truename env-dir))
                        ((probe-file (merge-pathnames "swank-lsp.asd" default-dir))
                         (truename default-dir)))))
  (cond
    ((null candidate)
     (format t ";; dev-image: swank-lsp not found (set $SWANK_LSP_DIR or install at ~A) — LSP integration disabled~%" default-dir))
    (t
     (pushnew candidate asdf:*central-registry* :test #'equal)
     ;; swank-lsp has its own qlot-pinned deps (cl+ssl etc.); load its
     ;; .qlot/setup.lisp so they resolve from there rather than our
     ;; .qlot/ (which doesn't carry them).
     (let ((swank-lsp-qlot (merge-pathnames ".qlot/setup.lisp" candidate)))
       (when (probe-file swank-lsp-qlot) (load swank-lsp-qlot)))
     (handler-case
         (progn
           (asdf:load-system :swank-lsp)
           (let ((*default-pathname-defaults* *project-root*))
             (funcall (read-from-string "swank-lsp:start-and-publish") :port 0))
           ;; Clean up the published port file on exit so a stale path
           ;; can't point at a dead listener (mirrors swank-lsp's own
           ;; stop-server contract; the README is explicit about this).
           (push (lambda ()
                   (let ((p (merge-pathnames ".swank-lsp-port" *project-root*)))
                     (when (probe-file p) (delete-file p))))
                 sb-ext:*exit-hooks*)
           (format t ";; dev-image: swank-lsp started; .swank-lsp-port written at project root~%"))
       (error (c)
         (format t ";; dev-image: swank-lsp load failed (~A) — LSP integration disabled~%" c))))))

(format t "~&;; dev-image: ready. Project root: ~A~%" *project-root*)
