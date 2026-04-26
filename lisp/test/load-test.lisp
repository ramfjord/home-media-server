(in-package :mediaserver-test)

(def-suite load-suite :description "load-config: ELP preprocessing, sort, override, validate")
(in-suite load-suite)

(defun fixture-root ()
  (asdf:system-relative-pathname :mediaserver "../test/fixtures/"))

(test load-config-services-found
  "Five fixture services load."
  (let ((cfg (mediaserver:load-config :root (fixture-root))))
    (is (= 5 (length (getf cfg :services))))))

(test load-config-sort-by-order
  "Services come back sorted by :order (10/20/30/50/60), not by glob order."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (names (mapcar (lambda (s) (getf s :name)) (getf cfg :services))))
    (is (equal '("fx-wireguard" "fx-caddy" "fx-sonarr"
                 "fx-qbittorrent" "fx-prometheus")
               names))))

(test load-config-elp-substitutes-globals
  "<%= install_base %> in service.yml substitutes via ELP at load time."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (qbt (find "fx-qbittorrent" (getf cfg :services)
                    :key (lambda (s) (getf s :name)) :test #'equal))
         (volumes (getf (getf qbt :docker-config) :volumes)))
    (is (equal "/opt/fx-mediaserver/config/fx-qbittorrent:/config"
               (first volumes)))
    (is (equal "/data:/data" (second volumes)))))

(test load-config-elp-default-globals-fall-through
  "Globals not set in any config file (e.g. media_path) come from
   *default-globals* and substitute correctly via ELP."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (sonarr (find "fx-sonarr" (getf cfg :services)
                       :key (lambda (s) (getf s :name)) :test #'equal))
         (volumes (getf (getf sonarr :docker-config) :volumes)))
    ;; media_path isn't in globals.yml or config.local.yml — only in
    ;; *default-globals*. Should still substitute to "/data".
    (is (equal "/data:/data" (second volumes)))))

(test load-config-overrides-scalar
  "service_overrides scalar replace works."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (caddy (find "fx-caddy" (getf cfg :services)
                      :key (lambda (s) (getf s :name)) :test #'equal)))
    (is (equal "Fixture reverse proxy (overridden)" (getf caddy :desc)))
    (is (equal "example.invalid/fx-caddy:overridden"
               (getf (getf caddy :docker-config) :image)))))

(test load-config-overrides-array-union
  "service_overrides array values union, not replace."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (caddy (find "fx-caddy" (getf cfg :services)
                      :key (lambda (s) (getf s :name)) :test #'equal))
         (volumes (getf (getf caddy :docker-config) :volumes)))
    (is (= 3 (length volumes)))
    (is (find "/etc/caddy-extra:/etc/caddy/extra:ro" volumes :test #'equal))))

(test load-config-globals
  "Globals plist has install-base from config.local.yml, hostname from
   globals.yml, media-path from defaults, and custom keys (fx-label)."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (g   (getf cfg :globals)))
    (is (equal "/opt/fx-mediaserver" (getf g :install-base)))
    (is (equal "fx-host" (getf g :hostname)))
    (is (equal "/data" (getf g :media-path)))
    (is (equal "fixture-deployment" (getf g :fx-label)))))

(test load-config-sets-known-fields
  "After load, *known-fields* is populated and FIELD errors on typos."
  (let* ((cfg (mediaserver:load-config :root (fixture-root)))
         (s (first (getf cfg :services))))
    (is (not (null mediaserver::*known-fields*)))
    (signals error (mediaserver:field s :prot))
    ;; :groups isn't on this service but IS in *known-fields* if any
    ;; service has it. fx-* fixtures don't have :groups (per design),
    ;; so :groups would also error — confirming the typo guard.
    (is-true (mediaserver:field s :name))))  ; sanity: real fields work

(test validate-rejects-missing-name
  "validate-services errors on a service without :name."
  (signals error
    (mediaserver::validate-services '((:port 1234) (:name "ok" :port 5678)))))

(test validate-rejects-duplicate-port
  "validate-services errors on two services with the same :port."
  (signals error
    (mediaserver::validate-services '((:name "a" :port 1000)
                                      (:name "b" :port 1000)))))

(defun run-tests ()
  "Run both suites; return T if all pass."
  (let ((field-results (run 'field-suite))
        (load-results  (run 'load-suite)))
    (explain! field-results)
    (explain! load-results)
    (every (lambda (r) (typep r 'fiveam::test-passed))
           (append field-results load-results))))
