;;; typespec-eval-op.el --- Type-level op handlers for typespec  -*- lexical-binding: t; -*-

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

;; One-to-one op handlers for typespec evaluation (e.g. cons -> typespec-eval-op-cons).
;; Functions are in abc order by op name.  Callers must load typespec-eval.

;;; Code:

(require 'cl-lib)
(require 'typespec-core)
(require 'typespec-eval-core)
(require 'typespec-eval-simplify)
(require 'typespec-eval-struct)
(require 'typespec-eval-types)
(require 'typespec-eval-numeric)

(declare-function typespec-eval--eval "typespec-eval" (form))

(defun typespec-eval-op-alist-get (key alist &optional default remove testfn)
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
     ((typespec-eval-struct-alist-form-p alist)
      (let ((value-type (typespec-eval-struct-alist-value-type alist)))
        (if default
            (typespec-eval-simplify-or (list default value-type))
          (typespec-eval-simplify-or
           (list (typespec-eval--make-const nil) value-type)))))
     ((let ((entry (typespec-eval-struct-alist-entry-seq-types alist)))
        (when entry
          (let ((value-type (cdr entry)))
            (if default
                (typespec-eval-simplify-or (list default value-type))
              (typespec-eval-simplify-or
               (list (typespec-eval--make-const nil) value-type)))))))
     (t 'unknown))))

(defun typespec-eval-op-alist-search (search-item alist search-key-p compare-fn)
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
     ((typespec-eval-struct-alist-form-p alist)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (cons :tuple (cons (typespec-eval-struct-alist-key-type alist)
                                (typespec-eval-struct-alist-value-type alist))))))
     ((let ((entry (typespec-eval-struct-alist-entry-seq-types alist)))
        (when entry
          (typespec-eval-simplify-or
           (list (typespec-eval--make-const nil)
                 (cons :tuple (cons (car entry) (cdr entry))))))))
     (t 'unknown))))

(defun typespec-eval-op-and (args)
  "Evaluate an `and` expression over ARGS."
  (let ((items (mapcar #'typespec-eval--eval args)))
    (typespec-eval-simplify-and items)))

(defun typespec-eval-op-append (args)
  "Evaluate an `append` expression over ARGS."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) (typespec-eval--make-const nil))
     ((seq-every-p #'typespec-eval--const-p args)
      (typespec-eval--make-const
       (apply #'append (mapcar #'typespec-eval--const-value args))))
     ((seq-every-p #'typespec-eval-struct-alist-form-p args)
      (list :alist
            (typespec-eval-simplify-or
             (mapcar #'typespec-eval-struct-alist-key-type args))
            (typespec-eval-simplify-or
             (mapcar #'typespec-eval-struct-alist-value-type args))))
     ((seq-every-p #'typespec-eval-struct-plist-form-p args)
      (list :plist
            (typespec-eval-simplify-or
             (mapcar #'typespec-eval-struct-plist-key-type args))
            (typespec-eval-simplify-or
             (mapcar #'typespec-eval-struct-plist-value-type args))))
     ((let* ((entries (mapcar #'typespec-eval-struct-plist-append-entry-types args))
             (all-entries (and (seq-every-p #'identity entries) entries)))
        (when all-entries
          (list :plist
                (typespec-eval-simplify-or (mapcar #'car entries))
                (typespec-eval-simplify-or (mapcar #'cdr entries))))))
     ((let* ((entries
              (mapcar
               (lambda (arg)
                 (cond
                  ((typespec-eval-struct-alist-form-p arg)
                   (cons (typespec-eval-struct-alist-key-type arg)
                         (typespec-eval-struct-alist-value-type arg)))
                  ((typespec-eval-struct-list-elem-type arg)
                   (typespec-eval-struct-alist-entry-types
                    (typespec-eval-struct-list-elem-type arg)))
                  (t nil)))
               args))
             (all-entries (and (seq-every-p #'identity entries) entries)))
        (when all-entries
          (list :alist
                (typespec-eval-simplify-or (mapcar #'car entries))
                (typespec-eval-simplify-or (mapcar #'cdr entries))))))
     (t
      (let* ((elems nil)
             (any-non-empty nil))
        (dolist (arg args)
          (cond
           ((typespec-eval-struct-list-elem-type arg)
            (push (typespec-eval-struct-list-elem-type arg) elems)
            (when (eq (car arg) 'list+) (setq any-non-empty t)))
           ((typespec-eval-struct-alist-form-p arg)
            (push (list 'cons
                        (typespec-eval-struct-alist-key-type arg)
                        (typespec-eval-struct-alist-value-type arg))
                  elems))
           ((typespec-eval-struct-plist-form-p arg)
            (push (typespec-eval-simplify-or
                   (list (typespec-eval-struct-plist-key-type arg)
                         (typespec-eval-struct-plist-value-type arg)))
                  elems))
           ((typespec-eval--const-p arg)
            (let ((val (typespec-eval--const-value arg)))
              (when (listp val)
                (when val (setq any-non-empty t))
                (push (typespec-eval-simplify-or
                       (mapcar #'typespec-eval--make-const val))
                      elems))))))
        (list (if any-non-empty 'list+ 'list)
              (if elems
                  (typespec-eval-simplify-or (nreverse elems))
                'mixed)))))))

(defun typespec-eval-op-aref (array n)
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
     ((typespec-eval-types-string-type-p array) 'integer)
     ((and (consp array) (eq (car array) 'vector))
      (cadr array))
     (t 'unknown))))

(defun typespec-eval-op-argspecs (argspecs)
  "Evaluate ARGSPECS in order, preserving markers like &rest.
Return `:invalid` if ARGSPECS ordering or structure is invalid."
  (let ((out nil)
        (seen-optional nil)
        (seen-rest nil)
        (seen-keys nil)
        (expect-rest nil)
        (expect-keys nil)
        (invalid nil))
    (dolist (spec argspecs)
      (when (not invalid)
        (cond
         ((memq spec '(&optional &rest &keys))
          (pcase spec
            ('&optional
             (if (or seen-optional seen-rest seen-keys expect-rest expect-keys)
                 (setq invalid t)
               (setq seen-optional t)
               (push '&optional out)))
            ('&rest
             (if (or seen-rest seen-keys expect-rest expect-keys)
                 (setq invalid t)
               (setq seen-rest t expect-rest t)
               (push '&rest out)))
            ('&keys
             (if (or seen-keys expect-rest expect-keys)
                 (setq invalid t)
               (setq seen-keys t expect-keys t)
               (push '&keys out)))))
         (t
          (cond
           (expect-rest
            (push (typespec-eval--eval spec) out)
            (setq expect-rest nil))
           (expect-keys
            (let ((eval-spec (typespec-eval--eval spec)))
              (if (or (typespec-eval-struct-plist-form-p eval-spec)
                      (typespec-eval-struct-plist-of-p eval-spec))
                  (push eval-spec out)
                (setq invalid t))
              (setq expect-keys nil)))
           (seen-keys
            (setq invalid t))
           ((and seen-rest (not expect-rest))
            (setq invalid t))
           (t
            (push (typespec-eval--eval spec) out)))))))
    (cond
     (invalid :invalid)
     (expect-rest :invalid)
     (expect-keys
      (push (typespec-eval--eval '(:plist keyword mixed)) out)
      (nreverse out))
     (t (nreverse out)))))

(defun typespec-eval-op-arith (args op &optional zero-value)
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
                                      (let ((info (typespec-eval-numeric-numeric-range-info arg)))
                                        (and info (typespec-eval-numeric-numeric-range-includes-zero-p info))))
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
     ((typespec-eval-numeric-arith-const-options args op))
     ((typespec-eval-numeric-integer-range-arith args op))
     ((typespec-eval-numeric-number-range-arith args op))
     ((typespec-eval-numeric-float-range-arith args op))
     (t (typespec-eval-numeric-arith-type args)))))

(defun typespec-eval-op-ash (value count)
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
     ((and (typespec-eval-types-non-negative-int-type-p value)
           (typespec-eval-types-non-negative-int-type-p count))
      '(integer 0 *))
     ((and (eq value 'positive-int)
           (typespec-eval-types-integer-type-p count))
      'integer)
     ((and (typespec-eval-types-non-negative-int-type-p value)
           (typespec-eval-types-integer-type-p count))
      '(integer 0 *))
     ((and (typespec-eval-types-integer-type-p value)
           (typespec-eval-types-integer-type-p count))
      'integer)
     (t 'unknown))))

(defun typespec-eval-op-assoc-default (key alist &optional test default)
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
     ((typespec-eval-struct-alist-form-p alist)
      (let ((value-type (typespec-eval-struct-alist-value-type alist)))
        (if default
            (typespec-eval-simplify-or (list default value-type))
          (typespec-eval-simplify-or
           (list (typespec-eval--make-const nil) value-type)))))
     ((let ((entry (typespec-eval-struct-alist-entry-seq-types alist)))
        (when entry
          (let ((value-type (cdr entry)))
            (if default
                (typespec-eval-simplify-or (list default value-type))
              (typespec-eval-simplify-or
               (list (typespec-eval--make-const nil) value-type)))))))
     (t 'unknown))))

(defun typespec-eval-op-assoc-delete-all (key alist &optional test)
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
     ((typespec-eval-struct-alist-form-p alist) alist)
     (t 'unknown))))

(defun typespec-eval-op-binary-string-compare (lhs rhs fn result-type)
  "Evaluate binary string comparison FN over LHS and RHS.
RESULT-TYPE is returned when both arguments are string types."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval-simplify-map-const-or
       lhs
       (lambda (item)
         (let ((res (typespec-eval-op-binary-string-compare item rhs fn result-type)))
           (when (typespec-eval--const-p res) res)))
       result-type))
     ((and (consp rhs) (eq (car rhs) 'or))
      (typespec-eval-simplify-map-const-or
       rhs
       (lambda (item)
         (let ((res (typespec-eval-op-binary-string-compare lhs item fn result-type)))
           (when (typespec-eval--const-p res) res)))
       result-type))
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs)
           (stringp (typespec-eval--const-value lhs))
           (stringp (typespec-eval--const-value rhs)))
      (typespec-eval--make-const
       (funcall fn (typespec-eval--const-value lhs)
                (typespec-eval--const-value rhs))))
     ((and (typespec-eval-types-string-type-p lhs)
           (typespec-eval-types-string-type-p rhs))
      result-type)
     (t 'unknown))))

(defun typespec-eval-op-binary-string-op (arg1 arg2 fn)
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
     ((and (typespec-eval-types-string-type-p arg1)
           (typespec-eval-types-string-type-p arg2))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-butlast (list &optional n)
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
     ((and (consp list) (eq (car list) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts))
             (len (length prefix))
             (count (if n (or nval 1) 1)))
        (cond
         (tail 'unknown)
         ((null prefix) (typespec-eval--make-const nil))
         ((and (integerp count) (<= count 0))
          (typespec-eval-struct-tuple-build prefix nil))
         ((and (integerp count) (>= count len))
          (typespec-eval--make-const nil))
         ((integerp count)
          (typespec-eval-struct-tuple-build (butlast prefix count) nil))
         (t (list 'list (typespec-eval-simplify-or prefix))))))
     ((typespec-eval-struct-alist-form-p list)
      (cond
       ((and (integerp nval) (<= nval 0)) list)
       (t list)))
     ((typespec-eval-struct-plist-form-p list)
      (cond
       ((and (integerp nval) (<= nval 0)) list)
       (t list)))
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

(defun typespec-eval-op-car-safe (arg)
  "Evaluate a `car-safe` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (typespec-eval--make-const (car-safe val))))
     ((typespec-eval-struct-sequence-elem-type arg)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval-struct-sequence-elem-type arg))))
     ((typespec-eval-struct-alist-form-p arg)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (list 'cons
                   (typespec-eval-struct-alist-key-type arg)
                   (typespec-eval-struct-alist-value-type arg)))))
     ((typespec-eval-struct-plist-form-p arg)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval-struct-plist-key-type arg))))
     ((and (consp arg) (eq (car arg) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr arg)))
             (prefix (car parts)))
        (if prefix
            (car prefix)
          (typespec-eval--make-const nil))))
     ((eq (car-safe arg) 'list+)
      (cadr arg))
     ((eq (car-safe arg) 'list)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil) (cadr arg))))
     (t 'unknown))))

(defun typespec-eval-op-cdr-safe (arg)
  "Evaluate a `cdr-safe` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (typespec-eval--make-const (cdr-safe val))))
     ((typespec-eval-struct-sequence-elem-type arg)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (list 'list (typespec-eval-struct-sequence-elem-type arg)))))
     ((typespec-eval-struct-alist-form-p arg)
      (typespec-eval-simplify-or (list (typespec-eval--make-const nil) arg)))
     ((typespec-eval-struct-plist-form-p arg)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (list 'cons
                   (typespec-eval-struct-plist-value-type arg)
                   arg))))
     ((and (consp arg) (eq (car arg) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr arg)))
             (prefix (car parts))
             (tail (cdr parts)))
        (cond
         ((null prefix) (typespec-eval--make-const nil))
         ((and (null (cdr prefix)) (null tail)) (typespec-eval--make-const nil))
         ((and (null (cdr prefix)) tail) tail)
         (t (typespec-eval-struct-tuple-build (cdr prefix) tail)))))
     ((memq (car-safe arg) '(list list+))
      (list 'list (cadr arg)))
     (t 'unknown))))

(defun typespec-eval-op-char-equal (lhs rhs)
  "Evaluate a `char-equal` expression for LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (char-equal (typespec-eval--const-value lhs)
                   (typespec-eval--const-value rhs))))
     ((and (typespec-eval-types-integer-type-p lhs)
           (typespec-eval-types-integer-type-p rhs))
      'boolean)
     ((and (typespec-eval-types-string-type-p lhs)
           (typespec-eval-types-string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-char-to-string (char)
  "Evaluate a `char-to-string` expression for CHAR."
  (let ((char (typespec-eval--eval char)))
    (cond
     ((typespec-eval--const-p char)
      (let ((val (typespec-eval--const-value char)))
        (if (characterp val)
            (typespec-eval--make-const (char-to-string val))
          'unknown)))
     ((typespec-eval-types-integer-type-p char)
      (typespec-eval--non-empty-string-expr))
     (t 'unknown))))

(defun typespec-eval-op-cl-endp (arg)
  "Evaluate a `cl-endp` predicate for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (cl-endp (typespec-eval--const-value arg))))
     ((eq (car-safe arg) 'list+)
      (typespec-eval--make-const nil))
     ((typespec-eval-types-list-type-p arg) 'boolean)
     (t 'unknown))))

(defun typespec-eval-op-cl-list-length (arg)
  "Evaluate a `cl-list-length` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (cl-list-length (typespec-eval--const-value arg))))
     ((typespec-eval-types-list-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval-op-concat (args)
  "Evaluate a `concat` expression over ARGS."
  (let ((eval-args (mapcar #'typespec-eval--eval args))
        (options nil)
        (all-const t))
    (dolist (arg eval-args)
      (let ((opts (typespec-eval-simplify-const-string-options arg)))
        (if opts
            (push opts options)
          (setq all-const nil))))
    (if all-const
        (let ((results (typespec-eval-simplify-concat-combinations (nreverse options))))
          (if results
              (typespec-eval-simplify-or
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
       ((and (seq-every-p #'typespec-eval-types-string-type-p eval-args)
             (seq-some
              (lambda (arg)
                (and (typespec-eval--const-p arg)
                     (stringp (typespec-eval--const-value arg))
                     (> (length (typespec-eval--const-value arg)) 0)))
              eval-args))
        (typespec-eval--non-empty-string-expr))
       ((seq-every-p #'typespec-eval-types-string-type-p eval-args) 'string)
       (t 'unknown)))))

(defun typespec-eval-op-cons (car cdr)
  "Evaluate a `cons' expression for CAR and CDR."
  (let* ((car (typespec-eval--eval car))
         (cdr (typespec-eval--eval cdr))
         (entry (typespec-eval-struct-alist-entry-types car)))
    (cond
     ((and (typespec-eval--const-p car) (typespec-eval--const-p cdr))
      (typespec-eval--make-const
       (cons (typespec-eval--const-value car)
             (typespec-eval--const-value cdr))))
     ((typespec-eval-struct-list-elem-type cdr)
      (let ((elem (typespec-eval-struct-list-elem-type cdr)))
        (list 'list+
              (if (equal car elem)
                  elem
                (typespec-eval-simplify-or (list car elem))))))
     ((typespec-eval--always-nil-p cdr)
      (list 'list+ car))
     ((and (typespec-eval-struct-alist-form-p cdr) entry)
      (list :alist
            (let ((key (car entry))
                  (prev (typespec-eval-struct-alist-key-type cdr)))
              (if (equal key prev)
                  key
                (typespec-eval-simplify-or (list key prev))))
            (let ((val (cdr entry))
                  (prev (typespec-eval-struct-alist-value-type cdr)))
              (if (equal val prev)
                  val
                (typespec-eval-simplify-or (list val prev))))))
     (t (list 'cons car cdr)))))

(defun typespec-eval-op-copy-tree (tree &optional vectors-and-records)
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

(defun typespec-eval-op-delete-consecutive-dups (list &optional circular)
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

(defun typespec-eval-op-delete-dups (list)
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

(defun typespec-eval-op-diff (lhs rhs)
  "Evaluate `(diff LHS RHS)` with simple simplifications."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((eq lhs 'never) 'never)
     ((eq rhs 'never) lhs)
     ;; Subtracting a top type (the whole universe) leaves nothing.
     ((memq rhs '(mixed t unknown)) 'never)
     ;; The gradual dynamic stays dynamic under set-difference: subtracting a
     ;; concrete type from `unknown' cannot yield a provable exclusion, so the
     ;; false branch of a `:guard!' narrowing on a not-yet-known value stays
     ;; `unknown' rather than leaving a `(diff unknown ...)' residue.  (Contrast
     ;; the top type `mixed', whose complement is a real subtractable universe.)
     ((eq lhs 'unknown) 'unknown)
     ((equal lhs rhs) 'never)
     ((and (consp rhs) (eq (car rhs) 'or))
      (let ((items (cdr rhs))
            (result lhs))
        (while (and items (not (eq result 'never)))
          (setq result (typespec-eval-op-diff result (car items)))
          (setq items (cdr items)))
        result))
     ((and (consp lhs) (eq (car lhs) 'or))
      (typespec-eval-simplify-or
       (mapcar (lambda (item) (typespec-eval-op-diff item rhs))
               (cdr lhs))))
     ((and (consp rhs) (eq (car rhs) 'diff)
           (equal (cadr rhs) 'mixed))
      (typespec-eval-simplify-and (list lhs (caddr rhs))))
     ;; Subtracting a disjoint type removes nothing.
     ((typespec-eval-types-disjoint-p lhs rhs) lhs)
     (t (list 'diff lhs rhs)))))

(defun typespec-eval-op-downcast (_value target)
  "Evaluate `(downcast VALUE TARGET)` as TARGET."
  (typespec-eval--eval target))

(defun typespec-eval-op-elt (sequence n)
  "Evaluate an `elt' expression for SEQUENCE and N."
  (let* ((sequence (typespec-eval--eval sequence))
         (n (typespec-eval--eval n))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--const-p sequence) (integerp nval))
      (let ((val (typespec-eval--const-value sequence)))
        (condition-case nil
            (typespec-eval--make-const (elt val nval))
          (args-out-of-range 'unknown))))
     ((and (consp sequence) (eq (car sequence) :tuple) (integerp nval))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr sequence)))
             (prefix (car parts))
             (tail (cdr parts)))
        (cond
         ((< nval 0) (typespec-eval--make-const nil))
         ((< nval (length prefix)) (nth nval prefix))
         ((null tail) (typespec-eval--make-const nil))
         ((typespec-eval-struct-list-elem-type tail)
          (let ((offset (- nval (length prefix)))
                (elem (typespec-eval-struct-list-elem-type tail)))
            (if (>= offset 0) elem (typespec-eval--make-const nil))))
         (t 'unknown))))
     ((and (consp sequence) (eq (car sequence) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr sequence)))
             (prefix (car parts))
             (tail (cdr parts))
             (items (append prefix
                            (when (typespec-eval-struct-list-elem-type tail)
                              (list (typespec-eval-struct-list-elem-type tail))))))
        (typespec-eval-simplify-or items)))
     ((typespec-eval-struct-sequence-elem-type sequence))
     ((eq sequence 'sequence) 'mixed)
     ((typespec-eval-types-string-type-p sequence) 'integer)
     ((typespec-eval-struct-list-elem-type sequence) (typespec-eval-struct-list-elem-type sequence))
     ((typespec-eval-struct-vector-of-p sequence 'integer) 'integer)
     ((and (consp sequence) (eq (car sequence) 'vector))
      (cadr sequence))
     (t 'unknown))))

(defun typespec-eval-op-equality (lhs rhs fn &optional value-pred type-pred)
  "Evaluate an equality expression over LHS and RHS using FN.
VALUE-PRED is an optional predicate to check const values
\\(e.g., #\\='numberp for =).
TYPE-PRED is an optional predicate to check evaluated types."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (null value-pred)
           (symbolp lhs)
           (symbolp rhs)
           (typespec-eval-types-type-category-with-guard lhs)
           (typespec-eval-types-type-category-with-guard rhs)
           (not (typespec-eval-types-type-subtype-p lhs rhs))
           (not (typespec-eval-types-type-subtype-p rhs lhs)))
      (typespec-eval--make-const nil))
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
      (let* ((lhs-info (typespec-eval-numeric-numeric-range-info lhs))
             (rhs-info (typespec-eval-numeric-numeric-range-info rhs)))
        (cond
         ((and lhs-info rhs-info
               (typespec-eval-numeric-numeric-range-disjoint-p lhs-info rhs-info))
          (typespec-eval--make-const nil))
         ((and lhs-info rhs-info
               (typespec-eval-numeric-numeric-range-singleton-p lhs-info)
               (typespec-eval-numeric-numeric-range-singleton-p rhs-info))
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

(defun typespec-eval-op-function-type (argspecs ret)
  "Evaluate function type ARGSPECS and RET."
  (let ((argspecs (typespec-eval-op-argspecs argspecs)))
    (if (eq argspecs :invalid)
        'unknown
      (pcase ret
        (`(:guard ,type)
         (list 'function argspecs (list :guard (typespec-eval--eval type))))
        (`(:guard ,type ,rt)
         (list 'function argspecs
               (list :guard (typespec-eval--eval type) (typespec-eval--eval rt))))
        (`(:guard! ,type)
         (list 'function argspecs (list :guard! (typespec-eval--eval type))))
        (`(:guard! ,type ,rt)
         (list 'function argspecs
               (list :guard! (typespec-eval--eval type) (typespec-eval--eval rt))))
        (`(:assert ,type)
         (list 'function argspecs (list :assert (typespec-eval--eval type))))
        (_
         (list 'function argspecs (typespec-eval--eval ret)))))))

(defun typespec-eval-op-generalize (value target)
  "Evaluate `(generalize VALUE TARGET)`."
  (let ((value (typespec-eval--eval value))
        (target (typespec-eval--eval target)))
    (cond
     ((typespec-eval--const-p value) target)
     ((typespec-eval-types-type-subtype-p value target) target)
     (t (list 'generalize value target)))))

(defun typespec-eval-op-generalize-signed (value)
  "Evaluate `(generalize-signed VALUE)`."
  (let ((value (typespec-eval--eval value)))
    (cond
     ((typespec-eval--const-p value)
      (let ((val (typespec-eval--const-value value)))
        (cond
         ((and (integerp val) (> val 0)) 'positive-int)
         ((and (integerp val) (< val 0)) 'negative-int)
         ((and (floatp val) (> val 0.0)) 'positive-float)
         ((and (floatp val) (< val 0.0)) 'negative-float)
         (t value))))
     ((and-let* ((cat (typespec-eval-types-type-category-with-guard value)))
        (memq cat '(integer float number)))
      value)
     ((memq value '(unknown mixed)) 'never)
     (t 'never))))

(defun typespec-eval-op--pred-has-disallowed-p (form)
  "Return non-nil if FORM contains a disallowed predicate call.
See `typespec-conditional-disallowed-functions'."
  (and (consp form)
       (or (and (symbolp (car form))
                (memq (car form) typespec-conditional-disallowed-functions))
           (seq-some #'typespec-eval-op--pred-has-disallowed-p form))))

(defun typespec-eval-op-validate-pred (pred)
  "Return non-nil if PRED is a valid `if' conditional predicate.
A predicate is invalid only when it calls a state-dependent or
environment-dependent function listed in
`typespec-conditional-disallowed-functions'; other forms are accepted and
evaluated conservatively."
  (not (typespec-eval-op--pred-has-disallowed-p pred)))

(defconst typespec-eval-op--rettype-heads '(:guard :guard! :assert if)
  "Heads of RETTYPE forms, valid only in a function return position.")

(defun typespec-eval-op--validate-args (args)
  "Validate ARGS of a function type; return a cause-error or nil.
Each argument type is a general TYPE position (no RETTYPE forms allowed)."
  (and (listp args)
       (seq-some
        (lambda (spec)
          (and (not (memq spec '(&optional &rest &keys &key &allow-other-keys)))
               (typespec-eval-op-validate-positions spec nil)))
        args)))

(defun typespec-eval-op-validate-positions (form &optional allow-rettype)
  "Return nil if RETTYPE forms in FORM appear only in return positions.
Otherwise return `(:cause-error (misplaced-rettype SUBFORM))' for the first
violation.  RETTYPE forms (`:guard'/`:guard!'/`:assert'/`if') are valid only
as a function return slot or a nested `if' branch; ALLOW-RETTYPE is non-nil
when FORM itself sits in such a position."
  (cond
   ((atom form) nil)
   ((memq (car form) typespec-eval-op--rettype-heads)
    (if (not allow-rettype)
        (typespec-eval--make-cause-error (list 'misplaced-rettype form))
      (pcase form
        (`(if ,_pred ,then ,else)
         (or (typespec-eval-op-validate-positions then t)
             (typespec-eval-op-validate-positions else t)))
        (`(,_ ,type . ,rest)
         (or (typespec-eval-op-validate-positions type nil)
             (and rest (typespec-eval-op-validate-positions (car rest) nil)))))))
   (t
    (pcase form
      ;; Leaf-like forms whose children are not types.
      (`(const . ,_) nil)
      (`(rx . ,_) nil)
      (`(var . ,_) nil)
      (`(quote . ,_) nil)
      (`(member . ,_) nil)
      (`(:class . ,_) nil)
      (`(:forall ,_ ,body)
       (typespec-eval-op-validate-positions body allow-rettype))
      (`(function ,args ,ret)
       (or (typespec-eval-op--validate-args args)
           (typespec-eval-op-validate-positions ret t)))
      (_
       ;; General type form: every cons child is a forbidden TYPE position.
       (seq-some (lambda (child)
                   (typespec-eval-op-validate-positions child nil))
                 (cdr form)))))))

(defun typespec-eval-op-if (pred then else)
  "Evaluate an `if` expression with PRED, THEN, and ELSE."
  (cond
   ((not (typespec-eval-op-validate-pred pred))
    (typespec-eval--make-cause-error (list 'invalid-predicate pred)))
   ((typespec-eval-op-if-rx-narrowing pred then else))
   (t
    (let ((pred (typespec-eval--eval pred)))
      (cond
       ((eq pred 'never) 'never)
       ((typespec-eval--always-non-nil-p pred)
        (typespec-eval--eval then))
       ((typespec-eval--always-nil-p pred)
        (typespec-eval--eval else))
       (t
        (typespec-eval-simplify-or
         (list (typespec-eval--eval then)
               (typespec-eval--eval else)))))))))

(defun typespec-eval-op--string-affix-narrowing (affix var rest then position)
  "Return a narrowing for string prefix/suffix predicates.

AFFIX is the string argument, VAR is the subject variable, REST holds
the optional IGNORE-CASE argument, THEN is the then-branch, and POSITION
is either `prefix` or `suffix`."
  (let ((affix (typespec-eval--eval affix))
        (ignore-case (when rest (typespec-eval--eval (car rest)))))
    (when (and (equal then var)
               (typespec-eval--const-p affix)
               (stringp (typespec-eval--const-value affix)))
      (let ((ignore-nil-p (or (null ignore-case)
                              (eq ignore-case nil)
                              (typespec-eval--always-nil-p ignore-case)))
            (ignore-non-nil-p (or (eq ignore-case t)
                                  (typespec-eval--always-non-nil-p ignore-case))))
        (cond
         (ignore-nil-p
          (if (eq position 'prefix)
              (list 'rx 'bos (typespec-eval--const-value affix))
            (list 'rx (typespec-eval--const-value affix) 'eos)))
         ((and (> (length (typespec-eval--const-value affix)) 0)
               ignore-non-nil-p)
          (typespec-eval-simplify-or
           (list
            (typespec-eval-simplify-and (list var '(not (const ""))))
            '(const nil)))))))))

(defun typespec-eval-op-if-rx-narrowing (pred then else)
  "Return an `(rx ...)` type when PRED narrows THEN with ELSE nil.
This matches `(if (string-match-p (rx ...) VAR) VAR nil)` patterns."
  (when-let* ((else-nil (or (null else) (equal else '(const nil)))))
    (pcase pred
      (`(string-match-p ,rx ,var)
       (when (and (equal then var)
                  (typespec-eval-types-rx-type-p rx))
         rx))
      (`(string-match ,rx ,var)
       (when (and (equal then var)
                  (typespec-eval-types-rx-type-p rx))
         rx))
      (`(string-prefix-p ,prefix ,var . ,rest)
       (typespec-eval-op--string-affix-narrowing prefix var rest then 'prefix))
      (`(string-suffix-p ,suffix ,var . ,rest)
       (typespec-eval-op--string-affix-narrowing suffix var rest then 'suffix))
      (`(string= ,lhs ,rhs)
       (let ((lhs (typespec-eval--eval lhs))
             (rhs (typespec-eval--eval rhs)))
         (cond
          ((and (equal then rhs)
                (typespec-eval--const-p lhs)
                (stringp (typespec-eval--const-value lhs)))
           (list 'rx 'bos (typespec-eval--const-value lhs) 'eos))
          ((and (equal then lhs)
                (typespec-eval--const-p rhs)
                (stringp (typespec-eval--const-value rhs)))
           (list 'rx 'bos (typespec-eval--const-value rhs) 'eos)))))
      (`(string-equal ,lhs ,rhs)
       (let ((lhs (typespec-eval--eval lhs))
             (rhs (typespec-eval--eval rhs)))
         (cond
          ((and (equal then rhs)
                (typespec-eval--const-p lhs)
                (stringp (typespec-eval--const-value lhs)))
           (list 'rx 'bos (typespec-eval--const-value lhs) 'eos))
          ((and (equal then lhs)
                (typespec-eval--const-p rhs)
                (stringp (typespec-eval--const-value rhs)))
           (list 'rx 'bos (typespec-eval--const-value rhs) 'eos))))))))

(defun typespec-eval-op-integer-variadic (args op &optional zero-value)
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
           (seq-every-p #'typespec-eval-types-non-negative-int-type-p args))
      '(integer 0 *))
     ((seq-every-p #'typespec-eval-types-integer-type-p args) 'integer)
     (t 'unknown))))

(defun typespec-eval-op-integerp (arg)
  "Evaluate `integerp` over ARG with const-or folding."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((and (consp arg) (eq (car arg) 'or)
           (seq-every-p (lambda (item)
                          (and (typespec-eval--const-p item)
                               (integerp (typespec-eval--const-value item))))
                        (cdr arg)))
      (typespec-eval--make-const t))
     (t
      (typespec-eval-op-unary-predicate arg #'integerp
                        #'typespec-eval-types-integer-type-p
                        #'typespec-eval-types-non-integer-type-p)))))

(defun typespec-eval-op-isnan (arg)
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
     ((typespec-eval-types-integer-type-p arg)
      (typespec-eval--make-const nil))
     ((typespec-eval-types-number-type-p arg)
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-last (list &optional n)
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
     ((and (consp list) (eq (car list) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts))
             (len (length prefix)))
        (cond
         (tail 'unknown)
         ((null prefix) (typespec-eval--make-const nil))
         ((null n)
          (typespec-eval-struct-tuple-build (last prefix 1) nil))
         ((and (integerp nval) (<= nval 0)) (typespec-eval--make-const nil))
         ((and (integerp nval) (>= nval len))
          (typespec-eval-struct-tuple-build prefix nil))
         ((integerp nval)
          (typespec-eval-struct-tuple-build (last prefix nval) nil))
         (t (list 'list (typespec-eval-simplify-or prefix))))))
     ((typespec-eval-struct-alist-form-p list)
      (cond
       ((and (integerp nval) (<= nval 0)) (typespec-eval--make-const nil))
       (t list)))
     ((typespec-eval-struct-plist-form-p list)
      (cond
       ((and (integerp nval) (<= nval 0)) (typespec-eval--make-const nil))
       (t list)))
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

(defun typespec-eval-op-length (arg)
  "Evaluate a `length` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (length (typespec-eval--const-value arg))))
     ((and (consp arg) (eq (car arg) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr arg)))
             (prefix (car parts))
             (tail (cdr parts)))
        (if (null tail)
            (typespec-eval--make-const (length prefix))
          'unknown)))
     ((typespec-eval-struct-alist-form-p arg)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval-struct-plist-form-p arg)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval-struct-sequence-elem-type arg)
      (typespec-eval--integer-range 0 '*))
     ((eq arg 'sequence)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval--non-empty-string-p arg)
      (typespec-eval--integer-range 1 '*))
     ((eq arg 'string)
      (typespec-eval--integer-range 0 '*))
     ((and (consp arg) (eq (car arg) 'list+))
      (typespec-eval--integer-range 1 '*))
     ((typespec-eval-types-list-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval-op-list (args)
  "Evaluate a `list` expression over ARGS."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) (typespec-eval--make-const nil))
     ((seq-every-p #'typespec-eval--const-p args)
      (typespec-eval--make-const
       (mapcar #'typespec-eval--const-value args)))
     (t
      (let* ((entries (mapcar #'typespec-eval-struct-alist-entry-types args))
             (all-entries (and (seq-every-p #'identity entries) entries)))
        (cond
         (all-entries
          (list :alist
                (typespec-eval-simplify-or (mapcar #'car entries))
                (typespec-eval-simplify-or (mapcar #'cdr entries))))
         ((and (zerop (mod (length args) 2))
               (seq-every-p (lambda (arg) (not (typespec-eval--const-p arg))) args))
          (let ((keys nil)
                (values nil)
                (idx 0))
            (dolist (arg args)
              (if (cl-evenp idx)
                  (push arg keys)
                (push arg values))
              (setq idx (1+ idx)))
            (list :plist
                  (typespec-eval-simplify-or (nreverse keys))
                  (typespec-eval-simplify-or (nreverse values)))))
         (t
          (list 'list+
                (typespec-eval-simplify-or args)))))))))

(defun typespec-eval-op-make-composed-keymap (maps &optional parent)
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

(defun typespec-eval-op-make-string (length char)
  "Evaluate a `make-string` expression for LENGTH and CHAR."
  (let* ((length (typespec-eval--eval length))
         (char (typespec-eval--eval char))
         (len (typespec-eval--const-integer-value length))
         (cval (and (typespec-eval--const-p char)
                    (typespec-eval--const-value char))))
    (cond
     ((and (integerp len) (characterp cval) (<= 0 len))
      (typespec-eval--make-const (make-string len cval)))
     ((and (typespec-eval-types-integer-type-p length)
           (typespec-eval-types-integer-type-p char))
      (if (typespec-eval-types-positive-int-type-p length)
          (typespec-eval--non-empty-string-expr)
        'string))
     (t 'unknown))))

(defun typespec-eval-op-member-like (elt list fn)
  "Evaluate list membership function FN over ELT and LIST."
  (let ((elt (typespec-eval--eval elt))
        (list (typespec-eval--eval list)))
    (cond
     ((and (typespec-eval--const-p elt) (typespec-eval--const-p list))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (typespec-eval--make-const (funcall fn (typespec-eval--const-value elt) val))
          'unknown)))
     ((typespec-eval-struct-list-elem-type list)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (list 'list (typespec-eval-struct-list-elem-type list)))))
     ((typespec-eval-struct-sequence-elem-type list)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (list 'list (typespec-eval-struct-sequence-elem-type list)))))
     ((and (consp list) (eq (car list) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts))
             (elem-types (append prefix
                                 (when (typespec-eval-struct-list-elem-type tail)
                                   (list (typespec-eval-struct-list-elem-type tail))))))
        (typespec-eval-simplify-or
         (list (typespec-eval--make-const nil)
               (list 'list (typespec-eval-simplify-or elem-types))))))
     (t 'unknown))))

(defun typespec-eval-op-minmax (args op)
  "Evaluate a MIN/MAX expression over ARGS using OP."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) 'unknown)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply op values))
          'unknown)))
     ((seq-every-p #'typespec-eval-types-integer-type-p args)
      (let* ((ranges (mapcar #'typespec-eval-numeric-integer-range-from args))
             (range (and (seq-every-p #'identity ranges)
                         (typespec-eval-numeric-minmax-range ranges op))))
        (cond
         (range
          (if (and (typespec-eval-types-fixnum-range-p range)
                   (not (seq-every-p (lambda (arg) (eq arg 'fixnum)) args)))
              'integer
            range))
         (t 'integer))))
     ((and (seq-every-p #'typespec-eval-types-number-type-p args)
           (seq-some #'typespec-eval-types-float-type-p args))
      (let ((ranges (mapcar #'typespec-eval-numeric-float-range-from args)))
        (if (seq-every-p #'identity ranges)
            (or (typespec-eval-numeric-minmax-range ranges op) 'float)
          'float)))
     ((seq-every-p #'typespec-eval-types-integer-type-p args) 'integer)
     ((seq-every-p #'typespec-eval-types-float-type-p args) 'float)
     ((seq-every-p #'typespec-eval-types-number-type-p args) 'number)
     (t 'unknown))))

(defun typespec-eval-op-mod (args)
  "Evaluate a `mod` expression over ARGS."
  (let ((args (mapcar #'typespec-eval--eval args)))
    (cond
     ((null args) 'unknown)
     ((seq-every-p #'typespec-eval--const-p args)
      (let ((values (mapcar #'typespec-eval--const-value args)))
        (if (seq-every-p #'numberp values)
            (typespec-eval--make-const (apply #'mod values))
          'unknown)))
     ((seq-some #'typespec-eval-types-float-type-p args) 'float)
     ((and (= (length args) 2)
           (seq-every-p #'typespec-eval-types-integer-or-const-p args))
      (let* ((rhs (cadr args))
             (rhs-range (typespec-eval-numeric-integer-range-from rhs))
             (rhs-info (typespec-eval-numeric-numeric-range-info rhs)))
        (cond
         ((and rhs-info (typespec-eval-numeric-numeric-range-includes-zero-p rhs-info))
          (if (and (typespec-eval-numeric-numeric-range-singleton-p rhs-info)
                   (zerop (plist-get rhs-info :low)))
              'never
            'unknown))
         (rhs-range
          (let* ((lowb (typespec-eval-types-integer-bound-min (cadr rhs-range)))
                 (highb (typespec-eval-types-integer-bound-max (caddr rhs-range))))
            (cond
             ((and (numberp lowb) (numberp highb)
                   (not (<= lowb 0 highb)))
              (if (> lowb 0)
                  (typespec-eval--integer-range 0 (1- highb))
                (typespec-eval--integer-range (1+ lowb) 0)))
             (t 'integer))))
         (t 'integer))))
     ((seq-every-p #'typespec-eval-types-integer-or-const-p args) 'integer)
     ((seq-every-p #'typespec-eval-types-number-type-p args) 'number)
     (t 'unknown))))

(defun typespec-eval-op-not (arg)
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

(defun typespec-eval-op-kbd (arg)
  "Evaluate a `kbd' expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (kbd val))
          'unknown)))
     ((typespec-eval-types-string-type-p arg)
      (typespec-eval-simplify-or (list 'string '(vector integer))))
     (t 'unknown))))

(defun typespec-eval-op-nth (n list)
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
     ((and (consp list) (eq (car list) :tuple) (integerp nval))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts)))
        (cond
         ((< nval 0) (typespec-eval--make-const nil))
         ((< nval (length prefix)) (nth nval prefix))
         ((null tail) (typespec-eval--make-const nil))
         ((typespec-eval-struct-list-elem-type tail)
          (let ((offset (- nval (length prefix)))
                (elem (typespec-eval-struct-list-elem-type tail)))
            (if (eq (car-safe tail) 'list+)
                (if (>= offset 0) elem (typespec-eval--make-const nil))
              (if (>= offset 0)
                  (typespec-eval-simplify-or
                   (list (typespec-eval--make-const nil) elem))
                (typespec-eval--make-const nil)))))
         (t 'unknown))))
     ((and (consp list) (eq (car list) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts))
             (items (append prefix
                            (when (typespec-eval-struct-list-elem-type tail)
                              (list (typespec-eval-struct-list-elem-type tail)))
                            (list (typespec-eval--make-const nil)))))
        (typespec-eval-simplify-or items)))
     ((and (typespec-eval-struct-alist-form-p list) (integerp nval))
      (let ((cell (list 'cons
                        (typespec-eval-struct-alist-key-type list)
                        (typespec-eval-struct-alist-value-type list))))
        (cond
         ((< nval 0) (typespec-eval--make-const nil))
         ((= nval 0) cell)
         (t (typespec-eval-simplify-or
             (list (typespec-eval--make-const nil) cell))))))
     ((and (typespec-eval-struct-plist-form-p list) (integerp nval))
      (let ((key (typespec-eval-struct-plist-key-type list))
            (value (typespec-eval-struct-plist-value-type list)))
        (cond
         ((< nval 0) (typespec-eval--make-const nil))
         ((= (mod nval 2) 0) key)
         (t value))))
     ((typespec-eval-struct-plist-form-p list)
      (typespec-eval-simplify-or
       (list (typespec-eval-struct-plist-key-type list)
             (typespec-eval-struct-plist-value-type list))))
     ((typespec-eval-struct-sequence-elem-type list)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval-struct-sequence-elem-type list))))
     ((and (integerp nval) (= nval 0) (eq (car-safe list) 'list+))
      ;; For nth 0 on list+, return element type directly (no nil)
      (cadr list))
     ((typespec-eval-struct-list-elem-type list)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             (typespec-eval-struct-list-elem-type list))))
     (t 'unknown))))

(defun typespec-eval-op-nthcdr (n list)
  "Evaluate an `nthcdr` expression for N and LIST.
When N is 1, behaves like `cdr`."
  (let* ((n (typespec-eval--eval n))
         (list (typespec-eval--eval list))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (typespec-eval--always-nil-p list) (integerp nval))
      (typespec-eval--make-const nil))
     ((and (typespec-eval--const-p list) (integerp nval))
      (let ((val (typespec-eval--const-value list)))
        (if (listp val)
            (if (null val)
                (typespec-eval--make-const nil)
              (typespec-eval--make-const (nthcdr nval val)))
          'unknown)))
     ((and (typespec-eval-struct-alist-form-p list) (integerp nval))
      (if (<= nval 0)
          list
        list))
     ((and (typespec-eval-struct-plist-form-p list) (integerp nval))
      (let ((value (typespec-eval-struct-plist-value-type list)))
        (if (<= nval 0)
            list
          (if (= (mod nval 2) 0)
              list
            (list 'cons value list)))))
     ((typespec-eval-struct-plist-form-p list)
      (list 'list
            (typespec-eval-simplify-or
             (list (typespec-eval-struct-plist-key-type list)
                   (typespec-eval-struct-plist-value-type list)))))
     ((and (consp list) (eq (car list) :tuple) (integerp nval))
      (let ((tuple (typespec-eval-struct-tuple-unconst (cdr list))))
        (if (<= nval 0)
            (cons :tuple tuple)
          (let ((tail (nthcdr nval tuple)))
            (if (listp tail)
                (cons :tuple tail)
              (typespec-eval--eval (cdr list)))))))
     ((and (consp list) (eq (car list) :tuple))
      (let* ((parts (typespec-eval-struct-tuple-split (cdr list)))
             (prefix (car parts))
             (tail (cdr parts))
             (elem-types (append prefix
                                 (when (typespec-eval-struct-list-elem-type tail)
                                   (list (typespec-eval-struct-list-elem-type tail))))))
        (list 'list (typespec-eval-simplify-or elem-types))))
     ((typespec-eval-struct-sequence-elem-type list)
      (list 'list (typespec-eval-struct-sequence-elem-type list)))
     ((typespec-eval-struct-list-elem-type list)
      (list 'list (typespec-eval-struct-list-elem-type list)))
     (t 'unknown))))

(defun typespec-eval-op-number-sequence (from &optional to inc)
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
     ((and (typespec-eval-types-number-or-const-p from)
           (or (null to) (typespec-eval-types-number-or-const-p to))
           (or (null inc) (typespec-eval-types-number-or-const-p inc)))
      (if (or (eq from 'number)
              (eq to 'number)
              (eq inc 'number))
          '(list number)
        (let* ((from-info (typespec-eval-numeric-numeric-range-info from))
               (to-info (and to (typespec-eval-numeric-numeric-range-info to)))
               (inc-default (null inc))
               (inc-info (and inc (typespec-eval-numeric-numeric-range-info inc)))
               (inc-zero (and inc-info (typespec-eval-numeric-numeric-range-includes-zero-p inc-info)))
               (inc-singleton-zero
                (and inc-info
                     (typespec-eval-numeric-numeric-range-singleton-p inc-info)
                     (let ((val (plist-get inc-info :low)))
                       (and (numberp val) (= val 0)))))
               (inc-pos (or inc-default
                            (and inc-info (typespec-eval-numeric-numeric-range-positive-p inc-info))))
               (inc-neg (and inc-info (typespec-eval-numeric-numeric-range-negative-p inc-info)))
               (from-low (and from-info (plist-get from-info :low)))
               (from-high (and from-info (plist-get from-info :high)))
               (to-low (and to-info (plist-get to-info :low)))
               (to-high (and to-info (plist-get to-info :high)))
               (float-output (or (typespec-eval-types-float-type-p from)
                                 (typespec-eval-types-float-type-p to)
                                 (typespec-eval-types-float-type-p inc))))
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
                         (t (typespec-eval-numeric-numeric-min from-low to-low))))
                   (high (cond
                          (inc-pos to-high)
                          (inc-neg from-high)
                          (t (typespec-eval-numeric-numeric-max from-high to-high))))
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

(defun typespec-eval-op-numeric-compare (lhs rhs pred)
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
     ((and (typespec-eval-types-number-or-marker-type-p lhs)
           (typespec-eval-types-number-or-marker-type-p rhs))
      (let* ((lhs-info (typespec-eval-numeric-numeric-range-info lhs))
             (rhs-info (typespec-eval-numeric-numeric-range-info rhs))
             (result (and lhs-info rhs-info
                          (typespec-eval-numeric-numeric-range-compare lhs-info rhs-info pred))))
        (cond
         ((and lhs-info rhs-info (eq result t)) (typespec-eval--make-const t))
         ((and lhs-info rhs-info (eq result nil)) (typespec-eval--make-const nil))
         (t 'boolean))))
     (t 'unknown))))

(defun typespec-eval-op-numeric-unary (arg fn)
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
     ((memq arg '(integer int bignum))
      'integer)
     ((memq arg '(float number real))
      (if (eq arg 'float) 'float 'number))
     ;; Try unified range operations for range types
     ((typespec-eval-types-number-or-const-p arg)
      (let ((info (typespec-eval-numeric-numeric-range-info arg)))
        (if info
            (let ((result (typespec-eval-numeric-numeric-range-unary info fn)))
              (cond
               ;; signum returns a simplified or-form directly
               ((eq fn #'cl-signum)
                (or result (if (eq (plist-get info :type) 'float) 'float 'integer)))
               ;; abs/shift return info plist, convert to form
               ((and result (plistp result) (plist-get result :type))
                (typespec-eval-numeric-numeric-range-to-form result))
               ;; Fallback to type
               ((typespec-eval-types-float-type-p arg) 'float)
               ((typespec-eval-types-integer-type-p arg) 'integer)
               (t 'number)))
          ;; No range info, fallback to type
          (cond
           ((typespec-eval-types-float-type-p arg) 'float)
           ((typespec-eval-types-integer-type-p arg) 'integer)
           ((typespec-eval-types-number-type-p arg) 'number)
           (t 'unknown)))))
     (t 'unknown))))

(defun typespec-eval-op-object-of-class-p (object class)
  "Evaluate `object-of-class-p` over OBJECT and CLASS."
  (let* ((object (typespec-eval--eval object))
         (class (typespec-eval--eval class))
         (class-sym (typespec-eval-types-class-symbol class)))
    (cond
     ((and (typespec-eval--const-p object)
           (typespec-eval--const-p class)
           (fboundp 'object-of-class-p))
      (typespec-eval--make-const
       (ignore-errors
         (object-of-class-p (typespec-eval--const-value object)
                            (typespec-eval--const-value class)))))
     ((and (typespec-eval--const-p object)
           class-sym
           (fboundp 'object-of-class-p))
      (typespec-eval--make-const
       (ignore-errors
         (object-of-class-p (typespec-eval--const-value object) class-sym))))
     ((and (typespec-eval-types-class-type-p object)
           class-sym)
      (let ((obj-class (cadr object)))
        (if (and (symbolp obj-class)
                 (typespec-eval-types-class-subtype-p obj-class class-sym))
            (typespec-eval--make-const t)
          (typespec-eval--make-const nil))))
     (t 'boolean))))

(defun typespec-eval-op-plist-get (plist key &optional default)
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
     ((typespec-eval-struct-plist-form-p plist)
      'unknown)
     ((typespec-eval-struct-plist-of-p plist)
      (let* ((entry-type (and (typespec-eval--const-p key)
                              (typespec-eval-struct-plist-of-entry-type
                               plist (typespec-eval--const-value key))))
             (value-type (typespec-eval-struct-plist-of-value-type plist))
             (items (list (typespec-eval--make-const nil)
                          (or entry-type value-type))))
        (when default
          (setq items (append items (list default))))
        (typespec-eval-simplify-or items)))
     (t 'unknown))))

(defun typespec-eval-op-plist-key-of (plist)
  "Evaluate `(plist-key-of PLIST)`."
  (let ((plist (typespec-eval--eval plist)))
    (cond
     ((typespec-eval-struct-plist-form-p plist)
      (typespec-eval-struct-plist-key-type plist))
     ((typespec-eval-struct-plist-of-p plist)
      (typespec-eval-simplify-or
       (mapcar (lambda (key)
                 (typespec-eval--make-const key))
               (delq nil
                     (mapcar #'typespec-eval-struct-plist-of-entry-key
                             (typespec-eval-struct-plist-of-entries plist))))))
     (t 'unknown))))

(defun typespec-eval-op-plist-member (plist key)
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
     ((typespec-eval-struct-plist-form-p plist)
      'unknown)
     ((typespec-eval-struct-plist-of-p plist)
      (typespec-eval-simplify-or
       (list (typespec-eval--make-const nil)
             '(list+ mixed))))
     (t 'unknown))))

(defun typespec-eval-op-plist-of (entries)
  "Evaluate a plist-of ENTRIES list."
  (cons :plist-of
        (mapcar
         (lambda (entry)
           (pcase entry
             (`(:? ,key ,type)
              (list :? key (typespec-eval--eval type)))
             (`(,key ,type)
              (list key (typespec-eval--eval type)))
             (_ entry)))
         entries)))

(defun typespec-eval-op-plist-value-of (plist)
  "Evaluate `(plist-value-of PLIST)`."
  (let ((plist (typespec-eval--eval plist)))
    (cond
     ((typespec-eval-struct-plist-form-p plist)
      (typespec-eval-struct-plist-value-type plist))
     ((typespec-eval-struct-plist-of-p plist)
      (typespec-eval-struct-plist-of-value-type plist))
     (t 'unknown))))

(defun typespec-eval-op-unary-predicate (arg pred &optional type-true-p type-false-p)
  "Evaluate unary predicate PRED over ARG with optional type check.
TYPE-TRUE-P and TYPE-FALSE-P are predicates over the evaluated type.
Also considers :guard-defined types via their base type."
  (let* ((arg (typespec-eval--eval arg))
         ;; Try to resolve guard type's base category
         (guard-base (and (symbolp arg)
                          (typespec-eval-types-get-type-base-category arg))))
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

(defun typespec-eval-op-rassq-delete-all (value alist)
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
     ((typespec-eval-struct-alist-form-p alist) alist)
     (t 'unknown))))

(defun typespec-eval-op-rem (args)
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
           (seq-every-p #'typespec-eval-types-integer-or-const-p args))
      (let* ((lhs (car args))
             (rhs (cadr args))
             (lhs-range (typespec-eval-numeric-integer-range-from lhs))
             (rhs-range (typespec-eval-numeric-integer-range-from rhs))
             (rhs-info (typespec-eval-numeric-numeric-range-info rhs)))
        (cond
         ((and rhs-info (typespec-eval-numeric-numeric-range-includes-zero-p rhs-info))
          (if (and (typespec-eval-numeric-numeric-range-singleton-p rhs-info)
                   (zerop (plist-get rhs-info :low)))
              'never
            'unknown))
         ((and lhs-range rhs-range)
          (let* ((lowa (typespec-eval-types-integer-bound-min (cadr lhs-range)))
                 (higha (typespec-eval-types-integer-bound-max (caddr lhs-range)))
                 (lowb (typespec-eval-types-integer-bound-min (cadr rhs-range)))
                 (highb (typespec-eval-types-integer-bound-max (caddr rhs-range))))
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
     ((seq-every-p #'typespec-eval-types-integer-or-const-p args) 'integer)
     (t 'unknown))))

(defun typespec-eval-op-remove-like (elt sequence fn &optional list-only)
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
     ((and (not list-only) (typespec-eval-types-string-type-p sequence)) 'string)
     ((and (not list-only) (consp sequence) (eq (car sequence) 'vector))
      (list 'vector (cadr sequence)))
     (t 'unknown))))

(defun typespec-eval-op-rounding (arg kind fn)
  "Evaluate rounding KIND using FN over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ((typespec-eval--float-range-p arg)
      (or (typespec-eval-numeric-float-rounding-range arg kind) 'integer))
     ((typespec-eval--integer-range-p arg) arg)
     ((typespec-eval-numeric-range-preserving-integer-type-p arg)
      (or (typespec-eval-numeric-integer-range-from arg) 'integer))
     ((typespec-eval-types-integer-type-p arg) 'integer)
     ((typespec-eval-types-number-type-p arg) 'integer)
     (t 'unknown))))

(defun typespec-eval-op-safe-length (list)
  "Evaluate a `safe-length` expression for LIST."
  (let ((list (typespec-eval--eval list)))
    (cond
     ((typespec-eval--const-p list)
      (typespec-eval--make-const (safe-length (typespec-eval--const-value list))))
     ((typespec-eval-struct-alist-form-p list)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval-struct-plist-form-p list)
      (typespec-eval--integer-range 0 '*))
     ((eq (car-safe list) 'list+)
      (typespec-eval--integer-range 1 '*))
     ((eq (car-safe list) 'list)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval-op-seq-empty-p (sequence)
  "Evaluate a `seq-empty-p` predicate for SEQUENCE."
  (let ((sequence (typespec-eval--eval sequence)))
    (cond
     ((typespec-eval--const-p sequence)
      (typespec-eval--make-const (seq-empty-p (typespec-eval--const-value sequence))))
     ((typespec-eval--non-empty-string-p sequence)
      (typespec-eval--make-const nil))
     ((eq (car-safe sequence) 'list+)
      (typespec-eval--make-const nil))
     ((typespec-eval-struct-sequence-elem-type sequence)
      'boolean)
     ((eq sequence 'sequence)
      'boolean)
     ((or (typespec-eval-types-string-type-p sequence)
          (typespec-eval-types-list-type-p sequence)
          (typespec-eval-types-vector-type-p sequence))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-seq-length (sequence)
  "Evaluate a `seq-length` expression for SEQUENCE."
  (let ((sequence (typespec-eval--eval sequence)))
    (cond
     ((typespec-eval--const-p sequence)
      (typespec-eval--make-const (seq-length (typespec-eval--const-value sequence))))
     ((typespec-eval-struct-sequence-elem-type sequence)
      (typespec-eval--integer-range 0 '*))
     ((eq sequence 'sequence)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval-types-string-type-p sequence)
      (typespec-eval--integer-range 0 '*))
     ((typespec-eval-types-list-type-p sequence)
      (typespec-eval--integer-range (if (eq (car-safe sequence) 'list+) 1 0) '*))
     ((typespec-eval-types-vector-type-p sequence)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval-op-sequence-identity (arg fn)
  "Evaluate a sequence-preserving operation FN over ARG.
FN is applied to const values; the type structure is preserved for typed args."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (or (listp val) (vectorp val) (stringp val))
            (typespec-eval--make-const (funcall fn val))
          'unknown)))
     ((typespec-eval-struct-sequence-elem-type arg)
      (list 'sequence (typespec-eval-struct-sequence-elem-type arg)))
     ((eq arg 'sequence) 'sequence)
     ((eq (car-safe arg) 'list+) (list 'list+ (cadr arg)))
     ((eq (car-safe arg) 'list) (list 'list (cadr arg)))
     ((typespec-eval-types-string-type-p arg) 'string)
     ((and (consp arg) (eq (car arg) 'vector))
      (list 'vector (cadr arg)))
     (t 'unknown))))

(defun typespec-eval-op-sha1 (arg)
  "Evaluate a `sha1` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (sha1 val))
          'unknown)))
     ((typespec-eval-types-string-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval-op-string-bytes (arg)
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

(defun typespec-eval-op-string-equal (lhs rhs)
  "Evaluate a `string-equal` expression over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (let ((mapped
             (typespec-eval-simplify-map-const-or
              lhs
              (lambda (item)
                (let ((res (typespec-eval-op-string-equal item rhs)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (consp rhs) (eq (car rhs) 'or))
      (let ((mapped
             (typespec-eval-simplify-map-const-or
              rhs
              (lambda (item)
                (let ((res (typespec-eval-op-string-equal lhs item)))
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

(defun typespec-eval-op-string-join (strings &optional separator)
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
     ((or (typespec-eval-struct-list-of-p strings 'string)
          (typespec-eval-struct-list-of-p strings (typespec-eval--non-empty-string-expr)))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-string-limit (string n)
  "Evaluate a `string-limit` expression for STRING and N."
  (let* ((string (typespec-eval--eval string))
         (n (typespec-eval--eval n))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (stringp sval) (integerp nval) (<= 0 nval))
      (typespec-eval--make-const (string-limit sval nval)))
     ((and (typespec-eval-types-string-type-p string)
           (typespec-eval-types-integer-type-p n))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-string-lines (string &optional omit-nulls keep-newlines)
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
     ((typespec-eval-types-string-type-p string)
      (if (typespec-eval--always-nil-p omit-nulls)
          '(list+ string)
        '(list string)))
     (t 'unknown))))

(defun typespec-eval-op-string-match-p (regexp string &optional start)
  "Evaluate a `string-match-p` expression for REGEXP, STRING, and START."
  (let* ((regexp (typespec-eval--eval regexp))
         (string (typespec-eval--eval string))
         (start (when start (typespec-eval--eval start)))
         (start-val (typespec-eval--const-integer-value start)))
    (cond
     ((and (consp regexp) (eq (car regexp) 'or))
      (typespec-eval-simplify-map-const-or
       regexp
       (lambda (item)
         (let ((res (typespec-eval-op-string-match-p item string start)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp string) (eq (car string) 'or))
      (typespec-eval-simplify-map-const-or
       string
       (lambda (item)
         (let ((res (typespec-eval-op-string-match-p regexp item start)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (or (null start) (integerp start-val))
           (let ((regexps (typespec-eval-simplify-const-regexp-options regexp))
                 (strings (typespec-eval-simplify-const-string-options string)))
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
                   (typespec-eval-simplify-or (nreverse results))))))))
     ((and (typespec-eval-types-string-type-p regexp)
           (typespec-eval-types-string-type-p string)
           (or (null start)
               (typespec-eval-types-integer-type-p start)))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-string-pad (string length &optional padding start)
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
         (start-ok (typespec-eval--boolish-const-p start)))
    (cond
     ((and (stringp sval) (integerp len) pad-ok start-ok)
      (typespec-eval--make-const
       (string-pad sval len pad (when start (typespec-eval--const-value start)))))
     ((and (typespec-eval-types-string-type-p string)
           (typespec-eval-types-integer-type-p length))
      (if (typespec-eval-types-positive-int-type-p length)
          (typespec-eval--non-empty-string-expr)
        'string))
     (t 'unknown))))

(defun typespec-eval-op-string-prefix-p (prefix string &optional ignore-case)
  "Evaluate a `string-prefix-p` expression for PREFIX, STRING, and IGNORE-CASE."
  (let ((prefix (typespec-eval--eval prefix))
        (string (typespec-eval--eval string))
        (ignore-case (when ignore-case (typespec-eval--eval ignore-case))))
    (cond
     ((and (typespec-eval--const-empty-string-p prefix)
           (or (typespec-eval--const-p string)
               (typespec-eval-types-string-type-p string))
           (typespec-eval--boolish-const-p ignore-case))
      (typespec-eval--make-const t))
     ((and (consp prefix) (eq (car prefix) 'or))
      (let ((mapped
             (typespec-eval-simplify-map-const-or
              prefix
              (lambda (item)
                (let ((res (typespec-eval-op-string-prefix-p item string ignore-case)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (consp string) (eq (car string) 'or))
      (let ((mapped
             (typespec-eval-simplify-map-const-or
              string
              (lambda (item)
                (let ((res (typespec-eval-op-string-prefix-p prefix item ignore-case)))
                  (and (consp res) (eq (car res) 'const) res)))
              'boolean)))
        (or mapped 'boolean)))
     ((and (typespec-eval--const-p prefix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value prefix))
           (stringp (typespec-eval--const-value string))
           (typespec-eval--boolish-const-p ignore-case))
      (typespec-eval--make-const
       (string-prefix-p (typespec-eval--const-value prefix)
                        (typespec-eval--const-value string)
                        (when ignore-case
                          (typespec-eval--const-value ignore-case)))))
     ((and (eq prefix 'string) (eq string 'string)) 'boolean)
     ((or (eq prefix 'string) (eq string 'string)) 'boolean)
     (t 'unknown))))

(defun typespec-eval-op-string-replace (from to string)
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
     ((and (typespec-eval-types-string-type-p from)
           (typespec-eval-types-string-type-p to)
           (typespec-eval-types-string-type-p string))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-string-search (needle haystack &optional start)
  "Evaluate a `string-search` expression for NEEDLE, HAYSTACK, and START."
  (let* ((needle (typespec-eval--eval needle))
         (haystack (typespec-eval--eval haystack))
         (start (when start (typespec-eval--eval start)))
         (start-val (typespec-eval--const-integer-value start)))
    (cond
     ((and (consp needle) (eq (car needle) 'or))
      (typespec-eval-simplify-map-const-or
       needle
       (lambda (item)
         (let ((res (typespec-eval-op-string-search item haystack start)))
           (when (typespec-eval--const-p res) res)))
       '(or (const nil) integer)))
     ((and (consp haystack) (eq (car haystack) 'or))
      (typespec-eval-simplify-map-const-or
       haystack
       (lambda (item)
         (let ((res (typespec-eval-op-string-search needle item start)))
           (when (typespec-eval--const-p res) res)))
       '(or (const nil) integer)))
     ((and (or (null start) (integerp start-val))
           (let ((needles (typespec-eval-simplify-const-string-options needle))
                 (haystacks (typespec-eval-simplify-const-string-options haystack)))
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
                   (typespec-eval-simplify-or (nreverse results))))))))
     ((and (typespec-eval-types-string-type-p needle)
           (typespec-eval-types-string-type-p haystack)
           (or (null start)
               (typespec-eval-types-integer-type-p start)))
      '(or (const nil) integer))
     (t 'unknown))))

(defun typespec-eval-op-string-split (string &optional separators omit-nulls trim)
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
     ((typespec-eval-types-string-type-p string)
      (if (typespec-eval--always-nil-p omit-nulls)
          '(list+ string)
        '(list string)))
     (t 'unknown))))

(defun typespec-eval-op-string-suffix-p (suffix string &optional ignore-case)
  "Evaluate a `string-suffix-p` expression for SUFFIX, STRING, and IGNORE-CASE."
  (let ((suffix (typespec-eval--eval suffix))
        (string (typespec-eval--eval string))
        (ignore-case (when ignore-case (typespec-eval--eval ignore-case))))
    (cond
     ((and (typespec-eval--const-empty-string-p suffix)
           (or (typespec-eval--const-p string)
               (typespec-eval-types-string-type-p string))
           (typespec-eval--boolish-const-p ignore-case))
      (typespec-eval--make-const t))
     ((and (consp suffix) (eq (car suffix) 'or))
      (typespec-eval-simplify-map-const-or
       suffix
       (lambda (item)
         (let ((res (typespec-eval-op-string-suffix-p item string ignore-case)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (consp string) (eq (car string) 'or))
      (typespec-eval-simplify-map-const-or
       string
       (lambda (item)
         (let ((res (typespec-eval-op-string-suffix-p suffix item ignore-case)))
           (when (typespec-eval--const-p res) res)))
       'boolean))
     ((and (typespec-eval--const-p suffix)
           (typespec-eval--const-p string)
           (stringp (typespec-eval--const-value suffix))
           (stringp (typespec-eval--const-value string))
           (typespec-eval--boolish-const-p ignore-case))
      (typespec-eval--make-const
       (string-suffix-p (typespec-eval--const-value suffix)
                        (typespec-eval--const-value string)
                        (when ignore-case
                          (typespec-eval--const-value ignore-case)))))
     ((and (typespec-eval-types-string-type-p suffix)
           (typespec-eval-types-string-type-p string))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-string-truncate-left (string n)
  "Evaluate a `string-truncate-left` expression for STRING and N."
  (let* ((string (typespec-eval--eval string))
         (n (typespec-eval--eval n))
         (sval (and (typespec-eval--const-p string)
                    (typespec-eval--const-value string)))
         (nval (typespec-eval--const-integer-value n)))
    (cond
     ((and (stringp sval) (integerp nval) (<= 0 nval))
      (typespec-eval--make-const (string-truncate-left sval nval)))
     ((and (typespec-eval-types-string-type-p string)
           (typespec-eval-types-integer-type-p n))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-string-unary (arg fn &optional preserve-non-empty)
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
     ((typespec-eval-types-string-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval-op-string-width (arg)
  "Evaluate a `string-width` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (string-width val))
          'unknown)))
     ((typespec-eval-types-string-type-p arg)
      (typespec-eval--integer-range 0 '*))
     (t 'unknown))))

(defun typespec-eval-op-substring (string start &optional end)
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
     ((and (typespec-eval-types-string-type-p string)
           (integerp start-val)
           (integerp end-val)
           (= start-val 0)
           (= end-val 1))
      (typespec-eval--non-empty-string-expr))
     ((and (typespec-eval-types-string-type-p string)
           (integerp start-val)
           (integerp end-val)
           (= start-val end-val))
      (typespec-eval--make-const ""))
     ((and (typespec-eval-types-string-type-p string)
           (typespec-eval-types-integer-type-p start)
           (typespec-eval-types-positive-int-type-p end))
      (typespec-eval--non-empty-string-expr))
     ((and (typespec-eval-types-string-type-p string)
           (typespec-eval-types-integer-type-p start)
           (typespec-eval-types-integer-type-p end))
      'string)
     (t 'unknown))))

(defun typespec-eval-op-symbol-name (arg)
  "Evaluate a `symbol-name` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (symbolp val)
            (typespec-eval--make-const (symbol-name val))
          'unknown)))
     ((typespec-eval-types-symbol-type-p arg) 'string)
     (t 'unknown))))

(defun typespec-eval-op-syntax-class (arg)
  "Evaluate a `syntax-class` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (integerp val)
            (typespec-eval--make-const (syntax-class val))
          'unknown)))
     ((typespec-eval-types-integer-type-p arg) 'integer)
     (t 'unknown))))

(defun typespec-eval-op-tuple (args)
  "Evaluate tuple ARGS in order, preserving dotted structure."
  (cond
   ((consp args)
    (cons (typespec-eval--eval (car args))
          (typespec-eval-op-tuple (cdr args))))
   ((null args) nil)
   (t (typespec-eval--eval args))))

(defun typespec-eval-op-type-of (arg fn)
  "Evaluate type function FN over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (funcall fn (typespec-eval--const-value arg))))
     (t 'symbol))))

(defun typespec-eval-op-value-of (arg)
  "Evaluate `(value-of ARG)`."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((and (consp arg) (eq (car arg) :tuple))
      (typespec-eval-simplify-or
       (typespec-eval-struct-tuple-elements (cdr arg))))
     ((and (consp arg) (memq (car arg) '(list list+)))
      (cadr arg))
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (listp val)
            (typespec-eval-simplify-or
             (mapcar #'typespec-eval--make-const val))
          'unknown)))
     (t 'unknown))))

(defun typespec-eval-op-value< (lhs rhs)
  "Evaluate a `value<' expression for LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (typespec-eval--const-p lhs)
           (typespec-eval--const-p rhs))
      (typespec-eval--make-const
       (value< (typespec-eval--const-value lhs)
               (typespec-eval--const-value rhs))))
     ((and (typespec-eval-types-number-type-p lhs)
           (typespec-eval-types-number-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-version-compare (lhs rhs fn)
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
     ((and (typespec-eval-types-string-type-p lhs)
           (typespec-eval-types-string-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-version-list-compare (lhs rhs fn)
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
     ((and (typespec-eval-types-list-type-p lhs)
           (typespec-eval-types-list-type-p rhs))
      'boolean)
     (t 'unknown))))

(defun typespec-eval-op-version-list-not-zero (lst)
  "Evaluate a `version-list-not-zero` expression for LST."
  (let ((lst (typespec-eval--eval lst)))
    (cond
     ((typespec-eval--const-p lst)
      (let ((val (typespec-eval--const-value lst)))
        (if (listp val)
            (typespec-eval--make-const (version-list-not-zero val))
          'unknown)))
     ((typespec-eval-types-list-type-p lst) 'integer)
     (t 'unknown))))

(defun typespec-eval-op-version-to-list (arg)
  "Evaluate a `version-to-list` expression for ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (stringp val)
            (typespec-eval--make-const (version-to-list val))
          'unknown)))
     ((typespec-eval-types-string-type-p arg) '(list integer))
     (t 'unknown))))

(defun typespec-eval-op-zerop (arg)
  "Evaluate `zerop` over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((typespec-eval--const-p arg)
      (let ((val (typespec-eval--const-value arg)))
        (if (numberp val)
            (typespec-eval--make-const (zerop val))
          'unknown)))
     ((typespec-eval--float-range-p arg)
      (let* ((low (typespec-eval-numeric-float-bound-value (cadr arg)))
             (high (typespec-eval-numeric-float-bound-value (caddr arg)))
             (low-excl (typespec-eval-numeric-float-bound-exclusive-p (cadr arg)))
             (high-excl (typespec-eval-numeric-float-bound-exclusive-p (caddr arg))))
        (cond
         ((and (numberp low) (numberp high)
               (= low 0.0) (= high 0.0)
               (not low-excl) (not high-excl))
          (typespec-eval--make-const t))
         ((not (typespec-eval-numeric-float-range-includes-zero-p arg))
          (typespec-eval--make-const nil))
         (t 'boolean))))
     ((typespec-eval--integer-range-p arg)
      (let ((low (typespec-eval-types-integer-bound-min (cadr arg)))
            (high (typespec-eval-types-integer-bound-max (caddr arg))))
        (cond
         ((and (numberp low) (numberp high) (= low 0) (= high 0))
          (typespec-eval--make-const t))
         ((and (numberp low) (> low 0))
          (typespec-eval--make-const nil))
         ((and (numberp high) (< high 0))
          (typespec-eval--make-const nil))
         (t 'boolean))))
     ((typespec-eval-types-integer-type-p arg)
      'boolean)
     ((typespec-eval-types-number-type-p arg)
      'boolean)
     (t 'unknown))))
(provide 'typespec-eval-op)
;;; typespec-eval-op.el ends here
