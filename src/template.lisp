;;;; template.lisp
;;;;
;;;; This file is part of the cl-closure-template library, released under Lisp-LGPL.
;;;; See file COPYING for details.
;;;;
;;;; Author: Moskvitin Andrey <archimag@gmail.com>

(in-package #:closure-template.parser)

(defparameter *lexer* nil)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *symbols-category* (make-hash-table)))

;;;; utils

(defun discard-parse-element ()
  (error 'wiki-parser:bad-element-condition))

(defun parse-expr-or-discard (expr)
  (handler-case
      (parse-expression expr)
    (error ()
      (discard-parse-element))))

(defun parse-arguments/impl (str)
  (let ((args nil))
    (ppcre:do-matches-as-strings (bind "\\w*=\"\\w*\"" str)
      (let ((eq-pos (position #\= bind)))
        (push (intern (string-upcase (subseq bind 0 eq-pos)) :keyword)
              args)
        (push (subseq bind (+ eq-pos 2) (1- (length bind)))
              args)))
    (nreverse args)))

(defun parse-arguments (str)
  (ppcre:register-groups-bind (args) ("^{\\w*\\s*((?:\\s*\\w*=\"\\w*\")*)\\s*}$" str)
    (parse-arguments/impl args)))

(defun parse-name-and-arguments (str)
  (ppcre:register-groups-bind (name args) ("^{\\w*\\s*([\\w-\\.]*)((?:\\s*\\w*=\"\\w*\")*)\\s*}$" str)
    (cons name
          (parse-arguments/impl args))))

;;;; closure template syntax
;;;; see http://code.google.com/intl/ru/closure/templates/docs/commands.html

(define-mode toplevel (0)
  (:allowed :baseonly eol one-line-comment multi-line-comment))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; comment
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode one-line-comment (20 :all)
  (:special "\\n//[^\\n]*(?=\\n)"))

(define-mode multi-line-comment (20 :all)
  (:entry "/\\*")
  (:exit "\\*/"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; substition
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode space-tag (20 :all)
  (:single "{sp}"))

(define-mode emptry-string (20 :all)
  (:single "{nil}"))

(define-mode carriage-return (20 :all)
  (:single "{\\\r}"))

(define-mode line-feed (20 :all)
  (:single "{\\\n}"))

(define-mode tab (20 :all)
  (:single "{\\\t}"))

(define-mode left-brace (20 :all)
  (:single "{lb}"))

(define-mode right-brace (20 :all)
  (:single "{rb}"))

(define-mode eol (30 :all)
  (:single "\\n"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; namespace tag
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun namespace-post-handler (item)
  (list 'namespace
        (string-trim #(#\Space #\Tab) (subseq (second item)
                                              (length "{namespace")
                                              (1- (length (second item)))))))

(define-mode namespace (10 :baseonly)
  (:special "{namespace\\s+[\\w\\.\\-]+\\s*}")
  (:post-handler namespace-post-handler))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; template tag
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode template (10 :baseonly)
  (:allowed :all)
  (:entry "{template[^}]*}(?=.*{/template})")
  (:entry-attribute-parser parse-name-and-arguments)
  (:exit "{/template}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; literag tag
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode literal (10 :all)
  (:entry "{literal}(?=.*{/literal})")
  (:exit "{/literal}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; print
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun print-tag-post-handler (obj)
  (or (ppcre:register-groups-bind (expr) ("^{(?:print\\s+)?([^\\s}]+)}$" (second obj))
        (list (car obj)
              (parse-expr-or-discard expr)))
      (discard-parse-element)))

(define-mode print-tag (200 :all)
  (:special "{print[^}]*}"
            "{[^}]*}")
  (:post-handler print-tag-post-handler))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; msg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode msg (30 :all)
  (:entry "{msg[^}]*}(?=.*{/msg})")
  (:entry-attribute-parser parse-arguments)
  (:exit "{/msg}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; if
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode elseif (10 :if)
  (:special "{elseif[^}]*}"))

(define-mode else-tag (10 :if)
  (:special "{else}"))

(define-mode if-tag (40 :all)
  (:allowed elseif else-tag)
  (:entry "{if[^}]*}(?=.*{/if})")
  (:exit "{/if}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; switch
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode case-tag (10 :switch)
  (:special "{\\s*case[^}]*}"))

(define-mode default-tag (10 :switch)
  (:special "{\\s*default\\s*}"))

(define-mode switch-tag (50 :all)
  (:allowed case-tag default-tag)
  (:entry "{switch[^}]*}(?=.*{/switch})")
  (:exit "{/switch}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; foreach
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun check-loop-variable (expr)
  (unless (and (consp expr)
               (eql :variable (car expr))
               (= (length expr) 2)
               (stringp (second expr)))
    (discard-parse-element))
  expr)

(defun parse-foreach-attributes (str)
  (or (ppcre:register-groups-bind (loop-var list-var) ("^{foreach\\s*([^\\s}]+)\\s*in\\s*([^\\s}]+)\\s*}$" str)
        (list (check-loop-variable (parse-expr-or-discard loop-var))
              (parse-expr-or-discard list-var))) 
      (discard-parse-element)))

(defun foreach-post-handler (item)
  (let ((parts (split-sequence:split-sequence 'ifempty
                                              (cddr item))))
    (when (> (length parts) 2)
      (discard-parse-element))
    (list* (car item)
           (second item)
           parts)))

(define-mode ifempty (10)
  (:single "{ifempty}"))

(define-mode foreach (60 :all)
  (:allowed :all ifempty)
  (:entry "{foreach\\s+[^}]*}(?=.*{/foreach})")
  (:entry-attribute-parser parse-foreach-attributes)
  (:exit "{/foreach}")
  (:post-handler foreach-post-handler))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; for
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun parse-for-attributes (str)
  (or (ppcre:register-groups-bind (loop-var expr) ("{for\\s+([^\\s]+)\\s+in\\s+([^}]*)}" str)
        (let ((p-expr (parse-expr-or-discard expr)))
          (unless (and (eql :range (car p-expr))
                       (second p-expr)
                       (< (length p-expr) 5))
            (discard-parse-element))
          (list (check-loop-variable (parse-expr-or-discard loop-var))
                p-expr)))
      (discard-parse-element)))

(define-mode for-tag (70 :all)
  (:entry "{for\\s+[^}]*}(?=.*{/for})")
  (:entry-attribute-parser parse-for-attributes)
  (:exit "{/for}"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; call
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode call (80 :all)
  (:allowed :all)
  (:entry "{call\\s*\\w*\\s*}(?=.*{/call})")
  (:exit "{/call}")
  (:entry-attribute-parser parse-name-and-arguments))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; css
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-mode css-tag (20 :all)
  (:special "{css[^}]*}"))

(wiki-parser:remake-lexer 'toplevel)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; parse-template
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod wiki-parser:parse ((markup (eql :closure-template.parser)) (obj string))
  (let* ((res (call-next-method markup (ppcre:regex-replace-all "\\s+" obj " ")))
         (namespace (iter (for item in res)
                          (finding (second item)
                                   such-that (and (consp item)
                                                  (eql (car item) 'namespace)))))
         (templates (iter (for item in res)
                          (if (and (consp item)
                                   (eql (car item) 'template))
                              (collect item)))))
    (list* 'namespace
           namespace
           templates)))
           
(defun parse-template (obj)
  (wiki-parser:parse :closure-template.parser obj))

(defun parse-single-template (obj)
  (third (parse-template obj)))
