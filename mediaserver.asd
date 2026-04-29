(defsystem "mediaserver"
  :description "Render media-server config from service.yml + ELP templates."
  :version "0.1.0"
  :author "Thomas Ramfjord"
  :license "MIT"
  :depends-on ("cl-yaml" "elp" "str" "alexandria")
  :pathname "lisp/src/"
  :serial t
  :components
  ((:file "package")
   (:file "field")
   (:file "derive")
   (:file "config")
   (:file "render")
   (:file "cli"))
  :in-order-to ((test-op (test-op "mediaserver/tests"))))

(defsystem "mediaserver/build"
  :description "Build the services manifest yaml from service.yml inputs."
  :depends-on ("mediaserver")
  :pathname "lisp/src/"
  :serial t
  :components ((:file "build-cli")))

(defsystem "mediaserver/tests"
  :description "Tests for mediaserver."
  :depends-on ("mediaserver" "fiveam")
  :pathname "lisp/test/"
  :serial t
  :components
  ((:file "package")
   (:file "field-test")
   (:file "render-test")))
