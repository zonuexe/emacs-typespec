;;; typespec-eval-var.el --- Variable resolution helpers for typespec  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  USAMI Kenta

;; Author: USAMI Kenta <tadsan@zonu.me>
;; Keywords: lisp, extensions

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Helpers for resolving `(var SYMBOL)` and `(value-of ...)` expressions.

;;; Code:

(require 'seq)
(require 'typespec-eval-core)

(defun typespec-eval-var--symbol (sym)
  "Return the symbol referenced by SYM, or nil."
  (pcase sym
    (`(quote ,name) (and (symbolp name) name))
    ((pred symbolp) sym)
    (_ nil)))

(defun typespec-eval-var--defconst-symbol-p (sym)
  "Return non-nil if SYM is defined by `defconst`."
  (and (eq (get sym 'risky-local-variable) t)
       (stringp (symbol-file sym 'defvar))))

(defun typespec-eval-var--custom-strip-keywords (form)
  "Return FORM with custom keyword arguments removed."
  (cond
   ((consp form)
    (let ((out nil)
          (tail form))
      (while tail
        (let ((item (car tail)))
          (if (and (symbolp item) (keywordp item))
              (setq tail (cddr tail))
            (push (typespec-eval-var--custom-strip-keywords item) out)
            (setq tail (cdr tail)))))
      (nreverse out)))
   (t form)))

(defun typespec-eval-var--custom-type-symbol (sym)
  "Return a typespec symbol for custom type SYM."
  (pcase sym
    ('sexp 'mixed)
    ('symbol 'symbol)
    ('variable 'symbol)
    ('face 'symbol)
    ('coding-system 'symbol)
    ('fringe-bitmap 'symbol)
    ('keyword 'keyword)
    ('string 'string)
    ('regexp 'string)
    ('file 'string)
    ('directory 'string)
    ('color 'string)
    ('key 'string)
    ('key-sequence 'string)
    ('character 'character)
    ('boolean 'boolean)
    ('number 'number)
    ('integer 'integer)
    ('natnum '(integer 0 *))
    ('float 'float)
    ('function 'function)
    ('hook '(list function))
    (_ sym)))

(defun typespec-eval-var--custom-type-to-typespec (form)
  "Convert custom type FORM into a typespec form."
  (let ((form (typespec-eval-var--custom-strip-keywords form)))
    (pcase form
      (`(repeat ,item)
       (list 'list (typespec-eval-var--custom-type-to-typespec item)))
      (`(cons ,a ,b)
       (list 'cons (typespec-eval-var--custom-type-to-typespec a)
             (typespec-eval-var--custom-type-to-typespec b)))
      (`(choice . ,items)
       (cons 'or (mapcar #'typespec-eval-var--custom-type-to-typespec items)))
      (`(const ,value)
       (list 'const value))
      (`(,sym) (and (symbolp sym) (typespec-eval-var--custom-type-symbol sym)))
      ((pred symbolp) (typespec-eval-var--custom-type-symbol form))
      (_ 'unknown))))

(defun typespec-eval-var--const-type (value)
  "Return a typespec form for constant VALUE."
  (cond
   ((and (consp value) (typespec-eval--list-of-symbols-p value))
    (cons :tuple (mapcar #'typespec-eval--make-const value)))
   (t (typespec-eval--make-const value))))

(defun typespec-eval-var--eval (sym)
  "Evaluate `(var SYM)` using defconst/defcustom metadata."
  (let ((sym (typespec-eval-var--symbol sym)))
    (cond
     ((null sym) 'unknown)
     ((and (boundp sym) (typespec-eval-var--defconst-symbol-p sym))
      (typespec-eval-var--const-type (symbol-value sym)))
     ((and (fboundp 'custom-variable-p)
           (custom-variable-p sym))
      (let* ((custom-type (if (fboundp 'custom-variable-type)
                              (custom-variable-type sym)
                            (get sym 'custom-type)))
             (custom-type (and custom-type
                               (typespec-eval-var--custom-type-to-typespec
                                custom-type))))
        (when custom-type
          (list 'unresolved custom-type))))
     (t (list 'var (list 'quote sym))))))

(provide 'typespec-eval-var)

;;; typespec-eval-var.el ends here
