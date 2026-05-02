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
          '(:name :port :docker_config :sighup_reload
            :compose_file :source_dir :dockerized :has_unit)))
    (declare (ignore mediaserver::*known-fields*))
    (list :services
          (list (list :name "alpha" :port 1234 :docker_config '(:image "x"))
                (list :name "beta"  :port 5678 :docker_config '(:image "y")
                      :sighup_reload t))
          :globals
          '(:install_base "/opt/test" :media_path "/d" :hostname "h"))))

(test render-template-bare-name-bindings
  "Per-field bindings let a template say <%= name %> instead of (field service :name)."
  (let* ((tmp  (fresh-tmpdir))
         (path (merge-pathnames "greet.elp" tmp))
         (cfg  (synth-config))
         (svc  (first (getf cfg :services)))
         (mediaserver::*known-fields*
           '(:name :port :docker_config :compose_file :source_dir
             :dockerized :has_unit))
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
           '(:name :port :docker_config :compose_file :source_dir
             :dockerized :has_unit))
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
           '(:name :port :docker_config :sighup_reload
             :compose_file :source_dir :dockerized :has_unit))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "<% (dolist (s services) %><%= (field :name s) %>:<%= (field :port s) %> <% ) %>" s))
    (is (equal "alpha:1234 beta:5678 "
               (mediaserver:render-template-to-string
                path (mediaserver::service-render-context nil cfg))))))

(test render-template-service-files-binding
  "When the CLI passes --files, templates can iterate `service_files`
   to enumerate per-service config files (used by systemd's
   service.path watcher)."
  (let* ((tmp  (fresh-tmpdir))
         (path (merge-pathnames "watcher.elp" tmp))
         (cfg  (synth-config))
         (svc  (first (getf cfg :services)))
         (mediaserver::*known-fields*
           '(:name :port :docker_config :compose_file :source_dir
             :dockerized :has_unit))
         (mediaserver:*globals* (getf cfg :globals)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "<%- (dolist (f service_files) -%>
P=<%= f %>
<%- ) -%>" s))
    ;; Augment the context with a :service_files binding (mirrors
    ;; what the CLI does when --files is given). LIST* prepends one
    ;; (key value) pair to the plist returned by service-render-context.
    (let* ((base (mediaserver::service-render-context svc cfg))
           (ctx  (list* :service_files
                        '("Caddyfile" "extra/policy.json")
                        base)))
      (is (equal "P=Caddyfile
P=extra/policy.json
"
                 (mediaserver:render-template-to-string path ctx))))))
