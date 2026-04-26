(defsystem "mediaserver"
  :description "Render media-server config from service.yml + ELP templates."
  :version "0.1.0"
  :author "Thomas Ramfjord"
  :license "MIT"
  :depends-on ("cl-yaml" "elp")
  :pathname "src/"
  :serial t
  :components
  ((:file "package")
   (:file "config"))
  :in-order-to ((test-op (test-op "mediaserver/tests"))))

(defsystem "mediaserver/tests"
  :description "Tests for mediaserver."
  :depends-on ("mediaserver" "fiveam")
  :pathname "test/"
  :serial t
  :components
  ((:file "package")))
