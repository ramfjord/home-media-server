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
;;; Single pass for v1 — extending to fixed-point iteration is a future
;;; option, but no current case needs more than one pass.

(defun manifest-render-context (cfg)
  "Kwargs plist for ELP-rendering manifest.yaml.elp against CFG.
   Exposes globals as bare symbols (so `<%= install_base %>` works) and
   binds :services / :globals for the for-service macro family."
  (let ((globals  (getf cfg :globals))
        (services (getf cfg :services))
        (h (make-hash-table)))
    (flet ((merge-in (plist)
             (loop for (k v) on plist by #'cddr
                   do (setf (gethash k h) v))))
      (merge-in (list :services services :globals globals))
      (merge-in globals))
    (loop for k being the hash-keys of h using (hash-value v)
          collect k collect v)))

(defun render-manifest (elp-path out-stream cfg)
  "ELP-render ELP-PATH against CFG, writing to OUT-STREAM. CFG is the
   in-memory plist (:services ... :globals ...) the .elp was emitted
   from — re-using it as scope avoids round-tripping through YAML.

   *KNOWN-FIELDS* must be populated before calling this (the
   for-service macro expands against it). Callers that just loaded
   the config have it set; callers reading from a manifest on disk
   should call (collect-known-fields services) first."
  (let ((*package* (find-package :mediaserver)))
    (apply #'elp:render
           (probe-file elp-path)
           out-stream
           (manifest-render-context cfg))))
