(defpackage :mediaserver
  (:use :cl)
  (:export
   ;; Loader
   :load-config
   :load-config-from-args
   ;; Field accessor + state
   :field
   :*globals*
   :*known-fields*
   ;; Manifest builder
   :derive-fields
   :emit-manifest
   :render-manifest
   :collect-known-fields
   ;; Render primitive
   :render-template-to-string
   ;; Template-scope macros (used inside .elp files)
   :with-service-scope
   :for-service
   :service-where
   :loop-services))
