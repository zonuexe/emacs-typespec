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

(defun typespec-eval--eval-upcase (arg)
  "Evaluate an `upcase` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((and (typespec-eval--const-p arg)
           (or (stringp (typespec-eval--const-value arg))
               (characterp (typespec-eval--const-value arg))))
      (typespec-eval--make-const
       (upcase (typespec-eval--const-value arg))))
     ((eq arg 'string) 'string)
     (t 'unknown))))

(defun typespec-eval--eval-string-to-number (arg)
  "Evaluate a `string-to-number` expression over ARG."
  (let ((arg (typespec-eval--eval arg)))
    (cond
     ((and (typespec-eval--const-p arg)
           (stringp (typespec-eval--const-value arg)))
      (typespec-eval--make-const
       (string-to-number (typespec-eval--const-value arg))))
     ((eq arg 'string) 'number)
     ((and (consp arg) (eq (car arg) 'or))
      (let ((items nil)
            (ok t))
        (dolist (item (cdr arg))
          (let ((res (typespec-eval--eval-string-to-number item)))
            (if (and (consp res) (eq (car res) 'const))
                (push res items)
              (setq ok nil))))
        (if ok
            (typespec-eval--simplify-or (nreverse items))
          'number)))
     (t 'unknown))))

(defun typespec-eval--eval-string-equal (lhs rhs)
  "Evaluate a `string-equal` expression over LHS and RHS."
  (let ((lhs (typespec-eval--eval lhs))
        (rhs (typespec-eval--eval rhs)))
    (cond
     ((and (consp lhs) (eq (car lhs) 'or))
      (let ((items nil)
            (ok t))
        (dolist (item (cdr lhs))
          (let ((res (typespec-eval--eval-string-equal item rhs)))
            (if (or (eq res 'boolean)
                    (and (consp res) (eq (car res) 'const)))
                (push res items)
              (setq ok nil))))
        (if ok
            (typespec-eval--simplify-or (nreverse items))
          'boolean)))
     ((and (consp rhs) (eq (car rhs) 'or))
      (let ((items nil)
            (ok t))
        (dolist (item (cdr rhs))
          (let ((res (typespec-eval--eval-string-equal lhs item)))
            (if (or (eq res 'boolean)
                    (and (consp res) (eq (car res) 'const)))
                (push res items)
              (setq ok nil))))
        (if ok
            (typespec-eval--simplify-or (nreverse items))
          'boolean)))
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
      (let ((items nil)
            (ok t))
        (dolist (item (cdr prefix))
          (let ((res (typespec-eval--eval-string-prefix-p item string ignore-case)))
            (if (or (eq res 'boolean)
                    (and (consp res) (eq (car res) 'const)))
                (push res items)
              (setq ok nil))))
        (if ok
            (typespec-eval--simplify-or (nreverse items))
          'boolean)))
     ((and (consp string) (eq (car string) 'or))
      (let ((items nil)
            (ok t))
        (dolist (item (cdr string))
          (let ((res (typespec-eval--eval-string-prefix-p prefix item ignore-case)))
            (if (or (eq res 'boolean)
                    (and (consp res) (eq (car res) 'const)))
                (push res items)
              (setq ok nil))))
        (if ok
            (typespec-eval--simplify-or (nreverse items))
          'boolean)))
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
    (`(and . ,args)
     (typespec-eval--eval-and args))
    (`(not ,arg)
     (typespec-eval--eval-not arg))
    (`(null ,arg)
     (typespec-eval--eval-null arg))
    (`(const ,_) form)
    (`(eq ,lhs ,rhs)
     (typespec-eval--eval-eq lhs rhs))
    (`(equal ,lhs ,rhs)
     (typespec-eval--eval-equal lhs rhs))
    (`(upcase ,arg)
     (typespec-eval--eval-upcase arg))
    (`(string-to-number ,arg)
     (typespec-eval--eval-string-to-number arg))
    (`(string-equal ,lhs ,rhs)
     (typespec-eval--eval-string-equal lhs rhs))
    (`(string-prefix-p ,prefix ,string . ,rest)
     (typespec-eval--eval-string-prefix-p
      prefix
      string
      (car rest)))
    (`(concat . ,args)
     (typespec-eval--eval-concat args))
    ((pred symbolp) form)
    (_ 'unknown)))

(defun typespec-eval (form)
  "Evaluate FORM in the typespec value/type evaluator."
  (typespec-eval--eval form))

(provide 'typespec-eval)
;;; typespec-eval.el ends here
