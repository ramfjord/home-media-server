(in-package :mediaserver)

;;; Render driver
;;;
;;; Walks ELP templates and writes rendered output, mirroring the Ruby
;;; renderer's path conventions:
;;;
;;;   <services-root>/<svc>/**/*.elp  -> <output>/<svc>/<rel-without-.elp>
;;;     rendered once with that service in scope.
;;;
;;;   <systemd-root>/<per-svc-tmpl>.elp  -> <output>/<see-table>
;;;     rendered once per dockerized service, with that service in scope.
;;;     The destination filename is per-template (e.g. service.service.elp
;;;     emits "<svc>.service" under systemd/).
;;;
;;;   <systemd-root>/sighup-reload.service.elp  -> <output>/systemd/<svc>-reload.service
;;;     rendered only for services with :sighup-reload set.
;;;
;;;   <systemd-root>/mediaserver.target.elp  -> <output>/systemd/mediaserver.target
;;;     rendered once, no service in scope.
;;;
;;; Output is written write-if-changed so unchanged templates don't bump
;;; mtimes (matters once these outputs feed systemd path units, not
;;; relevant in the fixture-test path).

(defun render-template-to-string (path context)
  "ELP-render PATH with CONTEXT (alist), return the rendered string."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (elp:render (probe-file path) context s))))

(defun service-render-context (service config)
  "Build the ELP context-alist for a render. Includes the underscored
   globals (install_base etc.) plus SERVICE / SERVICES / GLOBALS."
  (let ((globals  (getf config :globals))
        (services (getf config :services)))
    (append (globals->elp-context globals)
            (list (cons (intern "SERVICE"  :mediaserver) service)
                  (cons (intern "SERVICES" :mediaserver) services)
                  (cons (intern "GLOBALS"  :mediaserver) globals)))))

(defun write-if-changed (path content)
  "Write CONTENT to PATH only if the existing file differs.
   Returns T if written, NIL if skipped."
  (ensure-directories-exist (uiop:pathname-directory-pathname path))
  (let ((existing (and (probe-file path)
                       (uiop:read-file-string path))))
    (cond ((equal existing content) nil)
          (t (with-open-file (s path :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
               (write-string content s))
             t))))

;;; Per-service systemd template -> destination relpath. Mirrors
;;; PER_SERVICE_SYSTEMD in test/golden_test.rb.

(defparameter *per-service-systemd-templates*
  (list
   (list "service.compose.yml.elp"
         (lambda (s) (format nil "~A/docker-compose.yml" (getf s :name))))
   (list "service.service.elp"
         (lambda (s) (format nil "systemd/~A.service" (getf s :name))))
   (list "service.path.elp"
         (lambda (s) (format nil "systemd/~A.path" (getf s :name))))
   (list "service-compose.path.elp"
         (lambda (s) (format nil "systemd/~A-compose.path" (getf s :name))))
   (list "service-compose-reload.service.elp"
         (lambda (s) (format nil "systemd/~A-compose-reload.service" (getf s :name))))))

(defparameter *singleton-systemd-templates*
  '(("mediaserver.target.elp" . "systemd/mediaserver.target")))

(defun dockerized-services (services config)
  (remove-if-not (lambda (s) (field s :dockerized (getf config :globals)))
                 services))

(defun render-systemd-templates (config tdir output-dir)
  "Render every applicable template under TDIR. Returns count written."
  (let ((count 0)
        (services (getf config :services)))
    ;; Per-service expansion.
    (dolist (svc (dockerized-services services config))
      (dolist (entry *per-service-systemd-templates*)
        (let ((tmpl (merge-pathnames (first entry) tdir)))
          (when (probe-file tmpl)
            (let* ((relpath (funcall (second entry) svc))
                   (out (merge-pathnames relpath output-dir))
                   (content (render-template-to-string
                             tmpl (service-render-context svc config))))
              (when (write-if-changed out content) (incf count)))))))
    ;; sighup-reload (only services with :sighup-reload).
    (let ((tmpl (merge-pathnames "sighup-reload.service.elp" tdir)))
      (when (probe-file tmpl)
        (dolist (svc services)
          (when (field svc :sighup-reload (getf config :globals))
            (let* ((relpath (format nil "systemd/~A-reload.service" (getf svc :name)))
                   (out (merge-pathnames relpath output-dir))
                   (content (render-template-to-string
                             tmpl (service-render-context svc config))))
              (when (write-if-changed out content) (incf count)))))))
    ;; Singletons.
    (dolist (entry *singleton-systemd-templates*)
      (let ((tmpl (merge-pathnames (car entry) tdir)))
        (when (probe-file tmpl)
          (let* ((out (merge-pathnames (cdr entry) output-dir))
                 (content (render-template-to-string
                           tmpl (service-render-context nil config))))
            (when (write-if-changed out content) (incf count))))))
    count))

(defun render-per-service-templates (config sdir output-dir)
  "Render every <svc>/**/*.elp under SDIR. Returns count written."
  (let ((count 0))
    (dolist (svc (getf config :services))
      (let* ((svc-name (getf svc :name))
             (svc-dir  (merge-pathnames (format nil "~A/" svc-name) sdir)))
        (dolist (tmpl (directory (merge-pathnames "**/*.elp" svc-dir)))
          (let* ((rel-with-elp (uiop:enough-pathname tmpl svc-dir))
                 (rel-str (namestring rel-with-elp))
                 (rel-no-elp (subseq rel-str 0 (- (length rel-str) 4)))
                 (out (merge-pathnames
                       (format nil "~A/~A" svc-name rel-no-elp)
                       output-dir))
                 (content (render-template-to-string
                           tmpl (service-render-context svc config))))
            (when (write-if-changed out content) (incf count))))))
    count))

(defun render-tree (config &key systemd-template-dir services-template-dir output-dir)
  "Render every applicable .elp template, write results to OUTPUT-DIR.
   Returns the number of files written."
  (let ((output-dir (uiop:ensure-directory-pathname output-dir))
        (count 0))
    (when systemd-template-dir
      (incf count (render-systemd-templates
                   config
                   (uiop:ensure-directory-pathname systemd-template-dir)
                   output-dir)))
    (when services-template-dir
      (incf count (render-per-service-templates
                   config
                   (uiop:ensure-directory-pathname services-template-dir)
                   output-dir)))
    count))
