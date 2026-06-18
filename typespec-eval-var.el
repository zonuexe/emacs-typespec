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
(require 'typespec-builtins)

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
    ('hook '(hook (function () t)))
    (_ sym)))

(defconst typespec-eval-var--custom-keywords
  '(:args :tag :menu-tag :value :doc :format :complete :completions
    :options :match-alternatives :key-type :value-type)
  "Known custom type keyword arguments to ignore when parsing.")

(defun typespec-eval-var--custom-keyword-p (value)
  "Return non-nil if VALUE is a known custom type keyword."
  (and (keywordp value)
       (memq value typespec-eval-var--custom-keywords)))

(defun typespec-eval-var--custom-strip-keywords (form)
  "Return FORM with custom keyword arguments removed."
  (cond
   ((consp form)
    (let ((out nil)
          (tail form))
      (while tail
        (let ((item (car tail)))
          (if (typespec-eval-var--custom-keyword-p item)
              (setq tail (cddr tail))
            (push (typespec-eval-var--custom-strip-keywords item) out)
            (setq tail (cdr tail)))))
      (nreverse out)))
   (t form)))

(defun typespec-eval-var--custom-args (form)
  "Return positional arguments from custom type FORM."
  (let ((args nil)
        (tail (cdr form)))
    (while tail
      (cond
       ((eq (car tail) :args)
        (setq args (cadr tail))
        (setq tail nil))
       ((typespec-eval-var--custom-keyword-p (car tail))
        (setq tail (cddr tail)))
       (t
        (push (car tail) args)
        (setq tail (cdr tail)))))
    (nreverse args)))

(defun typespec-eval-var--custom-kw (form key default)
  "Return KEY value from custom type FORM, or DEFAULT."
  (let ((tail (cdr form))
        (value default))
    (while tail
      (when (eq (car tail) key)
        (setq value (cadr tail)))
      (setq tail (cddr tail)))
    value))

(defun typespec-eval-var--completion-const (value fallback)
  "Return a `(const ...)` for VALUE based on FALLBACK type."
  (cond
   ((eq fallback 'string)
    (cond
     ((stringp value) (list 'const value))
     ((symbolp value) (list 'const (symbol-name value)))
     (t nil)))
   (t
    (cond
     ((symbolp value) (list 'const value))
     ((stringp value) (list 'const (intern value)))
     (t nil)))))

(defun typespec-eval-var--custom-completions-to-typespec (form fallback)
  "Return typespec from :completions in FORM or FALLBACK."
  (let ((completions (typespec-eval-var--custom-kw form :completions nil)))
    (if (and (listp completions) completions)
        (cons 'or (delq nil (mapcar (lambda (item)
                                      (typespec-eval-var--completion-const item fallback))
                                    completions)))
      fallback)))

(defun typespec-eval-var--custom-hook-options (form)
  "Return a `:options (member ...)` clause for FORM or nil."
  (let ((options (typespec-eval-var--custom-kw form :options nil))
        (items nil))
    (when (and (listp options) options)
      (dolist (item options)
        (pcase item
          ((pred symbolp) (push item items))
          (`(,sym . ,_) (when (symbolp sym) (push sym items)))))
      (when items
        (list :options (cons 'member (nreverse items)))))))

(defun typespec-eval-var--custom-type-to-typespec (form)
  "Convert custom type FORM into a typespec form."
  (pcase form
    ((pred symbolp)
     (typespec-eval-var--custom-type-symbol form))
    (`(hook . ,_)
     (let ((opts (typespec-eval-var--custom-hook-options form)))
       (if opts
           (append '(hook (function () t)) opts)
         '(hook (function () t)))))
    (`(string . ,_)
     (typespec-eval-var--custom-completions-to-typespec form 'string))
    (`(symbol . ,_)
     (typespec-eval-var--custom-completions-to-typespec form 'symbol))
    (`(cons . ,_)
     (let* ((args (typespec-eval-var--custom-args form))
            (a (nth 0 args))
            (b (nth 1 args)))
       (if (and a b)
           (list 'cons (typespec-eval-var--custom-type-to-typespec a)
                 (typespec-eval-var--custom-type-to-typespec b))
         'unknown)))
    (`(list . ,_)
     (cons :tuple
           (mapcar #'typespec-eval-var--custom-type-to-typespec
                   (typespec-eval-var--custom-args form))))
    (`(group . ,_)
     (cons :tuple
           (mapcar #'typespec-eval-var--custom-type-to-typespec
                   (typespec-eval-var--custom-args form))))
    (`(vector . ,_)
     (list 'vector
           (cons 'or (mapcar #'typespec-eval-var--custom-type-to-typespec
                             (typespec-eval-var--custom-args form)))))
    (`(alist . ,_)
     (let ((key-type (typespec-eval-var--custom-kw form :key-type 'sexp))
           (value-type (typespec-eval-var--custom-kw form :value-type 'sexp)))
       (list :alist
             (typespec-eval-var--custom-type-to-typespec key-type)
             (typespec-eval-var--custom-type-to-typespec value-type))))
    (`(plist . ,_)
     (let ((key-type (typespec-eval-var--custom-kw form :key-type 'symbol))
           (value-type (typespec-eval-var--custom-kw form :value-type 'sexp)))
       (list :plist
             (typespec-eval-var--custom-type-to-typespec key-type)
             (typespec-eval-var--custom-type-to-typespec value-type))))
    (`(choice . ,_)
     (cons 'or (mapcar #'typespec-eval-var--custom-type-to-typespec
                       (typespec-eval-var--custom-args form))))
    (`(radio . ,_)
     (cons 'or (mapcar #'typespec-eval-var--custom-type-to-typespec
                       (typespec-eval-var--custom-args form))))
    (`(const . ,_)
     (let* ((args (typespec-eval-var--custom-args form))
            (value (car args)))
       (if (null args) 'unknown (list 'const value))))
    (`(other . ,_)
     (let ((value (car (typespec-eval-var--custom-args form))))
       (if (null value) 'mixed (list 'const value))))
    (`(function-item . ,_)
     (let ((fn (car (typespec-eval-var--custom-args form))))
       (if fn (list 'const fn) 'unknown)))
    (`(variable-item . ,_)
     (let ((var (car (typespec-eval-var--custom-args form))))
       (if var (list 'const var) 'unknown)))
    (`(set . ,_)
     (list 'list (cons 'or (mapcar #'typespec-eval-var--custom-type-to-typespec
                                   (typespec-eval-var--custom-args form)))))
    (`(repeat . ,_)
     (let ((item (car (typespec-eval-var--custom-args form))))
       (if item
           (list 'list (typespec-eval-var--custom-type-to-typespec item))
         'unknown)))
    (`(restricted-sexp . ,_)
     (let ((criteria (typespec-eval-var--custom-kw form :match-alternatives nil))
           (consts nil)
           (has-predicate nil))
       (when (and criteria (listp criteria))
         (dolist (item criteria)
           (pcase item
             (`(quote ,value) (push (list 'const value) consts))
             ((pred symbolp) (setq has-predicate t)))))
       (cond
        ((and has-predicate consts) (cons 'or (append (nreverse consts) '(mixed))))
        (has-predicate 'mixed)
        (consts (cons 'or (nreverse consts)))
        (t 'mixed))))
    (_
     (let ((stripped (typespec-eval-var--custom-strip-keywords form)))
       (pcase stripped
         (`(,sym) (and (symbolp sym) (typespec-eval-var--custom-type-symbol sym)))
         ((pred symbolp) (typespec-eval-var--custom-type-symbol stripped))
         (_ 'unknown))))))

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
