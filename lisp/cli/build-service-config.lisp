(defpackage :mediaserver/build-service-config
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/build-service-config)

;;; bin/build-service-config — build the manifest yaml.
;;;
;;; Usage:
;;;   bin/build-service-config [--override=PATH ...] SERVICE.yml ...
;;;
;;;   --override=PATH    layer this yaml onto globals + service_overrides
;;;                      (last-wins; pass config.yaml then config.local.yaml)
;;;   SERVICE.yml ...    one or more service.yml paths to include
;;;
;;; Writes pretty block-style YAML to stdout. Pure data transformation
;;; — no shelling out, no filesystem walks beyond reading the inputs +
;;; resolving :config_files under each service's directory.

(defun usage (stream)
  (format stream "Usage: build-service-config [--override=PATH ...] SERVICE.yml ...~%"))

(defun parse-args (args)
  (let (overrides services help)
    (dolist (arg args)
      (cond
        ((or (string= arg "-h") (string= arg "--help"))
         (setf help t))
        ((and (>= (length arg) 11)
              (string= "--override=" (subseq arg 0 11)))
         (push (subseq arg 11) overrides))
        ((and (> (length arg) 0) (char= (char arg 0) #\-))
         (error "unknown flag: ~A" arg))
        (t (push arg services))))
    (list :overrides (nreverse overrides)
          :services  (nreverse services)
          :help      help)))

(defun main (&optional args)
  (handler-case
      (let* ((argv (or args (uiop:command-line-arguments)))
             (opts (parse-args argv)))
        (when (getf opts :help)
          (usage *standard-output*)
          (uiop:quit 0))
        (let ((cfg (mediaserver:load-config-from-args
                    (getf opts :services)
                    (getf opts :overrides))))
          (mediaserver:emit-manifest cfg *standard-output*)
          (finish-output *standard-output*)
          (uiop:quit 0)))
    (error (e)
      (format *error-output* "build-service-config: ~A~%" e)
      (uiop:quit 1))))
