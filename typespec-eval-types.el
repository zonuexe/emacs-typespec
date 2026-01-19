;;; typespec-eval-types.el --- Type predicates and categories for typespec  -*- lexical-binding: t; -*-

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

;; Type predicates and type category system for typespec evaluation.
;; This module provides:
;; - Type predicates (*-type-p)
;; - Type category system for efficient comparison
;; - Guard type resolution
;; - Non-type predicates (non-*-type-p)

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'typespec-eval-core)

;;; Integer bound helpers

(defsubst typespec-eval-types-integer-bound-min (bound)
  "Return the inclusive minimum value for integer BOUND."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (1+ (car bound)))
   (t nil)))

(defsubst typespec-eval-types-integer-bound-max (bound)
  "Return the inclusive maximum value for integer BOUND."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (1- (car bound)))
   (t nil)))

;;; Basic type predicates

(defsubst typespec-eval-types-fixnum-range-p (form)
  "Return non-nil if FORM is a fixnum range.
A fixnum range is \\=(integer \\='most-negative-fixnum \\='most-positive-fixnum)."
  (and (typespec-eval--integer-range-p form)
       (let ((low (typespec-eval-types-integer-bound-min (cadr form)))
             (high (typespec-eval-types-integer-bound-max (caddr form))))
         (and (numberp low) (numberp high)
              (= low most-negative-fixnum)
              (= high most-positive-fixnum)))))

(defsubst typespec-eval-types-integer-type-p (form)
  "Return non-nil if FORM is an integer-like type."
  (or (memq form '(int integer fixnum bignum integer-or-marker
                       positive-int non-negative-int
                       negative-int non-positive-int
                       natnum wholenump))
      (typespec-eval--integer-range-p form)))

(defsubst typespec-eval-types-float-type-p (form)
  "Return non-nil if FORM is a float-like type."
  (or (memq form '(float positive-float negative-float
                         non-positive-float non-negative-float))
      (typespec-eval--float-range-p form)))

(defsubst typespec-eval-types-number-type-p (form)
  "Return non-nil if FORM is a number-like type."
  (or (memq form '(number real integer float fixnum bignum
                          integer-or-marker number-or-marker
                          positive-int non-negative-int
                          negative-int non-positive-int
                          positive-float negative-float
                          non-positive-float non-negative-float
                          natnum wholenump))
      (typespec-eval--integer-range-p form)
      (typespec-eval--float-range-p form)
      (typespec-eval--number-range-p form)
      (typespec-eval--real-range-p form)))

(defsubst typespec-eval-types-number-or-const-p (form)
  "Return non-nil if FORM is a number type or numeric const."
  (or (typespec-eval-types-number-type-p form)
      (and (typespec-eval--const-p form)
           (numberp (typespec-eval--const-value form)))))

(defsubst typespec-eval-types-integer-or-const-p (form)
  "Return non-nil if FORM is an integer type or integer const."
  (or (typespec-eval-types-integer-type-p form)
      (and (typespec-eval--const-p form)
           (integerp (typespec-eval--const-value form)))))

