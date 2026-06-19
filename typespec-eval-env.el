;;; typespec-eval-env.el --- Type environment and branch narrowing  -*- lexical-binding: t; -*-

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

;; A small flow-sensitivity layer on top of the type-level evaluator.  It
;; models the part of a type checker that tracks variable types and refines
;; them across conditional branches, WITHOUT walking Emacs Lisp source.
;;
;; - A *type environment* maps variables (symbols) to typespec types.
;; - `typespec-eval-env-narrow' applies a guard/assert predicate tested on a
;;   variable, returning the refined environments for the true/false (or
;;   assert) branches, using `typespec-eval-call-narrowing'.
;; - `typespec-eval-env-join' merges two environments at a control-flow
;;   confluence by unioning each variable's type.
;;
;; A real checker would drive these from the syntax of `if'/`cond'/`when'/
;; `and'/`or'/`let'; that traversal is out of scope here.

;;; Code:

(require 'typespec-eval)

(defconst typespec-eval-env-default 'unknown
  "Type assumed for variables absent from a type environment.")

(defun typespec-eval-env-make (&optional bindings)
  "Return a new type environment from BINDINGS, an alist of (VAR . TYPE)."
  (copy-alist bindings))

(defun typespec-eval-env-get (env var)
  "Return the type bound to VAR in ENV, or `typespec-eval-env-default'."
  (let ((cell (assq var env)))
    (if cell (cdr cell) typespec-eval-env-default)))

(defun typespec-eval-env-set (env var type)
  "Return a new environment like ENV with VAR bound to TYPE."
  (cons (cons var type)
        (assq-delete-all var (copy-alist env))))

(defun typespec-eval-env-narrow (env var funspec)
  "Refine ENV for a guard FUNSPEC tested on VAR.
FUNSPEC is a function typespec whose return is `:guard'/`:guard!'/`:assert'.
Return a plist describing the refined environments per branch:
- (:true ENV-TRUE :false ENV-FALSE) for `:guard'/`:guard!'.  For `:guard' the
  false environment is ENV unchanged (the predicate may be partial).
- (:assert ENV-ASSERT) for `:assert'.
Return nil when FUNSPEC has no guard/assert effect."
  (let* ((arg0 (typespec-eval-env-get env var))
         (narrowing (typespec-eval-call-narrowing funspec (list arg0))))
    (when narrowing
      (if (plist-member narrowing :assert)
          (list :assert
                (typespec-eval-env-set env var (plist-get narrowing :assert)))
        (list :true
              (typespec-eval-env-set env var (plist-get narrowing :true))
              :false
              (typespec-eval-env-set env var (plist-get narrowing :false)))))))

(defun typespec-eval-env-join (env-a env-b)
  "Join environments ENV-A and ENV-B at a control-flow confluence.
Each variable's type becomes the union of its type in each environment
\(variables absent on one side default to `typespec-eval-env-default')."
  (let ((vars (delete-dups (append (mapcar #'car env-a) (mapcar #'car env-b))))
        (result nil))
    (dolist (var vars)
      (push (cons var
                  (typespec-eval-simplify-or
                   (list (typespec-eval-env-get env-a var)
                         (typespec-eval-env-get env-b var))))
            result))
    (nreverse result)))

(provide 'typespec-eval-env)
;;; typespec-eval-env.el ends here
