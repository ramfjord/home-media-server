(defsystem "mediaserver"
  :description "Render media-server config from service.yml + ELP templates."
  :version "0.1.0"
  :author "Thomas Ramfjord"
  :license "MIT"
  :depends-on ("cl-yaml" "elp")
  :pathname "lisp/src/"
  :serial t
  :components
  ((:file "package")
   (:file "config")
   (:file "field")
   (:file "render")
   (:file "cli"))
  :in-order-to ((test-op (test-op "mediaserver/tests"))))

(defsystem "mediaserver/tests"
  :description "Tests for mediaserver."
  :depends-on ("mediaserver" "fiveam")
  :pathname "lisp/test/"
  :serial t
  :components
  ((:file "package")
   (:file "field-test")
   (:file "load-test")
   (:file "render-test")))
