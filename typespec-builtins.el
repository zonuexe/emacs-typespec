;;; typespec-builtins.el --- Built-in typespec registry  -*- lexical-binding: t; -*-

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

;; Simple pcase-based registry of built-in function types.
;; Intended to be consumed by the evaluator when no explicit typespec
;; is registered.

;;; Code:

(require 'typespec-core)

(defun typespec-builtins-lookup (sym)
  "Return the typespec ftype for built-in function SYM, or nil if unknown."
  (pcase sym
    ;; Keep sorted/alphabetical blocks for readability.
    ('bound-and-true-p '(function (symbol) (:guard t unknown)))
    ('member '(function (t list) (or (list+ t) (const nil))))
    ('memq   '(function (t list) (or (list+ t) (const nil))))
    ('memql  '(function (t list) (or (list+ t) (const nil))))
    ;; add more built-ins here
    (_ nil)))

(provide 'typespec-builtins)
;;; typespec-builtins.el ends here
