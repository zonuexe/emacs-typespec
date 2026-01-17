;;; typespec-eval.el --- Type-level evaluator for typespec  -*- lexical-binding: t; -*-

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

;; Minimal evaluator for typespec value/type expressions.
;; This is currently limited to simple constant folding for predicates
;; like `eq' and string operations like `upcase'.

;;; Code:

(require 'cl-lib)
(require 'rx)
(require 'seq)
(require 'subr-x)

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

(defsubst typespec-eval--integer-range-p (form)
  "Return non-nil if FORM is an `(integer LOW HIGH)` range."
  (and (consp form)
       (eq (car form) 'integer)
       (consp (cdr form))
       (consp (cddr form))))

(defsubst typespec-eval--float-range (low high)
  "Return a float range type expression for LOW and HIGH."
  (list 'float low high))

(defsubst typespec-eval--float-range-p (form)
  "Return non-nil if FORM is a `(float LOW HIGH)` range."
  (and (consp form)
       (eq (car form) 'float)
       (consp (cdr form))
       (consp (cddr form))))

(defsubst typespec-eval--integer-type-p (form)
  "Return non-nil if FORM is an integer-like type."
  (or (memq form '(int integer fixnum bignum
                       positive-int non-negative-int
                       negative-int non-positive-int))
      (typespec-eval--integer-range-p form)))

(defsubst typespec-eval--float-type-p (form)
  "Return non-nil if FORM is a float-like type."
  (or (memq form '(float positive-float negative-float
                         non-positive-float non-negative-float))
      (typespec-eval--float-range-p form)))

(defsubst typespec-eval--number-type-p (form)
  "Return non-nil if FORM is a number-like type."
  (or (memq form '(number real integer float fixnum bignum
                          positive-int non-negative-int
                          negative-int non-positive-int
                          positive-float negative-float
                          non-positive-float non-negative-float))
      (typespec-eval--integer-range-p form)
      (typespec-eval--float-range-p form)))

(defsubst typespec-eval--number-or-const-p (form)
  "Return non-nil if FORM is a number type or numeric const."
  (or (typespec-eval--number-type-p form)
      (and (typespec-eval--const-p form)
           (numberp (typespec-eval--const-value form)))))

(defsubst typespec-eval--integer-or-const-p (form)
  "Return non-nil if FORM is an integer type or integer const."
  (or (typespec-eval--integer-type-p form)
      (and (typespec-eval--const-p form)
           (integerp (typespec-eval--const-value form)))))

(defsubst typespec-eval--positive-int-type-p (form)
  "Return non-nil if FORM is a positive integer type."
  (or (eq form 'positive-int)
      (and (typespec-eval--integer-range-p form)
           (let ((low (cadr form)))
             (and (numberp low) (<= 1 low))))))

(defsubst typespec-eval--list-type-p (form)
  "Return non-nil if FORM is a list type."
  (or (eq form 'list)
      (and (consp form) (memq (car form) '(list list+)))))

(defsubst typespec-eval--vector-type-p (form)
  "Return non-nil if FORM is a vector type."
  (or (eq form 'vector)
      (and (consp form) (eq (car form) 'vector))))

(defsubst typespec-eval--boolean-type-p (form)
  "Return non-nil if FORM is a boolean type."
  (or (eq form 'boolean)
      (typespec-eval--always-nil-p form)
      (equal form '(const t))))

(defsubst typespec-eval--function-type-p (form)
  "Return non-nil if FORM is a function type."
  (and (consp form) (eq (car form) 'function)))

(defsubst typespec-eval--symbol-type-p (form)
  "Return non-nil if FORM is a symbol type."
  (memq form '(symbol keyword symbol-with-pos)))

(defsubst typespec-eval--keyword-type-p (form)
  "Return non-nil if FORM is a keyword type."
  (eq form 'keyword))

(defsubst typespec-eval--buffer-type-p (form)
  "Return non-nil if FORM is a buffer type."
  (eq form 'buffer))

(defsubst typespec-eval--marker-type-p (form)
  "Return non-nil if FORM is a marker type."
  (eq form 'marker))

(defsubst typespec-eval--hash-table-type-p (form)
  "Return non-nil if FORM is a hash-table type."
  (eq form 'hash-table))

(defsubst typespec-eval--bool-vector-type-p (form)
  "Return non-nil if FORM is a `bool-vector' type."
  (eq form 'bool-vector))

(defsubst typespec-eval--char-table-type-p (form)
  "Return non-nil if FORM is a char-table type."
  (eq form 'char-table))

(defsubst typespec-eval--record-type-p (form)
  "Return non-nil if FORM is a record type."
  (eq form 'record))

(defsubst typespec-eval--rx-type-p (form)
  "Return non-nil if FORM is an `(rx ...)` type."
  (and (consp form) (eq (car form) 'rx)))

(defsubst typespec-eval--string-type-p (form)
  "Return non-nil if FORM is a string-like type."
  (or (eq form 'string)
      (typespec-eval--rx-type-p form)
      (typespec-eval--non-empty-string-p form)))

(defun typespec-eval--type-category (form)
  "Return the type category of FORM as a symbol, or nil if unknown.
This function classifies types into categories for efficient comparison.
Note: `number' type returns \\='number, not \\='integer or \\='float."
  (cond
   ((typespec-eval--string-type-p form) 'string)
   ((typespec-eval--integer-type-p form) 'integer)
   ((typespec-eval--float-type-p form) 'float)
   ;; number/real are supertypes of integer and float
   ((memq form '(number real)) 'number)
   ((typespec-eval--list-type-p form) 'list)
   ((typespec-eval--vector-type-p form) 'vector)
   ((typespec-eval--symbol-type-p form) 'symbol)
   ((typespec-eval--buffer-type-p form) 'buffer)
   ((typespec-eval--marker-type-p form) 'marker)
   ((typespec-eval--hash-table-type-p form) 'hash-table)
   ((typespec-eval--bool-vector-type-p form) 'bool-vector)
   ((typespec-eval--char-table-type-p form) 'char-table)
   ((typespec-eval--function-type-p form) 'function)
   ((typespec-eval--record-type-p form) 'record)
   ;; Other known built-in type symbols
   ((memq form '(boolean sequence array)) form)))

(defun typespec-eval--type-predicate-name (type-name)
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

(defun typespec-eval--get-guard-return-type (pred-symbol)
  "Get the :guard or :guard! return type from PRED-SYMBOL's typespec.
Returns the guard type if found, nil otherwise."
  (when-let* ((spec (function-get pred-symbol 'typespec))
              (ret-type (and (eq (car-safe spec) 'function)
                             (nth 2 spec))))
    (pcase ret-type
      (`(:guard ,type) type)
      (`(:guard! ,type) type)
      (_ nil))))

(defun typespec-eval--guard-type-base (guard-type)
  "Return the base type category for GUARD-TYPE.
For `(rx ...)' types, returns \\='string.
For symbol types, returns the type-category."
  (pcase guard-type
    (`(rx . ,_) 'string)
    ((pred symbolp) (typespec-eval--type-category guard-type))
    (_ nil)))

(defun typespec-eval--get-type-base-category (type-name)
  "Get the base type category for TYPE-NAME via its predicate's typespec.
Returns nil if no :guard typespec is registered."
  (when-let* ((pred (typespec-eval--type-predicate-name type-name))
              (guard-type (typespec-eval--get-guard-return-type pred)))
    (typespec-eval--guard-type-base guard-type)))

(defun typespec-eval--type-category-with-guard (form)
  "Return the type category of FORM, including :guard-defined types."
  (or (typespec-eval--type-category form)
      (typespec-eval--get-type-base-category form)))

(defun typespec-eval--non-string-type-p (form)
  "Return non-nil if FORM is a known non-string type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval--type-category-with-guard form)))
    (not (eq cat 'string))))

(defun typespec-eval--non-number-type-p (form)
  "Return non-nil if FORM is a known non-number type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval--type-category-with-guard form)))
    (not (memq cat '(integer float number)))))

(defun typespec-eval--non-integer-type-p (form)
  "Return non-nil if FORM is a known non-integer type.
Considers :guard-defined types via their base type."
  (cond
   ((typespec-eval--rx-type-p form) t)
   ((and-let* ((cat (typespec-eval--type-category-with-guard form)))
      (not (memq cat '(integer number string)))))
   (t nil)))

(defun typespec-eval--non-float-type-p (form)
  "Return non-nil if FORM is a known non-float type.
Considers :guard-defined types via their base type."
  (cond
   ((typespec-eval--rx-type-p form) t)
   ((and-let* ((cat (typespec-eval--type-category-with-guard form)))
      (not (memq cat '(float number string)))))
   (t nil)))

(defun typespec-eval--non-list-type-p (form)
  "Return non-nil if FORM is a known non-list type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval--type-category-with-guard form)))
    (not (eq cat 'list))))

(defun typespec-eval--non-vector-type-p (form)
  "Return non-nil if FORM is a known non-vector type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval--type-category-with-guard form)))
    (not (eq cat 'vector))))

(defsubst typespec-eval--always-non-nil-p (form)
  "Return non-nil if FORM is known to be non-nil."
  (cond
   ((and (typespec-eval--const-p form)
         (not (null (typespec-eval--const-value form))))
    t)
   ((typespec-eval--non-empty-string-p form) t)
   ((eq form 'string) t)
   ((memq form '(number integer float real fixnum bignum
                        positive-int non-negative-int
                        negative-int non-positive-int
                        positive-float negative-float
                        keyword vector hash-table))
    t)
   ((and (consp form)
         (memq (car form) '(list+ cons vector)))
    t)
   (t nil)))

(defun typespec-eval--simplify-or (items)
  "Return a simplified `(or ...)` form for ITEMS."
  (cond
   ((null items) 'never)
   ((null (cdr items)) (car items))
   ((equal items '((const t) (const nil))) 'boolean)
   ((equal items '((const nil) (const t))) 'boolean)
   (t (cons 'or items))))

(defsubst typespec-eval--rx-form-to-regexp (rx-form)
  "Return a regexp string for RX-FORM, or nil if it is not `(rx ...)`."
  (when (and (consp rx-form) (eq (car rx-form) 'rx))
    (rx-to-string (cons 'seq (cdr rx-form)) t)))

(defun typespec-eval--const-string-matches-rx-p (string rx-form)
  "Return non-nil if STRING matches RX-FORM."
  (let ((regexp (typespec-eval--rx-form-to-regexp rx-form)))
    (when regexp
      (string-match-p regexp string))))

(defun typespec-eval--intersect-integer-types (lhs rhs)
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

(defun typespec-eval--intersect-number-types (lhs rhs)
  "Return the intersection of number-like LHS and RHS."
  (cond
   ((and (typespec-eval--integer-type-p lhs)
         (typespec-eval--integer-type-p rhs))
    (or (typespec-eval--intersect-integer-types lhs rhs) 'integer))
   ((and (typespec-eval--float-type-p lhs)
         (typespec-eval--float-type-p rhs))
    'float)
   ((and (typespec-eval--integer-type-p lhs)
         (typespec-eval--float-type-p rhs))
    'never)
   ((and (typespec-eval--float-type-p lhs)
         (typespec-eval--integer-type-p rhs))
    'never)
   ((and (typespec-eval--number-type-p lhs)
         (typespec-eval--number-type-p rhs))
    (cond
     ((typespec-eval--integer-type-p lhs) lhs)
     ((typespec-eval--integer-type-p rhs) rhs)
     ((typespec-eval--float-type-p lhs) lhs)
     ((typespec-eval--float-type-p rhs) rhs)
     (t 'number)))
   (t nil)))

(defun typespec-eval--and-merge (lhs rhs)
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
         (typespec-eval--rx-type-p rhs))
    (let ((val (typespec-eval--const-value lhs)))
      (cond
       ((and (stringp val)
             (typespec-eval--const-string-matches-rx-p val rhs))
        lhs)
       ((stringp val) 'never)
       (t 'never))))
   ((and (typespec-eval--const-p rhs)
         (typespec-eval--rx-type-p lhs))
    (let ((val (typespec-eval--const-value rhs)))
      (cond
       ((and (stringp val)
             (typespec-eval--const-string-matches-rx-p val lhs))
        rhs)
       ((stringp val) 'never)
       (t 'never))))
   ((and (typespec-eval--const-p lhs)
         (typespec-eval--string-type-p rhs))
    (let ((val (typespec-eval--const-value lhs)))
      (if (stringp val) lhs 'never)))
   ((and (typespec-eval--const-p rhs)
         (typespec-eval--string-type-p lhs))
    (let ((val (typespec-eval--const-value rhs)))
      (if (stringp val) rhs 'never)))
   ((and (typespec-eval--rx-type-p lhs)
         (typespec-eval--string-type-p rhs))
    lhs)
   ((and (typespec-eval--string-type-p lhs)
         (typespec-eval--rx-type-p rhs))
    rhs)
   ((and (or (typespec-eval--number-type-p lhs)
             (typespec-eval--integer-type-p lhs)
             (typespec-eval--float-type-p lhs))
         (or (typespec-eval--number-type-p rhs)
             (typespec-eval--integer-type-p rhs)
             (typespec-eval--float-type-p rhs)))
    (or (typespec-eval--intersect-number-types lhs rhs) (list 'and lhs rhs)))
   (t (list 'and lhs rhs))))

(defun typespec-eval--simplify-and (items)
  "Return a simplified `(and ...)` form for ITEMS."
  (let ((items (delq nil items)))
    (cond
     ((null items) 'mixed)
     (t
      (catch 'typespec-eval--and
        (let ((result nil))
          (dolist (item items)
            (setq result (if result (typespec-eval--and-merge result item) item))
            (when (eq result 'never)
              (throw 'typespec-eval--and result)))
          (or result 'mixed)))))))

(defun typespec-eval--eval-const-fold (arg fn pred &optional type-in type-out type-p fallback)
  "Evaluate FN over ARG with constant folding.
PRED is a predicate function to check if the value can be processed.
TYPE-IN is the input type to match (returns TYPE-OUT when matched).
TYPE-OUT is the output type (defaults to TYPE-IN).
TYPE-P is an optional predicate to check the evaluated type.
FALLBACK is the type to return when no rule matches (default: `unknown`)."
  (let* ((arg (typespec-eval--eval arg))
         (type-out (or type-out type-in))
         (fallback (or fallback 'unknown))
         (mapped
          (typespec-eval--map-const-or
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

(defsubst typespec-eval--string-or-char-p (val)
  "Return non-nil if VAL is a string or character."
  (or (stringp val) (characterp val)))

(defun typespec-eval--map-const-or (arg fn &optional fallback)
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
          (typespec-eval--simplify-or (nreverse items))
        fallback)))
   (t (or (funcall fn arg) fallback))))

(defun typespec-eval--literal-const (form)
  "Return a `(const VALUE)` for literal constants in FORM, or nil."
  (cond
   ((null form) (typespec-eval--make-const nil))
   ((numberp form) (typespec-eval--make-const form))
   ((stringp form) (typespec-eval--make-const form))
   ((characterp form) (typespec-eval--make-const form))
   ((keywordp form) (typespec-eval--make-const form))
   (t nil)))

;;; Generic evaluation helpers

(defun typespec-eval--eval-numeric-unary (arg fn)
  "Evaluate numeric unary FN over ARG, preserving numeric type."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ;; Constant folding
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ;; Simple type symbols - preserve as-is for compatibility
     ((memq arg '(integer int fixnum bignum))
      'integer)
     ((memq arg '(float number real))
      (if (eq arg 'float) 'float 'number))
     ;; Try unified range operations for range types
     ((typespec-eval--number-or-const-p arg)
      (let ((info (typespec-eval--numeric-range-info arg)))
        (if info
            (let ((result (typespec-eval--numeric-range-unary info fn)))
              (cond
               ;; signum returns a simplified or-form directly
               ((eq fn #'cl-signum)
                (or result (if (eq (plist-get info :type) 'float) 'float 'integer)))
               ;; abs/shift return info plist, convert to form
               ((and result (plistp result) (plist-get result :type))
                (typespec-eval--numeric-range-to-form result))
               ;; Fallback to type
               ((typespec-eval--float-type-p arg) 'float)
               ((typespec-eval--integer-type-p arg) 'integer)
               (t 'number)))
          ;; No range info, fallback to type
          (cond
           ((typespec-eval--float-type-p arg) 'float)
           ((typespec-eval--integer-type-p arg) 'integer)
           ((typespec-eval--number-type-p arg) 'number)
           (t 'unknown)))))
     (t 'unknown))))

(defun typespec-eval--eval-binary-string-compare (lhs rhs fn result-type)
  "Evaluate binary string comparison FN over LHS and RHS.
RESULT-TYPE is returned when both arguments are string types."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval--map-const-or
       lhs
       (lambda (item)
         (let ((res (typespec-eval--eval-binary-string-compare item rhs fn result-type)))
           (when (typespec-eval--const-p res) res)))
       result-type))
     ((and (consp rhs) (eq (car rhs) 'or))
      (typespec-eval--map-const-or
       rhs
       (lambda (item)
         (let ((res (typespec-eval--eval-binary-string-compare lhs item fn result-type)))
           (when (typespec-eval--const-p res) res)))
       result-type))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (funcall fn (typespec-eval--const-value lhs)
                (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      result-type)
     (t 'unknown))))

(defun typespec-eval--eval-numeric-compare (lhs rhs pred)
  "Evaluate numeric comparison PRED over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (numberp (typespec-eval--const-value lhs))
           (numberp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (funcall pred (typespec-eval--const-value lhs)
                (typespec-eval--const-value rhs))))
     ((and (typespec-eval--number-type-p lhs)
           (typespec-eval--number-type-p rhs))
      (let* ((lhs-info (typespec-eval--numeric-range-info lhs))
             (rhs-info (typespec-eval--numeric-range-info rhs))
             (result (and lhs-info rhs-info
                          (typespec-eval--numeric-range-compare lhs-info rhs-info pred))))
        (cond
         ((and lhs-info rhs-info (eq result t)) (typespec-eval--make-const t))
         ((and lhs-info rhs-info (eq result nil)) (typespec-eval--make-const nil))
         (t 'boolean))))
     (t 'unknown))))

(defun typespec-eval--eval-string-unary (arg fn &optional preserve-non-empty)
  "Evaluate unary string function FN for ARG.
When PRESERVE-NON-EMPTY is non-nil, return a non-empty string type."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ((and preserve-non-empty (typespec-eval--non-empty-string-p arg))
      (typespec-eval--non-empty-string-expr))
     ((typespec-eval--string-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-binary-string-op (arg1 arg2 fn)
  "Evaluate binary string operation FN for ARG1 and ARG2."
  (let ((arg1 (typespec-eval--eval arg1))
        (arg2 (typespec-eval--eval arg2)))
    (cond
     ((and (typespec-eval--const-p arg1)
           (typespec-eval--const-p arg2)
           (stringp (typespec-eval--const-value arg1))
           (stringp (typespec-eval--const-value arg2)))
      (typespec-eval--make-const
       (funcall fn (typespec-eval--const-value arg1)
                (typespec-eval--const-value arg2))))
     ((and (typespec-eval--string-type-p arg1)
           (typespec-eval--string-type-p arg2))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-predicate (arg pred &optional type-true-p type-false-p)
  "Evaluate predicate PRED over ARG with optional type check.
TYPE-TRUE-P and TYPE-FALSE-P are predicates over the evaluated type.
Also considers :guard-defined types via their base type."
  (let* ((arg (typespec-eval--eval arg))
         ;; Try to resolve guard type's base category
         (guard-base (and (symbolp arg)
                          (typespec-eval--get-type-base-category arg))))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (funcall pred (typespec-eval--const-value arg))))
     ((and type-true-p (funcall type-true-p arg))
      (typespec-eval--make-const t))
     ;; Check if guard type's base satisfies the predicate
     ((and type-true-p guard-base
           (funcall type-true-p guard-base))
      (typespec-eval--make-const t))
     ((and type-false-p (funcall type-false-p arg))
      (typespec-eval--make-const nil))
     ;; Check if guard type's base is disjoint from the predicate
     ((and type-true-p guard-base
           (not (funcall type-true-p guard-base)))
      (typespec-eval--make-const nil))
     (t 'boolean))))

(defun typespec-eval--eval-if-rx-narrowing (pred then else)
  "Return an `(rx ...)` type when PRED narrows THEN with ELSE nil.
This matches `(if (string-match-p (rx ...) VAR) VAR nil)` patterns."
  (pcase pred
    (`(string-match-p ,rx ,var)
     (when (and (equal then var)
                (or (null else) (equal else '(const nil))))
       (when (and (consp rx) (eq (car rx) 'rx))
         rx)))))

(defun typespec-eval--eval-if (pred then else)
  "Evaluate an `if` expression with PRED, THEN, and ELSE."
  (or (typespec-eval--eval-if-rx-narrowing pred then else)
      (let ((pred (typespec-eval--eval pred)))
        (cond
         ((eq pred 'never) 'never)
         ((typespec-eval--always-non-nil-p pred)
          (typespec-eval--eval then))
         ((typespec-eval--always-nil-p pred)
          (typespec-eval--eval else))
         (t
          (typespec-eval--simplify-or
           (list (typespec-eval--eval then)
                 (typespec-eval--eval else))))))))

(defsubst typespec-eval--non-negative-int-type-p (form)
  "Return non-nil if FORM is a non-negative integer type."
  (or (eq form 'non-negative-int)
      (eq form 'positive-int)
      (and (typespec-eval--integer-range-p form)
           (let ((low (cadr form)))
             (and (numberp low) (<= 0 low))))))


(defun typespec-eval--eval-char-equal (lhs rhs)
  "Evaluate a `char-equal` expression for LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (char-equal (typespec-eval--const-value lhs)
                   (typespec-eval--const-value rhs))))
     ((and (typespec-eval--integer-type-p lhs)
           (typespec-eval--integer-type-p rhs))
      'boolean)
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-value< (lhs rhs)
  "Evaluate a `value<` expression for LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (value< (typespec-eval--const-value lhs)
               (typespec-eval--const-value rhs))))
     ((and (typespec-eval--number-type-p lhs)
           (typespec-eval--number-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-equality (lhs rhs fn &optional value-pred type-pred)
  "Evaluate an equality expression over LHS and RHS using FN.
VALUE-PRED is an optional predicate to check const values
\\(e.g., #\\='numberp for =).
TYPE-PRED is an optional predicate to check evaluated types."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ;; nil checks (only for generic equality, not type-restricted)
     ((and (null value-pred)
           (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const t))
     ((and (null value-pred)
           (typespec-eval--always-non-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const nil))
     ((and (null value-pred)
           (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-non-nil-p rhs))
      (typespec-eval--make-const nil))
     ;; const comparison
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (or (null value-pred)
               (and (funcall value-pred (typespec-eval--const-value lhs))
                    (funcall value-pred (typespec-eval--const-value rhs)))))
      (typespec-eval--make-const
       (funcall fn (typespec-eval--const-value lhs)
                (typespec-eval--const-value rhs))))
     ((and value-pred type-pred
           (eq value-pred #'numberp)
           (funcall type-pred lhs)
           (funcall type-pred rhs))
      (let* ((lhs-info (typespec-eval--numeric-range-info lhs))
             (rhs-info (typespec-eval--numeric-range-info rhs)))
        (cond
         ((and lhs-info rhs-info
               (typespec-eval--numeric-range-disjoint-p lhs-info rhs-info))
          (typespec-eval--make-const nil))
         ((and lhs-info rhs-info
               (typespec-eval--numeric-range-singleton-p lhs-info)
               (typespec-eval--numeric-range-singleton-p rhs-info))
          (typespec-eval--make-const
           (funcall fn (plist-get lhs-info :low)
                    (plist-get rhs-info :low))))
         (t 'boolean))))
     ;; type check for specialized comparisons
     ((and type-pred
           (funcall type-pred lhs)
           (funcall type-pred rhs))
      'boolean)
     ;; default for generic equality
     ((null value-pred) 'boolean)
     (t 'unknown))))


(defsubst typespec-eval--list-of-p (form type)
  "Return non-nil if FORM is a list type of TYPE."
  (or (equal form (list 'list type))
      (equal form (list 'list+ type))))

(defsubst typespec-eval--vector-of-p (form type)
  "Return non-nil if FORM is a vector type of TYPE."
  (equal form (list 'vector type)))

(defsubst typespec-eval--list-elem-type (form)
  "Return element type if FORM is a list type."
  (when (and (consp form) (memq (car form) '(list list+)))
    (cadr form)))

(defsubst typespec-eval--alist-type-p (value)
  "Return non-nil if VALUE is an alist type."
  (and (consp value)
       (eq (car value) :alist)
       (consp (cdr value))
       (consp (cddr value))
       (null (cdddr value))))

(defsubst typespec-eval--alist-key-type (value)
  "Return the key type of an alist type VALUE."
  (cadr value))

(defsubst typespec-eval--alist-value-type (value)
  "Return the value type of an alist type VALUE."
  (caddr value))

(defsubst typespec-eval--plist-type-p (value)
  "Return non-nil if VALUE is a plist type."
  (and (consp value)
       (eq (car value) :plist)
       (consp (cdr value))
       (consp (cddr value))
       (null (cdddr value))))

(defsubst typespec-eval--plist-key-type (value)
  "Return the key type of a plist type VALUE."
  (cadr value))

(defsubst typespec-eval--plist-value-type (value)
  "Return the value type of a plist type VALUE."
  (caddr value))

(defsubst typespec-eval--plist-of-p (value)
  "Return non-nil if VALUE is a plist-of type."
  (and (consp value)
       (eq (car value) :plist-of)))

(defun typespec-eval--plist-of-entries (value)
  "Return entries for a plist-of type VALUE."
  (cdr value))

(defun typespec-eval--plist-of-value-type (value)
  "Return combined value type for plist-of VALUE."
  (typespec-eval--simplify-or
   (mapcar (lambda (entry) (cadr entry))
           (typespec-eval--plist-of-entries value))))

(defun typespec-eval--plist-of-entry-type (plist key)
  "Return entry type in PLIST for KEY, or nil if not found."
  (let ((entry (assoc key (typespec-eval--plist-of-entries plist))))
    (and entry (cadr entry))))

(defun typespec-eval--eval-tuple (args)
  "Evaluate tuple ARGS in order, preserving dotted structure."
  (cond
   ((consp args)
    (cons (typespec-eval--eval (car args))
          (typespec-eval--eval-tuple (cdr args))))
   ((null args) nil)
   (t (typespec-eval--eval args))))

(defun typespec-eval--tuple-unconst (args)
  "Return ARGS with const-wrapped elements unwrapped."
  (cond
   ((consp args)
    (cons (typespec-eval--unconst (car args))
          (typespec-eval--tuple-unconst (cdr args))))
   ((null args) nil)
   (t (typespec-eval--unconst args))))

(defun typespec-eval--eval-string-width (arg)
  "Evaluate a `string-width` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-width val))
          'unknown)))
     ((typespec-eval--string-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval--eval-string-lines (string &optional omit-nulls keep-newlines)
  "Evaluate a `string-lines` expression for STRING, OMIT-NULLS, and KEEP-NEWLINES."
  (let* ((string (typespec-eval--eval string))
         (omit-nulls (when omit-nulls (typespec-eval--eval omit-nulls)))
         (keep-newlines (when keep-newlines (typespec-eval--eval keep-newlines)))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (omit (and (typespec-eval--const-p omit-nulls)
                    (typespec-eval--const-value omit-nulls)))
         (keep (and (typespec-eval--const-p keep-newlines)
                    (typespec-eval--const-value keep-newlines))))
    (cond
     ((and (stringp sval)
           (or (null omit-nulls) (booleanp omit))
           (or (null keep-newlines) (booleanp keep)))
      (typespec-eval--make-const (string-lines sval omit keep)))
     ((typespec-eval--string-type-p string)
      (if (typespec-eval--always-nil-p omit-nulls)
          '(list+ string)
        '(list string)))
     (t 'unknown))))

(defun typespec-eval--eval-string-join (strings &optional separator)
  "Evaluate a `string-join` expression for STRINGS and SEPARATOR."
  (let* ((strings (typespec-eval--eval strings))
         (separator (when separator (typespec-eval--eval separator)))
         (sval (and (typespec-eval--const-p strings)
                    (typespec-eval--const-value strings)))
         (sep (and (typespec-eval--const-p separator)
                   (typespec-eval--const-value separator))))
    (cond
     ((and (typespec-eval--const-p strings)
           (listp sval)
           (seq-every-p #'stringp sval)
           (or (null separator) (stringp sep)))
      (typespec-eval--make-const (string-join sval sep)))
     ((or (typespec-eval--list-of-p strings 'string)
          (typespec-eval--list-of-p strings (typespec-eval--non-empty-string-expr)))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-match-p (regexp string &optional start)
  "Evaluate a `string-match-p` expression for REGEXP, STRING, and START."
  (let* ((regexp (typespec-eval--eval regexp))
         (string (typespec-eval--eval string))
         (start (when start (typespec-eval--eval start)))
         (start-val (typespec-eval--const-integer-value start)))
    (cond
     ((and (consp regexp) (eq (car regexp) 'or))
      (typespec-eval--map-const-or
       regexp
       (lambda (item)
         (let ((res (typespec-eval--eval-string-match-p item string start)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp string) (eq (car string) 'or))
      (typespec-eval--map-const-or
       string
       (lambda (item)
         (let ((res (typespec-eval--eval-string-match-p regexp item start)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (or (null start) (integerp start-val))
           (let ((regexps (typespec-eval--const-regexp-options regexp))
                 (strings (typespec-eval--const-string-options string)))
             (when (and regexps strings)
               (let ((results nil))
                 (catch 'typespec-eval--too-many
                   (dolist (re regexps)
                     (dolist (s strings)
                       (push (typespec-eval--make-const
                              (string-match-p re s start-val))
                             results)
                       (when (> (length results) typespec-eval--arith-option-limit)
                         (throw 'typespec-eval--too-many nil)))))
                 (when results
                   (typespec-eval--simplify-or (nreverse results))))))))
     ((and (typespec-eval--string-type-p regexp)
           (typespec-eval--string-type-p string)
           (or (null start)
               (typespec-eval--integer-type-p start)))
      'boolean)
     (t 'unknown))))


(defun typespec-eval--eval-string-limit (string n)
  "Evaluate a `string-limit` expression for STRING and N."
  (let* ((string (typespec-eval--eval string))
         (n (typespec-eval--eval n))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (stringp sval) (integerp nval) (<= 0 nval))
      (typespec-eval--make-const (string-limit sval nval)))
     ((and (typespec-eval--string-type-p string)
           (typespec-eval--integer-type-p n))
      'string)
     (t 'unknown))))


(defun typespec-eval--eval-char-to-string (char)
  "Evaluate a `char-to-string` expression for CHAR."
  (let ((char (typespec-eval--eval char)))
    (cond
     ((typespec-eval--const-p char)
      (let ((val (typespec-eval--const-value char)))
        (if (characterp val)
            (typespec-eval--make-const (char-to-string val))
          'unknown)))
     ((typespec-eval--integer-type-p char)
      (typespec-eval--non-empty-string-expr))
     (t 'unknown))))

(defun typespec-eval--eval-make-string (length char)
  "Evaluate a `make-string` expression for LENGTH and CHAR."
  (let* ((length (typespec-eval--eval length))
         (char (typespec-eval--eval char))
         (len (typespec-eval--const-integer-value length))
         (cval (and (typespec-eval--const-p char)
                    (typespec-eval--const-value char))))
    (cond
     ((and (integerp len) (characterp cval) (<= 0 len))
      (typespec-eval--make-const (make-string len cval)))
     ((and (typespec-eval--integer-type-p length)
           (typespec-eval--integer-type-p char))
      (if (typespec-eval--positive-int-type-p length)
          (typespec-eval--non-empty-string-expr)
        'string))
     (t 'unknown))))


(defun typespec-eval--eval-string-search (needle haystack &optional start)
  "Evaluate a `string-search` expression for NEEDLE, HAYSTACK, and START."
  (let* ((needle (typespec-eval--eval needle))
         (haystack (typespec-eval--eval haystack))
         (start (when start (typespec-eval--eval start)))
         (start-val (typespec-eval--const-integer-value start)))
    (cond
     ((and (consp needle) (eq (car needle) 'or))
      (typespec-eval--map-const-or
       needle
       (lambda (item)
         (let ((res (typespec-eval--eval-string-search item haystack start)))
           (when (typespec-eval--const-p res) res)))
       '(or (const nil) integer)))
     ((and (consp haystack) (eq (car haystack) 'or))
      (typespec-eval--map-const-or
       haystack
       (lambda (item)
         (let ((res (typespec-eval--eval-string-search needle item start)))
           (when (typespec-eval--const-p res) res)))
       '(or (const nil) integer)))
     ((and (or (null start) (integerp start-val))
           (let ((needles (typespec-eval--const-string-options needle))
                 (haystacks (typespec-eval--const-string-options haystack)))
             (when (and needles haystacks)
               (let ((results nil))
                 (catch 'typespec-eval--too-many
                   (dolist (n needles)
                     (dolist (h haystacks)
                       (push (typespec-eval--make-const
                              (string-search n h start-val))
                             results)
                       (when (> (length results) typespec-eval--arith-option-limit)
                         (throw 'typespec-eval--too-many nil)))))
                 (when results
                   (typespec-eval--simplify-or (nreverse results))))))))
     ((and (typespec-eval--string-type-p needle)
           (typespec-eval--string-type-p haystack)
           (or (null start)
               (typespec-eval--integer-type-p start)))
      '(or (const nil) integer))
     (t 'unknown))))

(defun typespec-eval--eval-string-split (string &optional separators omit-nulls trim)
  "Evaluate a `string-split` expression.
STRING, SEPARATORS, OMIT-NULLS, and TRIM are evaluated."
  (let* ((string (typespec-eval--eval string))
         (separators (when separators (typespec-eval--eval separators)))
         (omit-nulls (if (null omit-nulls)
                         (typespec-eval--make-const nil)
                       (typespec-eval--eval omit-nulls)))
         (trim (when trim (typespec-eval--eval trim)))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (sep (and (typespec-eval--const-p separators)
                   (typespec-eval--const-value separators)))
         (omit (and (typespec-eval--const-p omit-nulls)
                    (typespec-eval--const-value omit-nulls)))
         (trim-val (and (typespec-eval--const-p trim)
                        (typespec-eval--const-value trim)))
         (sep-ok (or (null separators)
                     (stringp sep)
                     (eq sep nil)
                     (eq sep t))))
    (cond
     ((and (stringp sval)
           sep-ok
           (or (null omit-nulls) (booleanp omit))
           (or (null trim) (stringp trim-val) (eq trim-val nil) (eq trim-val t)))
      (typespec-eval--make-const
       (string-split sval sep omit trim-val)))
     ((typespec-eval--string-type-p string)
      (if (typespec-eval--always-nil-p omit-nulls)
          '(list+ string)
        '(list string)))
     (t 'unknown))))

(defun typespec-eval--eval-string-replace (from to string)
  "Evaluate a `string-replace` expression for FROM, TO, and STRING."
  (let ((from (typespec-eval--eval from))
        (to (typespec-eval--eval to))
        (string (typespec-eval--eval string)))
    (cond
     ((and (typespec-eval--const-p from)
           (typespec-eval--const-p to)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value from))
           (stringp (typespec-eval--const-value to))
           (stringp (typespec-eval--const-value string)))
      (typespec-eval--make-const
       (string-replace (typespec-eval--const-value from)
                       (typespec-eval--const-value to)
                       (typespec-eval--const-value string))))
     ((and (typespec-eval--string-type-p from)
           (typespec-eval--string-type-p to)
           (typespec-eval--string-type-p string))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-truncate-left (string n)
  "Evaluate a `string-truncate-left` expression for STRING and N."
  (let* ((string (typespec-eval--eval string))
         (n (typespec-eval--eval n))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (stringp sval) (integerp nval) (<= 0 nval))
      (typespec-eval--make-const (string-truncate-left sval nval)))
     ((and (typespec-eval--string-type-p string)
           (typespec-eval--integer-type-p n))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-suffix-p (suffix string &optional ignore-case)
  "Evaluate a `string-suffix-p` expression for SUFFIX, STRING, and IGNORE-CASE."
  (let ((suffix (typespec-eval--eval suffix))
        (string (typespec-eval--eval string))
        (ignore-case (when ignore-case (typespec-eval--eval ignore-case))))
    (cond
     ((and (consp suffix) (eq (car suffix) 'or))
      (typespec-eval--map-const-or
       suffix
       (lambda (item)
         (let ((res (typespec-eval--eval-string-suffix-p item string ignore-case)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp string) (eq (car string) 'or))
      (typespec-eval--map-const-or
       string
       (lambda (item)
         (let ((res (typespec-eval--eval-string-suffix-p suffix item ignore-case)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (typespec-eval--const-p suffix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value suffix))
           (stringp (typespec-eval--const-value string))
           (or (null ignore-case)
               (and (typespec-eval--const-p ignore-case)
                    (memq (typespec-eval--const-value ignore-case) '(t nil)))))
      (typespec-eval--make-const
       (string-suffix-p (typespec-eval--const-value suffix)
                        (typespec-eval--const-value string)
                        (when ignore-case
                          (typespec-eval--const-value ignore-case)))))
     ((and (typespec-eval--string-type-p suffix)
           (typespec-eval--string-type-p string))
      'boolean)
     (t 'unknown))))


(defun typespec-eval--arith-type (args)
  "Return the numeric result type for ARGS."
  (cond
   ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
   ((seq-some #'typespec-eval--float-type-p args) 'float)
   ((seq-every-p #'typespec-eval--number-type-p args) 'number)
   (t 'unknown)))

(defun typespec-eval--float-range-bound (bound)
  "Normalize float range BOUND to a float or `*`."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) (float bound))
   ((and (consp bound) (numberp (car bound))) (float (car bound)))
   (t nil)))

(defsubst typespec-eval--float-bound-value (bound)
  "Return numeric value for float BOUND, or nil for `*`."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) (float bound))
   ((and (consp bound) (numberp (car bound))) (float (car bound)))
   (t nil)))

(defsubst typespec-eval--float-bound-exclusive-p (bound)
  "Return non-nil if float BOUND is exclusive."
  (and (consp bound) (numberp (car bound))))

(defsubst typespec-eval--float-bound-integer-p (bound)
  "Return non-nil if float BOUND is an exclusive integer boundary."
  (and (consp bound) (integerp (car bound))))

(defsubst typespec-eval--float-bound (value exclusive)
  "Return a float bound for VALUE with EXCLUSIVE."
  (if (eq value '*) '*
    (if exclusive (list value) value)))

(defsubst typespec-eval--float-bound-shift (bound delta)
  "Return BOUND shifted by DELTA, preserving exclusivity."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) (+ bound delta))
   ((and (consp bound) (numberp (car bound)))
    (list (+ (car bound) delta)))
   (t nil)))

(defsubst typespec-eval--integer-bound-min (bound)
  "Return the inclusive minimum value for integer BOUND."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (1+ (car bound)))
   (t nil)))

(defsubst typespec-eval--integer-bound-max (bound)
  "Return the inclusive maximum value for integer BOUND."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (1- (car bound)))
   (t nil)))

(defun typespec-eval--integer-range-from (form)
  "Return an `(integer LOW HIGH)` range for FORM, or nil."
  (cond
   ((typespec-eval--integer-range-p form) form)
   ((eq form 'positive-int) (typespec-eval--integer-range 1 '*))
   ((eq form 'non-negative-int) (typespec-eval--integer-range 0 '*))
   ((eq form 'negative-int) (typespec-eval--integer-range '* -1))
   ((eq form 'non-positive-int) (typespec-eval--integer-range '* 0))
   ((memq form '(int integer fixnum bignum))
    (typespec-eval--integer-range '* '*))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (integerp val)
        (typespec-eval--integer-range val val))))
   (t nil)))

(defun typespec-eval--minmax-range (ranges op)
  "Return a range for min/max over RANGES using OP."
  (let ((lows '())
        (highs '()))
    (dolist (range ranges)
      (push (cadr range) lows)
      (push (caddr range) highs))
    (cond
     ((eq op #'min)
      (let* ((low (let ((vals (delq '* lows)))
                    (if (null vals) '* (apply #'min vals))))
             (high (let ((vals (delq '* highs)))
                     (if (null vals) '* (apply #'min vals)))))
        (if (and (eq low '*) (eq high '*))
            nil
          (if (eq (car (car ranges)) 'integer)
              (typespec-eval--integer-range low high)
            (typespec-eval--float-range low high)))))
     ((eq op #'max)
      (let* ((low (let ((vals (delq '* lows)))
                    (if (null vals) '* (apply #'max vals))))
             (high (if (memq '* highs) '* (apply #'max highs))))
        (if (and (eq low '*) (eq high '*))
            nil
          (if (eq (car (car ranges)) 'integer)
              (typespec-eval--integer-range low high)
            (typespec-eval--float-range low high)))))
     (t nil))))

(defsubst typespec-eval--float-range-includes-zero-p (range)
  "Return non-nil if float RANGE includes 0.0."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval--float-bound-value low))
         (highv (typespec-eval--float-bound-value high))
         (low-excl (typespec-eval--float-bound-exclusive-p low))
         (high-excl (typespec-eval--float-bound-exclusive-p high)))
    (and (or (null lowv) (< lowv 0.0) (and (= lowv 0.0) (not low-excl)))
         (or (null highv) (> highv 0.0) (and (= highv 0.0) (not high-excl))))))

(defsubst typespec-eval--float-range-signum (range)
  "Return the `cl-signum` result for float RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval--float-bound-value low))
         (highv (typespec-eval--float-bound-value high))
         (low-excl (typespec-eval--float-bound-exclusive-p low))
         (high-excl (typespec-eval--float-bound-exclusive-p high))
         (can-neg (or (null lowv) (< lowv 0.0)))
         (can-pos (or (null highv) (> highv 0.0)))
         (can-zero (and (or (null lowv) (< lowv 0.0) (and (= lowv 0.0) (not low-excl)))
                        (or (null highv) (> highv 0.0) (and (= highv 0.0) (not high-excl)))))
         (opts nil))
    (when can-neg (push -1.0 opts))
    (when can-zero (push 0.0 opts))
    (when can-pos (push 1.0 opts))
    (when opts
      (typespec-eval--simplify-or
       (mapcar #'typespec-eval--make-const (nreverse opts))))))

(defun typespec-eval--float-range-from (form)
  "Return a `(float LOW HIGH)` range for FORM, or nil."
  (cond
   ((eq form 'positive-float)
    (typespec-eval--float-range '(0) '*))
   ((eq form 'negative-float)
    (typespec-eval--float-range '* '(0)))
   ((eq form 'non-negative-float)
    (typespec-eval--float-range 0.0 '*))
   ((eq form 'non-positive-float)
    (typespec-eval--float-range '* 0.0))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (numberp val)
        (typespec-eval--float-range (float val) (float val)))))
   ((typespec-eval--float-range-p form)
    (let ((low (typespec-eval--float-range-bound (cadr form)))
          (high (typespec-eval--float-range-bound (caddr form))))
      (when (and low high)
        (typespec-eval--float-range low high))))
   ((typespec-eval--integer-range-p form)
    (let ((low (cadr form))
          (high (caddr form)))
      (when (and (numberp low) (numberp high))
        (typespec-eval--float-range (float low) (float high)))))
   ((typespec-eval--float-type-p form)
    (typespec-eval--float-range '* '*))
   ((typespec-eval--integer-type-p form)
    (typespec-eval--float-range '* '*))
   (t nil)))

(defun typespec-eval--numeric-range-info (form)
  "Return numeric range info plist for FORM with :type annotation.
The plist contains :type (integer or float), :low, :high, :low-excl, :high-excl."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (numberp val)
        (list :type (if (integerp val) 'integer 'float)
              :low val :high val :low-excl nil :high-excl nil))))
   ((typespec-eval--float-range-p form)
    (let* ((low (cadr form))
           (high (caddr form))
           (lowv (typespec-eval--float-bound-value low))
           (highv (typespec-eval--float-bound-value high))
           (low-excl (typespec-eval--float-bound-exclusive-p low))
           (high-excl (typespec-eval--float-bound-exclusive-p high)))
      (list :type 'float :low lowv :high highv :low-excl low-excl :high-excl high-excl)))
   (t
    (let ((irange (typespec-eval--integer-range-from form)))
      (if irange
          (let ((low (typespec-eval--integer-bound-min (cadr irange)))
                (high (typespec-eval--integer-bound-max (caddr irange))))
            (list :type 'integer :low low :high high :low-excl nil :high-excl nil))
        (let ((frange (typespec-eval--float-range-from form)))
          (when frange
            (let* ((low (cadr frange))
                   (high (caddr frange)))
              (list :type 'float :low low :high high :low-excl nil :high-excl nil)))))))))

(defun typespec-eval--numeric-range-to-form (info)
  "Convert numeric range INFO back to a typespec form.
INFO must have :type, :low, :high, :low-excl, :high-excl.
Returns simple type symbol for fully unbounded ranges.
Alias types are normalized to canonical range forms."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (cond
     ;; Singleton value
     ((and (numberp low) (numberp high) (= low high)
           (not low-excl) (not high-excl))
      (typespec-eval--make-const (if (eq type 'float) (float low) low)))
     ;; Fully unbounded range -> simple type symbol
     ((and (null low) (null high))
      type)
     ;; Integer range (always use canonical form)
     ((eq type 'integer)
      (let ((lo (if low-excl (and (numberp low) (1+ low)) low))
            (hi (if high-excl (and (numberp high) (1- high)) high)))
        (typespec-eval--integer-range (or lo '*) (or hi '*))))
     ;; Float range - ensure float values
     (t
      (let ((lo (cond ((null low) '*)
                      (low-excl (list (float low)))
                      (t (float low))))
            (hi (cond ((null high) '*)
                      (high-excl (list (float high)))
                      (t (float high)))))
        (typespec-eval--float-range lo hi))))))

(defun typespec-eval--numeric-range-singleton-p (info)
  "Return non-nil if INFO describes a single numeric value."
  (let ((low (plist-get info :low))
        (high (plist-get info :high)))
    (and (numberp low)
         (numberp high)
         (= low high)
         (not (plist-get info :low-excl))
         (not (plist-get info :high-excl)))))

(defsubst typespec-eval--numeric-range-positive-p (info)
  "Return non-nil if INFO describes a positive range."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (numberp low)
         (or (> low 0) (and (= low 0) low-excl))
         (or (null high)
             (> high 0)
             (and (= high 0) high-excl)))))

(defsubst typespec-eval--numeric-range-negative-p (info)
  "Return non-nil if INFO describes a negative range."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (numberp high)
         (or (< high 0) (and (= high 0) high-excl))
         (or (null low)
             (< low 0)
             (and (= low 0) low-excl)))))

(defsubst typespec-eval--numeric-range-includes-zero-p (info)
  "Return non-nil if INFO includes zero."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (or (null low) (<= low 0))
         (or (null high) (<= 0 high))
         (not (and (numberp low) (= low 0) low-excl))
         (not (and (numberp high) (= high 0) high-excl)))))

(defsubst typespec-eval--numeric-min (a b)
  "Return minimum of A and B when both are numbers."
  (cond
   ((and (numberp a) (numberp b)) (min a b))
   (a a)
   (b b)
   (t nil)))

(defsubst typespec-eval--numeric-max (a b)
  "Return maximum of A and B when both are numbers."
  (cond
   ((and (numberp a) (numberp b)) (max a b))
   (a a)
   (b b)
   (t nil)))

;;; Unified numeric range operations

(defun typespec-eval--numeric-range-shift (info delta)
  "Return INFO shifted by DELTA.
For float ranges, exclusivity is cleared when shifting since the exact
boundary value changes."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high)))
    ;; For floats, shifting clears exclusivity (conservative approach)
    ;; For integers, exclusivity can be preserved in concept but we clear it
    ;; since the shifted value is different
    (list :type type
          :low (and (numberp low) (+ low delta))
          :high (and (numberp high) (+ high delta))
          :low-excl nil
          :high-excl nil)))

(defun typespec-eval--numeric-range-abs (info)
  "Compute absolute value range for INFO."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (cond
     ;; Unbounded on both sides
     ((and (null low) (null high))
      (list :type type :low 0 :high nil :low-excl nil :high-excl nil))
     ;; Unbounded below
     ((null low)
      (if (and high (<= high 0))
          ;; All non-positive -> [|high|, *)
          (list :type type :low (abs high) :high nil
                :low-excl high-excl :high-excl nil)
        ;; Crosses zero -> [0, *)
        (list :type type :low 0 :high nil :low-excl nil :high-excl nil)))
     ;; Unbounded above
     ((null high)
      (if (>= low 0)
          ;; All non-negative -> [low, *)
          (list :type type :low low :high nil :low-excl low-excl :high-excl nil)
        ;; Crosses zero -> [0, *)
        (list :type type :low 0 :high nil :low-excl nil :high-excl nil)))
     ;; Bounded
     ((and (numberp low) (numberp high))
      (cond
       ;; All non-negative: [low, high]
       ((>= low 0)
        (list :type type :low low :high high :low-excl low-excl :high-excl high-excl))
       ;; All non-positive: [|high|, |low|]
       ((<= high 0)
        (list :type type :low (abs high) :high (abs low)
              :low-excl high-excl :high-excl low-excl))
       ;; Crosses zero: [0, max(|low|, |high|)]
       (t
        (let* ((abs-low (abs low))
               (abs-high (abs high))
               (max-abs (max abs-low abs-high))
               (max-excl (cond
                          ((> abs-low abs-high) low-excl)
                          ((> abs-high abs-low) high-excl)
                          (t (and low-excl high-excl)))))
          (list :type type :low 0 :high max-abs :low-excl nil :high-excl max-excl)))))
     (t nil))))

(defun typespec-eval--numeric-range-signum (info)
  "Return signum result options as a simplified or-form for INFO."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl))
        (opts nil))
    ;; Check if range can be negative
    (when (or (null low) (< low 0))
      (push (if (eq type 'float) -1.0 -1) opts))
    ;; Check if range includes zero
    (when (and (or (null low) (< low 0) (and (= low 0) (not low-excl)))
               (or (null high) (> high 0) (and (= high 0) (not high-excl))))
      (push (if (eq type 'float) 0.0 0) opts))
    ;; Check if range can be positive
    (when (or (null high) (> high 0))
      (push (if (eq type 'float) 1.0 1) opts))
    (when opts
      (typespec-eval--simplify-or
       (mapcar #'typespec-eval--make-const (nreverse opts))))))

(defun typespec-eval--numeric-range-unary (info fn)
  "Apply unary FN to numeric range INFO.
Returns a new info plist for shift operations, or a result form for signum/abs."
  (cond
   ((memq fn (list #'1+ #'1-))
    (let ((delta (if (eq fn #'1+) 1 -1)))
      (typespec-eval--numeric-range-shift info delta)))
   ((eq fn #'abs)
    (typespec-eval--numeric-range-abs info))
   ((eq fn #'cl-signum)
    (typespec-eval--numeric-range-signum info))
   (t nil)))

(defun typespec-eval--numeric-range-disjoint-p (lhs rhs)
  "Return non-nil if numeric ranges LHS and RHS are disjoint."
  (let ((lhigh (plist-get lhs :high))
        (lhigh-excl (plist-get lhs :high-excl))
        (llow (plist-get lhs :low))
        (llow-excl (plist-get lhs :low-excl))
        (rhigh (plist-get rhs :high))
        (rhigh-excl (plist-get rhs :high-excl))
        (rlow (plist-get rhs :low))
        (rlow-excl (plist-get rhs :low-excl)))
    (or (and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow) (or lhigh-excl rlow-excl))))
        (and (numberp rhigh) (numberp llow)
             (or (< rhigh llow)
                 (and (= rhigh llow) (or rhigh-excl llow-excl)))))))

(defun typespec-eval--numeric-range-compare (lhs rhs pred)
  "Return t/nil if PRED is decidable for LHS and RHS, else `unknown`."
  (let ((llow (plist-get lhs :low))
        (llow-excl (plist-get lhs :low-excl))
        (lhigh (plist-get lhs :high))
        (lhigh-excl (plist-get lhs :high-excl))
        (rlow (plist-get rhs :low))
        (rlow-excl (plist-get rhs :low-excl))
        (rhigh (plist-get rhs :high))
        (rhigh-excl (plist-get rhs :high-excl)))
    (cond
     ((eq pred #'<)
      (cond
       ((and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow) (or lhigh-excl rlow-excl))))
        t)
       ((and (numberp llow) (numberp rhigh)
             (>= llow rhigh))
        nil)
       (t 'unknown)))
     ((eq pred #'>)
      (typespec-eval--numeric-range-compare rhs lhs #'<))
     ((eq pred #'<=)
      (cond
       ((and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow)
                      (not lhigh-excl)
                      (not rlow-excl))))
        t)
       ((and (numberp llow) (numberp rhigh)
             (or (> llow rhigh)
                 (and (= llow rhigh) (or llow-excl rhigh-excl))))
        nil)
       (t 'unknown)))
     ((eq pred #'>=)
      (typespec-eval--numeric-range-compare rhs lhs #'<=))
     ((eq pred #'/=)
      (cond
       ((and (typespec-eval--numeric-range-singleton-p lhs)
             (typespec-eval--numeric-range-singleton-p rhs))
        (not (= llow rlow)))
       ((typespec-eval--numeric-range-disjoint-p lhs rhs) t)
       (t 'unknown)))
     (t 'unknown))))

(defsubst typespec-eval--float-range-abs (range)
  "Return the absolute-value range for RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval--float-bound-value low))
         (highv (typespec-eval--float-bound-value high))
         (low-excl (typespec-eval--float-bound-exclusive-p low))
         (high-excl (typespec-eval--float-bound-exclusive-p high)))
    (cond
     ((and (null lowv) (null highv))
      (typespec-eval--float-range 0.0 '*))
     ((null lowv)
      (if (and highv (<= highv 0.0))
          (typespec-eval--float-range
           (typespec-eval--float-bound (abs highv) high-excl)
           '*)
        (typespec-eval--float-range 0.0 '*)))
     ((null highv)
      (if (>= lowv 0.0)
          (typespec-eval--float-range
           (typespec-eval--float-bound lowv low-excl)
           '*)
        (typespec-eval--float-range 0.0 '*)))
     ((and (numberp lowv) (numberp highv))
      (cond
       ((>= lowv 0.0)
        (typespec-eval--float-range
         (typespec-eval--float-bound lowv low-excl)
         (typespec-eval--float-bound highv high-excl)))
       ((<= highv 0.0)
        (typespec-eval--float-range
         (typespec-eval--float-bound (abs highv) high-excl)
         (typespec-eval--float-bound (abs lowv) low-excl)))
       (t
        (let* ((abs-low (abs lowv))
               (abs-high (abs highv))
               (max-abs (max abs-low abs-high))
               (max-excl
                (cond
                 ((> abs-low abs-high) low-excl)
                 ((> abs-high abs-low) high-excl)
                 (t (and low-excl high-excl)))))
          (typespec-eval--float-range
           0.0
           (typespec-eval--float-bound max-abs max-excl))))))
     (t nil))))

(defun typespec-eval--float-rounding-range (range kind)
  "Return an integer range for rounding KIND over float RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval--float-bound-value low))
         (highv (typespec-eval--float-bound-value high)))
    (cond
     ((or (null lowv) (null highv)) 'integer)
     ((eq kind 'floor)
      (let* ((min (floor lowv))
             (max (floor highv)))
        (when (and (typespec-eval--float-bound-integer-p high)
                   (integerp max))
          (setq max (1- max)))
        (typespec-eval--integer-range min max)))
     ((eq kind 'ceiling)
      (let* ((min (ceiling lowv))
             (max (ceiling highv)))
        (when (and (typespec-eval--float-bound-integer-p low)
                   (integerp min))
          (setq min (1+ min)))
        (typespec-eval--integer-range min max)))
     ((eq kind 'truncate)
      (cond
       ((>= lowv 0.0)
        (typespec-eval--float-rounding-range range 'floor))
       ((<= highv 0.0)
        (typespec-eval--float-rounding-range range 'ceiling))
       (t
        (let* ((min (ceiling lowv))
               (max (floor highv)))
          (when (and (typespec-eval--float-bound-integer-p low)
                     (integerp min))
            (setq min (1+ min)))
          (when (and (typespec-eval--float-bound-integer-p high)
                     (integerp max))
            (setq max (1- max)))
          (typespec-eval--integer-range min max)))))
     ((eq kind 'round)
      (let* ((min (round lowv))
             (max (round highv)))
        (when (and (typespec-eval--float-bound-integer-p low)
                   (integerp min))
          (setq min (1+ min)))
        (when (and (typespec-eval--float-bound-integer-p high)
                   (integerp max))
          (setq max (1- max)))
        (typespec-eval--integer-range min max)))
     (t 'integer))))

(defun typespec-eval--eval-rounding (arg kind fn)
  "Evaluate rounding KIND using FN over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ((typespec-eval--float-range-p arg)
      (or (typespec-eval--float-rounding-range arg kind) 'integer))
     ((typespec-eval--integer-range-p arg) arg)
     ((typespec-eval--integer-type-p arg) 'integer)
     ((typespec-eval--number-type-p arg) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-zerop (arg)
  "Evaluate `zerop` over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (zerop val))
          'unknown)))
     ((typespec-eval--float-range-p arg)
      (let* ((low (typespec-eval--float-bound-value (cadr arg)))
             (high (typespec-eval--float-bound-value (caddr arg)))
             (low-excl (typespec-eval--float-bound-exclusive-p (cadr arg)))
             (high-excl (typespec-eval--float-bound-exclusive-p (caddr arg))))
        (cond
         ((and (numberp low) (numberp high)
               (= low 0.0) (= high 0.0)
               (not low-excl) (not high-excl))
          (typespec-eval--make-const t))
         ((not (typespec-eval--float-range-includes-zero-p arg))
          (typespec-eval--make-const nil))
         (t 'boolean))))
     ((typespec-eval--integer-range-p arg)
      (let ((low (typespec-eval--integer-bound-min (cadr arg)))
            (high (typespec-eval--integer-bound-max (caddr arg))))
        (cond
         ((and (numberp low) (numberp high) (= low 0) (= high 0))
          (typespec-eval--make-const t))
         ((and (numberp low) (> low 0))
          (typespec-eval--make-const nil))
         ((and (numberp high) (< high 0))
          (typespec-eval--make-const nil))
         (t 'boolean))))
     ((typespec-eval--integer-type-p arg)
      'boolean)
     ((typespec-eval--number-type-p arg)
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-isnan (arg)
  "Evaluate `isnan` over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (isnan val))
          'unknown)))
     ((typespec-eval--float-range-p arg)
      (typespec-eval--make-const nil))
     ((memq arg '(positive-float negative-float non-negative-float non-positive-float))
      (typespec-eval--make-const nil))
     ((typespec-eval--integer-type-p arg)
      (typespec-eval--make-const nil))
     ((typespec-eval--number-type-p arg)
      'boolean)
     (t 'unknown))))

(defun typespec-eval--float-range-combine (lhs rhs op)
  "Combine float ranges LHS and RHS using OP, returning a float range or nil."
  (let* ((low1 (cadr lhs))
         (high1 (caddr lhs))
         (low2 (cadr rhs))
         (high2 (caddr rhs)))
    (pcase op
      (`+
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range
            (if (or (eq low1 '*) (eq low2 '*)) '* (+ low1 low2))
            (if (or (eq high1 '*) (eq high2 '*)) '* (+ high1 high2)))
         (typespec-eval--float-range (+ low1 low2) (+ high1 high2))))
      (`-
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range
            (if (or (eq low1 '*) (eq high2 '*)) '* (- low1 high2))
            (if (or (eq high1 '*) (eq low2 '*)) '* (- high1 low2)))
         (typespec-eval--float-range (- low1 high2) (- high1 low2))))
      (`*
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range '* '*)
         (let* ((candidates (list (* low1 low2) (* low1 high2)
                                  (* high1 low2) (* high1 high2)))
                (minv (apply #'min candidates))
                (maxv (apply #'max candidates)))
           (typespec-eval--float-range minv maxv))))
      (`/
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           nil
         (let ((zero-in-range (and (<= (min low2 high2) 0.0)
                                   (<= 0.0 (max low2 high2)))))
           (unless zero-in-range
             (let* ((candidates (list (/ low1 low2) (/ low1 high2)
                                      (/ high1 low2) (/ high1 high2)))
                    (minv (apply #'min candidates))
                    (maxv (apply #'max candidates)))
               (typespec-eval--float-range minv maxv))))))
      (_ nil))))

(defun typespec-eval--float-range-arith (args op)
  "Try to compute a float range for ARGS using OP."
  (when (seq-some #'typespec-eval--float-range-p args)
    (let ((ranges (mapcar #'typespec-eval--float-range-from args)))
      (when (seq-every-p #'identity ranges)
        (let ((result (car ranges)))
          (dolist (range (cdr ranges))
            (setq result (typespec-eval--float-range-combine result range op)))
          result)))))

(defun typespec-eval--const-integer-options (form)
  "Return a list of integer constants represented by FORM, or nil."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (integerp val) (list val))))
   ((and (consp form) (eq (car form) 'or))
    (let ((values nil)
          (ok t))
      (dolist (item (cdr form))
        (let ((opts (typespec-eval--const-integer-options item)))
          (if opts
              (setq values (append values opts))
            (setq ok nil))))
      (when ok values)))
   ((typespec-eval--integer-range-p form)
    (let ((low (cadr form))
          (high (caddr form)))
      (when (and (integerp low)
                 (integerp high)
                 (<= 0 (- high low))
                 (<= (- high low) typespec-eval--arith-option-limit))
        (number-sequence low high))))
   (t nil)))

(defun typespec-eval--arith-const-options (args op)
  "Return a simplified `(or ...)` for ARGS and OP when options are finite.
Return nil when options cannot be enumerated or exceed the limit."
  (let ((options (mapcar #'typespec-eval--const-integer-options args)))
    (when (seq-every-p #'identity options)
      (catch 'typespec-eval--arith
        (let ((results (car options)))
          (dolist (opts (cdr options))
            (let ((next nil))
              (dolist (lhs results)
                (dolist (rhs opts)
                  (push (funcall op lhs rhs) next)
                  (when (> (length next) typespec-eval--arith-option-limit)
                    (throw 'typespec-eval--arith nil))))
              (setq results (nreverse next))))
          (let* ((uniq (delete-dups (sort results #'<)))
                 (consts (mapcar #'typespec-eval--make-const uniq)))
            (typespec-eval--simplify-or consts)))))))

(defun typespec-eval--eval-arith (args op &optional zero-value)
  "Evaluate arithmetic OP over ARGS.
If all ARGS are numeric consts, return a const result.
ZERO-VALUE is used when ARGS is empty."
  (let* ((args (mapcar #'typespec-eval--eval args))
         (div-check (when (and (eq op #'/) (>= (length args) 2))
                      (let ((denoms (cdr args)))
                        (cond
                         ((seq-some (lambda (arg)
                                      (and (typespec-eval--const-p arg)
                                           (numberp (typespec-eval--const-value arg))
                                           (zerop (typespec-eval--const-value arg))))
                                    denoms)
                          'never)
                         ((seq-some (lambda (arg)
                                      (let ((info (typespec-eval--numeric-range-info arg)))
                                        (and info (typespec-eval--numeric-range-includes-zero-p info))))
                                    denoms)
                          'unknown))))))
    (cond
     ((null args)
      (if (null zero-value) 'unknown (typespec-eval--make-const zero-value)))
     (div-check div-check)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply op values))
          'unknown)))
     ((typespec-eval--arith-const-options args op))
     ((typespec-eval--float-range-arith args op))
     (t (typespec-eval--arith-type args)))))

(defun typespec-eval--eval-rem (args)
  "Evaluate a `%` expression over ARGS."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) 'unknown)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'integerp values)
            (typespec-eval--make-const (apply #'% values))
          'unknown)))
     ((and (= (length args) 2)
           (seq-every-p #'typespec-eval--integer-or-const-p args))
      (let* ((lhs (car args))
             (rhs (cadr args))
             (lhs-range (typespec-eval--integer-range-from lhs))
             (rhs-range (typespec-eval--integer-range-from rhs))
             (rhs-info (typespec-eval--numeric-range-info rhs)))
        (cond
         ((and rhs-info (typespec-eval--numeric-range-includes-zero-p rhs-info))
          (if (and (typespec-eval--numeric-range-singleton-p rhs-info)
                   (zerop (plist-get rhs-info :low)))
              'never
            'unknown))
         ((and lhs-range rhs-range)
          (let* ((lowa (typespec-eval--integer-bound-min (cadr lhs-range)))
                 (higha (typespec-eval--integer-bound-max (caddr lhs-range)))
                 (lowb (typespec-eval--integer-bound-min (cadr rhs-range)))
                 (highb (typespec-eval--integer-bound-max (caddr rhs-range))))
            (when (and (numberp lowb) (numberp highb)
                       (not (<= lowb 0 highb)))
              (let ((abs-max (max (abs lowb) (abs highb))))
                (cond
                 ((and (numberp lowa) (>= lowa 0))
                  (typespec-eval--integer-range 0 (1- abs-max)))
                 ((and (numberp higha) (<= higha 0))
                  (typespec-eval--integer-range (- (1- abs-max)) 0))
                 (t
                  (typespec-eval--integer-range (- (1- abs-max)) (1- abs-max)))))))))))
     ((seq-every-p #'typespec-eval--integer-or-const-p args) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-mod (args)
  "Evaluate a `mod` expression over ARGS."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) 'unknown)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply #'mod values))
          'unknown)))
     ((seq-some #'typespec-eval--float-type-p args) 'float)
     ((and (= (length args) 2)
           (seq-every-p #'typespec-eval--integer-or-const-p args))
      (let* ((rhs (cadr args))
             (rhs-range (typespec-eval--integer-range-from rhs))
             (rhs-info (typespec-eval--numeric-range-info rhs)))
        (cond
         ((and rhs-info (typespec-eval--numeric-range-includes-zero-p rhs-info))
          (if (and (typespec-eval--numeric-range-singleton-p rhs-info)
                   (zerop (plist-get rhs-info :low)))
              'never
            'unknown))
         (rhs-range
          (let* ((lowb (typespec-eval--integer-bound-min (cadr rhs-range)))
                 (highb (typespec-eval--integer-bound-max (caddr rhs-range))))
            (cond
             ((and (numberp lowb) (numberp highb)
                   (not (<= lowb 0 highb)))
              (if (> lowb 0)
                  (typespec-eval--integer-range 0 (1- highb))
                (typespec-eval--integer-range (1+ lowb) 0)))
             (t 'integer))))
         (t 'integer))))
     ((seq-every-p #'typespec-eval--integer-or-const-p args) 'integer)
     ((seq-every-p #'typespec-eval--number-type-p args) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-integer-variadic (args op &optional zero-value)
  "Evaluate integer OP over ARGS, returning `integer` or a const.
ZERO-VALUE is used when ARGS is empty."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args)
      (if (null zero-value) 'unknown (typespec-eval--make-const zero-value)))
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'integerp values)
            (typespec-eval--make-const (apply op values))
          'unknown)))
     ((and (memq op '(logand logior logxor))
           (seq-every-p #'typespec-eval--non-negative-int-type-p args))
      '(integer 0 *))
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-ash (value count)
  "Evaluate an `ash` expression for VALUE and COUNT."
  (let ((value (typespec-eval--eval value))
        (count (typespec-eval--eval count)))
    (cond
     ((and (typespec-eval--const-p value)
           (typespec-eval--const-p count)
           (integerp (typespec-eval--const-value value))
           (integerp (typespec-eval--const-value count)))
      (typespec-eval--make-const
       (ash (typespec-eval--const-value value)
            (typespec-eval--const-value count))))
     ((and (typespec-eval--non-negative-int-type-p value)
           (typespec-eval--integer-type-p count))
      '(integer 0 *))
     ((and (typespec-eval--integer-type-p value)
           (typespec-eval--integer-type-p count))
      'integer)
     (t 'unknown))))

(defun typespec-eval--eval-number-sequence (from &optional to inc)
  "Evaluate a `number-sequence` expression for FROM, TO, and INC."
  (let* ((from (typespec-eval--eval from))
         (to (when to (typespec-eval--eval to)))
         (inc (when inc (typespec-eval--eval inc)))
         (from-val (and (typespec-eval--const-p from)
                        (typespec-eval--const-value from)))
         (to-val (and (typespec-eval--const-p to)
                      (typespec-eval--const-value to)))
         (inc-val (and (typespec-eval--const-p inc)
                       (typespec-eval--const-value inc))))
    (cond
     ((and (numberp from-val)
           (or (null to) (numberp to-val))
           (or (null inc) (numberp inc-val)))
      (typespec-eval--make-const (number-sequence from-val to-val inc-val)))
     ((and (typespec-eval--number-or-const-p from)
           (or (null to) (typespec-eval--number-or-const-p to))
           (or (null inc) (typespec-eval--number-or-const-p inc)))
      (if (or (eq from 'number)
              (eq to 'number)
              (eq inc 'number))
          '(list number)
        (let* ((from-info (typespec-eval--numeric-range-info from))
               (to-info (and to (typespec-eval--numeric-range-info to)))
               (inc-default (null inc))
               (inc-info (and inc (typespec-eval--numeric-range-info inc)))
               (inc-zero (and inc-info (typespec-eval--numeric-range-includes-zero-p inc-info)))
               (inc-singleton-zero
                (and inc-info
                     (typespec-eval--numeric-range-singleton-p inc-info)
                     (let ((val (plist-get inc-info :low)))
                       (and (numberp val) (= val 0)))))
               (inc-pos (or inc-default
                            (and inc-info (typespec-eval--numeric-range-positive-p inc-info))))
               (inc-neg (and inc-info (typespec-eval--numeric-range-negative-p inc-info)))
               (from-low (and from-info (plist-get from-info :low)))
               (from-high (and from-info (plist-get from-info :high)))
               (to-low (and to-info (plist-get to-info :low)))
               (to-high (and to-info (plist-get to-info :high)))
               (float-output (or (typespec-eval--float-type-p from)
                                 (typespec-eval--float-type-p to)
                                 (typespec-eval--float-type-p inc))))
          (cond
           (inc-singleton-zero 'never)
           ((and inc-zero (not inc-singleton-zero)) 'unknown)
           ((and inc-info (not inc-pos) (not inc-neg))
            '(list number))
           ((and inc-pos from-low to-high (> from-low to-high))
            (typespec-eval--make-const nil))
           ((and inc-neg from-high to-low (< from-high to-low))
            (typespec-eval--make-const nil))
           (t
            (let* ((non-empty
                    (cond
                     ((and inc-pos from-high to-low (<= from-high to-low)) t)
                     ((and inc-neg from-low to-high (>= from-low to-high)) t)
                     (t nil)))
                   (low (cond
                         (inc-pos from-low)
                         (inc-neg to-low)
                         (t (typespec-eval--numeric-min from-low to-low))))
                   (high (cond
                          (inc-pos to-high)
                          (inc-neg from-high)
                          (t (typespec-eval--numeric-max from-high to-high))))
                   (singleton (null to))
                   (low (or low '*))
                   (high (or high '*))
                   (elem (cond
                          (singleton
                           (let* ((s-low (or from-low low))
                                  (s-high (or from-high high)))
                             (if float-output
                                 (typespec-eval--float-range
                                  (if (eq s-low '*) s-low (float s-low))
                                  (if (eq s-high '*) s-high (float s-high)))
                               (typespec-eval--integer-range s-low s-high))))
                          (float-output
                           (typespec-eval--float-range
                            (if (eq low '*) low (float low))
                            (if (eq high '*) high (float high))))
                          (t
                           (typespec-eval--integer-range low high)))))
              (list (if (or non-empty singleton) 'list+ 'list) elem)))))))
     (t 'unknown))))

(defun typespec-eval--eval-car-safe (arg)
  "Evaluate a `car-safe` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (typespec-eval--make-const (car-safe val))))
     ((eq (car-safe arg) 'list+)
      (cadr arg))
     ((eq (car-safe arg) 'list)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil) (cadr arg))))
     (t 'unknown))))

(defun typespec-eval--eval-cdr-safe (arg)
  "Evaluate a `cdr-safe` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (typespec-eval--make-const (cdr-safe val))))
     ((memq (car-safe arg) '(list list+))
      (list 'list (cadr arg)))
     (t 'unknown))))

(defun typespec-eval--eval-nth (n list)
  "Evaluate an `nth` expression for N and LIST.
When N is 0, behaves like `car` (including special handling for `list+`)."
  (let* ((n (typespec-eval--eval n))
         (list (typespec-eval--eval list))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p list) (integerp nval))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (nth nval val))
          'unknown)))
     ((and (integerp nval) (= nval 0) (eq (car-safe list) 'list+))
      ;; For nth 0 on list+, return element type directly (no nil)
      (cadr list))
     ((typespec-eval--list-elem-type list)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval--list-elem-type list))))
     (t 'unknown))))

(defun typespec-eval--eval-nthcdr (n list)
  "Evaluate an `nthcdr` expression for N and LIST.
When N is 1, behaves like `cdr`."
  (let* ((n (typespec-eval--eval n))
         (list (typespec-eval--eval list))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--always-nil-p list) (integerp nval))
      'nil)
     ((and (typespec-eval--const-p list) (integerp nval))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (if (null val)
                'nil
              (typespec-eval--make-const (nthcdr nval val)))
          'unknown)))
     ((and (consp list) (eq (car list) :tuple) (integerp nval))
      (let ((tuple (typespec-eval--tuple-unconst (cdr list))))
        (if (<= nval 0)
            (cons :tuple tuple)
          (let ((tail (nthcdr nval tuple)))
            (if (listp tail)
                (cons :tuple tail)
              (typespec-eval--eval (cdr list)))))))
     ((typespec-eval--list-elem-type list)
      (list 'list (typespec-eval--list-elem-type list)))
     (t 'unknown))))

(defun typespec-eval--eval-elt (sequence n)
  "Evaluate an `elt` expression for SEQUENCE and N."
  (let* ((sequence (typespec-eval--eval sequence))
         (n (typespec-eval--eval n))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p sequence) (integerp nval))
      (let ((val (typespec-eval--const-value sequence)))
        (condition-case nil
            (typespec-eval--make-const (elt val nval))
          (args-out-of-range 'unknown))))
     ((typespec-eval--string-type-p sequence) 'integer)
     ((typespec-eval--list-elem-type sequence) (typespec-eval--list-elem-type sequence))
     ((typespec-eval--vector-of-p sequence 'integer) 'integer)
     ((and (consp sequence) (eq (car sequence) 'vector))
      (cadr sequence))
     (t 'unknown))))

(defun typespec-eval--eval-aref (array n)
  "Evaluate an `aref` expression for ARRAY and N."
  (let* ((array (typespec-eval--eval array))
         (n (typespec-eval--eval n))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p array) (integerp nval))
      (let ((val (typespec-eval--const-value array)))
        (condition-case nil
            (typespec-eval--make-const (aref val nval))
          (args-out-of-range 'unknown))))
     ((typespec-eval--string-type-p array) 'integer)
     ((and (consp array) (eq (car array) 'vector))
      (cadr array))
     (t 'unknown))))

(defun typespec-eval--eval-sequence-identity (arg fn)
  "Evaluate a sequence-preserving operation FN over ARG.
FN is applied to const values; the type structure is preserved for typed args."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (or (listp val) (vectorp val) (stringp val))
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ((eq (car-safe arg) 'list+) (list 'list+ (cadr arg)))
     ((eq (car-safe arg) 'list) (list 'list (cadr arg)))
     ((typespec-eval--string-type-p arg) 'string)
     ((and (consp arg) (eq (car arg) 'vector))
      (list 'vector (cadr arg)))
     (t 'unknown))))

(defun typespec-eval--eval-safe-length (list)
  "Evaluate a `safe-length` expression for LIST."
  (let ((list (typespec-eval--eval list)))
    (cond
     ((typespec-eval--const-p list)
      (typespec-eval--make-const (safe-length (typespec-eval--const-value list))))
     ((eq (car-safe list) 'list+)
      (typespec-eval--integer-range 1 '*))
     ((eq (car-safe list) 'list)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval--eval-last (list &optional n)
  "Evaluate a `last` expression for LIST and N."
  (let* ((list (typespec-eval--eval list))
         (n (when n (typespec-eval--eval n)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p list) (or (null n) (integerp nval)))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (last val nval))
          'unknown)))
    ((eq (car-safe list) 'list+)
      (cond
       ((null n) (list 'list+ (cadr list)))
       ((and (integerp nval) (< nval 0)) (typespec-eval--make-const nil))
       ((and (integerp nval) (= nval 0)) (typespec-eval--make-const nil))
       ((and (integerp nval) (> nval 0)) (list 'list+ (cadr list)))
       (t (list 'list (cadr list)))))
     ((eq (car-safe list) 'list)
      (cond
       ((and (integerp nval) (< nval 0)) (typespec-eval--make-const nil))
       ((and (integerp nval) (= nval 0)) (typespec-eval--make-const nil))
       (t (list 'list (cadr list)))))
     (t 'unknown))))

(defun typespec-eval--eval-butlast (list &optional n)
  "Evaluate a `butlast` expression for LIST and N."
  (let* ((list (typespec-eval--eval list))
         (n (when n (typespec-eval--eval n)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p list) (or (null n) (integerp nval)))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (butlast val nval))
          'unknown)))
     ((eq (car-safe list) 'list+)
      (cond
       ((and (integerp nval) (<= nval 0)) (list 'list+ (cadr list)))
       ((integerp nval) (list 'list (cadr list)))
       (t (list 'list (cadr list)))))
     ((eq (car-safe list) 'list)
      (cond
       ((and (integerp nval) (<= nval 0)) (list 'list (cadr list)))
       ((integerp nval) (list 'list (cadr list)))
       (t (list 'list (cadr list)))))
     (t 'unknown))))

(defun typespec-eval--eval-alist-search (search-item alist search-key-p compare-fn)
  "Evaluate alist search expression.
SEARCH-ITEM is the key or value to search for.
ALIST is the alist to search in.
SEARCH-KEY-P is non-nil to search by key, nil to search by value.
COMPARE-FN is the comparison function (#\\='eq or #\\='equal)."
  (let* ((search-item (typespec-eval--eval search-item))
         (alist (typespec-eval--eval alist)))
    (cond
     ((and (typespec-eval--const-p search-item) (typespec-eval--const-p alist))
      (let ((alist-val (typespec-eval--const-value alist))
            (item-val (typespec-eval--const-value search-item)))
        (if (listp alist-val)
            (typespec-eval--make-const
             (if search-key-p
                 (if (eq compare-fn #'eq)
                     (assq item-val alist-val)
                   (assoc item-val alist-val))
               (if (eq compare-fn #'eq)
                   (rassq item-val alist-val)
                 (rassoc item-val alist-val))))
          'unknown)))
     ((typespec-eval--alist-type-p alist)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (cons :tuple (cons (typespec-eval--alist-key-type alist)
                                (typespec-eval--alist-value-type alist))))))
     (t 'unknown))))


(defun typespec-eval--eval-assoc-default (key alist &optional test default)
  "Evaluate an `assoc-default` expression for KEY, ALIST, TEST, and DEFAULT."
  (let* ((key (typespec-eval--eval key))
         (alist (typespec-eval--eval alist))
         (test (when test (typespec-eval--eval test)))
         (default (when default (typespec-eval--eval default))))
    (cond
     ((and (typespec-eval--const-p key)
           (typespec-eval--const-p alist)
           (or (null test) (typespec-eval--const-p test))
           (or (null default) (typespec-eval--const-p default)))
      (let ((alist-val (typespec-eval--const-value alist)))
        (if (listp alist-val)
            (typespec-eval--make-const
             (assoc-default (typespec-eval--const-value key)
                            alist-val
                            (when test (typespec-eval--const-value test))
                            (when default (typespec-eval--const-value default))))
          'unknown)))
     ((typespec-eval--alist-type-p alist)
      (let ((value-type (typespec-eval--alist-value-type alist)))
        (if default
            (typespec-eval--simplify-or (list default value-type))
          (typespec-eval--simplify-or
           (list (typespec-eval--make-const nil) value-type)))))
     (t 'unknown))))

(defun typespec-eval--eval-alist-get (key alist &optional default remove testfn)
  "Evaluate an `alist-get` expression for KEY, ALIST, DEFAULT, and TESTFN.
REMOVE is ignored in the type evaluator."
  (ignore remove)
  (let* ((key (typespec-eval--eval key))
         (alist (typespec-eval--eval alist))
         (default (when default (typespec-eval--eval default)))
         (testfn (when testfn (typespec-eval--eval testfn))))
    (cond
     ((and (typespec-eval--const-p key)
           (typespec-eval--const-p alist)
           (or (null default) (typespec-eval--const-p default))
           (or (null testfn) (typespec-eval--const-p testfn)))
      (let ((alist-val (typespec-eval--const-value alist)))
        (if (listp alist-val)
            (typespec-eval--make-const
             (alist-get (typespec-eval--const-value key)
                        alist-val
                        (when default (typespec-eval--const-value default))
                        nil
                        (when testfn (typespec-eval--const-value testfn))))
          'unknown)))
     ((typespec-eval--alist-type-p alist)
      (let ((value-type (typespec-eval--alist-value-type alist)))
        (if default
            (typespec-eval--simplify-or (list default value-type))
          (typespec-eval--simplify-or
           (list (typespec-eval--make-const nil) value-type)))))
     (t 'unknown))))


(defun typespec-eval--eval-plist-get (plist key &optional default)
  "Evaluate a `plist-get` expression for PLIST, KEY, and DEFAULT."
  (let* ((plist (typespec-eval--eval plist))
         (key (typespec-eval--eval key))
         (default (when default (typespec-eval--eval default))))
    (cond
     ((and (typespec-eval--const-p plist)
           (typespec-eval--const-p key)
           (or (null default) (typespec-eval--const-p default)))
      (let ((plist-val (typespec-eval--const-value plist)))
        (if (listp plist-val)
            (typespec-eval--make-const
             (plist-get plist-val
                        (typespec-eval--const-value key)
                        (when default (typespec-eval--const-value default))))
          'unknown)))
     ((typespec-eval--plist-type-p plist)
      (let* ((value-type (typespec-eval--plist-value-type plist))
             (items (list (typespec-eval--make-const nil) value-type)))
        (when default
          (setq items (append items (list default))))
        (typespec-eval--simplify-or items)))
     ((typespec-eval--plist-of-p plist)
      (let* ((entry-type (and (typespec-eval--const-p key)
                              (typespec-eval--plist-of-entry-type
                               plist (typespec-eval--const-value key))))
             (value-type (typespec-eval--plist-of-value-type plist))
             (items (list (typespec-eval--make-const nil)
                          (or entry-type value-type))))
        (when default
          (setq items (append items (list default))))
        (typespec-eval--simplify-or items)))
     (t 'unknown))))

(defun typespec-eval--eval-plist-member (plist key)
  "Evaluate a `plist-member` expression for PLIST and KEY."
  (let* ((plist (typespec-eval--eval plist))
         (key (typespec-eval--eval key)))
    (cond
     ((and (typespec-eval--const-p plist)
           (typespec-eval--const-p key))
      (let ((plist-val (typespec-eval--const-value plist)))
        (if (listp plist-val)
            (typespec-eval--make-const
             (plist-member plist-val (typespec-eval--const-value key)))
          'unknown)))
     ((or (typespec-eval--plist-type-p plist)
          (typespec-eval--plist-of-p plist))
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             '(list+ mixed))))
     (t 'unknown))))

(defun typespec-eval--eval-seq-length (sequence)
  "Evaluate a `seq-length` expression for SEQUENCE."
  (let ((sequence (typespec-eval--eval sequence)))
    (cond
     ((typespec-eval--const-p sequence)
      (typespec-eval--make-const (seq-length (typespec-eval--const-value sequence))))
     ((typespec-eval--string-type-p sequence)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval--list-type-p sequence)
      (typespec-eval--integer-range (if (eq (car-safe sequence) 'list+) 1 0) '*))
     ((typespec-eval--vector-type-p sequence)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))


(defun typespec-eval--eval-seq-empty-p (sequence)
  "Evaluate a `seq-empty-p` predicate for SEQUENCE."
  (let ((sequence (typespec-eval--eval sequence)))
    (cond
     ((typespec-eval--const-p sequence)
      (typespec-eval--make-const (seq-empty-p (typespec-eval--const-value sequence))))
     ((typespec-eval--non-empty-string-p sequence)
      (typespec-eval--make-const nil))
     ((eq (car-safe sequence) 'list+)
      (typespec-eval--make-const nil))
     ((or (typespec-eval--string-type-p sequence)
          (typespec-eval--list-type-p sequence)
          (typespec-eval--vector-type-p sequence))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-cl-endp (arg)
  "Evaluate a `cl-endp` predicate for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (cl-endp (typespec-eval--const-value arg))))
     ((eq (car-safe arg) 'list+)
      (typespec-eval--make-const nil))
     ((typespec-eval--list-type-p arg) 'boolean)
     (t 'unknown))))


(defun typespec-eval--eval-cl-list-length (arg)
  "Evaluate a `cl-list-length` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (cl-list-length (typespec-eval--const-value arg))))
     ((typespec-eval--list-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))


(defun typespec-eval--eval-type-of (arg fn)
  "Evaluate type function FN over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (funcall fn (typespec-eval--const-value arg))))
     (t 'symbol))))

(defun typespec-eval--eval-symbol-name (arg)
  "Evaluate a `symbol-name` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (symbolp val)
            (typespec-eval--make-const (symbol-name val))
          'unknown)))
     ((typespec-eval--symbol-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-kbd (arg)
  "Evaluate a `kbd` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (kbd val))
          'unknown)))
     ((typespec-eval--string-type-p arg)
      (typespec-eval--simplify-or (list 'string '(vector integer))))
     (t 'unknown))))

(defun typespec-eval--eval-make-composed-keymap (maps &optional parent)
  "Evaluate a `make-composed-keymap` expression for MAPS and PARENT."
  (let ((maps (typespec-eval--eval maps))
        (parent (when parent (typespec-eval--eval parent))))
    (cond
     ((and (typespec-eval--const-p maps)
           (or (null parent) (typespec-eval--const-p parent)))
      (typespec-eval--make-const
       (make-composed-keymap (typespec-eval--const-value maps)
                             (when parent (typespec-eval--const-value parent)))))
     (t 'keymap))))

(defun typespec-eval--eval-sha1 (arg)
  "Evaluate a `sha1` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (sha1 val))
          'unknown)))
     ((typespec-eval--string-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-syntax-class (arg)
  "Evaluate a `syntax-class` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (integerp val)
            (typespec-eval--make-const (syntax-class val))
          'unknown)))
     ((typespec-eval--integer-type-p arg) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-version-to-list (arg)
  "Evaluate a `version-to-list` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (version-to-list val))
          'unknown)))
     ((typespec-eval--string-type-p arg) '(list integer))
     (t 'unknown))))

(defun typespec-eval--eval-version-list-not-zero (lst)
  "Evaluate a `version-list-not-zero` expression for LST."
  (let ((lst (typespec-eval--eval lst)))
    (cond
     ((typespec-eval--const-p lst)
      (let ((val (typespec-eval--const-value lst)))
        (if (listp val)
            (typespec-eval--make-const (version-list-not-zero val))
          'unknown)))
     ((typespec-eval--list-type-p lst) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-version-list-compare (lhs rhs fn)
  "Evaluate version list comparison FN over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (let ((lval (typespec-eval--const-value lhs))
            (rval (typespec-eval--const-value rhs)))
        (if (and (listp lval) (listp rval))
            (typespec-eval--make-const (funcall fn lval rval))
          'unknown)))
     ((and (typespec-eval--list-type-p lhs)
           (typespec-eval--list-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-version-compare (lhs rhs fn)
  "Evaluate version string comparison FN over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (funcall fn (typespec-eval--const-value lhs)
                (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-assoc-delete-all (key alist &optional test)
  "Evaluate an `assoc-delete-all`/`assq-delete-all` expression.
KEY, ALIST, and TEST are evaluated."
  (let* ((key (typespec-eval--eval key))
         (alist (typespec-eval--eval alist))
         (test (when test (typespec-eval--eval test))))
    (cond
     ((and (typespec-eval--const-p key)
           (typespec-eval--const-p alist)
           (or (null test) (typespec-eval--const-p test) (symbolp test)))
      (let ((alist-val (typespec-eval--const-value alist)))
        (if (listp alist-val)
            (typespec-eval--make-const
             (assoc-delete-all (typespec-eval--const-value key)
                               alist-val
                               (cond
                                ((null test) nil)
                                ((typespec-eval--const-p test)
                                 (typespec-eval--const-value test))
                                (t test))))
          'unknown)))
     ((typespec-eval--alist-type-p alist) alist)
     (t 'unknown))))

(defun typespec-eval--eval-rassq-delete-all (value alist)
  "Evaluate a `rassq-delete-all` expression for VALUE and ALIST."
  (let* ((value (typespec-eval--eval value))
         (alist (typespec-eval--eval alist)))
    (cond
     ((and (typespec-eval--const-p value)
           (typespec-eval--const-p alist))
      (let ((alist-val (typespec-eval--const-value alist)))
        (if (listp alist-val)
            (typespec-eval--make-const
             (rassq-delete-all (typespec-eval--const-value value) alist-val))
          'unknown)))
     ((typespec-eval--alist-type-p alist) alist)
     (t 'unknown))))

(defun typespec-eval--eval-remove-like (elt sequence fn &optional list-only)
  "Evaluate element removal FN over ELT and SEQUENCE.
If LIST-ONLY is non-nil, only handle list types."
  (let ((elt (typespec-eval--eval elt))
        (sequence (typespec-eval--eval sequence)))
    (cond
     ((and (typespec-eval--const-p elt) (typespec-eval--const-p sequence))
      (let ((seq (typespec-eval--const-value sequence)))
        (condition-case nil
            (typespec-eval--make-const (funcall fn (typespec-eval--const-value elt) seq))
          (error 'unknown))))
     ((eq (car-safe sequence) 'list)
      (list 'list (cadr sequence)))
     ((eq (car-safe sequence) 'list+)
      (list 'list (cadr sequence)))
     ((and (not list-only) (typespec-eval--string-type-p sequence)) 'string)
     ((and (not list-only) (consp sequence) (eq (car sequence) 'vector))
      (list 'vector (cadr sequence)))
     (t 'unknown))))

(defun typespec-eval--eval-member-like (elt list fn)
  "Evaluate list membership function FN over ELT and LIST."
  (let ((elt (typespec-eval--eval elt))
        (list (typespec-eval--eval list)))
    (cond
     ((and (typespec-eval--const-p elt) (typespec-eval--const-p list))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (funcall fn (typespec-eval--const-value elt) val))
          'unknown)))
     ((typespec-eval--list-elem-type list)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (list 'list (typespec-eval--list-elem-type list)))))
     (t 'unknown))))

(defun typespec-eval--eval-copy-tree (tree &optional vectors-and-records)
  "Evaluate a `copy-tree` expression for TREE and VECTORS-AND-RECORDS."
  (let ((tree (typespec-eval--eval tree))
        (vectors-and-records (when vectors-and-records
                               (typespec-eval--eval vectors-and-records))))
    (cond
     ((and (typespec-eval--const-p tree)
           (or (null vectors-and-records)
               (typespec-eval--const-p vectors-and-records)))
      (let ((val (typespec-eval--const-value tree)))
        (condition-case nil
            (typespec-eval--make-const
             (copy-tree val
                        (when vectors-and-records
                          (typespec-eval--const-value vectors-and-records))))
          (error 'unknown))))
     ((memq (car-safe tree) '(list list+)) tree)
     ((and (consp tree) (eq (car tree) 'vector))
      (if vectors-and-records tree 'unknown))
     (t tree))))

(defun typespec-eval--eval-delete-dups (list)
  "Evaluate a `delete-dups` expression for LIST."
  (let ((list (typespec-eval--eval list)))
    (cond
     ((typespec-eval--const-p list)
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (delete-dups (copy-sequence val)))
          'unknown)))
     ((eq (car-safe list) 'list)
      (list 'list (cadr list)))
     ((eq (car-safe list) 'list+)
      (list 'list (cadr list)))
     (t 'unknown))))

(defun typespec-eval--eval-delete-consecutive-dups (list &optional circular)
  "Evaluate a `delete-consecutive-dups` expression for LIST and CIRCULAR."
  (let ((list (typespec-eval--eval list))
        (circular (when circular (typespec-eval--eval circular))))
    (cond
     ((and (typespec-eval--const-p list)
           (or (null circular) (typespec-eval--const-p circular)))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const
             (delete-consecutive-dups (copy-sequence val)
                                      (when circular
                                        (typespec-eval--const-value circular))))
          'unknown)))
     ((eq (car-safe list) 'list)
      (list 'list (cadr list)))
     ((eq (car-safe list) 'list+)
      (list 'list (cadr list)))
     (t 'unknown))))

(defun typespec-eval--eval-minmax (args op)
  "Evaluate a MIN/MAX expression over ARGS using OP."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) 'unknown)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply op values))
          'unknown)))
     ((seq-every-p #'typespec-eval--integer-type-p args)
      (let ((ranges (mapcar #'typespec-eval--integer-range-from args)))
        (if (seq-every-p #'identity ranges)
            (or (typespec-eval--minmax-range ranges op) 'integer)
          'integer)))
     ((and (seq-every-p #'typespec-eval--number-type-p args)
           (seq-some #'typespec-eval--float-type-p args))
      (let ((ranges (mapcar #'typespec-eval--float-range-from args)))
        (if (seq-every-p #'identity ranges)
            (or (typespec-eval--minmax-range ranges op) 'float)
          'float)))
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
     ((seq-every-p #'typespec-eval--float-type-p args) 'float)
     ((seq-every-p #'typespec-eval--number-type-p args) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-length (arg)
  "Evaluate a `length` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (length (typespec-eval--const-value arg))))
     ((typespec-eval--non-empty-string-p arg)
      (typespec-eval--integer-range 1 '*))
     ((eq arg 'string)
      (typespec-eval--integer-range 0 '*))
     ((and (consp arg) (eq (car arg) 'list+))
      (typespec-eval--integer-range 1 '*))
     ((typespec-eval--list-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval--eval-string-bytes (arg)
  "Evaluate a `string-bytes` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-bytes val))
          'unknown)))
     ((typespec-eval--non-empty-string-p arg)
      (typespec-eval--integer-range 1 '*))
     ((eq arg 'string)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval--eval-substring (string start &optional end)
  "Evaluate a `substring` expression for STRING, START, and END."
  (let* ((string (typespec-eval--eval string))
         (start (typespec-eval--eval start))
         (end (when end (typespec-eval--eval end)))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (start-val (typespec-eval--const-integer-value start))
         (end-val (and end (typespec-eval--const-integer-value end))))
    (cond
     ((and (stringp sval)
           (integerp start-val)
           (or (null end) (integerp end-val)))
      (condition-case nil
          (typespec-eval--make-const
           (substring sval start-val end-val))
        (args-out-of-range 'never)))
     ((and (typespec-eval--string-type-p string)
           (integerp start-val)
           (integerp end-val)
           (= start-val 0)
           (= end-val 1))
      (typespec-eval--non-empty-string-expr))
     ((and (typespec-eval--string-type-p string)
           (integerp start-val)
           (integerp end-val)
           (= start-val end-val))
      (typespec-eval--make-const ""))
     ((and (typespec-eval--string-type-p string)
           (typespec-eval--integer-type-p start)
           (typespec-eval--positive-int-type-p end))
      (typespec-eval--non-empty-string-expr))
     ((and (typespec-eval--string-type-p string)
           (typespec-eval--integer-type-p start)
           (typespec-eval--integer-type-p end))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-pad (string length &optional padding start)
  "Evaluate a `string-pad` expression for STRING, LENGTH, PADDING, and START."
  (let* ((string (typespec-eval--eval string))
         (length (typespec-eval--eval length))
         (padding (when padding (typespec-eval--eval padding)))
         (start (when start (typespec-eval--eval start)))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (len (typespec-eval--const-integer-value length))
         (pad (and (typespec-eval--const-p padding)
                   (typespec-eval--const-value padding)))
         (pad-ok (or (null padding) (stringp pad) (characterp pad)))
         (start-ok (or (null start)
                       (and (typespec-eval--const-p start)
                            (memq (typespec-eval--const-value start) '(t nil))))))
    (cond
     ((and (stringp sval) (integerp len) pad-ok start-ok)
      (typespec-eval--make-const
       (string-pad sval len pad (when start (typespec-eval--const-value start)))))
     ((and (typespec-eval--string-type-p string)
           (typespec-eval--integer-type-p length))
      (if (typespec-eval--positive-int-type-p length)
          (typespec-eval--non-empty-string-expr)
        'string))
     (t 'unknown))))

(defun typespec-eval--eval-string-equal (lhs rhs)
  "Evaluate a `string-equal` expression over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (let ((mapped
             (typespec-eval--map-const-or
              lhs
              (lambda (item)
                (let ((res (typespec-eval--eval-string-equal item rhs)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (consp rhs) (eq (car rhs) 'or))
      (let ((mapped
             (typespec-eval--map-const-or
              rhs
              (lambda (item)
                (let ((res (typespec-eval--eval-string-equal lhs item)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-equal (typespec-eval--const-value lhs)
                     (typespec-eval--const-value rhs))))
     ((and (eq lhs 'string) (eq rhs 'string)) 'boolean)
     ((or (eq lhs 'string) (eq rhs 'string)) 'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-string-prefix-p (prefix string &optional ignore-case)
  "Evaluate a `string-prefix-p` expression for PREFIX, STRING, and IGNORE-CASE."
  (let ((prefix (typespec-eval--eval prefix))
        (string (typespec-eval--eval string))
        (ignore-case (when ignore-case (typespec-eval--eval ignore-case))))
    (cond
     ((and (consp prefix) (eq (car prefix) 'or))
      (let ((mapped
             (typespec-eval--map-const-or
              prefix
              (lambda (item)
                (let ((res (typespec-eval--eval-string-prefix-p item string ignore-case)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (consp string) (eq (car string) 'or))
      (let ((mapped
             (typespec-eval--map-const-or
              string
              (lambda (item)
                (let ((res (typespec-eval--eval-string-prefix-p prefix item ignore-case)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (typespec-eval--const-p prefix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value prefix))
           (stringp (typespec-eval--const-value string))
           (or (null ignore-case)
               (and (typespec-eval--const-p ignore-case)
                    (memq (typespec-eval--const-value ignore-case) '(t nil)))))
      (typespec-eval--make-const
       (string-prefix-p (typespec-eval--const-value prefix)
                        (typespec-eval--const-value string)
                        (when ignore-case
                          (typespec-eval--const-value ignore-case)))))
     ((and (eq prefix 'string) (eq string 'string)) 'boolean)
     ((or (eq prefix 'string) (eq string 'string)) 'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-not (arg)
  "Evaluate a `not` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (not (typespec-eval--const-value arg))))
     ((typespec-eval--always-nil-p arg)
      (typespec-eval--make-const t))
     ((typespec-eval--always-non-nil-p arg)
      (typespec-eval--make-const nil))
     ((eq arg 'boolean) 'boolean)
     (t 'boolean))))


(defun typespec-eval--eval-and (args)
  "Evaluate an `and` expression over ARGS."
  (let ((items (mapcar #'typespec-eval--eval args)))
    (typespec-eval--simplify-and items)))

(defun typespec-eval--const-string-options (form)
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
        (let ((opts (typespec-eval--const-string-options item)))
          (if opts
              (setq strings (append strings opts))
            (setq ok nil))))
      (and ok strings)))
   (t nil)))

(defun typespec-eval--const-regexp-options (form)
  "Return list of regexp strings for FORM, or nil if unknown."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (stringp val) (list val))))
   ((typespec-eval--rx-type-p form)
    (let ((regexp (typespec-eval--rx-form-to-regexp form)))
      (when regexp (list regexp))))
   ((and (consp form) (eq (car form) 'or))
    (let ((regexps nil)
          (ok t))
      (dolist (item (cdr form))
        (let ((opts (typespec-eval--const-regexp-options item)))
          (if opts
              (setq regexps (append regexps opts))
            (setq ok nil))))
      (and ok regexps)))
   (t nil)))

(defun typespec-eval--concat-combinations (options-list)
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

(defun typespec-eval--eval-concat (args)
  "Evaluate a `concat` expression over ARGS."
  (let ((eval-args (mapcar #'typespec-eval--eval args))
        (options nil)
        (all-const t))
    (dolist (arg eval-args)
      (let ((opts (typespec-eval--const-string-options arg)))
        (if opts
            (push opts options)
          (setq all-const nil))))
    (if all-const
        (let ((results (typespec-eval--concat-combinations (nreverse options))))
          (if results
              (typespec-eval--simplify-or
               (mapcar (lambda (s) (typespec-eval--make-const s)) results))
            (let ((empty-possible t))
              (dolist (opts options)
                (unless (member "" opts)
                  (setq empty-possible nil)))
              (if empty-possible
                  'string
                (typespec-eval--non-empty-string-expr)))))
      (cond
       ((seq-some #'typespec-eval--non-empty-string-p eval-args)
        (typespec-eval--non-empty-string-expr))
       ((and (seq-every-p #'typespec-eval--string-type-p eval-args)
             (seq-some
              (lambda (arg)
                (and (typespec-eval--const-p arg)
                     (stringp (typespec-eval--const-value arg))
                     (> (length (typespec-eval--const-value arg)) 0)))
              eval-args))
        (typespec-eval--non-empty-string-expr))
       ((seq-every-p #'typespec-eval--string-type-p eval-args) 'string)
       (t 'unknown)))))

(defun typespec-eval--eval (form)
  "Evaluate a typespec FORM into a simplified type/value expression."
  (pcase form
    ((pred typespec-eval--literal-const)
     (typespec-eval--literal-const form))
    (`(or . ,args)
     (typespec-eval--simplify-or (mapcar #'typespec-eval--eval args)))
    (`(list+ ,type)
     (list 'list+ (typespec-eval--eval type)))
    (`(list ,type)
     (list 'list (typespec-eval--eval type)))
    (`(vector ,type)
     (list 'vector (typespec-eval--eval type)))
    (`(:forall ,_ ,body)
     (typespec-eval--eval body))
    (`(rx . ,_) form)
    (`(:alist ,key ,value)
     (list :alist (typespec-eval--eval key) (typespec-eval--eval value)))
    (`(:tuple . ,args)
     (cons :tuple (typespec-eval--eval-tuple args)))
    (`(and . ,args)
     (typespec-eval--eval-and args))
    (`(not ,arg)
     (typespec-eval--eval-not arg))
    (`(null ,arg)
     (typespec-eval--eval-predicate arg #'null
                       #'typespec-eval--always-nil-p
                       #'typespec-eval--always-non-nil-p))
    (`(const ,_) form)
    (`(if ,pred ,then ,else)
     (typespec-eval--eval-if pred then else))
    (`(integer ,low ,high)
     (typespec-eval--integer-range low high))
    (`(float ,low ,high)
     (typespec-eval--float-range low high))
    ('positive-float
     (typespec-eval--float-range '(0) '*))
    ('negative-float
     (typespec-eval--float-range '* '(0)))
    ('non-negative-float
     (typespec-eval--float-range 0.0 '*))
    ('non-positive-float
     (typespec-eval--float-range '* 0.0))
    (`(eq ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'eq))
    (`(eql ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'eql))
    (`(equal ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'equal))
    (`(equal-including-properties ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'equal-including-properties))
    (`(= ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'= #'numberp #'typespec-eval--number-type-p))
    (`(/= ,lhs ,rhs)
     (typespec-eval--eval-numeric-compare lhs rhs #'/=))
    (`(< ,lhs ,rhs)
     (typespec-eval--eval-numeric-compare lhs rhs #'<))
    (`(<= ,lhs ,rhs)
     (typespec-eval--eval-numeric-compare lhs rhs #'<=))
    (`(> ,lhs ,rhs)
     (typespec-eval--eval-numeric-compare lhs rhs #'>))
    (`(>= ,lhs ,rhs)
     (typespec-eval--eval-numeric-compare lhs rhs #'>=))
    (`(value< ,lhs ,rhs)
     (typespec-eval--eval-value< lhs rhs))
    (`(char-equal ,lhs ,rhs)
     (typespec-eval--eval-char-equal lhs rhs))
    (`(identity ,arg)
     (typespec-eval--eval arg))
    (`(stringp ,arg)
     (typespec-eval--eval-predicate arg #'stringp
                       #'typespec-eval--string-type-p
                       #'typespec-eval--non-string-type-p))
    (`(integerp ,arg)
     (typespec-eval--eval-predicate arg #'integerp
                       #'typespec-eval--integer-type-p
                       #'typespec-eval--non-integer-type-p))
    (`(floatp ,arg)
     (typespec-eval--eval-predicate arg #'floatp
                       #'typespec-eval--float-type-p
                       #'typespec-eval--non-float-type-p))
    (`(numberp ,arg)
     (typespec-eval--eval-predicate arg #'numberp
                       #'typespec-eval--number-type-p
                       #'typespec-eval--non-number-type-p))
    (`(natnump ,arg)
     (typespec-eval--eval-predicate arg #'natnump
                       #'typespec-eval--non-negative-int-type-p))
    (`(wholenump ,arg)
     (typespec-eval--eval-predicate arg #'wholenump
                       #'typespec-eval--non-negative-int-type-p))
    (`(fixnump ,arg)
     (typespec-eval--eval-predicate arg #'fixnump
                       (lambda (form) (eq form 'fixnum))))
    (`(bignump ,arg)
     (typespec-eval--eval-predicate arg #'bignump
                       (lambda (form) (eq form 'bignum))))
    (`(booleanp ,arg)
     (typespec-eval--eval-predicate arg #'booleanp
                       #'typespec-eval--boolean-type-p))
    (`(listp ,arg)
     (typespec-eval--eval-predicate arg #'listp
                       #'typespec-eval--list-type-p
                       #'typespec-eval--non-list-type-p))
    (`(consp ,arg)
     (typespec-eval--eval-predicate arg #'consp
                       (lambda (form)
                         (or (eq (car-safe form) 'list+)
                             (eq (car-safe form) 'cons)))
                       (lambda (form)
                         (and (typespec-eval--list-type-p form)
                              (not (eq (car-safe form) 'list+))))))
    (`(atom ,arg)
     (typespec-eval--eval-predicate arg #'atom
                       (lambda (form) (not (typespec-eval--list-type-p form)))
                       (lambda (form) (eq (car-safe form) 'list+))))
    (`(nlistp ,arg)
     (typespec-eval--eval-predicate arg #'nlistp
                       #'typespec-eval--non-list-type-p
                       #'typespec-eval--list-type-p))
    (`(vectorp ,arg)
     (typespec-eval--eval-predicate arg #'vectorp
                       #'typespec-eval--vector-type-p
                       #'typespec-eval--non-vector-type-p))
    (`(arrayp ,arg)
     (typespec-eval--eval-predicate arg #'arrayp
                       (lambda (form)
                         (or (typespec-eval--string-type-p form)
                             (typespec-eval--vector-type-p form)))
                       #'typespec-eval--list-type-p))
    (`(sequencep ,arg)
     (typespec-eval--eval-predicate arg #'sequencep
                       (lambda (form)
                         (or (typespec-eval--list-type-p form)
                             (typespec-eval--string-type-p form)
                             (typespec-eval--vector-type-p form)))))
    (`(symbolp ,arg)
     (typespec-eval--eval-predicate arg #'symbolp
                       #'typespec-eval--symbol-type-p
                       #'typespec-eval--non-string-type-p))
    (`(keywordp ,arg)
     (typespec-eval--eval-predicate arg #'keywordp
                       #'typespec-eval--keyword-type-p))
    (`(proper-list-p ,arg)
     (typespec-eval--eval-predicate arg #'proper-list-p
                       #'typespec-eval--list-type-p))
    (`(char-or-string-p ,arg)
     (typespec-eval--eval-predicate arg #'char-or-string-p
                       (lambda (form)
                         (or (typespec-eval--string-type-p form)
                             (typespec-eval--integer-type-p form)))))
    (`(char-table-p ,arg)
     (typespec-eval--eval-predicate arg #'char-table-p
                       #'typespec-eval--char-table-type-p))
    (`(char-uppercase-p ,arg)
     (typespec-eval--eval-predicate arg #'char-uppercase-p
                       (lambda (form) (typespec-eval--integer-type-p form))))
    (`(multibyte-string-p ,arg)
     (typespec-eval--eval-predicate arg #'multibyte-string-p
                       #'typespec-eval--string-type-p))
    (`(vector-or-char-table-p ,arg)
     (typespec-eval--eval-predicate arg #'vector-or-char-table-p
                       (lambda (form)
                         (or (typespec-eval--vector-type-p form)
                             (typespec-eval--char-table-type-p form)))))
    (`(bare-symbol-p ,arg)
     (typespec-eval--eval-predicate arg #'bare-symbol-p
                       (lambda (form) (eq form 'symbol))))
    (`(symbol-with-pos-p ,arg)
     (typespec-eval--eval-predicate arg #'symbol-with-pos-p
                       (lambda (form) (eq form 'symbol-with-pos))))
    (`(integer-or-marker-p ,arg)
     (typespec-eval--eval-predicate arg #'integer-or-marker-p
                       (lambda (form)
                         (or (typespec-eval--integer-type-p form)
                             (typespec-eval--marker-type-p form)))))
    (`(number-or-marker-p ,arg)
     (typespec-eval--eval-predicate arg #'number-or-marker-p
                       (lambda (form)
                         (or (typespec-eval--number-type-p form)
                             (typespec-eval--marker-type-p form)))))
    (`(bufferp ,arg)
     (typespec-eval--eval-predicate arg #'bufferp
                       #'typespec-eval--buffer-type-p))
    (`(markerp ,arg)
     (typespec-eval--eval-predicate arg #'markerp
                       #'typespec-eval--marker-type-p))
    (`(bool-vector-p ,arg)
     (typespec-eval--eval-predicate arg #'bool-vector-p
                       #'typespec-eval--bool-vector-type-p))
    (`(functionp ,arg)
     (typespec-eval--eval-predicate arg #'functionp
                       #'typespec-eval--function-type-p))
    (`(hash-table-p ,arg)
     (typespec-eval--eval-predicate arg #'hash-table-p
                       #'typespec-eval--hash-table-type-p))
    (`(recordp ,arg)
     (typespec-eval--eval-predicate arg #'recordp
                       #'typespec-eval--record-type-p))
    (`(subrp ,arg)
     (typespec-eval--eval-predicate arg #'subrp))
    (`(byte-code-function-p ,arg)
     (typespec-eval--eval-predicate arg #'byte-code-function-p))
    (`(interpreted-function-p ,arg)
     (typespec-eval--eval-predicate arg #'interpreted-function-p))
    (`(closurep ,arg)
     (typespec-eval--eval-predicate arg #'closurep))
    (`(module-function-p ,arg)
     (typespec-eval--eval-predicate arg #'module-function-p))
    (`(string-empty-p ,arg)
     (typespec-eval--eval-predicate arg #'string-empty-p
                       (lambda (form) (equal form '(const "")))
                       #'typespec-eval--non-string-type-p))
    (`(string-blank-p ,arg)
     (typespec-eval--eval-predicate arg #'string-blank-p
                       nil
                       #'typespec-eval--non-string-type-p))
    (`(string-or-null-p ,arg)
     (typespec-eval--eval-predicate arg #'string-or-null-p
                       (lambda (form)
                         (or (typespec-eval--string-type-p form)
                             (typespec-eval--always-nil-p form)))
                       #'typespec-eval--non-string-type-p))
    (`(mouse-event-p ,arg)
     (typespec-eval--eval-predicate arg #'mouse-event-p))
    (`(upcase ,arg)
     (typespec-eval--eval-const-fold arg #'upcase #'typespec-eval--string-or-char-p 'string))
    (`(downcase ,arg)
     (typespec-eval--eval-const-fold arg #'downcase #'typespec-eval--string-or-char-p 'string))
    (`(capitalize ,arg)
     (typespec-eval--eval-const-fold arg #'capitalize #'typespec-eval--string-or-char-p 'string))
    (`(string-to-number ,arg)
     (typespec-eval--eval-const-fold arg #'string-to-number #'stringp 'string 'number))
    (`(number-to-string ,arg)
     (typespec-eval--eval-const-fold arg #'number-to-string #'numberp 'number 'string))
    (`(string-trim ,arg)
     (typespec-eval--eval-const-fold arg #'string-trim #'stringp 'string))
    (`(string-trim-left ,arg)
     (typespec-eval--eval-const-fold arg #'string-trim-left #'stringp 'string))
    (`(string-trim-right ,arg)
     (typespec-eval--eval-const-fold arg #'string-trim-right #'stringp 'string))
    (`(string-width ,arg)
     (typespec-eval--eval-string-width arg))
    (`(string-lines ,string . ,rest)
     (typespec-eval--eval-string-lines string (car rest) (cadr rest)))
    (`(string-join ,strings . ,rest)
     (typespec-eval--eval-string-join strings (car rest)))
    (`(abs ,arg)
     (typespec-eval--eval-numeric-unary arg #'abs))
    (`(floor ,arg)
     (typespec-eval--eval-rounding arg 'floor #'floor))
    (`(ceiling ,arg)
     (typespec-eval--eval-rounding arg 'ceiling #'ceiling))
    (`(round ,arg)
     (typespec-eval--eval-rounding arg 'round #'round))
    (`(truncate ,arg)
     (typespec-eval--eval-rounding arg 'truncate #'truncate))
    (`(length ,arg)
     (typespec-eval--eval-length arg))
    (`(string-bytes ,arg)
     (typespec-eval--eval-string-bytes arg))
    (`(substring ,string ,start . ,rest)
     (typespec-eval--eval-substring string start (car rest)))
    (`(car ,arg)
     (typespec-eval--eval-nth 0 arg))
    (`(cdr ,arg)
     (typespec-eval--eval-nthcdr 1 arg))
    (`(car-safe ,arg)
     (typespec-eval--eval-car-safe arg))
    (`(cdr-safe ,arg)
     (typespec-eval--eval-cdr-safe arg))
    (`(nth ,n ,list)
     (typespec-eval--eval-nth n list))
    (`(nthcdr ,n ,list)
     (typespec-eval--eval-nthcdr n list))
    (`(elt ,sequence ,n)
     (typespec-eval--eval-elt sequence n))
    (`(aref ,array ,n)
     (typespec-eval--eval-aref array n))
    (`(reverse ,arg)
     (typespec-eval--eval-sequence-identity arg #'reverse))
    (`(copy-sequence ,sequence)
     (typespec-eval--eval-sequence-identity sequence #'copy-sequence))
    (`(safe-length ,list)
     (typespec-eval--eval-safe-length list))
    (`(last ,list . ,rest)
     (typespec-eval--eval-last list (car rest)))
    (`(butlast ,list . ,rest)
     (typespec-eval--eval-butlast list (car rest)))
    (`(assoc ,key ,alist)
     (typespec-eval--eval-alist-search key alist t #'equal))
    (`(assq ,key ,alist)
     (typespec-eval--eval-alist-search key alist t #'eq))
    (`(rassoc ,value ,alist)
     (typespec-eval--eval-alist-search value alist nil #'equal))
    (`(alist-get ,key ,alist . ,rest)
     (typespec-eval--eval-alist-get key alist (car rest) (cadr rest) (caddr rest)))
    (`(assoc-default ,key ,alist . ,rest)
     (typespec-eval--eval-assoc-default key alist (car rest) (cadr rest)))
    (`(rassq ,value ,alist)
     (typespec-eval--eval-alist-search value alist nil #'eq))
    (`(assoc-delete-all ,key ,alist . ,rest)
     (typespec-eval--eval-assoc-delete-all key alist (car rest)))
    (`(assq-delete-all ,key ,alist)
     (typespec-eval--eval-assoc-delete-all key alist 'eq))
    (`(rassq-delete-all ,value ,alist)
     (typespec-eval--eval-rassq-delete-all value alist))
    (`(plist-get ,plist ,key . ,rest)
     (typespec-eval--eval-plist-get plist key (car rest)))
    (`(plist-member ,plist ,key)
     (typespec-eval--eval-plist-member plist key))
    (`(memq ,elt ,list)
     (typespec-eval--eval-member-like elt list #'memq))
    (`(member ,elt ,list)
     (typespec-eval--eval-member-like elt list #'member))
    (`(member-ignore-case ,elt ,list)
     (typespec-eval--eval-member-like elt list #'member-ignore-case))
    (`(seq-length ,sequence)
     (typespec-eval--eval-seq-length sequence))
    (`(seq-elt ,sequence ,n)
     (typespec-eval--eval-elt sequence n))
    (`(seq-empty-p ,sequence)
     (typespec-eval--eval-seq-empty-p sequence))
    (`(cl-endp ,arg)
     (typespec-eval--eval-cl-endp arg))
    (`(cl-first ,arg)
     (typespec-eval--eval-nth 0 arg))
    (`(cl-second ,arg)
     (typespec-eval--eval-nth 1 arg))
    (`(cl-third ,arg)
     (typespec-eval--eval-nth 2 arg))
    (`(cl-fourth ,arg)
     (typespec-eval--eval-nth 3 arg))
    (`(cl-fifth ,arg)
     (typespec-eval--eval-nth 4 arg))
    (`(cl-sixth ,arg)
     (typespec-eval--eval-nth 5 arg))
    (`(cl-seventh ,arg)
     (typespec-eval--eval-nth 6 arg))
    (`(cl-eighth ,arg)
     (typespec-eval--eval-nth 7 arg))
    (`(cl-ninth ,arg)
     (typespec-eval--eval-nth 8 arg))
    (`(cl-tenth ,arg)
     (typespec-eval--eval-nth 9 arg))
    (`(cl-list-length ,arg)
     (typespec-eval--eval-cl-list-length arg))
    (`(cl-plusp ,arg)
     (typespec-eval--eval-predicate arg #'cl-plusp #'typespec-eval--number-type-p))
    (`(cl-minusp ,arg)
     (typespec-eval--eval-predicate arg #'cl-minusp #'typespec-eval--number-type-p))
    (`(cl-evenp ,arg)
     (typespec-eval--eval-predicate arg #'cl-evenp #'typespec-eval--integer-type-p))
    (`(cl-oddp ,arg)
     (typespec-eval--eval-predicate arg #'cl-oddp #'typespec-eval--integer-type-p))
    (`(cl-equalp ,lhs ,rhs)
     (typespec-eval--eval-equality lhs rhs #'cl-equalp))
    (`(type-of ,arg)
     (typespec-eval--eval-type-of arg #'type-of))
    (`(cl-type-of ,arg)
     (typespec-eval--eval-type-of arg #'cl-type-of))
    (`(symbol-name ,arg)
     (typespec-eval--eval-symbol-name arg))
    (`(kbd ,arg)
     (typespec-eval--eval-kbd arg))
    (`(make-composed-keymap ,maps . ,rest)
     (typespec-eval--eval-make-composed-keymap maps (car rest)))
    (`(sha1 ,arg)
     (typespec-eval--eval-sha1 arg))
    (`(syntax-class ,arg)
     (typespec-eval--eval-syntax-class arg))
    (`(version-to-list ,arg)
     (typespec-eval--eval-version-to-list arg))
    (`(version-list-not-zero ,lst)
     (typespec-eval--eval-version-list-not-zero lst))
    (`(version-list-< ,lhs ,rhs)
     (typespec-eval--eval-version-list-compare lhs rhs #'version-list-<))
    (`(version-list-<= ,lhs ,rhs)
     (typespec-eval--eval-version-list-compare lhs rhs #'version-list-<=))
    (`(version-list-= ,lhs ,rhs)
     (typespec-eval--eval-version-list-compare lhs rhs #'version-list-=))
    (`(version< ,lhs ,rhs)
     (typespec-eval--eval-version-compare lhs rhs #'version<))
    (`(version<= ,lhs ,rhs)
     (typespec-eval--eval-version-compare lhs rhs #'version<=))
    (`(version= ,lhs ,rhs)
     (typespec-eval--eval-version-compare lhs rhs #'version=))
    (`(copy-tree ,tree . ,rest)
     (typespec-eval--eval-copy-tree tree (car rest)))
    (`(delete-dups ,list)
     (typespec-eval--eval-delete-dups list))
    (`(delete-consecutive-dups ,list . ,rest)
     (typespec-eval--eval-delete-consecutive-dups list (car rest)))
    (`(remove ,elt ,sequence)
     (typespec-eval--eval-remove-like elt sequence #'remove))
    (`(remq ,elt ,list)
     (typespec-eval--eval-remove-like elt list #'remq t))
    (`(string-pad ,string ,length . ,rest)
     (typespec-eval--eval-string-pad string length (car rest) (cadr rest)))
    (`(string-remove-prefix ,prefix ,string)
     (typespec-eval--eval-binary-string-op prefix string #'string-remove-prefix))
    (`(string-remove-suffix ,suffix ,string)
     (typespec-eval--eval-binary-string-op suffix string #'string-remove-suffix))
    (`(string-to-char ,arg)
     (typespec-eval--eval-const-fold arg #'string-to-char #'stringp nil 'integer #'typespec-eval--string-type-p))
    (`(string-to-list ,arg)
     (typespec-eval--eval-const-fold arg #'string-to-list #'stringp nil '(list integer) #'typespec-eval--string-type-p))
    (`(string-to-vector ,arg)
     (typespec-eval--eval-const-fold arg #'string-to-vector #'stringp nil '(vector integer) #'typespec-eval--string-type-p))
    (`(string-equal ,lhs ,rhs)
     (typespec-eval--eval-string-equal lhs rhs))
    (`(string-prefix-p ,prefix ,string . ,rest)
     (typespec-eval--eval-string-prefix-p
      prefix
      string
      (car rest)))
    (`(string-suffix-p ,suffix ,string . ,rest)
     (typespec-eval--eval-string-suffix-p
      suffix
      string
      (car rest)))
    (`(string< ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-lessp 'boolean))
    (`(string> ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-greaterp 'boolean))
    (`(string= ,lhs ,rhs)
     (typespec-eval--eval-string-equal lhs rhs))
    (`(string-lessp ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-lessp 'boolean))
    (`(string-greaterp ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-greaterp 'boolean))
    (`(string-equal-ignore-case ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-equal-ignore-case 'boolean))
    (`(string-search ,needle ,haystack . ,rest)
     (typespec-eval--eval-string-search needle haystack (car rest)))
    (`(string-split ,string . ,rest)
     (typespec-eval--eval-string-split string (car rest) (cadr rest) (caddr rest)))
    (`(string-replace ,from ,to ,string)
     (typespec-eval--eval-string-replace from to string))
    (`(string-truncate-left ,string ,n)
     (typespec-eval--eval-string-truncate-left string n))
    (`(string-match-p ,regexp ,string . ,rest)
     (typespec-eval--eval-string-match-p regexp string (car rest)))
    (`(string-to-multibyte ,string)
     (typespec-eval--eval-string-unary string #'string-to-multibyte t))
    (`(string-to-unibyte ,string)
     (typespec-eval--eval-string-unary string #'string-to-unibyte t))
    (`(string-chop-newline ,string)
     (typespec-eval--eval-string-unary string #'string-chop-newline))
    (`(string-clean-whitespace ,string)
     (typespec-eval--eval-string-unary string #'string-clean-whitespace))
    (`(string-limit ,string ,n)
     (typespec-eval--eval-string-limit string n))
    (`(string-distance ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-distance 'integer))
    (`(string-version-lessp ,lhs ,rhs)
     (typespec-eval--eval-binary-string-compare lhs rhs #'string-version-lessp 'boolean))
    (`(char-to-string ,char)
     (typespec-eval--eval-char-to-string char))
    (`(make-string ,length ,char)
     (typespec-eval--eval-make-string length char))
    (`(+ . ,args)
     (typespec-eval--eval-arith args #'+ 0))
    (`(* . ,args)
     (typespec-eval--eval-arith args #'* 1))
    (`(- . ,args)
     (typespec-eval--eval-arith args #'- 0))
    (`(/ . ,args)
     (typespec-eval--eval-arith args #'/))
    (`(% . ,args)
     (typespec-eval--eval-rem args))
    (`(mod . ,args)
     (typespec-eval--eval-mod args))
    (`(logand . ,args)
     (typespec-eval--eval-integer-variadic args #'logand -1))
    (`(logior . ,args)
     (typespec-eval--eval-integer-variadic args #'logior 0))
    (`(logxor . ,args)
     (typespec-eval--eval-integer-variadic args #'logxor 0))
    (`(lognot ,arg)
     (typespec-eval--eval-const-fold arg #'lognot #'integerp nil 'integer #'typespec-eval--integer-type-p))
    (`(logcount ,arg)
     (typespec-eval--eval-const-fold arg #'logcount #'integerp nil '(integer 0 *)
                        #'typespec-eval--integer-type-p))
    (`(ash ,value ,count)
     (typespec-eval--eval-ash value count))
    (`(zerop ,arg)
     (typespec-eval--eval-zerop arg))
    (`(isnan ,arg)
     (typespec-eval--eval-isnan arg))
    (`(cl-signum ,arg)
     (typespec-eval--eval-numeric-unary arg #'cl-signum))
    (`(number-sequence ,from . ,rest)
     (typespec-eval--eval-number-sequence from (car rest) (cadr rest)))
    (`(1+ ,arg)
     (typespec-eval--eval-numeric-unary arg #'1+))
    (`(1- ,arg)
     (typespec-eval--eval-numeric-unary arg #'1-))
    (`(max . ,args)
     (typespec-eval--eval-minmax args #'max))
    (`(min . ,args)
     (typespec-eval--eval-minmax args #'min))
    (`(concat . ,args)
     (typespec-eval--eval-concat args))
    (`int 'integer)
    ((pred symbolp) form)
    (_ 'unknown)))

(defun typespec-eval (form)
  "Evaluate FORM in the typespec value/type evaluator."
  (typespec-eval--eval form))

(provide 'typespec-eval)
;;; typespec-eval.el ends here
