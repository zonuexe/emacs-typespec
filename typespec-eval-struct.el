;;; typespec-eval-struct.el --- List, alist, plist, cons, tuple helpers  -*- lexical-binding: t; -*-

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

;; Structure helpers for typespec evaluation: list, alist, plist, cons, tuple.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'typespec-eval-core)
(require 'typespec-eval-simplify)

;;; List and vector

(defsubst typespec-eval-struct-list-of-p (form type)
  "Return non-nil if FORM is a list type of TYPE."
  (or (equal form (list 'list type))
      (equal form (list 'list+ type))))

(defsubst typespec-eval-struct-vector-of-p (form type)
  "Return non-nil if FORM is a vector type of TYPE."
  (equal form (list 'vector type)))

(defsubst typespec-eval-struct-list-elem-type (form)
  "Return element type if FORM is a list type."
  (when (and (consp form) (memq (car form) '(list list+)))
    (cadr form)))

(defsubst typespec-eval-struct-sequence-elem-type (form)
  "Return element type if FORM is a sequence type."
  (when (and (consp form) (eq (car form) 'sequence))
    (cadr form)))

;;; Alist

(defsubst typespec-eval-struct-alist-form-p (value)
  "Return non-nil if VALUE is an alist type."
  (and (consp value)
       (eq (car value) :alist)
       (consp (cdr value))
       (consp (cddr value))
       (null (cdddr value))))

(defsubst typespec-eval-struct-alist-key-type (value)
  "Return the key type of an alist type VALUE."
  (cadr value))

(defsubst typespec-eval-struct-alist-value-type (value)
  "Return the value type of an alist type VALUE."
  (caddr value))

;;; Plist

(defsubst typespec-eval-struct-plist-key-type (value)
  "Return the key type of a plist type VALUE."
  (cadr value))

(defsubst typespec-eval-struct-plist-value-type (value)
  "Return the value type of a plist type VALUE."
  (caddr value))

(defun typespec-eval-struct-plist-form-p (value)
  "Return non-nil if VALUE is a plist type."
  (and (consp value)
       (eq (car value) :plist)
       (consp (cdr value))
       (consp (cddr value))
       (null (cdddr value))))

;;; Plist-of

(defsubst typespec-eval-struct-plist-of-p (value)
  "Return non-nil if VALUE is a plist-of type."
  (and (consp value)
       (eq (car value) :plist-of)))

(defsubst typespec-eval-struct-plist-of-entries (value)
  "Return entries for a plist-of type VALUE."
  (cdr value))

(defsubst typespec-eval-struct-plist-of-entry-key (entry)
  "Return the key for plist-of ENTRY."
  (pcase entry
    (`(:? ,key ,_) key)
    (`(,key ,_) key)
    (_ nil)))

(defsubst typespec-eval-struct-plist-of-entry-optional-p (entry)
  "Return non-nil if plist-of ENTRY is optional."
  (and (consp entry) (eq (car entry) :?)))

(defsubst typespec-eval-struct-plist-of-entry-value (entry)
  "Return the value type for plist-of ENTRY."
  (pcase entry
    (`(:? ,_ ,value) value)
    (`(,_ ,value) value)
    (_ nil)))

(defun typespec-eval-struct-plist-of-value-type (value)
  "Return combined value type for plist-of VALUE."
  (typespec-eval-simplify-or
   (delq nil
         (mapcar
          (lambda (entry)
            (let ((val (typespec-eval-struct-plist-of-entry-value entry)))
              (when val
                (if (typespec-eval-struct-plist-of-entry-optional-p entry)
                    (typespec-eval-simplify-or
                     (list (typespec-eval--make-const nil) val))
                  val))))
          (typespec-eval-struct-plist-of-entries value)))))

(defun typespec-eval-struct-plist-of-entry-type (plist key)
  "Return entry type in PLIST for KEY, or nil if not found."
  (let ((entry (seq-find
                (lambda (item)
                  (equal key (typespec-eval-struct-plist-of-entry-key item)))
                (typespec-eval-struct-plist-of-entries plist))))
    (when entry
      (let ((val (typespec-eval-struct-plist-of-entry-value entry)))
        (when val
          (if (typespec-eval-struct-plist-of-entry-optional-p entry)
              (typespec-eval-simplify-or
               (list (typespec-eval--make-const nil) val))
            val))))))

;;; Cons

(defsubst typespec-eval-struct-cons-form-p (form)
  "Return non-nil if FORM is a cons cell type."
  (and (consp form)
       (eq (car form) 'cons)
       (consp (cdr form))
       (consp (cddr form))
       (null (cdddr form))))

(defsubst typespec-eval-struct-cons-key-type (form)
  "Return the key type of a cons FORM."
  (cadr form))

(defsubst typespec-eval-struct-cons-value-type (form)
  "Return the value type of a cons FORM."
  (caddr form))

;;; Tuple

(defun typespec-eval-struct-tuple-unconst (args)
  "Return ARGS with const-wrapped elements unwrapped."
  (cond
   ((consp args)
    (cons (typespec-eval--unconst (car args))
          (typespec-eval-struct-tuple-unconst (cdr args))))
   ((null args) nil)
   (t (typespec-eval--unconst args))))

(defun typespec-eval-struct-tuple-split (args)
  "Split tuple ARGS into (PREFIX . TAIL), unwrapping consts."
  (let ((prefix nil)
        (tail args))
    (while (consp tail)
      (push (typespec-eval--unconst (car tail)) prefix)
      (setq tail (cdr tail)))
    (cons (nreverse prefix) (typespec-eval--unconst tail))))

(defun typespec-eval-struct-tuple-elements (args)
  "Return tuple elements from ARGS as a flat list."
  (let ((items nil)
        (tail args))
    (while (consp tail)
      (push (car tail) items)
      (setq tail (cdr tail)))
    (when tail
      (push tail items))
    (nreverse items)))

(defun typespec-eval-struct-tuple-build (prefix tail)
  "Return a :tuple expression from PREFIX and TAIL."
  (let ((body (if tail
                  (letrec ((build
                            (lambda (items end)
                              (if (null items)
                                  end
                                (cons (car items)
                                      (funcall build (cdr items) end))))))
                    (funcall build prefix tail))
                prefix)))
    (cons :tuple body)))

;;; Alist entry types

(defun typespec-eval-struct-alist-entry-types (form)
  "Return (KEY . VALUE) for an alist entry type FORM, or nil."
  (cond
   ((typespec-eval-struct-cons-form-p form)
    (cons (typespec-eval-struct-cons-key-type form)
          (typespec-eval-struct-cons-value-type form)))
   ((and (consp form) (eq (car form) :tuple))
    (let* ((parts (typespec-eval-struct-tuple-split (cdr form)))
           (prefix (car parts))
           (tail (cdr parts)))
      (and tail (= (length prefix) 1)
           (cons (car prefix) tail))))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (consp val)
        (cons (typespec-eval--make-const (car val))
              (typespec-eval--make-const (cdr val))))))
   (t nil)))

(defun typespec-eval-struct-alist-entry-seq-types (form)
  "Return (KEY . VALUE) if FORM is a sequence of alist entries."
  (cond
   ((typespec-eval-struct-alist-form-p form)
    (cons (typespec-eval-struct-alist-key-type form)
          (typespec-eval-struct-alist-value-type form)))
   ((typespec-eval-struct-list-elem-type form)
    (typespec-eval-struct-alist-entry-types
     (typespec-eval-struct-list-elem-type form)))
   ((typespec-eval-struct-sequence-elem-type form)
    (or (typespec-eval-struct-alist-entry-types
         (typespec-eval-struct-sequence-elem-type form))
        (cons 'unknown 'unknown)))
   ((and (consp form) (eq (car form) :tuple))
    (let* ((parts (typespec-eval-struct-tuple-split (cdr form)))
           (prefix (car parts))
           (tail (cdr parts))
           (entries (mapcar #'typespec-eval-struct-alist-entry-types prefix)))
      (when (seq-every-p #'identity entries)
        (let ((keys (mapcar #'car entries))
              (vals (mapcar #'cdr entries)))
          (when (typespec-eval-struct-list-elem-type tail)
            (let ((tail-entry (typespec-eval-struct-alist-entry-types
                               (typespec-eval-struct-list-elem-type tail))))
              (when tail-entry
                (push (car tail-entry) keys)
                (push (cdr tail-entry) vals))))
          (when keys
            (cons (typespec-eval-simplify-or (nreverse keys))
                  (typespec-eval-simplify-or (nreverse vals))))))))
   (t nil)))

(defun typespec-eval-struct-plist-append-entry-types (arg)
  "Return (KEY . VALUE) if ARG can contribute to a plist append."
  (cond
   ((typespec-eval-struct-plist-form-p arg)
    (cons (typespec-eval-struct-plist-key-type arg)
          (typespec-eval-struct-plist-value-type arg)))
   ((typespec-eval--const-p arg)
    (let* ((val (typespec-eval--const-value arg))
           (len (and (listp val) (length val))))
      (when (and len (zerop (mod len 2)))
        (let ((keys nil)
              (values nil)
              (idx 0))
          (dolist (item val)
            (if (cl-evenp idx)
                (push (typespec-eval--make-const item) keys)
              (push (typespec-eval--make-const item) values))
            (setq idx (1+ idx)))
          (cons (typespec-eval-simplify-or (nreverse keys))
                (typespec-eval-simplify-or (nreverse values)))))))
   (t nil)))

(provide 'typespec-eval-struct)
;;; typespec-eval-struct.el ends here
