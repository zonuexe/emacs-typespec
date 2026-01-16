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

(require 'seq)

(defun typespec-eval--const-p (form)
  "Return non-nil if FORM is a `(const VALUE)` expression."
  (and (consp form)
       (eq (car form) 'const)
       (consp (cdr form))
       (null (cddr form))))

(defun typespec-eval--const-value (form)
  "Return the VALUE from a `(const VALUE)` FORM."
  (cadr form))

(defun typespec-eval--make-const (value)
  "Return a `(const VALUE)` expression."
  (list 'const value))

(defun typespec-eval--non-empty-string-expr ()
  "Return the canonical non-empty string type expression."
  '(and string (not (const ""))))

(defun typespec-eval--non-empty-string-p (form)
  "Return non-nil if FORM is known to be a non-empty string."
  (cond
   ((and (typespec-eval--const-p form)
         (stringp (typespec-eval--const-value form)))
    (> (length (typespec-eval--const-value form)) 0))
   ((equal form (typespec-eval--non-empty-string-expr)) t)
   (t nil)))

(defun typespec-eval--always-nil-p (form)
  "Return non-nil if FORM is known to be nil."
  (or (equal form '(const nil))
      (eq form 'null)))

(defun typespec-eval--const-integer-value (form)
  "Return integer value if FORM is a const integer, otherwise nil."
  (when (and (typespec-eval--const-p form)
             (integerp (typespec-eval--const-value form)))
    (typespec-eval--const-value form)))

(defun typespec-eval--integer-range (low high)
  "Return an integer range type expression for LOW and HIGH."
  (list 'integer low high))

(defun typespec-eval--integer-range-p (form)
  "Return non-nil if FORM is an `(integer LOW HIGH)` range."
  (and (consp form)
       (eq (car form) 'integer)
       (consp (cdr form))
       (consp (cddr form))))

(defun typespec-eval--integer-type-p (form)
  "Return non-nil if FORM is an integer-like type."
  (or (memq form '(int integer fixnum bignum
                       positive-int non-negative-int
                       negative-int non-positive-int))
      (typespec-eval--integer-range-p form)))

(defun typespec-eval--float-type-p (form)
  "Return non-nil if FORM is a float-like type."
  (memq form '(float positive-float negative-float)))

(defun typespec-eval--number-type-p (form)
  "Return non-nil if FORM is a number-like type."
  (or (memq form '(number real integer float fixnum bignum
                       positive-int non-negative-int
                       negative-int non-positive-int
                       positive-float negative-float))
      (typespec-eval--integer-range-p form)))

(defun typespec-eval--positive-int-type-p (form)
  "Return non-nil if FORM is a positive integer type."
  (or (eq form 'positive-int)
      (and (typespec-eval--integer-range-p form)
           (let ((low (cadr form)))
             (and (numberp low) (<= 1 low))))))

(defun typespec-eval--list-type-p (form)
  "Return non-nil if FORM is a list type."
  (or (eq form 'list)
      (and (consp form) (memq (car form) '(list list+)))))

(defun typespec-eval--always-non-nil-p (form)
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

(defun typespec-eval--string-type-p (form)
  "Return non-nil if FORM is a string-like type."
  (or (eq form 'string)
      (typespec-eval--non-empty-string-p form)))

(defun typespec-eval--simplify-or (items)
  "Return a simplified `(or ...)` form for ITEMS."
  (cond
   ((null items) 'never)
   ((null (cdr items)) (car items))
   ((equal items '((const t) (const nil))) 'boolean)
   ((equal items '((const nil) (const t))) 'boolean)
   (t (cons 'or items))))

(defun typespec-eval--simplify-and (items)
  "Return a simplified `(and ...)` form for ITEMS."
  (let ((items (delq nil items)))
    (cond
     ((null items) 'mixed)
     ((memq 'never items) 'never)
     ((null (cdr items)) (car items))
     ((and (= (length items) 2)
           (eq (car items) 'string)
           (equal (cadr items) '(not (const ""))))
      (typespec-eval--non-empty-string-expr))
     ((and (= (length items) 2)
           (eq (cadr items) 'string)
           (equal (car items) '(not (const ""))))
      (typespec-eval--non-empty-string-expr))
     ((and (= (length items) 2)
           (eq (car items) 'string)
           (eq (cadr items) 'string))
      'string)
     (t (cons 'and items)))))

(eval-and-compile
  (defun typespec-eval--constant-defun--predicate (pred value)
    "Return a predicate form for PRED and VALUE."
    (if (and (consp pred) (eq (car pred) 'or))
        `(or ,@(mapcar (lambda (p) `(,p ,value)) (cdr pred)))
      `(,pred ,value))))

(defmacro typespec-eval--constant-defun (name predicates &rest keys)
  "Define a const-folding evaluator for NAME using PREDICATES.

PREDICATES is a list containing a predicate form, such as `(or stringp
characterp)`.  Optional KEYS:

- :type TYPE — return TYPE when the evaluated argument is TYPE.
- :type-in TYPE — return :type-out when the evaluated argument is TYPE.
- :type-out TYPE — output type for :type-in (defaults to :type-in).
- :type-p PRED — return :type-out when (PRED ARG) is non-nil.
- :fallback TYPE — return TYPE when no rule matches (default: `unknown`)."
  (declare (indent 1))
  (let* ((pred (car predicates))
         (arg-sym (make-symbol "arg"))
         (item-sym (make-symbol "item"))
         (value-sym (make-symbol "value"))
         (type (plist-get keys :type))
         (type-in (or (plist-get keys :type-in) type))
         (type-p (plist-get keys :type-p))
         (type-out (or (plist-get keys :type-out) type-in))
         (fallback (or (plist-get keys :fallback) 'unknown))
         (pred-form (typespec-eval--constant-defun--predicate pred value-sym))
         (eval-fn (intern (format "typespec-eval--eval-%s" name))))
    `(defun ,eval-fn (,arg-sym)
       ,(format "Evaluate a `%s` expression over ARG." name)
       (let* ((,arg-sym (typespec-eval--eval ,arg-sym))
              (mapped
               (typespec-eval--map-const-or
                ,arg-sym
                (lambda (,item-sym)
                  (when (typespec-eval--const-p ,item-sym)
                    (let ((,value-sym (typespec-eval--const-value ,item-sym)))
                      (when ,pred-form
                        (typespec-eval--make-const
                         (,name ,value-sym)))))))))
         (cond
         (mapped mapped)
          ,@(when type-in `(((eq ,arg-sym ',type-in) ',type-out)))
          ,@(when type-p `(((funcall #',type-p ,arg-sym) ',type-out)))
          (t ',fallback))))))

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

(defun typespec-eval--eval-eq (lhs rhs)
  "Evaluate an `eq` expression over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const t))
     ((and (typespec-eval--always-non-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const nil))
     ((and (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-non-nil-p rhs))
      (typespec-eval--make-const nil))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (eq (typespec-eval--const-value lhs)
           (typespec-eval--const-value rhs))))
     (t 'boolean))))

(defun typespec-eval--eval-equal (lhs rhs)
  "Evaluate an `equal` expression over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const t))
     ((and (typespec-eval--always-non-nil-p lhs)
           (typespec-eval--always-nil-p rhs))
      (typespec-eval--make-const nil))
     ((and (typespec-eval--always-nil-p lhs)
           (typespec-eval--always-non-nil-p rhs))
      (typespec-eval--make-const nil))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (equal (typespec-eval--const-value lhs)
              (typespec-eval--const-value rhs))))
     (t 'boolean))))

(typespec-eval--constant-defun upcase ((or stringp characterp)) :type string)
(typespec-eval--constant-defun downcase ((or stringp characterp)) :type string)

(typespec-eval--constant-defun string-to-number (stringp)
  :type-in string
  :type-out number)
(typespec-eval--constant-defun capitalize ((or stringp characterp)) :type string)
(typespec-eval--constant-defun number-to-string (numberp)
  :type-in number
  :type-out string)
(typespec-eval--constant-defun string-trim (stringp) :type string)
(typespec-eval--constant-defun string-trim-left (stringp) :type string)
(typespec-eval--constant-defun string-trim-right (stringp) :type string)
(typespec-eval--constant-defun string-reverse (stringp) :type string)

(defun typespec-eval--eval-abs (arg)
  "Evaluate an `abs` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (abs val))
          'unknown)))
     ((typespec-eval--float-type-p arg) 'float)
     ((typespec-eval--integer-type-p arg) 'integer)
     ((typespec-eval--number-type-p arg) 'number)
     (t 'unknown))))

(typespec-eval--constant-defun floor (numberp)
  :type-p typespec-eval--number-type-p
  :type-out integer)
(typespec-eval--constant-defun ceiling (numberp)
  :type-p typespec-eval--number-type-p
  :type-out integer)
(typespec-eval--constant-defun round (numberp)
  :type-p typespec-eval--number-type-p
  :type-out integer)
(typespec-eval--constant-defun truncate (numberp)
  :type-p typespec-eval--number-type-p
  :type-out integer)

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
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
     ((seq-every-p #'typespec-eval--float-type-p args) 'float)
     ((seq-every-p #'typespec-eval--number-type-p args) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-max (args)
  "Evaluate a `max` expression over ARGS."
  (typespec-eval--eval-minmax args #'max))

(defun typespec-eval--eval-min (args)
  "Evaluate a `min` expression over ARGS."
  (typespec-eval--eval-minmax args #'min))

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
  "Evaluate a `string-pad` expression."
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

(defun typespec-eval--eval-string-remove-prefix (prefix string)
  "Evaluate a `string-remove-prefix` expression."
  (let ((prefix (typespec-eval--eval prefix))
        (string (typespec-eval--eval string)))
    (cond
     ((and (typespec-eval--const-p prefix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value prefix))
           (stringp (typespec-eval--const-value string)))
      (typespec-eval--make-const
       (string-remove-prefix (typespec-eval--const-value prefix)
                             (typespec-eval--const-value string))))
     ((and (typespec-eval--string-type-p prefix)
           (typespec-eval--string-type-p string))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-remove-suffix (suffix string)
  "Evaluate a `string-remove-suffix` expression."
  (let ((suffix (typespec-eval--eval suffix))
        (string (typespec-eval--eval string)))
    (cond
     ((and (typespec-eval--const-p suffix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value suffix))
           (stringp (typespec-eval--const-value string)))
      (typespec-eval--make-const
       (string-remove-suffix (typespec-eval--const-value suffix)
                             (typespec-eval--const-value string))))
     ((and (typespec-eval--string-type-p suffix)
           (typespec-eval--string-type-p string))
      'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-to-char (arg)
  "Evaluate a `string-to-char` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-to-char val))
          'unknown)))
     ((typespec-eval--string-type-p arg) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-string-to-list (arg)
  "Evaluate a `string-to-list` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-to-list val))
          'unknown)))
     ((typespec-eval--string-type-p arg) '(list integer))
     (t 'unknown))))

(defun typespec-eval--eval-string-to-vector (arg)
  "Evaluate a `string-to-vector` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-to-vector val))
          'unknown)))
     ((typespec-eval--string-type-p arg) '(vector integer))
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

(defun typespec-eval--eval-null (arg)
  "Evaluate a `null` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
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
    (`(and . ,args)
     (typespec-eval--eval-and args))
    (`(not ,arg)
     (typespec-eval--eval-not arg))
    (`(null ,arg)
     (typespec-eval--eval-null arg))
    (`(const ,_) form)
    (`(integer ,low ,high)
     (list 'integer low high))
    (`(eq ,lhs ,rhs)
     (typespec-eval--eval-eq lhs rhs))
    (`(equal ,lhs ,rhs)
     (typespec-eval--eval-equal lhs rhs))
    (`(upcase ,arg)
     (typespec-eval--eval-upcase arg))
    (`(downcase ,arg)
     (typespec-eval--eval-downcase arg))
    (`(capitalize ,arg)
     (typespec-eval--eval-capitalize arg))
    (`(string-to-number ,arg)
     (typespec-eval--eval-string-to-number arg))
    (`(number-to-string ,arg)
     (typespec-eval--eval-number-to-string arg))
    (`(string-trim ,arg)
     (typespec-eval--eval-string-trim arg))
    (`(string-trim-left ,arg)
     (typespec-eval--eval-string-trim-left arg))
    (`(string-trim-right ,arg)
     (typespec-eval--eval-string-trim-right arg))
    (`(string-reverse ,arg)
     (typespec-eval--eval-string-reverse arg))
    (`(abs ,arg)
     (typespec-eval--eval-abs arg))
    (`(floor ,arg)
     (typespec-eval--eval-floor arg))
    (`(ceiling ,arg)
     (typespec-eval--eval-ceiling arg))
    (`(round ,arg)
     (typespec-eval--eval-round arg))
    (`(truncate ,arg)
     (typespec-eval--eval-truncate arg))
    (`(length ,arg)
     (typespec-eval--eval-length arg))
    (`(string-bytes ,arg)
     (typespec-eval--eval-string-bytes arg))
    (`(substring ,string ,start . ,rest)
     (typespec-eval--eval-substring string start (car rest)))
    (`(string-pad ,string ,length . ,rest)
     (typespec-eval--eval-string-pad string length (car rest) (cadr rest)))
    (`(string-remove-prefix ,prefix ,string)
     (typespec-eval--eval-string-remove-prefix prefix string))
    (`(string-remove-suffix ,suffix ,string)
     (typespec-eval--eval-string-remove-suffix suffix string))
    (`(string-to-char ,arg)
     (typespec-eval--eval-string-to-char arg))
    (`(string-to-list ,arg)
     (typespec-eval--eval-string-to-list arg))
    (`(string-to-vector ,arg)
     (typespec-eval--eval-string-to-vector arg))
    (`(string-equal ,lhs ,rhs)
     (typespec-eval--eval-string-equal lhs rhs))
    (`(string-prefix-p ,prefix ,string . ,rest)
     (typespec-eval--eval-string-prefix-p
      prefix
      string
      (car rest)))
    (`(max . ,args)
     (typespec-eval--eval-max args))
    (`(min . ,args)
     (typespec-eval--eval-min args))
    (`(concat . ,args)
     (typespec-eval--eval-concat args))
    ((pred symbolp) form)
    (_ 'unknown)))

(defun typespec-eval (form)
  "Evaluate FORM in the typespec value/type evaluator."
  (typespec-eval--eval form))

(provide 'typespec-eval)
;;; typespec-eval.el ends here
