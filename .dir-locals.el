;;; Project-local Emacs config. Tells SLIME to spawn SBCL via the
;;; project's launcher script instead of bare `sbcl`, so M-x slime
;;; lands in a REPL with :mediaserver loaded and the manifest read.
;;;
;;; First time you open a file in this project, Emacs will prompt to
;;; trust this file — that's the standard .dir-locals.el security
;;; gate, not a bug. Choose "!" to remember the trust.
;;;
;;; Path is relative to the directory containing this file (Emacs
;;; resolves dir-locals paths against the project root automatically).
;;; If you work inside a container, set $LISP_LAUNCHER in your shell
;;; before launching Emacs — the launcher script picks it up.

((nil . ((eval . (when (boundp 'slime-lisp-implementations)
                   (let* ((root (or (and buffer-file-name
                                         (locate-dominating-file
                                          buffer-file-name ".dir-locals.el"))
                                    default-directory))
                          (cmd (expand-file-name "script/start-image.sh" root)))
                     (setq-local slime-lisp-implementations
                                 `((mediaserver (,cmd)
                                                :coding-system utf-8-unix))))))))
 (lisp-mode . ((indent-tabs-mode . nil))))
