(defpackage :mediaserver
  (:use :cl)
  (:export
   ;; Loader
   :load-config
   ;; Field accessor + state
   :field
   :*derived-fields*
   :*globals*
   ;; Render primitive
   :render-template-to-string))
