;;; typespec-eval-test.el --- Tests for typespec-eval  -*- lexical-binding: t; -*-

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

;; Tests for the typespec evaluator.

;;; Code:

(require 'ert)
(require 'seq)
(require 'typespec-eval)

(ert-deftest typespec-eval-eq ()
  (should (equal (typespec-eval '(eq (const 1) (const 1)))
                 '(const t)))
  (should (equal (typespec-eval '(eq (const 1) (const 2)))
                 '(const nil)))
  (should (equal (typespec-eval '(eq number number)) 'boolean))
  (should (equal (typespec-eval '(eq unknown unknown)) 'boolean)))

(ert-deftest typespec-eval-upcase ()
  (should (equal (typespec-eval '(upcase "a"))
                 '(const "A")))
  (should (equal (typespec-eval '(upcase (or "a" "b" "c")))
                 '(or (const "A") (const "B") (const "C"))))
  (should (equal (typespec-eval '(upcase string))
                 'string)))

(ert-deftest typespec-eval-string-to-number ()
  (should (equal (typespec-eval '(string-to-number "1"))
                 '(const 1)))
  (should (equal (typespec-eval '(string-to-number "a"))
                 '(const 0)))
  (should (equal (typespec-eval '(string-to-number "1.1"))
                 '(const 1.1)))
  (should (equal (typespec-eval '(string-to-number string))
                 'number))
  (should (equal (typespec-eval '(string-to-number (or "1" "2")))
                 '(or (const 1) (const 2)))))

(ert-deftest typespec-eval-string-equal ()
  (should (equal (typespec-eval '(string-equal "a" "a"))
                 '(const t)))
  (should (equal (typespec-eval '(string-equal "a" "b"))
                 '(const nil)))
  (should (equal (typespec-eval '(string-equal string string))
                 'boolean))
  (should (equal (typespec-eval '(string-equal (or "a" "b") "a"))
                 'boolean)))

(ert-deftest typespec-eval-string-prefix-p ()
  (should (equal (typespec-eval '(string-prefix-p "a" "abc"))
                 '(const t)))
  (should (equal (typespec-eval '(string-prefix-p "a" "xyz"))
                 '(const nil)))
  (should (equal (typespec-eval '(string-prefix-p string string))
                 'boolean))
  (should (equal (typespec-eval '(string-prefix-p (or "a" "b") "abc"))
                 'boolean)))

(ert-deftest typespec-eval-not-null ()
  (should (equal (typespec-eval '(not (const nil)))
                 '(const t)))
  (should (equal (typespec-eval '(not (const t)))
                 '(const nil)))
  (should (equal (typespec-eval '(not (list unknown)))
                 'boolean))
  (should (equal (typespec-eval '(not (list+ unknown)))
                 '(const nil)))
  (should (equal (typespec-eval '(not unknown))
                 'boolean))
  (should (equal (typespec-eval '(not (not (const nil))))
                 '(const nil)))
  (should (equal (typespec-eval '(not boolean))
                 'boolean))
  (should (equal (typespec-eval '(not string))
                 '(const nil)))
  (should (equal (typespec-eval '(null (const nil)))
                 '(const t)))
  (should (equal (typespec-eval '(null string))
                 '(const nil)))
  (should (equal (typespec-eval '(null (list unknown)))
                 'boolean))
  (should (equal (typespec-eval '(null (list+ unknown)))
                 '(const nil))))

(ert-deftest typespec-eval-concat ()
  (should (equal (typespec-eval '(concat "a" "b" "c"))
                 '(const "abc")))
  (should (equal (typespec-eval '(concat string string))
                 'string))
  (should (equal (typespec-eval '(concat (const "x") string))
                 '(and string (not (const ""))))))

(provide 'typespec-eval-test)
;;; typespec-eval-test.el ends here
