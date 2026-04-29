(in-package :mediaserver)

;;; Plist <-> hash-table shape transforms.
;;;
;;; Our internal data shape is keyword-keyed plists (yaml->plist
;;; output). cl-yaml's emit takes hash-tables for maps. PLIST-TREE->DICT
;;; bridges the two by recursively converting plists to equal
;;; hash-tables; lists pass through (with their elements recursed),
;;; atoms pass through.

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
   back as a different type (int, bool, null)."
  (or (member s '("true" "false" "yes" "no" "null" "~") :test #'equal)
      (and (> (length s) 0) (every #'digit-char-p s))))

(defmethod yaml.emitter:emit-object (em (obj string))
  (yaml.emitter:emit-scalar em obj
    :style (if (yaml-ambiguous-string-p obj)
               :single-quoted-scalar-style
               :plain-scalar-style)))
