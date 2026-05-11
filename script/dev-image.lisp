;;;; Dev-image init: start swank-lsp for editor LSP integration.

(in-package :cl-user)

;; Make sure ASDF can find :mediaserver — its .asd lives in lisp/
;; relative to this script's parent.
(pushnew (merge-pathnames "lisp/"
                          (make-pathname :defaults *load-pathname*
                                         :directory (butlast (pathname-directory *load-pathname*))
                                         :name nil :type nil))
         asdf:*central-registry* :test #'equal)

(ql:quickload :mediaserver :silent t)

(ql:quickload :swank-lsp :silent t)

;; ELP and swank-lsp don't know about each other — this project uses
;; both, so it wires them here. ELP extracts the embedded Lisp from
;; .elp templates; the default-package tells swank-lsp's hover machinery
;; which package to resolve symbols in when the extracted text has no
;; explicit (in-package …) form.
(swank-lsp:register-byte-stream-translator "elp"
  (lambda (uri text) (declare (ignore uri)) (elp:extract-code-text text)))
(swank-lsp:use-default-package-for-extension "elp" "mediaserver")

;; In docker the internal port is fixed (7777) so compose's port mapping
;; has something concrete to forward to; SWANK_LSP_HOST_PORT carries the
;; host-side port nvim should dial. Outside docker, :port 0 picks any
;; free port and the file gets the actual bound number. Bind
;; *default-pathname-defaults* to the project root so .swank-lsp-port
;; lands where nvim's plugin looks for it (root, not lisp/).
(let* ((project-root
         (truename (make-pathname :defaults *load-pathname*
                                  :directory (butlast (pathname-directory *load-pathname*))
                                  :name nil :type nil)))
       (*default-pathname-defaults* project-root)
       (advertise-port
         (let ((env (uiop:getenv "SWANK_LSP_HOST_PORT")))
           (and env (ignore-errors (parse-integer env)))))
       (internal-port (if advertise-port 7777 0)))
  (swank-lsp:start-and-publish :port internal-port
                               :advertise-port advertise-port))

(format t "~&;; dev-image: ready~%")
