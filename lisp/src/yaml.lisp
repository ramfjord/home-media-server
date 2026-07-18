(in-package :mediaserver)

;;; YAML <-> plist bridge.
;;;
;;; cl-yaml represents YAML maps as hash-tables (string keys) and
;;; sequences as conses; we work internally with keyword-keyed plists.
;;; This file holds everything that translates between the two shapes,
;;; on both the parse and emit sides, plus the round-trip-safety method
;;; on yaml.emitter:emit-object.

(defun plistp (x)
  "True for proper plists with keyword keys (cheap structural check)."
  (and (consp x)
       (evenp (length x))
       (loop for k in x by #'cddr always (keywordp k))))

;;; Parse side: cl-yaml output -> plist.
;;;
;;; cl-yaml returns hash-tables (EQUALP, string keys), nested maps as
;;; more hash-tables, sequences as conses, atoms as native Lisp types
;;; (booleans -> T/NIL, integers, strings).
;;;
;;; We flatten to plists with keyword keys; YAML keys carry through
;;; verbatim (so "use_vpn" -> :USE_VPN). Underscores match the YAML
;;; convention; the codebase uses :foo_bar uniformly.

(defun yaml->plist (x)
  "Recursively convert cl-yaml output to keyword-keyed plists.
   Hash-tables become plists; conses are mapcar'd; atoms pass through."
  (etypecase x
    (hash-table (loop for k being the hash-keys of x using (hash-value v)
                      collect (alexandria:make-keyword (string-upcase k))
                      collect (yaml->plist v)))
    (cons       (mapcar #'yaml->plist x))
    (t          x)))

(defun read-yaml-file (path)
  "Read PATH as plain YAML, returning a plist (or NIL for missing file
   or empty contents)."
  (let ((p (probe-file path)))
    (when p
      (let ((parsed (cl-yaml:parse p)))
        (and parsed (yaml->plist parsed))))))

;;; Emit side: plist -> cl-yaml's expected hash-table+cons shape.

(defun plist-tree->dict (x)
  "Recursively convert map-shaped data in X into equal hash-tables:
     - keyword-keyed plists  -> dict with str:downcased keys
     - alists with string cars -> dict with literal string keys
   Plain lists pass through; their elements are recursed."
  (cond
    ((plistp x)
     (let ((h (make-hash-table :test 'equal)))
       (loop for (k v) on x by #'cddr
             do (setf (gethash (str:downcase (symbol-name k)) h)
                      (plist-tree->dict v)))
       h))
    ((and (consp x) (consp (car x)) (stringp (caar x)))
     (let ((h (make-hash-table :test 'equal)))
       (dolist (entry x)
         (setf (gethash (car entry) h) (plist-tree->dict (cdr entry))))
       h))
    ((listp x) (mapcar #'plist-tree->dict x))
    (t x)))

;;; YAML scalar round-trip safety.
;;;
;;; cl-yaml's default emit writes strings as plain scalars. A string
;;; like "true" or "9090" then re-parses as a bool/int — silently
;;; mutating the value's type. Force-quote strings that would round-trip
;;; to a different type so source intent is preserved (matters for
;;; docker labels, user IDs, etc.).

(defun yaml-ambiguous-string-p (s)
  "True for strings that, emitted as a plain YAML scalar, would parse
   back as a different type (int, bool, null), or that carry ELP
   template tags we want to preserve verbatim through the round-trip."
  (or (member s '("true" "false" "yes" "no" "null" "~") :test #'equal)
      (and (> (length s) 0) (every #'digit-char-p s))
      (search "<%" s)
      (search "%>" s)))

(defmethod yaml.emitter:emit-object (em (obj string))
  (yaml.emitter:emit-scalar em obj
    :style (if (yaml-ambiguous-string-p obj)
               :single-quoted-scalar-style
               :plain-scalar-style)))

;;; Upstream fix: cl-yaml's emit-scalar (src/emitter.lisp) passes
;;; (length printed-value) — a CHARACTER count — as libyaml's
;;; scalar_event length, which is specified in BYTES of the UTF-8
;;; encoding. CFFI hands libyaml the encoded octets, so any scalar
;;; containing non-ASCII is truncated by exactly (bytes - chars): a
;;; string with four em-dashes silently loses its last 8 characters.
;;;
;;; It bites manifest values that carry prose, i.e. the `api_resources`
;;; literal blocks, and it fails silently — the truncation lands at the
;;; end of the value, so it only became visible once a block ended in
;;; load-bearing content rather than a trailing comment.
;;;
;;; Redefining the function rather than forking cl-yaml keeps the fix in
;;; one readable place; re-check it after `qlot update cl-yaml`.
(defun yaml.emitter::emit-scalar (emitter value &rest rest
                                  &key anchor tag plain-implicit
                                       quoted-implicit style)
  (declare (ignorable anchor tag plain-implicit quoted-implicit style))
  (let ((printed-value (yaml.emitter::print-scalar value)))
    (apply #'yaml.emitter::scalar-event
           (yaml.emitter::foreign-event emitter)
           printed-value
           (babel:string-size-in-octets printed-value :encoding :utf-8)
           rest)
    (libyaml.emitter:emit (yaml.emitter::foreign-emitter emitter)
                          (yaml.emitter::foreign-event emitter))))

;;; JSON emission — same plist-tree shape, JSON output.
;;; Used by templates that produce JSON config files (e.g. docker daemon.json).

(defun plist-tree->json-string (x)
  "Encode plist tree X as a JSON string. Plists become objects, lists
   become arrays, atoms pass through to yason."
  (with-output-to-string (s)
    (yason:encode (plist-tree->dict x) s)))

;;; Manifest emission.

(defun emit-manifest (cfg stream)
  "Emit CFG (a plist with :globals and :services) as block-style YAML
   to STREAM. The output round-trips back to an equivalent CFG via
   cl-yaml:parse + yaml->plist."
  (yaml:with-emitter-to-stream (em stream)
    (yaml:emit-pretty-as-document em (plist-tree->dict cfg))))
