(in-package :mediaserver)

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
  "Convert :install_base -> install_base (a symbol in :mediaserver)."
  (alexandria:ensure-symbol key :mediaserver))

(defun service-field-bindings (service globals)
  "Return an alist binding every key in *known-fields* (direct or
   derived) to its value on SERVICE, using Ruby-style underscored
   symbol names. Direct fields the service doesn't carry resolve
   to NIL via FIELD's default. Returns NIL when SERVICE is NIL.

   Templates can write <%= name %> / <%= compose_file %> /
   <%- (when use_vpn -%> instead of (field :name service) etc.

   A service field shadows a like-named global when both bind the
   same symbol; in practice this hasn't happened on real fixtures."
  (when service
    (mapcar (lambda (k)
              (cons (%field-binding-symbol k)
                    (field k service globals)))
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
             (list (cons (alexandria:ensure-symbol "SERVICE"  :mediaserver) service)
                   (cons (alexandria:ensure-symbol "SERVICES" :mediaserver) services)
                   (cons (alexandria:ensure-symbol "GLOBALS"  :mediaserver) globals))))))
