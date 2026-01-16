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

(provide 'typespec-core-test)
;;; typespec-core-test.el ends here
