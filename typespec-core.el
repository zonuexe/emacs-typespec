;;; typespec-core.el --- High-level Type specification  -*- lexical-binding: t; -*-

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

;; This file defines the public `typespec` macro, which attaches a
;; typespec S-expression to a function symbol via a function property.
;; The stored spec is literal (not evaluated) so tooling can later read
;; and interpret it without executing arbitrary forms.
;;
;; See typespec.md for the current spec syntax and conventions.

;;; Code:
(defconst typespec-baseline-version "2026-01-01"
  "Baseline feature set version for typespec resolvers.")

(defvar typespec-builtin-resolvers nil
  "Alist of baseline type resolvers for builtin typespec features.")

(defvar typespec-resolvers (copy-sequence typespec-builtin-resolvers)
  "Alist of registered type resolvers, including custom extensions.")

(defun typespec--version-older-p (version required)
  "Return non-nil if VERSION is older than REQUIRED."
  (let ((v (if (symbolp version) (symbol-name version) version))
        (r (if (symbolp required) (symbol-name required) required)))
    (and (stringp v) (stringp r) (string< v r))))

(defmacro typespec-register-type (name resolver)
  "Register RESOLVER for typespec utility type NAME."
  (declare (indent 1))
  `(progn
     (setq typespec-resolvers
           (cons (cons ,name ,resolver)
                 (assq-delete-all ,name typespec-resolvers)))
     ,name))

(defun typespec-get-resolver-by-version (version &key require-baseline)
  "Return resolver alist, warning if baseline is older than REQUIRE-BASELINE."
  (when (and require-baseline
             (typespec--version-older-p typespec-baseline-version require-baseline))
    (message
     "typespec baseline %s is older than required %s; please update typespec"
     typespec-baseline-version require-baseline))
  (copy-sequence typespec-resolvers))

(defun typespec--make-record (spec)
  "Return a typespec record for SPEC."
  (list :spec spec
        :baseline typespec-baseline-version
        :resolvers (copy-sequence typespec-resolvers)))

(provide 'typespec-core)
;;; typespec-core.el ends here
