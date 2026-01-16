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

(defsubst typespec-eval--integer-range (low high)
  "Return an integer range type expression for LOW and HIGH."
  (list 'integer low high))

(defsubst typespec-eval--integer-range-p (form)
  "Return non-nil if FORM is an `(integer LOW HIGH)` range."
  (and (consp form)
       (eq (car form) 'integer)
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
  (memq form '(float positive-float negative-float)))

(defsubst typespec-eval--number-type-p (form)
  "Return non-nil if FORM is a number-like type."
  (or (memq form '(number real integer float fixnum bignum
                       positive-int non-negative-int
                       negative-int non-positive-int
                       positive-float negative-float))
      (typespec-eval--integer-range-p form)))

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

(defsubst typespec-eval--string-type-p (form)
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

(defun typespec-eval--eval-tuple (args)
  "Evaluate tuple ARGS in order, preserving dotted structure."
  (cond
   ((consp args)
    (cons (typespec-eval--eval (car args))
          (typespec-eval--eval-tuple (cdr args))))
   ((null args) nil)
   (t (typespec-eval--eval args))))

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
  "Evaluate a `string-lines` expression."
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
      '(list string))
     (t 'unknown))))

(defun typespec-eval--eval-string-join (strings &optional separator)
  "Evaluate a `string-join` expression."
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
  "Evaluate a `string-match-p` expression."
  (let ((regexp (typespec-eval--eval regexp))
        (string (typespec-eval--eval string))
        (start (when start (typespec-eval--eval start))))
    (cond
     ((and (typespec-eval--const-p regexp)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value regexp))
           (stringp (typespec-eval--const-value string))
           (or (null start)
               (typespec-eval--const-p start))
           (or (null start)
               (integerp (typespec-eval--const-value start))))
      (typespec-eval--make-const
       (string-match-p (typespec-eval--const-value regexp)
                       (typespec-eval--const-value string)
                       (when start (typespec-eval--const-value start)))))
     ((and (typespec-eval--string-type-p regexp)
           (typespec-eval--string-type-p string)
           (or (null start)
               (typespec-eval--integer-type-p start)))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-string-to-multibyte (string)
  "Evaluate a `string-to-multibyte` expression."
  (let ((string (typespec-eval--eval string)))
    (cond
     ((typespec-eval--const-p string)
      (let ((val (typespec-eval--const-value string)))
        (if (stringp val)
            (typespec-eval--make-const (string-to-multibyte val))
          'unknown)))
     ((typespec-eval--non-empty-string-p string)
      (typespec-eval--non-empty-string-expr))
     ((typespec-eval--string-type-p string) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-to-unibyte (string)
  "Evaluate a `string-to-unibyte` expression."
  (let ((string (typespec-eval--eval string)))
    (cond
     ((typespec-eval--const-p string)
      (let ((val (typespec-eval--const-value string)))
        (if (stringp val)
            (typespec-eval--make-const (string-to-unibyte val))
          'unknown)))
     ((typespec-eval--non-empty-string-p string)
      (typespec-eval--non-empty-string-expr))
     ((typespec-eval--string-type-p string) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-chop-newline (string)
  "Evaluate a `string-chop-newline` expression."
  (let ((string (typespec-eval--eval string)))
    (cond
     ((typespec-eval--const-p string)
      (let ((val (typespec-eval--const-value string)))
        (if (stringp val)
            (typespec-eval--make-const (string-chop-newline val))
          'unknown)))
     ((typespec-eval--string-type-p string) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-clean-whitespace (string)
  "Evaluate a `string-clean-whitespace` expression."
  (let ((string (typespec-eval--eval string)))
    (cond
     ((typespec-eval--const-p string)
      (let ((val (typespec-eval--const-value string)))
        (if (stringp val)
            (typespec-eval--make-const (string-clean-whitespace val))
          'unknown)))
     ((typespec-eval--string-type-p string) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-limit (string n)
  "Evaluate a `string-limit` expression."
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

(defun typespec-eval--eval-string-distance (lhs rhs)
  "Evaluate a `string-distance` expression."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-distance (typespec-eval--const-value lhs)
                        (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'integer)
     (t 'unknown))))

(defun typespec-eval--eval-char-to-string (char)
  "Evaluate a `char-to-string` expression."
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
  "Evaluate a `make-string` expression."
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

(defun typespec-eval--eval-string-version-lessp (lhs rhs)
  "Evaluate a `string-version-lessp` expression."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-version-lessp (typespec-eval--const-value lhs)
                             (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-string-search (needle haystack &optional start)
  "Evaluate a `string-search` expression."
  (let ((needle (typespec-eval--eval needle))
        (haystack (typespec-eval--eval haystack))
        (start (when start (typespec-eval--eval start))))
    (cond
     ((and (typespec-eval--const-p needle)
           (typespec-eval--const-p haystack)
           (stringp (typespec-eval--const-value needle))
           (stringp (typespec-eval--const-value haystack))
           (or (null start)
               (typespec-eval--const-p start))
           (or (null start)
               (integerp (typespec-eval--const-value start))))
      (typespec-eval--make-const
       (string-search (typespec-eval--const-value needle)
                      (typespec-eval--const-value haystack)
                      (when start (typespec-eval--const-value start)))))
     ((and (typespec-eval--string-type-p needle)
           (typespec-eval--string-type-p haystack)
           (or (null start)
               (typespec-eval--integer-type-p start)))
      '(or (const nil) integer))
     (t 'unknown))))

(defun typespec-eval--eval-string-split (string &optional separators omit-nulls trim)
  "Evaluate a `string-split` expression."
  (let* ((string (typespec-eval--eval string))
         (separators (when separators (typespec-eval--eval separators)))
         (omit-nulls (when omit-nulls (typespec-eval--eval omit-nulls)))
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
      '(list string))
     (t 'unknown))))

(defun typespec-eval--eval-string-replace (from to string)
  "Evaluate a `string-replace` expression."
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
  "Evaluate a `string-truncate-left` expression."
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
  "Evaluate a `string-suffix-p` expression."
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

(defun typespec-eval--eval-string-lessp (lhs rhs)
  "Evaluate a `string-lessp` expression."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval--map-const-or
       lhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-lessp item rhs)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp rhs) (eq (car rhs) 'or))
      (typespec-eval--map-const-or
       rhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-lessp lhs item)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-lessp (typespec-eval--const-value lhs)
                     (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-string-greaterp (lhs rhs)
  "Evaluate a `string-greaterp` expression."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval--map-const-or
       lhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-greaterp item rhs)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp rhs) (eq (car rhs) 'or))
      (typespec-eval--map-const-or
       rhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-greaterp lhs item)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-greaterp (typespec-eval--const-value lhs)
                        (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-string-equal-ignore-case (lhs rhs)
  "Evaluate a `string-equal-ignore-case` expression."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval--map-const-or
       lhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-equal-ignore-case item rhs)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp rhs) (eq (car rhs) 'or))
      (typespec-eval--map-const-or
       rhs
       (lambda (item)
         (let ((res (typespec-eval--eval-string-equal-ignore-case lhs item)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (string-equal-ignore-case (typespec-eval--const-value lhs)
                                 (typespec-eval--const-value rhs))))
     ((and (typespec-eval--string-type-p lhs)
           (typespec-eval--string-type-p rhs))
      'boolean)
     (t 'unknown))))

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

(defun typespec-eval--arith-type (args)
  "Return the numeric result type for ARGS."
  (cond
   ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
   ((seq-some #'typespec-eval--float-type-p args) 'float)
   ((seq-every-p #'typespec-eval--number-type-p args) 'number)
   (t 'unknown)))

(defun typespec-eval--eval-arith (args op &optional zero-value)
  "Evaluate arithmetic OP over ARGS.
If all ARGS are numeric consts, return a const result.
ZERO-VALUE is used when ARGS is empty."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args)
      (if (null zero-value) 'unknown (typespec-eval--make-const zero-value)))
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply op values))
          'unknown)))
     (t (typespec-eval--arith-type args)))))

(defun typespec-eval--eval-plus (args)
  "Evaluate a `+` expression over ARGS."
  (typespec-eval--eval-arith args #'+ 0))

(defun typespec-eval--eval-times (args)
  "Evaluate a `*` expression over ARGS."
  (typespec-eval--eval-arith args #'* 1))

(defun typespec-eval--eval-minus (args)
  "Evaluate a `-` expression over ARGS."
  (typespec-eval--eval-arith args #'- 0))

(defun typespec-eval--eval-divide (args)
  "Evaluate a `/` expression over ARGS."
  (typespec-eval--eval-arith args #'/))

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
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
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
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
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
     ((seq-every-p #'typespec-eval--integer-type-p args) 'integer)
     (t 'unknown))))

(defun typespec-eval--eval-logand (args)
  "Evaluate a `logand` expression over ARGS."
  (typespec-eval--eval-integer-variadic args #'logand -1))

(defun typespec-eval--eval-logior (args)
  "Evaluate a `logior` expression over ARGS."
  (typespec-eval--eval-integer-variadic args #'logior 0))

(defun typespec-eval--eval-logxor (args)
  "Evaluate a `logxor` expression over ARGS."
  (typespec-eval--eval-integer-variadic args #'logxor 0))

(defun typespec-eval--eval-ash (value count)
  "Evaluate an `ash` expression."
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
     ((and (typespec-eval--integer-type-p value)
           (typespec-eval--integer-type-p count))
      'integer)
     (t 'unknown))))

(typespec-eval--constant-defun lognot (integerp)
  :type-p typespec-eval--integer-type-p
  :type-out integer)
(typespec-eval--constant-defun logcount (integerp)
  :type-p typespec-eval--integer-type-p
  :type-out integer)
(typespec-eval--constant-defun zerop (numberp)
  :type-p typespec-eval--number-type-p
  :type-out boolean)

(defun typespec-eval--eval-number-sequence (from &optional to inc)
  "Evaluate a `number-sequence` expression."
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
     ((and (typespec-eval--number-type-p from)
           (or (null to) (typespec-eval--number-type-p to))
           (or (null inc) (typespec-eval--number-type-p inc)))
      '(list number))
     (t 'unknown))))

(defun typespec-eval--eval-isnan (arg)
  "Evaluate an `isnan` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (isnan val))
          'unknown)))
     ((typespec-eval--number-type-p arg) 'boolean)
     (t 'unknown))))

(defun typespec-eval--eval-cl-signum (arg)
  "Evaluate a `cl-signum` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (cl-signum val))
          'unknown)))
     ((typespec-eval--float-type-p arg) 'float)
     ((typespec-eval--integer-type-p arg) 'integer)
     ((typespec-eval--number-type-p arg) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-add1 (arg)
  "Evaluate a `1+` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (1+ val))
          'unknown)))
     ((typespec-eval--float-type-p arg) 'float)
     ((typespec-eval--integer-type-p arg) 'integer)
     ((typespec-eval--number-type-p arg) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-sub1 (arg)
  "Evaluate a `1-` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (1- val))
          'unknown)))
     ((typespec-eval--float-type-p arg) 'float)
     ((typespec-eval--integer-type-p arg) 'integer)
     ((typespec-eval--number-type-p arg) 'number)
     (t 'unknown))))

(defun typespec-eval--eval-car (arg)
  "Evaluate a `car` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (listp val)
            (typespec-eval--make-const (car val))
          'unknown)))
     ((eq (car-safe arg) 'list+)
      (cadr arg))
     ((eq (car-safe arg) 'list)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil) (cadr arg))))
     (t 'unknown))))

(defun typespec-eval--eval-cdr (arg)
  "Evaluate a `cdr` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (listp val)
            (typespec-eval--make-const (cdr val))
          'unknown)))
     ((memq (car-safe arg) '(list list+))
      (list 'list (cadr arg)))
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
  "Evaluate an `nth` expression."
  (let* ((n (typespec-eval--eval n))
         (list (typespec-eval--eval list))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p list) (integerp nval))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (nth nval val))
          'unknown)))
     ((typespec-eval--list-elem-type list)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval--list-elem-type list))))
     (t 'unknown))))

(defun typespec-eval--eval-nthcdr (n list)
  "Evaluate an `nthcdr` expression."
  (let* ((n (typespec-eval--eval n))
         (list (typespec-eval--eval list))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p list) (integerp nval))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (nthcdr nval val))
          'unknown)))
     ((typespec-eval--list-elem-type list)
      (list 'list (typespec-eval--list-elem-type list)))
     (t 'unknown))))

(defun typespec-eval--eval-elt (sequence n)
  "Evaluate an `elt` expression."
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
  "Evaluate an `aref` expression."
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

(defun typespec-eval--eval-reverse (arg)
  "Evaluate a `reverse` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (or (listp val) (vectorp val) (stringp val))
            (typespec-eval--make-const (reverse val))
          'unknown)))
     ((eq (car-safe arg) 'list+) (list 'list+ (cadr arg)))
     ((eq (car-safe arg) 'list) (list 'list (cadr arg)))
     ((typespec-eval--string-type-p arg) 'string)
     ((and (consp arg) (eq (car arg) 'vector))
      (list 'vector (cadr arg)))
     (t 'unknown))))

(defun typespec-eval--eval-copy-sequence (sequence)
  "Evaluate a `copy-sequence` expression."
  (let ((sequence (typespec-eval--eval sequence)))
    (cond
     ((typespec-eval--const-p sequence)
      (let ((val (typespec-eval--const-value sequence)))
        (if (or (listp val) (vectorp val) (stringp val))
            (typespec-eval--make-const (copy-sequence val))
          'unknown)))
     ((eq (car-safe sequence) 'list+) (list 'list+ (cadr sequence)))
     ((eq (car-safe sequence) 'list) (list 'list (cadr sequence)))
     ((typespec-eval--string-type-p sequence) 'string)
     ((and (consp sequence) (eq (car sequence) 'vector))
      (list 'vector (cadr sequence)))
     (t 'unknown))))

(defun typespec-eval--eval-safe-length (list)
  "Evaluate a `safe-length` expression."
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
  "Evaluate a `last` expression."
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
  "Evaluate a `butlast` expression."
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

(defun typespec-eval--eval-assoc (key alist &optional eqp)
  "Evaluate an `assoc`/`assq` expression."
  (let* ((key (typespec-eval--eval key))
         (alist (typespec-eval--eval alist))
         (key-type (typespec-eval--alist-key-type alist)))
    (cond
     ((and (typespec-eval--const-p key) (typespec-eval--const-p alist))
      (let ((val (typespec-eval--const-value alist)))
        (if (listp val)
            (typespec-eval--make-const
             (if eqp
                 (assq (typespec-eval--const-value key) val)
               (assoc (typespec-eval--const-value key) val)))
          'unknown)))
     ((typespec-eval--alist-type-p alist)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (cons :tuple (cons key-type
                                (typespec-eval--alist-value-type alist))))))
     (t 'unknown))))

(defun typespec-eval--eval-assoc-default (key alist &optional test default)
  "Evaluate an `assoc-default` expression."
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

(defun typespec-eval--eval-rassq (value alist)
  "Evaluate a `rassq` expression."
  (let* ((value (typespec-eval--eval value))
         (alist (typespec-eval--eval alist)))
    (cond
     ((and (typespec-eval--const-p value) (typespec-eval--const-p alist))
      (let ((alist-val (typespec-eval--const-value alist)))
        (if (listp alist-val)
            (typespec-eval--make-const (rassq (typespec-eval--const-value value)
                                              alist-val))
          'unknown)))
     ((typespec-eval--alist-type-p alist)
      (typespec-eval--simplify-or
       (list (typespec-eval--make-const nil)
             (cons :tuple (cons (typespec-eval--alist-key-type alist)
                                (typespec-eval--alist-value-type alist))))))
     (t 'unknown))))

(defun typespec-eval--eval-assoc-delete-all (key alist &optional test)
  "Evaluate an `assoc-delete-all`/`assq-delete-all` expression."
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
  "Evaluate a `rassq-delete-all` expression."
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

(defun typespec-eval--eval-remove (elt sequence)
  "Evaluate a `remove` expression."
  (let ((elt (typespec-eval--eval elt))
        (sequence (typespec-eval--eval sequence)))
    (cond
     ((and (typespec-eval--const-p elt) (typespec-eval--const-p sequence))
      (let ((seq (typespec-eval--const-value sequence)))
        (condition-case nil
            (typespec-eval--make-const (remove (typespec-eval--const-value elt) seq))
          (error 'unknown))))
     ((eq (car-safe sequence) 'list)
      (list 'list (cadr sequence)))
     ((eq (car-safe sequence) 'list+)
      (list 'list (cadr sequence)))
     ((typespec-eval--string-type-p sequence) 'string)
     ((and (consp sequence) (eq (car sequence) 'vector))
      (list 'vector (cadr sequence)))
     (t 'unknown))))

(defun typespec-eval--eval-remq (elt list)
  "Evaluate a `remq` expression."
  (let ((elt (typespec-eval--eval elt))
        (list (typespec-eval--eval list)))
    (cond
     ((and (typespec-eval--const-p elt) (typespec-eval--const-p list))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (remq (typespec-eval--const-value elt) val))
          'unknown)))
     ((eq (car-safe list) 'list)
      (list 'list (cadr list)))
     ((eq (car-safe list) 'list+)
      (list 'list (cadr list)))
     (t 'unknown))))

(defun typespec-eval--eval-copy-tree (tree &optional vectors-and-records)
  "Evaluate a `copy-tree` expression."
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
  "Evaluate a `delete-dups` expression."
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
  "Evaluate a `delete-consecutive-dups` expression."
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
    (`(vector ,type)
     (list 'vector (typespec-eval--eval type)))
    (`(:alist ,key ,value)
     (list :alist (typespec-eval--eval key) (typespec-eval--eval value)))
    (`(:tuple . ,args)
     (cons :tuple (typespec-eval--eval-tuple args)))
    (`(and . ,args)
     (typespec-eval--eval-and args))
    (`(not ,arg)
     (typespec-eval--eval-not arg))
    (`(null ,arg)
     (typespec-eval--eval-null arg))
    (`(const ,_) form)
    (`(integer ,low ,high)
     (typespec-eval--integer-range low high))
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
    (`(string-width ,arg)
     (typespec-eval--eval-string-width arg))
    (`(string-lines ,string . ,rest)
     (typespec-eval--eval-string-lines string (car rest) (cadr rest)))
    (`(string-join ,strings . ,rest)
     (typespec-eval--eval-string-join strings (car rest)))
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
    (`(car ,arg)
     (typespec-eval--eval-car arg))
    (`(cdr ,arg)
     (typespec-eval--eval-cdr arg))
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
     (typespec-eval--eval-reverse arg))
    (`(copy-sequence ,sequence)
     (typespec-eval--eval-copy-sequence sequence))
    (`(safe-length ,list)
     (typespec-eval--eval-safe-length list))
    (`(last ,list . ,rest)
     (typespec-eval--eval-last list (car rest)))
    (`(butlast ,list . ,rest)
     (typespec-eval--eval-butlast list (car rest)))
    (`(assoc ,key ,alist)
     (typespec-eval--eval-assoc key alist))
    (`(assq ,key ,alist)
     (typespec-eval--eval-assoc key alist t))
    (`(assoc-default ,key ,alist . ,rest)
     (typespec-eval--eval-assoc-default key alist (car rest) (cadr rest)))
    (`(rassq ,value ,alist)
     (typespec-eval--eval-rassq value alist))
    (`(assoc-delete-all ,key ,alist . ,rest)
     (typespec-eval--eval-assoc-delete-all key alist (car rest)))
    (`(assq-delete-all ,key ,alist)
     (typespec-eval--eval-assoc-delete-all key alist 'eq))
    (`(rassq-delete-all ,value ,alist)
     (typespec-eval--eval-rassq-delete-all value alist))
    (`(copy-tree ,tree . ,rest)
     (typespec-eval--eval-copy-tree tree (car rest)))
    (`(delete-dups ,list)
     (typespec-eval--eval-delete-dups list))
    (`(delete-consecutive-dups ,list . ,rest)
     (typespec-eval--eval-delete-consecutive-dups list (car rest)))
    (`(remove ,elt ,sequence)
     (typespec-eval--eval-remove elt sequence))
    (`(remq ,elt ,list)
     (typespec-eval--eval-remq elt list))
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
    (`(string-suffix-p ,suffix ,string . ,rest)
     (typespec-eval--eval-string-suffix-p
      suffix
      string
      (car rest)))
    (`(string< ,lhs ,rhs)
     (typespec-eval--eval-string-lessp lhs rhs))
    (`(string> ,lhs ,rhs)
     (typespec-eval--eval-string-greaterp lhs rhs))
    (`(string= ,lhs ,rhs)
     (typespec-eval--eval-string-equal lhs rhs))
    (`(string-lessp ,lhs ,rhs)
     (typespec-eval--eval-string-lessp lhs rhs))
    (`(string-greaterp ,lhs ,rhs)
     (typespec-eval--eval-string-greaterp lhs rhs))
    (`(string-equal-ignore-case ,lhs ,rhs)
     (typespec-eval--eval-string-equal-ignore-case lhs rhs))
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
     (typespec-eval--eval-string-to-multibyte string))
    (`(string-to-unibyte ,string)
     (typespec-eval--eval-string-to-unibyte string))
    (`(string-chop-newline ,string)
     (typespec-eval--eval-string-chop-newline string))
    (`(string-clean-whitespace ,string)
     (typespec-eval--eval-string-clean-whitespace string))
    (`(string-limit ,string ,n)
     (typespec-eval--eval-string-limit string n))
    (`(string-distance ,lhs ,rhs)
     (typespec-eval--eval-string-distance lhs rhs))
    (`(string-version-lessp ,lhs ,rhs)
     (typespec-eval--eval-string-version-lessp lhs rhs))
    (`(char-to-string ,char)
     (typespec-eval--eval-char-to-string char))
    (`(make-string ,length ,char)
     (typespec-eval--eval-make-string length char))
    (`(+ . ,args)
     (typespec-eval--eval-plus args))
    (`(* . ,args)
     (typespec-eval--eval-times args))
    (`(- . ,args)
     (typespec-eval--eval-minus args))
    (`(/ . ,args)
     (typespec-eval--eval-divide args))
    (`(% . ,args)
     (typespec-eval--eval-rem args))
    (`(mod . ,args)
     (typespec-eval--eval-mod args))
    (`(logand . ,args)
     (typespec-eval--eval-logand args))
    (`(logior . ,args)
     (typespec-eval--eval-logior args))
    (`(logxor . ,args)
     (typespec-eval--eval-logxor args))
    (`(lognot ,arg)
     (typespec-eval--eval-lognot arg))
    (`(logcount ,arg)
     (typespec-eval--eval-logcount arg))
    (`(ash ,value ,count)
     (typespec-eval--eval-ash value count))
    (`(zerop ,arg)
     (typespec-eval--eval-zerop arg))
    (`(isnan ,arg)
     (typespec-eval--eval-isnan arg))
    (`(cl-signum ,arg)
     (typespec-eval--eval-cl-signum arg))
    (`(number-sequence ,from . ,rest)
     (typespec-eval--eval-number-sequence from (car rest) (cadr rest)))
    (`(1+ ,arg)
     (typespec-eval--eval-add1 arg))
    (`(1- ,arg)
     (typespec-eval--eval-sub1 arg))
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
