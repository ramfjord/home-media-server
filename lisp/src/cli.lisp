(defpackage :mediaserver/cli
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/cli)

;;; Drop-in interface compatible with render.rb:
;;;
;;;   bin/render [--service NAME] [--root DIR] [--files LIST] [TEMPLATE]
;;;
;;; If TEMPLATE is omitted, reads from stdin (mirroring `./render.rb < x`).
;;;
;;; --service NAME sets which service is in scope for the render. Falls
;;;   back to the SERVICE_NAME env var, then nil (singleton templates).
;;; --root DIR points at the config root (default: cwd). config files
;;;   live under <root>/globals.yml, <root>/services/, etc.
;;; --files "a b c" passes a whitespace-separated file list, exposed as
;;;   `service_files` in the template context. Used by templates that
;;;   need to enumerate a service's deployed config files (e.g. the
;;;   systemd service.path watcher). Defaults to SERVICE_FILES env var.
;;;
;;; Make is the dispatcher: each per-template recipe invokes this CLI
;;; once with the right --service / --files / template path / output
;;; redirect. The Lisp side does not walk the filesystem itself; that's
;;; Make's job and other targets (NixOS, k8s) wouldn't share the
;;; conventions.

(defun usage (stream)
  (format stream "Usage: render [--service NAME] [--root DIR] [--files LIST] [TEMPLATE]~%")
  (format stream "       render --help~%~%")
  (format stream "  --service NAME   Service in scope. Defaults to SERVICE_NAME env.~%")
  (format stream "  --root DIR       Config root (default: cwd).~%")
  (format stream "  --files \"a b c\"  Whitespace-separated deployed filenames; exposed~%")
  (format stream "                   to templates as `service_files`. Defaults to~%")
  (format stream "                   SERVICE_FILES env.~%")
  (format stream "  TEMPLATE         Template path. If omitted, reads stdin.~%"))

(defun parse-args (args)
  (let (service root files template help)
    (loop while args do
      (let ((arg (pop args)))
        (cond
          ((or (string= arg "-h") (string= arg "--help"))
           (setf help t))
          ((string= arg "--service")
           (setf service (or (pop args)
                             (error "--service requires an argument"))))
          ((string= arg "--root")
           (setf root (or (pop args)
                          (error "--root requires an argument"))))
          ((string= arg "--files")
           (setf files (or (pop args)
                           (error "--files requires an argument"))))
          ((and (> (length arg) 0) (char= (char arg 0) #\-))
           (error "unknown flag: ~A" arg))
          (t
           (when template
             (error "extra positional arg: ~A" arg))
           (setf template arg)))))
    (list :service service :root root :files files
          :template template :help help)))

(defun split-whitespace (s)
  "Return a list of non-empty whitespace-separated tokens in S."
  (when (and s (> (length s) 0))
    (remove "" (uiop:split-string s :separator #(#\Space #\Tab #\Newline))
            :test #'equal)))

(defun stdin-to-tempfile ()
  "Read stdin to a tempfile (ELP needs a file path). Caller deletes it."
  (let ((path (uiop:tmpize-pathname #p"/tmp/render-stdin.elp")))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (loop for line = (read-line *standard-input* nil nil)
            while line do (write-line line out)))
    path))

(defun augmented-context (service config service-files)
  "Standard service-render-context plus a SERVICE_FILES binding."
  (let ((ctx (mediaserver::service-render-context service config))
        (sym (intern "SERVICE_FILES" :mediaserver)))
    ;; Cons new entry to the front so it wins on duplicate-key dedup
    ;; semantics inside ELP's let wrapper.
    (cons (cons sym service-files) ctx)))

(defun main (&optional args)
  (handler-case
      (let* ((argv (or args (uiop:command-line-arguments)))
             (opts (parse-args argv))
             (service-name (or (getf opts :service)
                               (uiop:getenv "SERVICE_NAME")))
             (root (or (getf opts :root) (namestring (uiop:getcwd))))
             (files-raw (or (getf opts :files) (uiop:getenv "SERVICE_FILES")))
             (service-files (split-whitespace files-raw))
             (template-arg (getf opts :template)))
        (when (getf opts :help)
          (usage *standard-output*)
          (uiop:quit 0))
        (let* ((cfg (mediaserver:load-config :root root))
               (svc (and service-name
                         (not (string= "" service-name))
                         (or (find service-name (getf cfg :services)
                                   :key (lambda (s) (getf s :name)) :test #'equal)
                             (error "service not found: ~A" service-name))))
               (template (cond
                           ((null template-arg) (stdin-to-tempfile))
                           ((probe-file template-arg) (probe-file template-arg))
                           (t (error "template not found: ~A" template-arg))))
               (cleanup-template (null template-arg))
               (output (mediaserver:render-template-to-string
                        template (augmented-context svc cfg service-files))))
          (write-string output *standard-output*)
          (finish-output *standard-output*)
          (when cleanup-template (ignore-errors (delete-file template)))
          (uiop:quit 0)))
    (error (e)
      (format *error-output* "render: ~A~%" e)
      (uiop:quit 1))))