(defsubst typespec-eval-types-positive-int-type-p (form)
  "Return non-nil if FORM is a positive integer type."
  (or (eq form 'positive-int)
      (and (typespec-eval--integer-range-p form)
           (let ((low (cadr form)))
             (and (numberp low) (<= 1 low))))))

(defsubst typespec-eval-types-non-negative-int-type-p (form)
  "Return non-nil if FORM is a non-negative integer type."
  (or (eq form 'non-negative-int)
      (eq form 'positive-int)
      (and (typespec-eval--integer-range-p form)
           (let ((low (cadr form)))
             (and (numberp low) (<= 0 low))))))

(defsubst typespec-eval-types-list-type-p (form)
  "Return non-nil if FORM is a list type."
  (or (eq form 'list)
      (and (consp form) (memq (car form) '(list list+)))))

(defsubst typespec-eval-types-vector-type-p (form)
  "Return non-nil if FORM is a vector type."
  (or (eq form 'vector)
      (and (consp form) (eq (car form) 'vector))))

(defsubst typespec-eval-types-boolean-type-p (form)
  "Return non-nil if FORM is a boolean type."
  (or (eq form 'boolean)
      (typespec-eval--always-nil-p form)
      (equal form '(const t))))

(defsubst typespec-eval-types-function-type-p (form)
  "Return non-nil if FORM is a function type."
  (and (consp form) (eq (car form) 'function)))

(defsubst typespec-eval-types-symbol-type-p (form)
  "Return non-nil if FORM is a symbol type."
  (memq form '(symbol keyword symbol-with-pos)))

(defsubst typespec-eval-types-keyword-type-p (form)
  "Return non-nil if FORM is a keyword type."
  (eq form 'keyword))

(defsubst typespec-eval-types-buffer-type-p (form)
  "Return non-nil if FORM is a buffer type."
  (eq form 'buffer))

(defsubst typespec-eval-types-marker-type-p (form)
  "Return non-nil if FORM is a marker type."
  (eq form 'marker))

(defsubst typespec-eval-types-hash-table-type-p (form)
  "Return non-nil if FORM is a hash-table type."
  (eq form 'hash-table))

(defsubst typespec-eval-types-bool-vector-type-p (form)
  "Return non-nil if FORM is a `bool-vector' type."
  (eq form 'bool-vector))

(defsubst typespec-eval-types-char-table-type-p (form)
  "Return non-nil if FORM is a char-table type."
  (eq form 'char-table))

(defsubst typespec-eval-types-record-type-p (form)
  "Return non-nil if FORM is a record type."
  (eq form 'record))

(defsubst typespec-eval-types-class-type-p (form)
  "Return non-nil if FORM is a `(:class CLASS)` type."
  (and (consp form) (eq (car form) :class)))

(defsubst typespec-eval-types-rx-type-p (form)
  "Return non-nil if FORM is an `(rx ...)` type."
  (and (consp form) (eq (car form) 'rx)))

(defsubst typespec-eval-types-string-type-p (form)
  "Return non-nil if FORM is a string-like type."
  (or (eq form 'string)
      (typespec-eval-types-rx-type-p form)
      (typespec-eval--non-empty-string-p form)))

;;; Type category system

(defun typespec-eval-types-type-category (form)
  "Return the type category of FORM as a symbol, or nil if unknown.
This function classifies types into categories for efficient comparison.
Note: `number' type returns \\='number, not \\='integer or \\='float."
  (cond
   ((typespec-eval-types-string-type-p form) 'string)
   ((typespec-eval-types-integer-type-p form) 'integer)
   ((typespec-eval-types-float-type-p form) 'float)
   ;; number/real are supertypes of integer and float
   ((or (memq form '(number real))
        (typespec-eval--number-range-p form)
        (typespec-eval--real-range-p form))
    'number)
   ((typespec-eval-types-list-type-p form) 'list)
   ((typespec-eval-types-vector-type-p form) 'vector)
   ((typespec-eval-types-symbol-type-p form) 'symbol)
   ((typespec-eval-types-buffer-type-p form) 'buffer)
   ((typespec-eval-types-marker-type-p form) 'marker)
   ((typespec-eval-types-hash-table-type-p form) 'hash-table)
   ((typespec-eval-types-bool-vector-type-p form) 'bool-vector)
   ((typespec-eval-types-char-table-type-p form) 'char-table)
   ((typespec-eval-types-function-type-p form) 'function)
   ((typespec-eval-types-record-type-p form) 'record)
   ;; Other known built-in type symbols
   ((memq form '(boolean sequence array)) form)))

;;; Subtype checks

(defun typespec-eval-types-type-subtype-p (sub super)
  "Return non-nil if SUB is a known subtype of SUPER."
  (let ((subcat (typespec-eval-types-type-category-with-guard sub))
        (supercat (typespec-eval-types-type-category-with-guard super)))
    (cond
     ((or (null subcat) (null supercat)) nil)
     ((eq subcat supercat) t)
     ((and (eq supercat 'number)
           (memq subcat '(integer float number)))
      t)
     ((and (eq supercat 'sequence)
           (memq subcat '(list vector string bool-vector char-table)))
      t)
     ((and (eq supercat 'array)
           (memq subcat '(string vector bool-vector char-table)))
      t)
     (t nil))))

;;; Guard type resolution

(defun typespec-eval-types-type-predicate-name (type-name)
  "Return the predicate function symbol for TYPE-NAME.
Follows `cl-typep' priority: TYPE-NAMEp, TYPE-NAME-p, TYPE-NAME.
Checks for `typespec' property first, then `fboundp'."
  (when (symbolp type-name)
    (let* ((name (symbol-name type-name))
           (namep (intern (concat name "p")))
           (name-p (intern (concat name "-p"))))
      (cond
       ;; Check typespec property first (covers registered but not yet defined)
       ((function-get namep 'typespec) namep)
       ((function-get name-p 'typespec) name-p)
       ((function-get type-name 'typespec) type-name)
       ;; Fall back to fboundp for runtime-defined functions
       ((fboundp namep) namep)
       ((fboundp name-p) name-p)
       ((fboundp type-name) type-name)))))

(defun typespec-eval-types-get-guard-return-type (pred-symbol)
  "Get the :guard or :guard! return type from PRED-SYMBOL's typespec.
Returns the guard type if found, nil otherwise."
  (when-let* ((spec (function-get pred-symbol 'typespec))
              (ret-type (and (eq (car-safe spec) 'function)
                             (nth 2 spec))))
    (pcase ret-type
      (`(:guard ,type) type)
      (`(:guard! ,type) type)
      (_ nil))))

(defun typespec-eval-types-guard-type-base (guard-type)
  "Return the base type category for GUARD-TYPE.
For `(rx ...)' types, returns \\='string.
For symbol types, returns the type-category."
  (pcase guard-type
    (`(rx . ,_) 'string)
    ((pred symbolp) (typespec-eval-types-type-category guard-type))
    (_ nil)))

(defun typespec-eval-types-class-subtype-p (sub super)
  "Return non-nil if class SUB is a subclass of SUPER."
  (cond
   ((eq sub super) t)
   ((and (fboundp 'child-of-class-p)
         (ignore-errors (child-of-class-p sub super))))
   (t nil)))

(defun typespec-eval-types-class-symbol (form)
  "Return class symbol from FORM if possible."
  (cond
   ((typespec-eval-types-class-type-p form) (cadr form))
   ((symbolp form) form)
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (and (symbolp val) val)))
   (t nil)))

(defun typespec-eval-types-get-type-base-category (type-name)
  "Get the base type category for TYPE-NAME via its predicate's typespec.
Returns nil if no :guard typespec is registered."
  (when-let* ((pred (typespec-eval-types-type-predicate-name type-name))
              (guard-type (typespec-eval-types-get-guard-return-type pred)))
    (typespec-eval-types-guard-type-base guard-type)))

(defun typespec-eval-types-type-category-with-guard (form)
  "Return the type category of FORM, including :guard-defined types."
  (or (typespec-eval-types-type-category form)
      (typespec-eval-types-get-type-base-category form)))

;;; Non-type predicates

(defun typespec-eval-types-non-string-type-p (form)
  "Return non-nil if FORM is a known non-string type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
    (not (eq cat 'string))))

(defun typespec-eval-types-non-number-type-p (form)
  "Return non-nil if FORM is a known non-number type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
    (not (memq cat '(integer float number)))))

(defun typespec-eval-types-non-integer-type-p (form)
  "Return non-nil if FORM is a known non-integer type.
Considers :guard-defined types via their base type."
  (cond
   ((typespec-eval-types-rx-type-p form) t)
   ((and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
      (not (memq cat '(integer number string)))))
   (t nil)))

(defun typespec-eval-types-non-float-type-p (form)
  "Return non-nil if FORM is a known non-float type.
Considers :guard-defined types via their base type."
  (cond
   ((typespec-eval-types-rx-type-p form) t)
   ((and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
      (not (memq cat '(float number string)))))
   (t nil)))

(defun typespec-eval-types-non-list-type-p (form)
  "Return non-nil if FORM is a known non-list type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
    (not (eq cat 'list))))

(defun typespec-eval-types-non-vector-type-p (form)
  "Return non-nil if FORM is a known non-vector type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
    (not (eq cat 'vector))))

(provide 'typespec-eval-types)
;;; typespec-eval-types.el ends here
