(in-package :mediaserver-test)

(def-suite render-suite :description "render primitives + per-field bindings")
(in-suite render-suite)

(defun fresh-tmpdir ()
  "Create a fresh empty tmpdir under uiop:temporary-directory and return it."
  (let ((d (uiop:ensure-directory-pathname
            (format nil "~A/mediaserver-render-~D-~D/"
                    (uiop:native-namestring (uiop:temporary-directory))
                    (get-universal-time)
                    (random 100000)))))
    (uiop:delete-directory-tree d :validate t :if-does-not-exist :ignore)
    (ensure-directories-exist d)
    d))

(defun synth-config ()
  "A minimal hand-built config plist (no fixture files needed)."
  (let ((mediaserver::*known-fields*
          '(:name :port :docker-config :sighup-reload
            :compose-file :source-dir :dockerized :has-unit)))
    (declare (ignore mediaserver::*known-fields*))
    (list :services
          (list (list :name "alpha" :port 1234 :docker-config '(:image "x"))
                (list :name "beta"  :port 5678 :docker-config '(:image "y")
                      :sighup-reload t))
          :globals
          '(:install-base "/opt/test" :media-path "/d" :hostname "h"))))

(test render-template-bare-name-bindings
  "Per-field bindings let a template say <%= name %> instead of (field service :name)."
  (let* ((tmp  (fresh-tmpdir))
         (path (merge-pathnames "greet.elp" tmp))
         (cfg  (synth-config))
         (svc  (first (getf cfg :services)))
         (mediaserver::*known-fields*
           '(:name :port :docker-config :compose-file :source-dir
             :dockerized :has-unit))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "hello <%= name %> on port <%= port %>" s))
    (is (equal "hello alpha on port 1234"
               (mediaserver:render-template-to-string
                path (mediaserver::service-render-context svc cfg))))))

(test render-template-derived-fields-bind
  "Derived fields (compose-file, dockerized) bind alongside direct fields."
  (let* ((tmp  (fresh-tmpdir))
         (path (merge-pathnames "compose.elp" tmp))
         (cfg  (synth-config))
         (svc  (first (getf cfg :services)))
         (mediaserver::*known-fields*
           '(:name :port :docker-config :compose-file :source-dir
             :dockerized :has-unit))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "<%= compose_file %> dockerized=<%= (if dockerized \"y\" \"n\") %>" s))
    (is (equal "/opt/test/config/alpha/docker-compose.yml dockerized=y"
               (mediaserver:render-template-to-string
                path (mediaserver::service-render-context svc cfg))))))

(test render-template-iterates-services
  "Templates can iterate (services) and pull fields via field/getf."
  (let* ((tmp  (fresh-tmpdir))
         (path (merge-pathnames "names.elp" tmp))
         (cfg  (synth-config))
         (mediaserver::*known-fields*
           '(:name :port :docker-config :sighup-reload
             :compose-file :source-dir :dockerized :has-unit))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "<% (dolist (s services) %><%= (field s :name) %>:<%= (field s :port) %> <% ) %>" s))
    (is (equal "alpha:1234 beta:5678 "
               (mediaserver:render-template-to-string
                path (mediaserver::service-render-context nil cfg))))))

(test service-source-files-walks-and-filters
  "service-source-files returns relative paths, skips service.yml and .erb."
  (let* ((root (fresh-tmpdir))
         (svc-dir (merge-pathnames "services/foo/" root))
         (cfg (list :globals '(:install-base "/opt/test")))
         (svc '(:name "foo" :docker-config (:image "x"))))
    (declare (ignore cfg))
    (ensure-directories-exist svc-dir)
    (ensure-directories-exist (merge-pathnames "sub/" svc-dir))
    (with-open-file (s (merge-pathnames "service.yml" svc-dir)
                       :direction :output :if-exists :supersede)
      (write-string "name: foo" s))
    (with-open-file (s (merge-pathnames "config.elp" svc-dir)
                       :direction :output :if-exists :supersede)
      (write-string "x" s))
    (with-open-file (s (merge-pathnames "config.erb" svc-dir)
                       :direction :output :if-exists :supersede)
      (write-string "x" s))
    (with-open-file (s (merge-pathnames "sub/nested.elp" svc-dir)
                       :direction :output :if-exists :supersede)
      (write-string "x" s))
    (let ((mediaserver:*globals* (list :install-base "/opt/test"))
          (mediaserver::*known-fields*
            '(:name :docker-config :source-dir :dockerized :has-unit
              :compose-file))
          (*default-pathname-defaults* (uiop:ensure-directory-pathname root)))
      (let ((files (mediaserver:service-source-files svc)))
        (is (= 2 (length files)))
        (is (find #p"config.elp" files :test #'equal))
        (is (find #p"sub/nested.elp" files :test #'equal))))))

(test installed-path-strips-elp
  "installed-path strips .elp suffix and joins under install-base/config/svc."
  (let ((mediaserver:*globals* '(:install-base "/opt/test"))
        (mediaserver::*known-fields*
          '(:name :docker-config :source-dir :dockerized :has-unit
            :compose-file))
        (svc '(:name "foo" :docker-config (:image "x"))))
    (is (equal "/opt/test/config/foo/Caddyfile"
               (mediaserver:installed-path "Caddyfile.elp" svc "/opt/test")))
    (is (equal "/opt/test/config/foo/sub/nested.yml"
               (mediaserver:installed-path "sub/nested.yml.elp" svc "/opt/test")))))
