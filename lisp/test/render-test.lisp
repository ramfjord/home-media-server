(in-package :mediaserver-test)

(def-suite render-suite :description "render-tree driver")
(in-suite render-suite)

(defparameter *tmp-root* nil)

(defun fresh-tmpdir ()
  "Create a fresh empty tmpdir under uiop:temporary-directory and return it."
  (let ((d (uiop:ensure-directory-pathname
            (format nil "~A/mediaserver-render-~D/"
                    (uiop:native-namestring (uiop:temporary-directory))
                    (get-universal-time)))))
    (uiop:delete-directory-tree d :validate t :if-does-not-exist :ignore)
    (ensure-directories-exist d)
    d))

(defun synth-config ()
  "A minimal hand-built config plist (no fixture files needed)."
  (list :services
        (list (list :name "alpha" :port 1234 :docker-config '(:image "x"))
              (list :name "beta"  :port 5678 :docker-config '(:image "y")
                    :sighup-reload t))
        :globals
        '(:install-base "/opt/test" :media-path "/d" :hostname "h")))

(test write-if-changed-creates
  "write-if-changed creates a missing file."
  (let* ((d (fresh-tmpdir))
         (p (merge-pathnames "x.txt" d)))
    (is-true (mediaserver:write-if-changed p "hello"))
    (is (equal "hello" (uiop:read-file-string p)))))

(test write-if-changed-skips-identical
  "Identical content -> no write, returns NIL."
  (let* ((d (fresh-tmpdir))
         (p (merge-pathnames "x.txt" d)))
    (mediaserver:write-if-changed p "same")
    (is (null (mediaserver:write-if-changed p "same")))))

(test write-if-changed-overwrites-different
  "Different content -> overwrite, returns T."
  (let* ((d (fresh-tmpdir))
         (p (merge-pathnames "x.txt" d)))
    (mediaserver:write-if-changed p "old")
    (is-true (mediaserver:write-if-changed p "new"))
    (is (equal "new" (uiop:read-file-string p)))))

(test render-tree-empty-no-output
  "render-tree against empty template dirs writes nothing."
  (let* ((tmpls   (fresh-tmpdir))   ; empty: no .elp files
         (svc-dir (fresh-tmpdir))
         (out     (fresh-tmpdir))
         (cfg     (synth-config))
         (mediaserver:*globals* (getf cfg :globals)))
    (is (zerop (mediaserver:render-tree
                cfg
                :systemd-template-dir tmpls
                :services-template-dir svc-dir
                :output-dir out)))
    (is (null (directory (merge-pathnames "**/*" out))))))

(test render-tree-per-service-template
  "A hand-written .elp under <services>/<svc>/ renders to <out>/<svc>/<rel>."
  (let* ((svc-dir (fresh-tmpdir))
         (out     (fresh-tmpdir))
         (cfg     (synth-config))
         (mediaserver:*globals* (getf cfg :globals)))
    ;; Write a tiny ELP template for service 'alpha'.
    (ensure-directories-exist (merge-pathnames "alpha/" svc-dir))
    (with-open-file (s (merge-pathnames "alpha/greeting.txt.elp" svc-dir)
                       :direction :output :if-exists :supersede)
      (write-string "hello <%= (mediaserver:field service :name) %>" s))
    ;; Render.
    (let ((written (mediaserver:render-tree
                    cfg
                    :services-template-dir svc-dir
                    :output-dir out)))
      (is (= 1 written))
      (is (equal "hello alpha"
                 (uiop:read-file-string
                  (merge-pathnames "alpha/greeting.txt" out)))))))

(test render-tree-singleton-systemd-template
  "mediaserver.target.elp under <systemd>/ renders once to <out>/systemd/mediaserver.target."
  (let* ((tmpls (fresh-tmpdir))
         (out   (fresh-tmpdir))
         (cfg   (synth-config))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s (merge-pathnames "mediaserver.target.elp" tmpls)
                       :direction :output :if-exists :supersede)
      (write-string "Wants=<% (dolist (s services) %><%= (mediaserver:field s :name) %>.service <% ) %>" s))
    (let ((written (mediaserver:render-tree
                    cfg :systemd-template-dir tmpls :output-dir out)))
      (is (= 1 written))
      (is (search "alpha.service"
                  (uiop:read-file-string
                   (merge-pathnames "systemd/mediaserver.target" out)))))))

(test render-tree-per-service-systemd-expansion
  "service.service.elp expands to one output per dockerized service."
  (let* ((tmpls (fresh-tmpdir))
         (out   (fresh-tmpdir))
         (cfg   (synth-config))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s (merge-pathnames "service.service.elp" tmpls)
                       :direction :output :if-exists :supersede)
      (write-string "[Unit]
Description=<%= (mediaserver:field service :name) %>" s))
    (let ((written (mediaserver:render-tree
                    cfg :systemd-template-dir tmpls :output-dir out)))
      (is (= 2 written))
      (is (search "Description=alpha"
                  (uiop:read-file-string
                   (merge-pathnames "systemd/alpha.service" out))))
      (is (search "Description=beta"
                  (uiop:read-file-string
                   (merge-pathnames "systemd/beta.service" out)))))))

(test render-tree-sighup-only-applicable
  "sighup-reload.service.elp renders only for services with :sighup-reload."
  (let* ((tmpls (fresh-tmpdir))
         (out   (fresh-tmpdir))
         (cfg   (synth-config))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s (merge-pathnames "sighup-reload.service.elp" tmpls)
                       :direction :output :if-exists :supersede)
      (write-string "reload <%= (mediaserver:field service :name) %>" s))
    (let ((written (mediaserver:render-tree
                    cfg :systemd-template-dir tmpls :output-dir out)))
      ;; Only 'beta' has :sighup-reload set in synth-config.
      (is (= 1 written))
      (is (probe-file (merge-pathnames "systemd/beta-reload.service" out)))
      (is (null (probe-file (merge-pathnames "systemd/alpha-reload.service" out)))))))
