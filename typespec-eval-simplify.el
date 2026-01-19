;;; typespec-eval-simplify.el --- Type simplification for typespec  -*- lexical-binding: t; -*-

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

;; Type simplification functions for typespec evaluation.
;; This module provides:
;; - `or` and `and` type simplification
;; - Type intersection
;; - rx pattern matching helpers

;;; Code:

(require 'rx)
(require 'seq)
(require 'typespec-eval-core)
(require 'typespec-eval-types)

(declare-function typespec-eval--eval "typespec-eval" (form))

;;; `or` type simplification

(defun typespec-eval-simplify-or (items)
  "Return a simplified `(or ...)` form for ITEMS."
  (declare (ftype (function (t) t)))
  (let ((flat nil))
    (dolist (item items)
      (setq flat
            (append flat
                    (if (and (consp item) (eq (car item) 'or))
                        (cdr item)
                      (list item)))))
    (setq items (seq-uniq (mapcar #'typespec-eval--normalize-const-nil flat)
                          #'equal)))
  (cond
   ((null items) 'never)
   ((null (cdr items)) (car items))
   ((equal items '((const t) (const nil))) 'boolean)
   ((equal items '((const nil) (const t))) 'boolean)
   (t (cons 'or items))))

;;; rx pattern helpers

(defsubst typespec-eval-simplify-rx-form-to-regexp (rx-form)
  "Return a regexp string for RX-FORM, or nil if it is not `(rx ...)`."
  (when (and (consp rx-form) (eq (car rx-form) 'rx))
    (rx-to-string (cons 'seq (cdr rx-form)) t)))

(defun typespec-eval-simplify-const-string-matches-rx-p (string rx-form)
  "Return non-nil if STRING matches RX-FORM."
  (let ((regexp (typespec-eval-simplify-rx-form-to-regexp rx-form)))
    (when regexp
      (string-match-p regexp string))))

;;; Type intersection

(defun typespec-eval-simplify-intersect-integer-types (lhs rhs)
  "Return the intersection of integer-like LHS and RHS."
  (cond
   ((equal lhs rhs) lhs)
   ((memq lhs '(int integer)) rhs)
   ((memq rhs '(int integer)) lhs)
   ((and (typespec-eval--integer-range-p lhs)
         (typespec-eval--integer-range-p rhs))
    (let ((low (max (cadr lhs) (cadr rhs)))
          (high (min (caddr lhs) (caddr rhs))))
      (if (and (numberp low) (numberp high) (> low high))
          'never
        (typespec-eval--integer-range low high))))
   (t nil)))

(defun typespec-eval-simplify-intersect-number-types (lhs rhs)
  "Return the intersection of number-like LHS and RHS."
  (cond
   ((and (typespec-eval-types-integer-type-p lhs)
         (typespec-eval-types-integer-type-p rhs))
    (or (typespec-eval-simplify-intersect-integer-types lhs rhs) 'integer))
   ((and (typespec-eval-types-float-type-p lhs)
         (typespec-eval-types-float-type-p rhs))
    'float)
   ((and (typespec-eval-types-integer-type-p lhs)
         (typespec-eval-types-float-type-p rhs))
    'never)
   ((and (typespec-eval-types-float-type-p lhs)
         (typespec-eval-types-integer-type-p rhs))
    'never)
   ((and (typespec-eval-types-number-type-p lhs)
         (typespec-eval-types-number-type-p rhs))
    (cond
     ((typespec-eval-types-integer-type-p lhs) lhs)
     ((typespec-eval-types-integer-type-p rhs) rhs)
     ((typespec-eval-types-float-type-p lhs) lhs)
     ((typespec-eval-types-float-type-p rhs) rhs)
     (t 'number)))
   (t nil)))

;;; `and` type merge and simplification

(defun typespec-eval-simplify-and-merge (lhs rhs)
  "Return the intersection of LHS and RHS for `and` types."
  (cond
   ((or (eq lhs 'never) (eq rhs 'never)) 'never)
   ((or (equal lhs '(const nil)) (equal rhs '(const nil))) 'never)
   ((equal lhs '(const t)) rhs)
   ((equal rhs '(const t)) lhs)
   ((eq lhs 'unknown) rhs)
   ((eq rhs 'unknown) lhs)
   ((eq lhs 'mixed) rhs)
   ((eq rhs 'mixed) lhs)
   ((and (typespec-eval--const-p lhs)
         (typespec-eval--const-p rhs))
    (if (equal lhs rhs) lhs 'never))
   ((and (typespec-eval--const-p lhs)
         (typespec-eval-types-rx-type-p rhs))
    (let ((val (typespec-eval--const-value lhs)))
      (cond
       ((and (stringp val)
             (typespec-eval-simplify-const-string-matches-rx-p val rhs))
        lhs)
       ((stringp val) 'never)
       (t 'never))))
   ((and (typespec-eval--const-p rhs)
         (typespec-eval-types-rx-type-p lhs))
    (let ((val (typespec-eval--const-value rhs)))
      (cond
       ((and (stringp val)
             (typespec-eval-simplify-const-string-matches-rx-p val lhs))
        rhs)
       ((stringp val) 'never)
       (t 'never))))
   ((and (typespec-eval--const-p lhs)
         (typespec-eval-types-string-type-p rhs))
    (let ((val (typespec-eval--const-value lhs)))
      (if (stringp val) lhs 'never)))
   ((and (typespec-eval--const-p rhs)
         (typespec-eval-types-string-type-p lhs))
    (let ((val (typespec-eval--const-value rhs)))
      (if (stringp val) rhs 'never)))
   ((and (typespec-eval-types-rx-type-p lhs)
         (typespec-eval-types-string-type-p rhs))
    lhs)
   ((and (typespec-eval-types-string-type-p lhs)
         (typespec-eval-types-rx-type-p rhs))
    rhs)
   ((and (or (typespec-eval-types-number-type-p lhs)
             (typespec-eval-types-integer-type-p lhs)
             (typespec-eval-types-float-type-p lhs))
         (or (typespec-eval-types-number-type-p rhs)
             (typespec-eval-types-integer-type-p rhs)
             (typespec-eval-types-float-type-p rhs)))
    (or (typespec-eval-simplify-intersect-number-types lhs rhs) (list 'and lhs rhs)))
   (t (list 'and lhs rhs))))

(defun typespec-eval-simplify-and (items)
  "Return a simplified `(and ...)` form for ITEMS."
  (let ((items (delq nil items)))
    (cond
     ((null items) 'mixed)
     (t
      (catch 'typespec-eval--and
        (let ((result nil))
          (dolist (item items)
            (setq result (if result (typespec-eval-simplify-and-merge result item) item))
            (when (eq result 'never)
              (throw 'typespec-eval--and result)))
          (or result 'mixed)))))))

;;; Const value helpers

(defun typespec-eval-simplify-string-or-char-p (val)
  "Return non-nil if VAL is a string or character."
  (or (stringp val) (characterp val)))

(defun typespec-eval-simplify-map-const-or (arg fn &optional fallback)
  "Apply FN to const values inside ARG; otherwise return FALLBACK.

ARG should already be evaluated.  FN receives an evaluated item and should
return a `(const ...)` form or nil.  If ARG is an `(or ...)` of consts and
all map successfully, return a simplified `(or ...)` of results."
  (cond
   ((and (consp arg) (eq (car arg) 'or))
    (let ((items nil)
          (ok t))
      (dolist (item (cdr arg))
        (let ((res (funcall fn item)))
          (if res
              (push res items)
            (setq ok nil))))
      (if ok
          (typespec-eval-simplify-or (nreverse items))
        fallback)))
   (t (or (funcall fn arg) fallback))))

(defun typespec-eval-simplify-unary-const-fold (arg fn pred &optional type-in type-out type-p fallback)
  "Apply unary FN over ARG with constant folding and type inference.

ARG is evaluated via `typespec-eval--eval'.
FN is the function to apply to const values; PRED is a predicate to
check if a value can be processed (when const), and must hold for
the value before calling FN.
TYPE-IN, when given and ARG matches it, yields TYPE-OUT (defaults to TYPE-IN).
TYPE-P, when given, is a predicate on the evaluated form; if it
holds, return TYPE-OUT.
FALLBACK is returned when no rule matches (default: `unknown')."
  (let* ((arg (typespec-eval--eval arg))
         (type-out (or type-out type-in))
         (fallback (or fallback 'unknown))
         (mapped
          (typespec-eval-simplify-map-const-or
           arg
           (lambda (item)
             (when (typespec-eval--const-p item)
               (let ((val (typespec-eval--const-value item)))
                 (when (funcall pred val)
                   (typespec-eval--make-const (funcall fn val)))))))))
    (cond
     (mapped mapped)
     ((and type-in (eq arg type-in)) type-out)
     ((and type-p (funcall type-p arg)) type-out)
     (t fallback))))

(defun typespec-eval-simplify-literal-const (form)
  "Return a `(const VALUE)` for literal constants in FORM, or nil."
  (cond
   ((null form) (typespec-eval--make-const nil))
   ((numberp form) (typespec-eval--make-const form))
   ((stringp form) (typespec-eval--make-const form))
   ((characterp form) (typespec-eval--make-const form))
   ((keywordp form) (typespec-eval--make-const form))
   (t nil)))

;;; Const options and concat

(defun typespec-eval-simplify-const-string-options (form)
  "Return list of constant strings for FORM, or nil if unknown."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (cond
       ((stringp val) (list val))
       ((characterp val) (list (string val)))
       (t nil))))
   ((and (consp form) (eq (car form) 'or))
    (let ((strings nil)
          (ok t))
      (dolist (item (cdr form))
        (let ((opts (typespec-eval-simplify-const-string-options item)))
          (if opts
              (setq strings (append strings opts))
            (setq ok nil))))
      (and ok strings)))
   (t nil)))

(defun typespec-eval-simplify-const-regexp-options (form)
  "Return list of regexp strings for FORM, or nil if unknown."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (stringp val) (list val))))
   ((typespec-eval-types-rx-type-p form)
    (let ((regexp (typespec-eval-simplify-rx-form-to-regexp form)))
      (when regexp (list regexp))))
   ((and (consp form) (eq (car form) 'or))
    (let ((regexps nil)
          (ok t))
      (dolist (item (cdr form))
        (let ((opts (typespec-eval-simplify-const-regexp-options item)))
          (if opts
              (setq regexps (append regexps opts))
            (setq ok nil))))
      (and ok regexps)))
   (t nil)))

(defun typespec-eval-simplify-concat-combinations (options-list)
  "Return concatenation results from OPTIONS-LIST or nil if too many."
  (let ((results '(""))
        (limit 20))
    (catch 'too-many
      (dolist (opts options-list)
        (let ((next nil))
          (dolist (prefix results)
            (dolist (suffix opts)
              (push (concat prefix suffix) next)
              (when (> (length next) limit)
                (throw 'too-many nil))))
          (setq results (nreverse next))))
      results)))

(provide 'typespec-eval-simplify)
;;; typespec-eval-simplify.el ends here
