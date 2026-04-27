(in-package :mediaserver-test)

(def-suite field-suite :description "field accessor + derived fields")
(in-suite field-suite)

(defun fixture-path (relative)
  (asdf:system-relative-pathname :mediaserver
                                 (concatenate 'string "test/" relative)))

(defun load-fixture-service (name)
  "Read a fixture service.yml and convert to plist. Note: ELP preprocessing
   (which substitutes <%= install_base %> etc.) happens at LOAD-CONFIG time
   in the real flow; these field tests only exercise plist+field semantics
   on data that doesn't depend on substitution (:name, :port, :use-vpn)."
  (mediaserver::yaml->plist
   (cl-yaml:parse (fixture-path
                   (format nil "services/~A/service.yml" name)))))

(test yaml->plist-keyword-keys
  "Underscored YAML keys become hyphenated keywords."
  (let ((s (load-fixture-service "fx-qbittorrent")))
    (is (equal "fx-qbittorrent" (getf s :name)))
    (is (eq t (getf s :use-vpn)))
    (is (= 18080 (getf s :port)))))

(test field-direct-lookup
  "FIELD returns the literal value for keys present in the service plist."
  (let ((s (load-fixture-service "fx-qbittorrent"))
        (mediaserver:*globals* '(:install-base "/opt/mediaserver"
                                 :media-path "/data"
                                 :hostname "fixture-host")))
    (is (equal "fx-qbittorrent" (mediaserver:field s :name)))
    (is (eq t (mediaserver:field s :use-vpn)))
    (is (= 18080 (mediaserver:field s :port)))))

(test field-missing-returns-nil
  "Keys absent from the service plist (and not derived) return NIL.
   Without *known-fields* set, no typo guard fires."
  (let ((s (load-fixture-service "fx-qbittorrent"))
        (mediaserver::*known-fields* nil))
    (is (null (mediaserver:field s :sighup-reload)))
    (is (null (mediaserver:field s :groups)))))

(test field-derived-compose-file
  "Compose-file is derived from globals install-base + service name.
   Source-dir and dockerized are also derived."
  (let ((s (load-fixture-service "fx-qbittorrent"))
        (mediaserver:*globals* '(:install-base "/opt/mediaserver"
                                 :media-path "/data"
                                 :hostname "fixture-host")))
    (is (equal "/opt/mediaserver/config/fx-qbittorrent/docker-compose.yml"
               (mediaserver:field s :compose-file)))
    (is (equal "services/fx-qbittorrent" (mediaserver:field s :source-dir)))
    (is (eq t (mediaserver:field s :dockerized)))))

(defun run-tests ()
  (let ((results (run 'field-suite)))
    (explain! results)
    (every (lambda (r) (typep r 'fiveam::test-passed)) results)))
