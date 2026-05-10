(defpackage :mediaserver/build-service-config
  (:use :cl :mediaserver)
  (:export :main))

(in-package :mediaserver/build-service-config)

;;; bin/build-service-config — build the manifest yaml.
;;;
;;; Usage:
;;;   bin/build-service-config [--override=PATH ...] -o OUT_ELP SERVICE.yml.elp ...
;;;
;;;   --override=PATH        layer this yaml onto globals + service_overrides
;;;                          (last-wins; pass config.yaml then config.local.yaml)
;;;   -o, --out=PATH         write the merged-but-unrendered manifest YAML to
;;;                          PATH (must end in .elp). The rendered manifest
;;;                          is written alongside it, with the .elp suffix
;;;                          stripped (e.g. -o foo/manifest.yaml.elp also
;;;                          writes foo/manifest.yaml).
;;;   SERVICE.yml.elp ...    one or more service.yml.elp paths to include
;;;
;;; Two-phase output: the .elp file is the merged service plists serialized
;;; as YAML, with any <%= ... %> tags from service.yml.elp carried through
;;; verbatim. Then mediaserver:render-manifest evaluates those tags with
;;; the full set of services in scope, producing the final .yaml.

(defun usage (stream)
  (format stream "Usage: build-service-config [--override=PATH ...] -o OUT_ELP SERVICE.yml.elp ...~%"))

(defun parse-args (args)
  (let (overrides services out help)
    (loop while args do
      (let ((arg (pop args)))
        (cond
          ((or (string= arg "-h") (string= arg "--help"))
           (setf help t))
          ((and (>= (length arg) 11)
                (string= "--override=" (subseq arg 0 11)))
           (push (subseq arg 11) overrides))
          ((and (>= (length arg) 6)
                (string= "--out=" (subseq arg 0 6)))
           (setf out (subseq arg 6)))
          ((string= arg "-o")
           (setf out (pop args)))
          ((and (> (length arg) 0) (char= (char arg 0) #\-))
           (error "unknown flag: ~A" arg))
          (t (push arg services)))))
    (list :overrides (nreverse overrides)
          :services  (nreverse services)
          :out       out
          :help      help)))

(defun strip-elp-suffix (path)
  "PATH must end in .elp; return PATH without that suffix."
  (let ((s (namestring path)))
    (unless (and (>= (length s) 4)
                 (string= ".elp" s :start2 (- (length s) 4)))
      (error "expected .elp suffix on output path: ~A" s))
    (subseq s 0 (- (length s) 4))))

(defun main (&optional args)
  (handler-case
      (let* ((argv (or args (uiop:command-line-arguments)))
             (opts (parse-args argv)))
        (when (getf opts :help)
          (usage *standard-output*)
          (uiop:quit 0))
        (let* ((out-elp (or (getf opts :out)
                            (error "missing -o/--out=PATH (.elp output)")))
               (out-yaml (strip-elp-suffix out-elp))
               (cfg (mediaserver:load-config-from-args
                     (getf opts :services)
                     (getf opts :overrides))))
          ;; Phase 1: emit merged manifest with <%= ... %> tags preserved.
          (with-open-file (s out-elp :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
            (mediaserver:emit-manifest cfg s))
          ;; Phase 2: ELP-render that file with services in scope.
          (setf mediaserver:*known-fields*
                (mediaserver:collect-known-fields (getf cfg :services)))
          (with-open-file (s out-yaml :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create)
            (mediaserver:render-manifest out-elp s cfg))
          (uiop:quit 0)))
    (error (e)
      (format *error-output* "build-service-config: ~A~%" e)
      (uiop:quit 1))))
