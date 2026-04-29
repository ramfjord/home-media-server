(defpackage :mediaserver/cli
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/cli)

;;; CLI entry point:
;;;
;;;   bin/render [--service NAME] [TEMPLATE]
;;;
;;; If TEMPLATE is omitted, reads from stdin.
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

(defun stdin-to-tempfile ()
  "Read stdin to a tempfile (ELP needs a file path). Caller deletes it."
  (let ((path (uiop:tmpize-pathname #p"/tmp/render-stdin.elp")))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (loop for line = (read-line *standard-input* nil nil)
            while line do (write-line line out)))
    path))

(defun options ()
  (list
   (clingon:make-option
    :string
    :description "service in scope for the render"
    :short-name #\s
    :long-name "service"
    :env-vars '("SERVICE_NAME")
    :key :service)))

(defun handler (cmd)
  (handler-case
      (let* ((service-name (clingon:getopt cmd :service))
             (free (clingon:command-arguments cmd))
             (template-arg (first free)))
        (when (rest free)
          (error "extra positional arg: ~A" (second free)))
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
          (when cleanup-template (ignore-errors (delete-file template)))))
    (error (e)
      (format *error-output* "render: ~A~%" e)
      (uiop:quit 1))))

(defun command ()
  (clingon:make-command
   :name "render"
   :description "Render an ELP template against the services manifest."
   :usage "[--service NAME] [TEMPLATE]"
   :options (options)
   :handler #'handler))

(defun main (&optional args)
  (clingon:run (command) (or args (uiop:command-line-arguments))))
