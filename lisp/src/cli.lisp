(defpackage :mediaserver/cli
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/cli)

;;; Drop-in interface compatible with render.rb:
;;;
;;;   bin/render [--service NAME] [TEMPLATE]
;;;
;;; If TEMPLATE is omitted, reads from stdin (mirroring `./render.rb < x`).
;;;
;;; --service NAME sets which service is in scope for the render. Falls
;;;   back to the SERVICE_NAME env var, then nil (singleton templates).
;;;
;;; Reads the services manifest from `services/manifest.yaml` (relative
;;; to cwd) at startup. The manifest is built by bin/build-service-config;
;;; see the Makefile.
;;;
;;; Make is the dispatcher: each per-template recipe invokes this CLI
;;; once with the right --service / template path / output redirect.

(defun usage (stream)
  (format stream "Usage: render [--service NAME] [TEMPLATE]~%")
  (format stream "       render --help~%~%")
  (format stream "  --service NAME   Service in scope. Defaults to SERVICE_NAME env.~%")
  (format stream "  TEMPLATE         Template path. If omitted, reads stdin.~%"))

(defun parse-args (args)
  (let (service template help)
    (loop while args do
      (let ((arg (pop args)))
        (cond
          ((or (string= arg "-h") (string= arg "--help"))
           (setf help t))
          ((string= arg "--service")
           (setf service (or (pop args)
                             (error "--service requires an argument"))))
          ((and (> (length arg) 0) (char= (char arg 0) #\-))
           (error "unknown flag: ~A" arg))
          (t
           (when template
             (error "extra positional arg: ~A" arg))
           (setf template arg)))))
    (list :service service :template template :help help)))

(defun stdin-to-tempfile ()
  "Read stdin to a tempfile (ELP needs a file path). Caller deletes it."
  (let ((path (uiop:tmpize-pathname #p"/tmp/render-stdin.elp")))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (loop for line = (read-line *standard-input* nil nil)
            while line do (write-line line out)))
    path))

(defun main (&optional args)
  (handler-case
      (let* ((argv (or args (uiop:command-line-arguments)))
             (opts (parse-args argv))
             (service-name (or (getf opts :service)
                               (uiop:getenv "SERVICE_NAME")))
             (template-arg (getf opts :template)))
        (when (getf opts :help)
          (usage *standard-output*)
          (uiop:quit 0))
        (let* ((cfg (mediaserver:load-config))
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
                        template
                        (mediaserver::service-render-context svc cfg))))
          (write-string output *standard-output*)
          (finish-output *standard-output*)
          (when cleanup-template (ignore-errors (delete-file template)))
          (uiop:quit 0)))
    (error (e)
      (format *error-output* "render: ~A~%" e)
      (uiop:quit 1))))
