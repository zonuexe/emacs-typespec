;;; typespec-eval-core.el --- Core helpers for typespec evaluation  -*- lexical-binding: t; -*-

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

;; Shared helper functions used across typespec evaluators.

;;; Code:

(require 'seq)

(defsubst typespec-eval--const-p (form)
  "Return non-nil if FORM is a `(const VALUE)` expression."
  (and (consp form)
       (eq (car form) 'const)
       (consp (cdr form))
       (null (cddr form))))

(defsubst typespec-eval--const-value (form)
  "Return the VALUE from a `(const VALUE)` FORM."
  (cadr form))

(defsubst typespec-eval--unconst (form)
  "Return FORM without a const wrapper when possible."
  (if (typespec-eval--const-p form)
      (typespec-eval--const-value form)
    form))

(defsubst typespec-eval--type-eq-p (sym)
  "Return a predicate that check if FORM equals SYM."
  (lambda (form) (eq form sym)))

(defsubst typespec-eval--make-const (value)
  "Return a `(const VALUE)` expression."
  (list 'const value))

(defsubst typespec-eval--non-empty-string-expr ()
  "Return the canonical non-empty string type expression."
  '(and string (not (const ""))))

(defsubst typespec-eval--non-empty-string-p (form)
  "Return non-nil if FORM is known to be a non-empty string."
  (cond
   ((and (typespec-eval--const-p form)
         (stringp (typespec-eval--const-value form)))
    (> (length (typespec-eval--const-value form)) 0))
   ((equal form (typespec-eval--non-empty-string-expr)) t)
   (t nil)))

(defsubst typespec-eval--always-nil-p (form)
  "Return non-nil if FORM is known to be nil."
  (or (equal form '(const nil))
      (eq form 'null)))

(defsubst typespec-eval--const-integer-value (form)
  "Return integer value if FORM is a const integer, otherwise nil."
  (when (and (typespec-eval--const-p form)
             (integerp (typespec-eval--const-value form)))
    (typespec-eval--const-value form)))

(defconst typespec-eval--arith-option-limit 20
  "Maximum number of arithmetic constant options to enumerate.")

(defsubst typespec-eval--integer-range (low high)
  "Return an integer range type expression for LOW and HIGH."
  (list 'integer low high))

(defsubst typespec-eval--range-p (form type-sym)
  "Return non-nil if FORM is a `(TYPE-SYM LOW HIGH)` range."
  (and (consp form)
       (eq (car form) type-sym)
       (consp (cdr form))
       (consp (cddr form))))

(defsubst typespec-eval--integer-range-p (form)
  "Return non-nil if FORM is an `(integer LOW HIGH)` range."
  (typespec-eval--range-p form 'integer))

(defsubst typespec-eval--float-range (low high)
  "Return a float range type expression for LOW and HIGH."
  (list 'float low high))

(defsubst typespec-eval--number-range-bound (bound)
  "Normalize numeric range BOUND to a number or `*`."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (list (car bound)))
   (t nil)))

(defsubst typespec-eval--number-range (low high)
  "Return a number range type expression for LOW and HIGH."
  (let ((low (typespec-eval--number-range-bound low))
        (high (typespec-eval--number-range-bound high)))
    (if (and low high)
        (list 'number low high)
      'number)))

(defsubst typespec-eval--real-range (low high)
  "Return a real range type expression for LOW and HIGH."
  (let ((low (typespec-eval--number-range-bound low))
        (high (typespec-eval--number-range-bound high)))
    (if (and low high)
        (list 'real low high)
      'real)))

(defsubst typespec-eval--float-range-p (form)
  "Return non-nil if FORM is a `(float LOW HIGH)` range."
  (typespec-eval--range-p form 'float))

(defsubst typespec-eval--number-range-p (form)
  "Return non-nil if FORM is a `(number LOW HIGH)` range."
  (typespec-eval--range-p form 'number))

(defsubst typespec-eval--real-range-p (form)
  "Return non-nil if FORM is a `(real LOW HIGH)` range."
  (typespec-eval--range-p form 'real))

(defun typespec-eval--list-of-symbols-p (value)
  "Return non-nil if VALUE is a proper list of symbols."
  (and (listp value)
       (or (not (fboundp 'proper-list-p))
           (proper-list-p value))
       (seq-every-p #'symbolp value)))

(provide 'typespec-eval-core)

;;; typespec-eval-core.el ends here
