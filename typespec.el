;;; typespec.el --- High-level Type specification    -*- lexical-binding: t; -*-

;; Copyright (C) 2026  USAMI Kenta

;; Author: USAMI Kenta <tadsan@zonu.me>
;; Homepage: https://github.com/zonuexe/emacs-typespec.el
;; Keywords: lisp, extensions
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; License: GPL-3.0-or-later

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
(defmacro typespec (function spec &rest options)
  "Attach SPEC to FUNCTION as a `typespec' function property.
SPEC is stored as literal data and is not evaluated.
OPTIONS are reserved for future use and currently must be empty."
  (declare (indent 1))
  (when options
    (error "Unsupported typespec options: %S" options))
  `(function-put ,function 'typespec ',spec))

(provide 'typespec)
;;; typespec.el ends here
