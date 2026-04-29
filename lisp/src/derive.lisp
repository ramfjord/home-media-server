(in-package :mediaserver)

;;; Compute derived fields into a service plist at manifest-build time.
;;;
;;; This file is the only place that resolves "this service's
;;; <derived-field> is computed from <these inputs>". Render-time
;;; field access is plain getf — by the time the manifest reaches the
;;; renderer, every accessible field is a literal value in the plist.
;;;
;;; Adding a derived field = adding a SETF line. Order entries by
;;; data dependency (later ones can reference earlier ones via getf).

(defun resolve-group-ids (group-names)
  "Resolve each name via `getent group <name>` to a numeric GID. Names
   not found drop out — matches the prior Ruby group_ids behavior."
  (loop for g in group-names
        for line = (uiop:run-program (list "getent" "group" g)
                                     :output :string
                                     :ignore-error-status t)
        for trimmed = (str:trim line)
        when (and trimmed (> (length trimmed) 0))
          collect (parse-integer (third (str:split ":" trimmed)))))

(defun config-files-for (name)
  "Files under services/<NAME>/ that get deployed verbatim. Skips
   service.yml (data) and *.erb (legacy shadows). Strips .elp so the
   listed name matches the deployed file."
  (let ((src (truename (format nil "services/~A/" name))))
    (loop for p in (directory (merge-pathnames "**/*.*" src))
          for r = (enough-namestring p src)
          when (uiop:file-pathname-p p)
          unless (or (string= r "service.yml") (str:ends-with? ".erb" r))
          collect (if (str:ends-with? ".elp" r)
                      (subseq r 0 (- (length r) 4)) r))))

(defun derive-fields (service globals)
  "Return SERVICE with computed fields filled in. Pure transformation:
   no shelling out, no target-side state. Walks the local filesystem
   under services/<name>/ for :config_files."
  (let* ((s    (copy-list service))
         (name (getf s :name)))
    (setf (getf s :compose_file)
          (format nil "~A/config/~A/docker-compose.yml"
                  (getf globals :install_base) name))
    (setf (getf s :source_dir)    (format nil "services/~A" name))
    (setf (getf s :dockerized)    (and (getf s :docker_config) t))
    (setf (getf s :has_unit)      (and (getf s :unit) t))
    (setf (getf s :config_files)  (config-files-for name))
    (setf (getf s :group_ids)
          (and (getf s :groups) (resolve-group-ids (getf s :groups))))
    s))
