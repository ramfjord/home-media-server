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
   ;; Render primitive
   :render-template-to-string))
