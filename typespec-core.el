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
;; See docs/typespec.md for the current spec syntax and conventions.

;;; Code:
;; (require 'byte-run) byte-run is not feature.

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
    zerop number-sequence
    + - * / % mod 1+ 1- abs max min
    floor ceiling round truncate isnan cl-signum
    logand logior logxor lognot logcount ash
    concat string-bytes
    string-chop-newline string-clean-whitespace string-distance
    string-equal string-equal-ignore-case string-greaterp string-lessp
    string-join string-limit string-lines string-match string-match-p
    upcase downcase capitalize char-to-string make-string substring
    string-pad string-prefix-p string-remove-prefix string-remove-suffix
    string-replace string-search string-split string-suffix-p
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

(defconst typespec-conditional-disallowed-functions
  '(;; environment-dependent symbol operations
    intern make-symbol symbol-value symbol-function
    boundp fboundp indirect-function indirect-variable
    ;; runtime loading / mode state
    macrop provided-mode-derived-p
    ;; buffer-, process-, and window-dependent queries
    current-buffer buffer-name buffer-live-p get-buffer get-buffer-process
    process-status process-live-p selected-window window-live-p)
  "Functions explicitly disallowed in `if' predicates for conditional types.
These consult mutable editor or environment state and must not appear in a
type-level predicate.  See `docs/type-level-evaluation.md'.")

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

;;; Typespec -> ftype erasure

(defconst typespec--ftype-aliases
  '((integer-or-marker . (or integer marker))
    (number-or-marker . (or number marker))
    (positive-int . integer)
    (non-negative-int . integer)
    (negative-int . integer)
    (non-positive-int . integer)
    (hook . (list function)))
  "Aliases for erasing typespec forms into ftype-compatible forms.")

(defun typespec--ftype-const-type (value)
  "Return a simple ftype for constant VALUE."
  (cond
   ((eq value t) 'boolean)
   ((null value) 'null)
   ((stringp value) 'string)
   ((integerp value) 'integer)
   ((floatp value) 'float)
   ((symbolp value) 'symbol)
   (t 't)))

(defun typespec--ftype-simplify-or (items)
  "Simplify ftype OR ITEMS into a minimal form."
  (let* ((flat (seq-filter #'identity items))
         (uniq (delete-dups (copy-sequence flat))))
    (cond
     ((null uniq) 't)
     ((null (cdr uniq)) (car uniq))
     ((equal uniq '(integer float)) 'number)
     ((equal uniq '(float integer)) 'number)
     ((equal uniq '(integer marker)) 'integer-or-marker)
     ((equal uniq '(marker integer)) 'integer-or-marker)
     ((equal uniq '(number marker)) 'number-or-marker)
     ((equal uniq '(marker number)) 'number-or-marker)
     (t (cons 'or uniq)))))

(defun typespec--ftype-erase (form)
  "Erase typespec FORM into an `ftype`-compatible type expression."
  (pcase form
    ((pred symbolp)
     (or (cdr (assq form typespec--ftype-aliases))
         (pcase form
           ((or 'unknown 'mixed 'void) 't)
           ('never 'nil)
           (_ form))))
    (`(const ,value) (typespec--ftype-const-type value))
    (`(:guard ,type) (typespec--ftype-erase type))
    (`(:guard! ,type) (typespec--ftype-erase type))
    (`(:assert ,type) (typespec--ftype-erase type))
    (`(:cause-error . ,_) 't)
    (`(benevolent ,type) (typespec--ftype-erase type))
    (`(generalize ,_ ,target) (typespec--ftype-erase target))
    (`(generalize-signed ,_) 't)
    (`(downcast ,_ ,target) (typespec--ftype-erase target))
    (`(diff ,lhs ,rhs)
     (list 'and (typespec--ftype-erase lhs)
           (list 'not (typespec--ftype-erase rhs))))
    (`(value-of ,_) 't)
    (`(:alist . ,_) 'list)
    (`(:plist . ,_) 'list)
    (`(:plist-of . ,_) 'list)
    (`(:tuple . ,items)
     (cons 'list (mapcar #'typespec--ftype-erase items)))
    (`(function ,argspecs ,ret)
     (list 'function
           (typespec--ftype-argspecs argspecs)
           (typespec--ftype-erase ret)))
    (`(:forall ,_ ,body) (typespec--ftype-erase body))
    (`(,op . ,args)
     (cond
      ((eq op 'or)
       (typespec--ftype-simplify-or (mapcar #'typespec--ftype-erase args)))
      ((memq op '(and not))
       (cons op (mapcar #'typespec--ftype-erase args)))
      (t 't)))
    (_ 't)))

(defun typespec--ftype-argspecs (argspecs)
  "Return ftype-compatible ARGSPECS."
  (let ((out nil)
        (in-key nil))
    (dolist (spec argspecs)
      (pcase spec
        ('&keys (push '&key out) (setq in-key t))
        ('&key (push '&key out) (setq in-key t))
        ((or '&optional '&rest '&allow-other-keys)
         (push spec out))
        (_
         (if (and in-key (consp spec))
             (setq in-key t)
           (push (typespec--ftype-erase spec) out)))))
    (nreverse out)))

(defun typespec--ftype-from-spec (spec)
  "Return an `ftype` function spec for SPEC, or nil."
  (pcase spec
    (`(:forall ,_ ,body) (typespec--ftype-from-spec body))
    (`(function ,argspecs ,ret)
     (list 'function
           (typespec--ftype-argspecs argspecs)
           (typespec--ftype-erase ret)))
    (_ nil)))

;;; `defun' declaration handler

(defun typespec--defun-decl-ftype (function args val &optional function-name)
  "Handle `typespec-ftype` declarations.
FUNCTION is the target symbol, ARGS are the lambda list arguments, and
VAL is the declared typespec."
  (let* ((spec (pcase val
                 (`(:forall . ,_) val)
                 (`(function . ,_) val)
                 (_ `(function ,val))))
         (ftype (typespec--ftype-from-spec spec)))
    (when ftype
      (byte-run--set-function-type function args ftype function-name))))

(when (boundp 'defun-declarations-alist)
  (add-to-list 'defun-declarations-alist
               (list 'typespec-ftype #'typespec--defun-decl-ftype)))

(provide 'typespec-core)
;;; typespec-core.el ends here
