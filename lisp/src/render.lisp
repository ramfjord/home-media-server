(in-package :mediaserver)

(defun ruby-capitalize (s)
  "Mirror Ruby's String#capitalize: upcase the first character, downcase
   the rest. CL's string-capitalize splits on word boundaries, which
   would turn \"blackbox-exporter\" into \"Blackbox-Exporter\" instead
   of \"Blackbox-exporter\"."
  (if (zerop (length s))
      s
      (concatenate 'string
                   (string (char-upcase (char s 0)))
                   (string-downcase (subseq s 1)))))

;;; Block-style YAML emit, the subset templates need.
;;;
;;; Mirrors Ruby Psych's defaults closely enough for the docker-compose
;;; templates to produce byte-identical output. Not a general YAML
;;; serializer — leans on a few invariants:
;;;   - Maps are plists with keyword keys; emitted "key: value".
;;;   - Sequences are CL lists; emitted "- item".
;;;   - Scalars: T/NIL -> true/false; integers bare; strings quoted
;;;     iff empty (-> '') or starting with "/" (-> "..."), else bare.
;;;     This matches the quoting Psych picks for our fixture data.
;;;
;;; Tested against test/config/*/docker-compose.yml goldens.

(defun %yaml-key-name (k)
  "Map :container-name -> \"container_name\" (keyword keys carry the
   plist-key convention, where hyphens stand in for YAML's underscores).
   String keys (e.g. service names like \"fx-caddy\") pass through
   unchanged."
  (etypecase k
    (keyword (substitute #\_ #\- (string-downcase (symbol-name k))))
    (string  k)))

(defun %yaml-pairs (obj)
  "Return OBJ as a list of (key value) pairs, in order. Accepts both
   keyword-keyed plists (the load-side convention) and lists of conses
   (alists) used when keys must be data-side strings."
  (cond
    ((null obj) nil)
    ((consp (car obj))
     (mapcar (lambda (p) (list (car p) (cdr p))) obj))
    (t (loop for (k v) on obj by #'cddr collect (list k v)))))

(defun %map-like-p (x)
  "True when X is a structure emit-yaml-block should treat as a map:
   either a keyword-keyed plist or an alist of (key . value) conses."
  (or (mediaserver::plistp x)
      (and (consp x) (consp (car x)))))

(defun %yaml-scalar (v)
  "Render a leaf value as the scalar text Psych would emit."
  (cond
    ((eq v t)     "true")
    ((eq v nil)   "false")
    ((integerp v) (princ-to-string v))
    ((stringp v)
     (cond
       ((string= v "") "''")
       ;; Strings that would parse back as a different type if emitted
       ;; bare. Psych single-quotes these to lock them as strings.
       ((or (member v '("true" "false" "yes" "no" "null" "~") :test #'equal)
            (every #'digit-char-p v))
        (format nil "'~A'" v))
       ;; Match Ruby Psych's defensive quoting for our data: leading
       ;; "/" (volume-mount paths) and leading "-" (CLI flags). Other
       ;; special chars haven't come up — extend as goldens find them.
       ((and (> (length v) 0)
             (or (char= (char v 0) #\/)
                 (char= (char v 0) #\-)))
        (format nil "\"~A\"" v))
       (t v)))
    (t (princ-to-string v))))

(defun emit-yaml-block (obj stream indent)
  "Block-style YAML emit of OBJ to STREAM, leading INDENT spaces per
   nesting level. Maps -> \"key: value\" lines; sequences -> \"- item\"
   lines; atoms -> scalars via %YAML-SCALAR."
  (cond
    ((%map-like-p obj)
     (dolist (pair (%yaml-pairs obj))
       (let ((k (first pair)) (v (second pair)))
         (format stream "~v@T~A:" indent (%yaml-key-name k))
         (cond
           ((%map-like-p v)
            (terpri stream)
            (emit-yaml-block v stream (+ indent 2)))
           ((listp v)
            (terpri stream)
            (dolist (item v)
              (format stream "~v@T- ~A~%" indent (%yaml-scalar item))))
           (t
            (format stream " ~A~%" (%yaml-scalar v)))))))
    ((listp obj)
     (dolist (item obj)
       (format stream "~v@T- ~A~%" indent (%yaml-scalar item))))
    (t (write-string (%yaml-scalar obj) stream))))

(defun emit-compose (service)
  "Build the docker-compose.yml structure for SERVICE and return it as
   a string (no leading `---`). Mirrors systemd/service.compose.yml.erb
   line-for-line: predefined keys first, then docker_config merged in,
   then optional group_add. The networks block is appended at top level
   for non-VPN services."
  (let* ((name        (field service :name))
         (use-vpn     (field service :use-vpn))
         (port        (field service :port))
         (user-id     (field service :user-id))
         (docker-cfg  (or (field service :docker-config) '()))
         (explicit-net-mode (getf docker-cfg :network-mode))
         (groups      (field service :groups))
         (svc (list :container-name name
                    :environment (list "TZ=Etc/UTC"))))
    (when user-id
      (setf svc (append svc (list :user (princ-to-string user-id)))))
    (cond
      (use-vpn
       (setf svc (append svc (list :network-mode "container:wireguard"))))
      (explicit-net-mode
       ;; docker_config.network_mode wins; skip mediaserver-network injection.
       )
      (t
       (setf svc (append svc (list :networks (list "mediaserver"))))
       ;; Auto-publish container :port to host :port unless the user
       ;; pinned :ports explicitly OR set :public-url. The public-url
       ;; case means "users reach this via a proxy, not a host port" —
       ;; auto-publishing would shadow the proxy and (for vaultwarden)
       ;; expose plaintext on the TLS port.
       (when (and port
                  (not (getf docker-cfg :ports))
                  (not (getf service :public-url)))
         (setf svc (append svc
                           (list :ports
                                 (list (format nil "~A:~A" port port))))))))
    ;; Merge docker_config keys: append in declaration order if not
    ;; present, replace in place if present. Mirrors Ruby Hash#merge,
    ;; which preserves original key positions and appends new ones.
    (loop for (k v) on docker-cfg by #'cddr
          do (let ((existing (getf svc k 'no)))
               (if (eq existing 'no)
                   (setf svc (append svc (list k v)))
                   (setf (getf svc k) v))))
    (when (and groups (consp groups))
      ;; Mirrors Ruby's group_ids: resolve each group name to a GID via
      ;; `getent group <name>` (cut field 3). Non-existent groups drop
      ;; out so docker-compose doesn't get a literal name in group_add.
      (let ((gids (loop for g in groups
                        for line = (uiop:run-program
                                    (list "getent" "group" g)
                                    :output :string
                                    :ignore-error-status t)
                        for trimmed = (string-trim '(#\Space #\Tab #\Newline) line)
                        when (and trimmed (> (length trimmed) 0))
                          collect (parse-integer
                                   (third (uiop:split-string trimmed
                                                             :separator ":"))))))
        (when gids
          (setf svc (append svc (list :group-add gids))))))
    ;; The service name is data, not a plist-key — wrap as alist so the
    ;; emitter passes it through verbatim instead of running it through
    ;; the keyword->underscore conversion.
    (let ((compose (list :services (list (cons name svc)))))
      (unless (or use-vpn explicit-net-mode)
        (setf compose
              (append compose
                      (list :networks
                            (list :mediaserver
                                  (list :external t :name "mediaserver"))))))
      (with-output-to-string (s)
        (emit-yaml-block compose s 0)))))

;;; Render primitives.
;;;
;;; The Lisp side renders ONE template at a time, given a service
;;; context. Make is the dispatcher: it knows the path conventions
;;; (output target -> file layout), per-template dependencies, and
;;; which services to iterate. The CLI (cli.lisp) wraps these
;;; primitives for command-line use; tests call them directly.

(defun render-template-to-string (path context)
  "ELP-render PATH with CONTEXT (alist), return the rendered string."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (elp:render (probe-file path) context s))))

(defun %field-binding-symbol (key)
  "Convert :install-base -> install_base (a symbol in :mediaserver)."
  (intern (substitute #\_ #\- (symbol-name key)) :mediaserver))

(defun service-field-bindings (service globals)
  "Return an alist binding every key in *known-fields* (direct or
   derived) to its value on SERVICE, using Ruby-style underscored
   symbol names. Direct fields the service doesn't carry resolve
   to NIL via FIELD's default. Returns NIL when SERVICE is NIL.

   Templates can write <%= name %> / <%= compose_file %> /
   <%- (when use_vpn -%> instead of (field service :name) etc.

   A service field shadows a like-named global when both bind the
   same symbol; in practice this hasn't happened on real fixtures."
  (when service
    (mapcar (lambda (k)
              (cons (%field-binding-symbol k)
                    (field service k globals)))
            *known-fields*)))

(defun %dedup-alist (alist)
  "Return ALIST with duplicate keys removed; first occurrence wins.
   Needed because ELP wraps the context alist in a LET, and CL signals
   on duplicate variable bindings."
  (let ((seen (make-hash-table)) (result nil))
    (dolist (entry alist (nreverse result))
      (unless (gethash (car entry) seen)
        (setf (gethash (car entry) seen) t)
        (push entry result)))))

(defun service-render-context (service config)
  "Build the ELP context-alist for a render.

   Includes, in priority order (first wins on duplicates):
   - Per-service field bindings (only when SERVICE is non-nil) —
     every key in *known-fields*, named with underscores
     (e.g. install_base, compose_file, sighup_reload).
   - Underscored globals (install_base, media_path, hostname, plus
     any custom keys from config files).
   - SERVICE / SERVICES / GLOBALS, for templates that need raw plists
     (most commonly inside iteration loops over SERVICES)."
  (let ((globals  (getf config :globals))
        (services (getf config :services)))
    (%dedup-alist
     (append (service-field-bindings service globals)
             (globals->elp-context globals)
             (list (cons (intern "SERVICE"  :mediaserver) service)
                   (cons (intern "SERVICES" :mediaserver) services)
                   (cons (intern "GLOBALS"  :mediaserver) globals))))))
