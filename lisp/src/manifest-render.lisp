(in-package :mediaserver)

;;; Manifest render pass.
;;;
;;; bin/build-service-config emits services/manifest.yaml.elp — the merged
;;; service plists serialized as YAML, with any <%= ... %> tags from
;;; service.yml carried through verbatim as YAML string content. This pass
;;; ELP-renders that file with `services` and globals in scope, producing
;;; the final services/manifest.yaml. That render is where cross-service
;;; references (e.g. `<%= (for-service :smtp from) %>`) resolve.
;;;
;;; Iteration model: the input file (.elp) never changes between passes;
;;; only the SCOPE does. Each pass parses the previous output as YAML to
;;; build a fresh scope, then re-renders the original input. A reference
;;; that resolves to another reference takes one extra pass to settle —
;;; chain depth N converges in N+1 iterations. We cap at *MAX-RENDER-PASSES*
;;; and error if a `<%=` tag survives the final pass.

(defparameter *max-render-passes* 10
  "Hard cap on render iterations. Generous — most chains are depth 1.
   Cycle detection is by lack of progress (output stops changing); the
   cap is the safety net for genuine divergence (e.g. a service's field
   that recursively names itself).")

(defun manifest-render-context-from (services globals)
  "Kwargs plist for ELP-rendering manifest.yaml.elp against SERVICES /
   GLOBALS. Exposes globals as bare symbols (so `<%= install_base %>`
   works) and binds :services / :globals for the for-service macro family."
  (let ((h (make-hash-table)))
    (flet ((merge-in (plist)
             (loop for (k v) on plist by #'cddr
                   do (setf (gethash k h) v))))
      (merge-in (list :services services :globals globals))
      (merge-in globals))
    (loop for k being the hash-keys of h using (hash-value v)
          collect k collect v)))

(defun %render-once (elp-path services globals)
  "Render ELP-PATH against the given scope, return the rendered text."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (apply #'elp:render
             (probe-file elp-path)
             s
             (manifest-render-context-from services globals)))))

(defun %scope-from-text (text)
  "Parse TEXT as YAML to extract (services globals) for the next pass."
  (let* ((parsed (yaml->plist (cl-yaml:parse text))))
    (values (getf parsed :services) (getf parsed :globals))))

(defun render-manifest (elp-path out-stream cfg)
  "Iteratively ELP-render ELP-PATH until the output stops changing,
   writing the converged result to OUT-STREAM. CFG seeds the first
   pass — re-used here so the common single-pass case avoids one
   YAML parse.

   *KNOWN-FIELDS* must be populated before calling this (the
   for-service macro expands against it)."
  (let ((services (getf cfg :services))
        (globals  (getf cfg :globals))
        (prev nil))
    (dotimes (i *max-render-passes*)
      (let ((rendered (%render-once elp-path services globals)))
        (when (equal rendered prev)
          (when (search "<%" rendered)
            (error "manifest render converged with unresolved tags ~
                    after ~A pass~:P" (1+ i)))
          (write-string rendered out-stream)
          (return-from render-manifest (1+ i)))
        (setf prev rendered)
        (multiple-value-setq (services globals) (%scope-from-text rendered))))
    (error "manifest render did not converge after ~A passes; ~
            check for cyclic references" *max-render-passes*)))
