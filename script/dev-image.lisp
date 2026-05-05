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

(defun overlay-in-package (canvas pkg)
  "Overlay `(in-package :PKG)` on the first all-whitespace line of
   CANVAS that's wide enough to hold it. Mutates and returns CANVAS.
   Used so swank-lsp's PARSE-IN-PACKAGE picks up the project's
   package on extracted .elp content. Doing this in dev-image.lisp
   (not in ELP) keeps the elp library project-agnostic — the project
   knows its own package name."
  (let* ((form (format nil "(in-package :~A)" pkg))
         (form-len (length form))
         (canvas-len (length canvas))
         (line-start 0))
    (loop while (< line-start canvas-len) do
      (let* ((next-newline (or (position #\Newline canvas :start line-start)
                               canvas-len))
             (line-len (- next-newline line-start))
             (all-whitespace
               (loop for i from line-start below next-newline
                     always (char= (schar canvas i) #\Space))))
        (when (and all-whitespace (>= line-len form-len))
          (replace canvas form
                   :start1 line-start :end1 (+ line-start form-len))
          (return-from overlay-in-package canvas))
        (setf line-start (1+ next-newline)))))
  canvas)

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

;; Opportunistic local-override for :elp. mediaserver depends on :elp
;; via qlot (pinned to a published version), but during dev we usually
;; want the working tree at $ELP_DIR (default ~/projects/elp/) so
;; in-progress changes (e.g. embed.lisp / extract-code-text) are
;; visible in the image. Pushing onto *central-registry* first makes
;; ASDF pick our copy over qlot's. Skipped silently if no local copy
;; exists — qlot's version takes over.
(let* ((env-elp (uiop:getenv "ELP_DIR"))
       (default-elp (merge-pathnames "projects/elp/" (user-homedir-pathname)))
       (candidate (cond ((and env-elp (probe-file (merge-pathnames "elp.asd" env-elp)))
                         (truename env-elp))
                        ((probe-file (merge-pathnames "elp.asd" default-elp))
                         (truename default-elp)))))
  (when candidate
    (pushnew candidate asdf:*central-registry* :test #'equal)
    (format t ";; dev-image: using local elp at ~A~%" candidate)))

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
           ;; Wire ELP into swank-lsp's byte-stream-translator
           ;; registry so .elp files get parsed as the embedded Lisp
           ;; only. ELP and swank-lsp don't know about each other —
           ;; the project that uses both is the one that connects
           ;; them, here. Mediaserver renders templates in :mediaserver,
           ;; so we overlay (in-package :mediaserver) on the extracted
           ;; text to give swank-lsp the right package context.
           (when (and (find-package :elp) (find-package :swank-lsp))
             (let ((registry
                     (symbol-value (find-symbol "*BYTE-STREAM-TRANSLATORS*"
                                                :swank-lsp)))
                   (extract (find-symbol "EXTRACT-CODE-TEXT" :elp)))
               (setf (gethash "elp" registry)
                     (lambda (uri text)
                       (declare (ignore uri))
                       (let ((extracted (funcall extract text)))
                         (overlay-in-package extracted "mediaserver"))))))
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
