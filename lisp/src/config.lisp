(in-package :mediaserver)

;;; YAML -> plist conversion
;;;
;;; cl-yaml returns hash-tables (EQUALP, string keys), nested
;;; maps as more hash-tables, sequences as conses, atoms as their
;;; native Lisp types (booleans -> T/NIL, integers, strings).
;;;
;;; We flatten to a plist with keyword keys at the load boundary.
;;; Underscores in YAML keys become hyphens in keywords:
;;; "use_vpn" -> :USE-VPN.

(defun yaml->plist (x)
  "Recursively convert cl-yaml output to keyword-keyed plists.
   Hash-tables become plists; conses are mapcar'd; atoms pass through."
  (etypecase x
    (hash-table (loop for k being the hash-keys of x using (hash-value v)
                      collect (intern (string-upcase (substitute #\- #\_ k))
                                      :keyword)
                      collect (yaml->plist v)))
    (cons       (mapcar #'yaml->plist x))
    (t          x)))
