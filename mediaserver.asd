(defsystem "mediaserver"
  :description "Render media-server config from service.yml + ELP templates."
  :version "0.1.0"
  :author "Thomas Ramfjord"
  :license "MIT"
  :depends-on ("cl-yaml" "elp" "str" "alexandria" "serapeum" "clingon")
  :serial t
  :components
  ((:module "lib"
    :pathname "lisp/src/"
    :serial t
    :components ((:file "package")
                 (:file "field")
                 (:file "derive")
                 (:file "yaml")
                 (:file "config")
                 (:file "render")))
   (:module "cli"
    :pathname "lisp/cli/"
    :components ((:file "render")
                 (:file "build-service-config"))))
  :in-order-to ((test-op (test-op "mediaserver/tests"))))

(defsystem "mediaserver/tests"
  :description "Tests for mediaserver."
  :depends-on ("mediaserver" "fiveam")
  :pathname "lisp/test/"
  :serial t
  :components
  ((:file "package")
   (:file "field-test")
   (:file "render-test")))
