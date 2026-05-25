(in-package :mediaserver)

;;; Render primitives.
;;;
;;; The Lisp side renders ONE template at a time, given a service
;;; context. Make is the dispatcher: it knows the path conventions
;;; (output target -> file layout), per-template dependencies, and
;;; which services to iterate. The CLI (cli.lisp) wraps these
;;; primitives for command-line use; tests call them directly.

(defun render-template-to-string (path context)
  "ELP-render PATH with CONTEXT (a plist of keyword->value), return
   the rendered string."
  (with-output-to-string (s)
    (let ((*package* (find-package :mediaserver)))
      (apply #'elp:render (elp:filepath-source (probe-file path)) s context))))

(defun find-service-by-name (key services-list)
  "Look up the service named KEY (a keyword like :radarr) in
   SERVICES-LIST by case-insensitive string match against :name.
   Errors when no match — typo guard for FOR-SERVICE."
  (or (find (symbol-name key) services-list
            :key (lambda (s) (field :name s))
            :test #'string-equal)
      (error "no service named ~S" key)))

(defun service-field-plist (service globals)
  "Plist binding every key in *KNOWN-FIELDS* (direct or derived) to
   its value on SERVICE, keyed by the field keywords. Direct fields
   the service doesn't carry resolve to NIL via FIELD's default.
   Returns NIL when SERVICE is NIL.

   This is the kwarg-shape that ELP:RENDER consumes — each pair
   becomes one keyword argument to the compiled template lambda.
   Templates write <%= name %> / <%= compose_file %> / <%- (when
   use_vpn -%>; the walker resolves the bare symbols against the
   matching :name / :compose_file / :use_vpn kwargs."
  (when service
    (loop for k in *known-fields*
          collect k
          collect (field k service globals))))

(defmacro with-service-scope (svc &body body)
  "Bind every key in *KNOWN-FIELDS* as a symbol-macro that looks up
   that field on SVC, and bind SERVICE to the raw plist itself. Lets
   BODY write `name` instead of (field :name svc), and `(getf service
   :x)` for the dynamic / single-consumer-optional case.

   The primitive binder. FOR-SERVICE, SERVICE-WHERE, and LOOP-SERVICES
   all expand through this — field access AND `service` are uniform
   across all three (previously `service` was reachable only in
   per-service fanout templates via the render context, making
   `(getf service :x)` a silent nil inside loop-services; binding it
   here closes that trap).

   `service` is anaphoric, consistent with the already-anaphoric
   `services` and `globals` in this scope. It is `ignorable` so the
   common body that never touches it stays style-warning-free.

   FIELD's globals fallback comes from the GLOBALS symbol in the ELP
   context. Expanded at template-compile time, so *KNOWN-FIELDS* must
   be populated — the normal LOAD-CONFIG path does this before any
   render. SVC is evaluated once."
  (unless *known-fields*
    (error "with-service-scope expanded before *known-fields* was set; ~
            ensure config is loaded before rendering."))
  (let ((svc-var (gensym "SVC"))
        (svc-sym (%field-binding-symbol :service)))
    `(let ((,svc-var ,svc))
       (let ((,svc-sym ,svc-var))
         (declare (ignorable ,svc-sym))
         (symbol-macrolet
             ,(mapcar (lambda (k)
                        (list (%field-binding-symbol k)
                              `(field ,k ,svc-var globals)))
                      *known-fields*)
           ,@body)))))

(defmacro for-service (key &body body)
  "Resolve KEY (a keyword like :radarr) to a service plist by name
   lookup against the SERVICES binding from the render context, then
   bind every field for BODY's scope via WITH-SERVICE-SCOPE.

   The file-top wrap for per-service .elp templates:

     <%- (for-service :radarr -%>
     ...template body referring to `name`, `port`, `group`, etc...
     <%- ) -%>"
  (let ((s (gensym "SVC")))
    `(let ((,s (find-service-by-name ,key services)))
       (with-service-scope ,s ,@body))))

(defmacro service-where (predicate)
  "Return the subset of SERVICES for which PREDICATE (evaluated in
   field-scope per service) returns non-nil. Compose with plain CL:

     (service-where (and dockerized port))
     (service-where (and (not (string= partof \"dashboard\")) port))

   Pass the result to LOOP-SERVICES, MAPCAR, etc. — it's just a list."
  (let ((s (gensym "SVC")))
    `(remove-if-not (lambda (,s) (with-service-scope ,s ,predicate))
                    services)))

(defmacro loop-services (source &body body)
  "Iterate SOURCE (a list of service plists), exposing each service's
   fields as bare symbols (`name`, `port`, `public_url`, ...) within
   BODY.

   To iterate every service: pass SERVICES directly. To iterate a
   filtered subset: build SOURCE with SERVICE-WHERE, e.g.

     (loop-services (service-where dockerized) ...)
     (loop-services (service-where (and use_vpn port)) ...)
     (loop-services services ...)   ; all services, no filter"
  (let ((s (gensym "SVC")))
    `(dolist (,s ,source)
       (with-service-scope ,s
         ,@body))))

(defun service-render-context (service config)
  "Build the plist of ELP keyword arguments for a render call.

   Priority order (highest wins on duplicates):
   - Per-service field bindings (only when SERVICE is non-nil) —
     every key in *known-fields* (e.g. :install_base, :compose_file,
     :sighup_reload).
   - Globals (already a plist with keyword keys: :install_base,
     :media_path, :hostname, plus any custom keys from config files).
   - :service / :services / :globals, for templates that need the
     raw plists (most commonly inside iteration loops over services).

   Duplicates are resolved via a hash: lower-priority sources are
   inserted first and overwritten by higher-priority sources, then
   the result is flattened back into a plist for APPLY to RENDER."
  (let ((globals  (getf config :globals))
        (services (getf config :services))
        (h (make-hash-table)))
    (flet ((merge-in (plist)
             (loop for (k v) on plist by #'cddr
                   do (setf (gethash k h) v))))
      (merge-in (list :service service :services services :globals globals))
      (merge-in globals)
      (merge-in (service-field-plist service globals)))
    (loop for k being the hash-keys of h using (hash-value v)
          collect k collect v)))
