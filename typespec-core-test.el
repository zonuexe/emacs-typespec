;;; typespec-core-test.el --- Tests for typespec-core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  USAMI Kenta

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

;; Tests for core typespec predicates.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'typespec-core)

(ert-deftest typespec-core-conditional-predicate-functions-are-fboundp ()
  "All conditional predicate functions should be defined."
  (dolist (fn typespec-conditional-predicate-functions)
    (should (fboundp fn))))

(ert-deftest typespec-core-defun-decl-ftype ()
  "Typespec-ftype should expand to an ftype declaration."
  (skip-unless (fboundp 'byte-run--set-function-type))
  (let ((sym 'typespec-core-test--fn))
    (should (equal (typespec--defun-decl-ftype
                    sym '(arg) '(function (integer-or-marker) (const t)))
                   '(function-put 'typespec-core-test--fn 'function-type
                                  '(function ((or integer marker)) boolean))))))

(ert-deftest typespec-core-defun-decl-ftype-unknown ()
  "Typespec-ftype should return nil for unsupported specs."
  (let ((sym 'typespec-core-test--fn2))
    (should (equal (typespec--defun-decl-ftype sym '(arg) '(or integer string))
                   nil))))

(ert-deftest typespec-core-ftype-accepted-by-comp-cstr ()
  "Erased ftype should be accepted by `comp-type-spec-to-cstr`."
  (require 'comp-cstr nil t)
  (skip-unless (fboundp 'comp-type-spec-to-cstr))
  (let* ((spec '(function (integer-or-marker) (const t)))
         (ftype (typespec--ftype-from-spec spec)))
    (should (equal ftype '(function ((or integer marker)) boolean)))
    (let ((comp-ctxt (make-comp-cstr-ctxt)))
      (comp-cstr-ctxt-update-type-slots comp-ctxt)
      (should (comp-type-spec-to-cstr ftype)))))

(ert-deftest typespec-core-ftype-erase-constants ()
  "Ftype erasure should collapse constants to simple types."
  (should (equal (typespec--ftype-erase 'positive-int) 'integer))
  (should (equal (typespec--ftype-erase '(const 1.1)) 'float))
  (should (equal (typespec--ftype-erase '(const "foo")) 'string))
  (should (equal (typespec--ftype-erase '(or integer marker))
                 'integer-or-marker))
  (should (equal (typespec--ftype-erase '(or number marker))
                 'number-or-marker))
  (should (equal (typespec--ftype-erase '(or (const "foo") (const "bar")))
                 'string))
  (should (equal (typespec--ftype-erase '(or (const 1) (const 1.1)))
                 'number))
  (should (equal (typespec--ftype-erase '(or (const 1.1) (const 2.1)))
                 'float))
  (should (equal (typespec--ftype-erase '(or (const "foo") (const 1)))
                 '(or string integer))))

(provide 'typespec-core-test)
;;; typespec-core-test.el ends here
