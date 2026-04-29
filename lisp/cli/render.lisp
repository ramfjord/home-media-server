(defpackage :mediaserver/render
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/render)

;;; CLI entry point:
;;;
;;;   bin/render [--service NAME] TEMPLATE
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
  (let* ((service-name (clingon:getopt cmd :service))
         (template (first (clingon:command-arguments cmd)))
         (cfg (mediaserver:load-config))
         (svc (and service-name
                   (or (find service-name (getf cfg :services)
                             :key (lambda (s) (getf s :name)) :test #'equal)
                       (error "service not found: ~A" service-name))))
         (*package* (find-package :mediaserver)))
    (elp:render (probe-file template)
                (mediaserver::service-render-context svc cfg))))

(defun command ()
  (clingon:make-command
   :name "render"
   :description "Render an ELP template against the services manifest."
   :usage "[--service NAME] TEMPLATE"
   :options (options)
   :handler #'handler))

(defun main (&optional args)
  (clingon:run (command) (or args (uiop:command-line-arguments))))
