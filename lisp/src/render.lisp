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
