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
      (apply #'elp:render (probe-file path) s context))))

(defun %field-binding-symbol (key)
  "Convert :install_base -> install_base (a symbol in :mediaserver).
   Used by WITH-SERVICE-SCOPE's symbol-macrolet, which exposes each
   field as a bare symbol in template bodies — distinct from the
   keyword keys used at the kwarg-dispatch boundary."
  (alexandria:ensure-symbol key :mediaserver))

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
   that field on SVC. Lets template bodies write `name` instead of
   (field :name svc).

   FIELD's globals fallback comes from the GLOBALS symbol in the ELP
   context. Expanded at template-compile time, so *KNOWN-FIELDS* must
   be populated — the normal LOAD-CONFIG path does this before any
   render. SVC is evaluated once."
  (unless *known-fields*
    (error "with-service-scope expanded before *known-fields* was set; ~
            ensure config is loaded before rendering."))
  (let ((svc-var (gensym "SVC")))
    `(let ((,svc-var ,svc))
       (symbol-macrolet
           ,(mapcar (lambda (k)
                      (list (%field-binding-symbol k)
                            `(field ,k ,svc-var globals)))
                    *known-fields*)
         ,@body))))

(defmacro loopservices ((source-form &key (where t)) &body body)
  "Iterate over services from SOURCE-FORM, exposing each service's
   fields as bare symbols (`name`, `port`, `public_url`, ...) within
   BODY and any :where clause.

   SOURCE-FORM is evaluated once in the enclosing scope. :WHERE, when
   given, is evaluated in field-scope per candidate; services for
   which it returns NIL are skipped."
  (let ((s (gensym "SVC")))
    `(dolist (,s ,source-form)
       (with-service-scope ,s
         (when ,where
           ,@body)))))

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
