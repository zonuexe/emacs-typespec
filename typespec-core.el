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

(defconst typespec-conditional-predicate-functions
  '(stringp integerp symbolp null
    consp atom listp nlistp
    keywordp vectorp recordp arrayp sequencep
    bufferp markerp bool-vector-p
    integer-or-marker-p numberp number-or-marker-p floatp natnump
    booleanp proper-list-p fixnump bignump wholenump
    functionp hash-table-p
    subrp byte-code-function-p interpreted-function-p closurep
    module-function-p
    char-or-string-p char-table-p char-uppercase-p
    string-empty-p string-blank-p string-or-null-p
    multibyte-string-p vector-or-char-table-p
    bare-symbol-p symbol-with-pos-p
    = /= > >= < <=
    value< char-equal
    string< string> string=
    string-lessp
    equal eql eq equal-including-properties
    car cdr car-safe cdr-safe nth nthcdr elt aref length
    reverse last butlast safe-length copy-sequence
    memq member member-ignore-case
    assoc assq rassoc alist-get
    plist-get plist-member
    log10 lsh zerop number-sequence
    + - * / % mod 1+ 1- abs max min
    floor ceiling round truncate isnan cl-signum
    logand logior logxor lognot logcount ash
    concat string-as-multibyte string-as-unibyte string-bytes
    string-chop-newline string-clean-whitespace string-distance
    string-equal string-equal-ignore-case string-greaterp string-lessp
    string-join string-limit string-lines string-match-p
    upcase downcase capitalize char-to-string make-string substring
    string-pad string-prefix-p string-remove-prefix string-remove-suffix
    string-replace string-reverse string-search string-split string-suffix-p
    string-to-char string-to-list string-to-multibyte string-to-number
    string-to-unibyte string-to-vector string-trim string-trim-left
    string-trim-right string-truncate-left string-version-lessp
    number-to-string
    version-list-< version-list-<= version-list-= version-list-not-zero
    version-to-list version< version<= version=
    cl-plusp cl-minusp cl-evenp cl-oddp cl-equalp cl-endp
    cl-first cl-second cl-third cl-fourth cl-fifth cl-sixth
    cl-seventh cl-eighth cl-ninth cl-tenth cl-list-length
    seq-empty-p seq-length seq-elt
    symbol-name identity not type-of cl-type-of
    kbd make-composed-keymap mouse-event-p sha1 syntax-class)
  "Functions allowed in `if' predicates for conditional return types.")

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
