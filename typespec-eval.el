;;; typespec-eval.el --- Type-level evaluator for typespec  -*- lexical-binding: t; -*-

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

;; Minimal evaluator for typespec value/type expressions.
;; This is currently limited to simple constant folding for predicates
;; like `eq' and string operations like `upcase'.

;;; Code:

(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))
(require 'rx)
(require 'seq)
(require 'typespec-eval-core)
(require 'typespec-eval-var)
(require 'typespec-eval-types)
(require 'typespec-eval-simplify)
(require 'typespec-eval-op)
(require 'typespec-eval-numeric)

(defun typespec-eval--eval (form)
  "Evaluate a typespec FORM into a simplified type/value expression."
  (declare (ftype (function (t) t)))
  (pcase form
    ((pred typespec-eval-simplify-literal-const)
     (typespec-eval-simplify-literal-const form))
    (`(or . ,args)
     (typespec-eval-simplify-or (mapcar #'typespec-eval--eval args)))
    (`(diff ,lhs ,rhs)
     (typespec-eval-op-diff lhs rhs))
    (`(list+ ,type)
     (list 'list+ (typespec-eval--eval type)))
    (`(list ,type)
     (list 'list (typespec-eval--eval type)))
    (`(vector ,type)
     (list 'vector (typespec-eval--eval type)))
    (`(sequence ,type)
     (list 'sequence (typespec-eval--eval type)))
    (`(hook ,funtype . ,rest)
     (apply #'list 'hook (typespec-eval--eval funtype) rest))
    (`(hash-table ,key ,value)
     (list 'hash-table (typespec-eval--eval key) (typespec-eval--eval value)))
    (`(:class ,class)
     (list :class class))
    (`(:forall ,_ ,body)
     (typespec-eval--eval body))
    (`(:cause-error . ,_) form)
    (`(function ,argspecs ,ret)
     (typespec-eval-op-function-type argspecs ret))
    (`(generalize ,value ,target)
     (typespec-eval-op-generalize value target))
    (`(generalize-signed ,value)
     (typespec-eval-op-generalize-signed value))
    (`(:guard ,type)
     (list :guard (typespec-eval--eval type)))
    (`(:guard! ,type)
     (list :guard! (typespec-eval--eval type)))
    (`(:assert ,type)
     (list :assert (typespec-eval--eval type)))
    (`(downcast ,value ,target)
     (typespec-eval-op-downcast value target))
    (`(benevolent ,value)
     (list 'benevolent (typespec-eval--eval value)))
    (`(rx . ,_) form)
    ((and `(member . ,members) (guard (seq-every-p #'atom members)))
     (typespec-eval-simplify-or
      (mapcar #'typespec-eval--make-const members)))
    (`(:alist ,key ,value)
     (list :alist (typespec-eval--eval key) (typespec-eval--eval value)))
    (`(:plist ,key ,value)
     (list :plist (typespec-eval--eval key) (typespec-eval--eval value)))
    (`(:plist-of . ,entries)
     (typespec-eval-op-plist-of entries))
    (`(:tuple . ,args)
     (cons :tuple (typespec-eval-op-tuple args)))
    (`(value-of ,arg)
     (typespec-eval-op-value-of arg))
    (`(var ,sym)
     (let ((result (typespec-eval-var--eval sym)))
       (pcase result
         (`(unresolved ,value) (typespec-eval--eval value))
         (_ result))))
    (`(plist-key-of ,plist)
     (typespec-eval-op-plist-key-of plist))
    (`(plist-value-of ,plist)
     (typespec-eval-op-plist-value-of plist))
    (`(and . ,args)
     (typespec-eval-op-and args))
    (`(not ,arg)
     (typespec-eval-op-not arg))
    (`(null ,arg)
     (typespec-eval-op-unary-predicate arg #'null
                       #'typespec-eval--always-nil-p
                       #'typespec-eval--always-non-nil-p))
    (`(const ,_) form)
    (`(if ,pred ,then ,else)
     (typespec-eval-op-if pred then else))
    (`(integer ,low ,high)
     (typespec-eval--integer-range low high))
    (`(float ,low ,high)
     (typespec-eval--float-range low high))
    (`(real ,low ,high)
     (typespec-eval--real-range low high))
    (`(number ,low ,high)
     (typespec-eval--number-range low high))
    ('positive-float
     (typespec-eval--float-range '(0) '*))
    ('negative-float
     (typespec-eval--float-range '* '(0)))
    ('non-negative-float
     (typespec-eval--float-range 0.0 '*))
    ('non-positive-float
     (typespec-eval--float-range '* 0.0))
    (`(eq ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'eq))
    (`(eql ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'eql))
    (`(equal ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'equal))
    (`(equal-including-properties ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'equal-including-properties))
    (`(= ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'= #'numberp #'typespec-eval-types-number-or-marker-type-p))
    (`(/= ,lhs ,rhs)
     (typespec-eval-op-numeric-compare lhs rhs #'/=))
    (`(< ,lhs ,rhs)
     (typespec-eval-op-numeric-compare lhs rhs #'<))
    (`(<= ,lhs ,rhs)
     (typespec-eval-op-numeric-compare lhs rhs #'<=))
    (`(> ,lhs ,rhs)
     (typespec-eval-op-numeric-compare lhs rhs #'>))
    (`(>= ,lhs ,rhs)
     (typespec-eval-op-numeric-compare lhs rhs #'>=))
    (`(value< ,lhs ,rhs)
     (typespec-eval-op-value< lhs rhs))
    (`(char-equal ,lhs ,rhs)
     (typespec-eval-op-char-equal lhs rhs))
    (`(identity ,arg)
     (typespec-eval--eval arg))
    (`(stringp ,arg)
     (typespec-eval-op-unary-predicate arg #'stringp
                       #'typespec-eval-types-string-type-p
                       #'typespec-eval-types-non-string-type-p))
    (`(integerp ,arg)
     (typespec-eval-op-integerp arg))
    (`(floatp ,arg)
     (typespec-eval-op-unary-predicate arg #'floatp
                       #'typespec-eval-types-float-type-p
                       #'typespec-eval-types-non-float-type-p))
    (`(numberp ,arg)
     (typespec-eval-op-unary-predicate arg #'numberp
                       #'typespec-eval-types-number-type-p
                       #'typespec-eval-types-non-number-type-p))
    (`(natnump ,arg)
     (typespec-eval-op-unary-predicate arg #'natnump
                       #'typespec-eval-types-non-negative-int-type-p))
    (`(wholenump ,arg)
     (typespec-eval-op-unary-predicate arg #'wholenump
                       #'typespec-eval-types-non-negative-int-type-p))
    (`(fixnump ,arg)
     (typespec-eval-op-unary-predicate arg #'fixnump
                       (lambda (form)
                         (or (eq form 'fixnum)
                             (typespec-eval-types-fixnum-range-p form)))
                       #'typespec-eval-types-non-integer-type-p))
    (`(bignump ,arg)
     (typespec-eval-op-unary-predicate arg #'bignump
                       (typespec-eval--type-eq-p 'bignum)))
    (`(booleanp ,arg)
     (typespec-eval-op-unary-predicate arg #'booleanp
                       #'typespec-eval-types-boolean-type-p))
    (`(listp ,arg)
     (typespec-eval-op-unary-predicate arg #'listp
                       #'typespec-eval-types-list-type-p
                       #'typespec-eval-types-non-list-type-p))
    (`(consp ,arg)
     (typespec-eval-op-unary-predicate arg #'consp
                       (lambda (form)
                         (or (eq (car-safe form) 'list+)
                             (eq (car-safe form) 'cons)))
                       (lambda (form)
                         (and (typespec-eval-types-list-type-p form)
                              (not (eq (car-safe form) 'list+))))))
    (`(atom ,arg)
     (typespec-eval-op-unary-predicate arg #'atom
                       (lambda (form) (not (typespec-eval-types-list-type-p form)))
                       (lambda (form) (eq (car-safe form) 'list+))))
    (`(nlistp ,arg)
     (typespec-eval-op-unary-predicate arg #'nlistp
                       #'typespec-eval-types-non-list-type-p
                       #'typespec-eval-types-list-type-p))
    (`(vectorp ,arg)
     (typespec-eval-op-unary-predicate arg #'vectorp
                       #'typespec-eval-types-vector-type-p
                       #'typespec-eval-types-non-vector-type-p))
    (`(arrayp ,arg)
     (typespec-eval-op-unary-predicate arg #'arrayp
                       (lambda (form)
                         (or (typespec-eval-types-string-type-p form)
                             (typespec-eval-types-vector-type-p form)))
                       #'typespec-eval-types-list-type-p))
    (`(sequencep ,arg)
     (typespec-eval-op-unary-predicate arg #'sequencep
                       (lambda (form)
                         (or (typespec-eval-types-list-type-p form)
                             (typespec-eval-types-string-type-p form)
                             (typespec-eval-types-vector-type-p form)))))
    (`(symbolp ,arg)
     (typespec-eval-op-unary-predicate arg #'symbolp
                       #'typespec-eval-types-symbol-type-p
                       #'typespec-eval-types-non-string-type-p))
    (`(keywordp ,arg)
     (typespec-eval-op-unary-predicate arg #'keywordp
                       #'typespec-eval-types-keyword-type-p))
    (`(proper-list-p ,arg)
     (typespec-eval-op-unary-predicate arg #'proper-list-p
                       #'typespec-eval-types-list-type-p))
    (`(char-or-string-p ,arg)
     (typespec-eval-op-unary-predicate arg #'char-or-string-p
                       (lambda (form)
                         (or (typespec-eval-types-string-type-p form)
                             (typespec-eval-types-integer-type-p form)))))
    (`(char-table-p ,arg)
     (typespec-eval-op-unary-predicate arg #'char-table-p
                       #'typespec-eval-types-char-table-type-p))
    (`(char-uppercase-p ,arg)
     (typespec-eval-op-unary-predicate arg #'char-uppercase-p
                       (lambda (form) (typespec-eval-types-integer-type-p form))))
    (`(multibyte-string-p ,arg)
     (typespec-eval-op-unary-predicate arg #'multibyte-string-p
                       #'typespec-eval-types-string-type-p))
    (`(vector-or-char-table-p ,arg)
     (typespec-eval-op-unary-predicate arg #'vector-or-char-table-p
                       (lambda (form)
                         (or (typespec-eval-types-vector-type-p form)
                             (typespec-eval-types-char-table-type-p form)))))
    (`(bare-symbol-p ,arg)
     (typespec-eval-op-unary-predicate arg #'bare-symbol-p
                       (typespec-eval--type-eq-p 'symbol)))
    (`(symbol-with-pos-p ,arg)
     (typespec-eval-op-unary-predicate arg #'symbol-with-pos-p
                       (typespec-eval--type-eq-p 'symbol-with-pos)))
    (`(integer-or-marker-p ,arg)
     (typespec-eval-op-unary-predicate arg #'integer-or-marker-p
                       (lambda (form)
                         (or (typespec-eval-types-integer-type-p form)
                             (typespec-eval-types-marker-type-p form)))))
    (`(number-or-marker-p ,arg)
     (typespec-eval-op-unary-predicate arg #'number-or-marker-p
                       (lambda (form)
                         (or (typespec-eval-types-number-type-p form)
                             (typespec-eval-types-marker-type-p form)))))
    (`(bufferp ,arg)
     (typespec-eval-op-unary-predicate arg #'bufferp
                       #'typespec-eval-types-buffer-type-p))
    (`(markerp ,arg)
     (typespec-eval-op-unary-predicate arg #'markerp
                       #'typespec-eval-types-marker-type-p))
    (`(bool-vector-p ,arg)
     (typespec-eval-op-unary-predicate arg #'bool-vector-p
                       #'typespec-eval-types-bool-vector-type-p))
    (`(functionp ,arg)
     (typespec-eval-op-unary-predicate arg #'functionp
                       #'typespec-eval-types-function-type-p))
    (`(hash-table-p ,arg)
     (typespec-eval-op-unary-predicate arg #'hash-table-p
                       #'typespec-eval-types-hash-table-type-p))
    (`(recordp ,arg)
     (typespec-eval-op-unary-predicate arg #'recordp
                       #'typespec-eval-types-record-type-p))
    (`(subrp ,arg)
     (typespec-eval-op-unary-predicate arg #'subrp))
    (`(byte-code-function-p ,arg)
     (typespec-eval-op-unary-predicate arg #'byte-code-function-p))
    (`(interpreted-function-p ,arg)
     (typespec-eval-op-unary-predicate arg #'interpreted-function-p))
    (`(closurep ,arg)
     (typespec-eval-op-unary-predicate arg #'closurep))
    (`(module-function-p ,arg)
     (typespec-eval-op-unary-predicate arg #'module-function-p))
    (`(object-of-class-p ,object ,class)
     (typespec-eval-op-object-of-class-p object class))
    (`(string-empty-p ,arg)
     (typespec-eval-op-unary-predicate arg #'string-empty-p
                       #'typespec-eval--const-empty-string-p
                       #'typespec-eval-types-non-string-type-p))
    (`(string-blank-p ,arg)
     (typespec-eval-op-unary-predicate arg #'string-blank-p
                       nil
                       #'typespec-eval-types-non-string-type-p))
    (`(string-or-null-p ,arg)
     (typespec-eval-op-unary-predicate arg #'string-or-null-p
                       (lambda (form)
                         (or (typespec-eval-types-string-type-p form)
                             (typespec-eval--always-nil-p form)))
                       #'typespec-eval-types-non-string-type-p))
    (`(mouse-event-p ,arg)
     (typespec-eval-op-unary-predicate arg #'mouse-event-p))
    (`(upcase ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'upcase #'typespec-eval-simplify-string-or-char-p 'string))
    (`(downcase ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'downcase #'typespec-eval-simplify-string-or-char-p 'string))
    (`(capitalize ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'capitalize #'typespec-eval-simplify-string-or-char-p 'string))
    (`(string-to-number ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-to-number #'stringp 'string 'number))
    (`(number-to-string ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'number-to-string #'numberp 'number 'string))
    (`(string-trim ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-trim #'stringp 'string))
    (`(string-trim-left ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-trim-left #'stringp 'string))
    (`(string-trim-right ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-trim-right #'stringp 'string))
    (`(string-width ,arg)
     (typespec-eval-op-string-width arg))
    (`(string-lines ,string . ,rest)
     (typespec-eval-op-string-lines string (car rest) (cadr rest)))
    (`(cons ,car ,cdr)
     (typespec-eval-op-cons car cdr))
    (`(append . ,args)
     (typespec-eval-op-append args))
    (`(list . ,args)
     (typespec-eval-op-list args))
    (`(string-join ,strings . ,rest)
     (typespec-eval-op-string-join strings (car rest)))
    (`(abs ,arg)
     (typespec-eval-op-numeric-unary arg #'abs))
    (`(floor ,arg)
     (typespec-eval-op-rounding arg 'floor #'floor))
    (`(ceiling ,arg)
     (typespec-eval-op-rounding arg 'ceiling #'ceiling))
    (`(round ,arg)
     (typespec-eval-op-rounding arg 'round #'round))
    (`(truncate ,arg)
     (typespec-eval-op-rounding arg 'truncate #'truncate))
    (`(length ,arg)
     (typespec-eval-op-length arg))
    (`(string-bytes ,arg)
     (typespec-eval-op-string-bytes arg))
    (`(substring ,string ,start . ,rest)
     (typespec-eval-op-substring string start (car rest)))
    (`(car ,arg)
     (typespec-eval-op-nth 0 arg))
    (`(cdr ,arg)
     (typespec-eval-op-nthcdr 1 arg))
    (`(car-safe ,arg)
     (typespec-eval-op-car-safe arg))
    (`(cdr-safe ,arg)
     (typespec-eval-op-cdr-safe arg))
    (`(nth ,n ,list)
     (typespec-eval-op-nth n list))
    (`(nthcdr ,n ,list)
     (typespec-eval-op-nthcdr n list))
    (`(elt ,sequence ,n)
     (typespec-eval-op-elt sequence n))
    (`(aref ,array ,n)
     (typespec-eval-op-aref array n))
    (`(reverse ,arg)
     (typespec-eval-op-sequence-identity arg #'reverse))
    (`(copy-sequence ,sequence)
     (typespec-eval-op-sequence-identity sequence #'copy-sequence))
    (`(safe-length ,list)
     (typespec-eval-op-safe-length list))
    (`(last ,list . ,rest)
     (typespec-eval-op-last list (car rest)))
    (`(butlast ,list . ,rest)
     (typespec-eval-op-butlast list (car rest)))
    (`(assoc ,key ,alist)
     (typespec-eval-op-alist-search key alist t #'equal))
    (`(assq ,key ,alist)
     (typespec-eval-op-alist-search key alist t #'eq))
    (`(rassoc ,value ,alist)
     (typespec-eval-op-alist-search value alist nil #'equal))
    (`(alist-get ,key ,alist . ,rest)
     (typespec-eval-op-alist-get key alist (car rest) (cadr rest) (caddr rest)))
    (`(assoc-default ,key ,alist . ,rest)
     (typespec-eval-op-assoc-default key alist (car rest) (cadr rest)))
    (`(rassq ,value ,alist)
     (typespec-eval-op-alist-search value alist nil #'eq))
    (`(assoc-delete-all ,key ,alist . ,rest)
     (typespec-eval-op-assoc-delete-all key alist (car rest)))
    (`(assq-delete-all ,key ,alist)
     (typespec-eval-op-assoc-delete-all key alist 'eq))
    (`(rassq-delete-all ,value ,alist)
     (typespec-eval-op-rassq-delete-all value alist))
    (`(plist-get ,plist ,key . ,rest)
     (typespec-eval-op-plist-get plist key (car rest)))
    (`(plist-member ,plist ,key)
     (typespec-eval-op-plist-member plist key))
    (`(memq ,elt ,list)
     (typespec-eval-op-member-like elt list #'memq))
    (`(member ,elt ,list)
     (typespec-eval-op-member-like elt list #'member))
    (`(member-ignore-case ,elt ,list)
     (typespec-eval-op-member-like elt list #'member-ignore-case))
    (`(seq-length ,sequence)
     (typespec-eval-op-seq-length sequence))
    (`(seq-elt ,sequence ,n)
     (typespec-eval-op-elt sequence n))
    (`(seq-empty-p ,sequence)
     (typespec-eval-op-seq-empty-p sequence))
    (`(cl-endp ,arg)
     (typespec-eval-op-cl-endp arg))
    (`(cl-first ,arg)
     (typespec-eval-op-nth 0 arg))
    (`(cl-second ,arg)
     (typespec-eval-op-nth 1 arg))
    (`(cl-third ,arg)
     (typespec-eval-op-nth 2 arg))
    (`(cl-fourth ,arg)
     (typespec-eval-op-nth 3 arg))
    (`(cl-fifth ,arg)
     (typespec-eval-op-nth 4 arg))
    (`(cl-sixth ,arg)
     (typespec-eval-op-nth 5 arg))
    (`(cl-seventh ,arg)
     (typespec-eval-op-nth 6 arg))
    (`(cl-eighth ,arg)
     (typespec-eval-op-nth 7 arg))
    (`(cl-ninth ,arg)
     (typespec-eval-op-nth 8 arg))
    (`(cl-tenth ,arg)
     (typespec-eval-op-nth 9 arg))
    (`(cl-list-length ,arg)
     (typespec-eval-op-cl-list-length arg))
    (`(cl-plusp ,arg)
     (typespec-eval-op-unary-predicate arg #'cl-plusp #'typespec-eval-types-number-type-p))
    (`(cl-minusp ,arg)
     (typespec-eval-op-unary-predicate arg #'cl-minusp #'typespec-eval-types-number-type-p))
    (`(cl-evenp ,arg)
     (typespec-eval-op-unary-predicate arg #'cl-evenp #'typespec-eval-types-integer-type-p))
    (`(cl-oddp ,arg)
     (typespec-eval-op-unary-predicate arg #'cl-oddp #'typespec-eval-types-integer-type-p))
    (`(cl-equalp ,lhs ,rhs)
     (typespec-eval-op-equality lhs rhs #'cl-equalp))
    (`(type-of ,arg)
     (typespec-eval-op-type-of arg #'type-of))
    (`(cl-type-of ,arg)
     (typespec-eval-op-type-of arg #'cl-type-of))
    (`(symbol-name ,arg)
     (typespec-eval-op-symbol-name arg))
    (`(kbd ,arg)
     (typespec-eval-op-kbd arg))
    (`(make-composed-keymap ,maps . ,rest)
     (typespec-eval-op-make-composed-keymap maps (car rest)))
    (`(sha1 ,arg)
     (typespec-eval-op-sha1 arg))
    (`(syntax-class ,arg)
     (typespec-eval-op-syntax-class arg))
    (`(version-to-list ,arg)
     (typespec-eval-op-version-to-list arg))
    (`(version-list-not-zero ,lst)
     (typespec-eval-op-version-list-not-zero lst))
    (`(version-list-< ,lhs ,rhs)
     (typespec-eval-op-version-list-compare lhs rhs #'version-list-<))
    (`(version-list-<= ,lhs ,rhs)
     (typespec-eval-op-version-list-compare lhs rhs #'version-list-<=))
    (`(version-list-= ,lhs ,rhs)
     (typespec-eval-op-version-list-compare lhs rhs #'version-list-=))
    (`(version< ,lhs ,rhs)
     (typespec-eval-op-version-compare lhs rhs #'version<))
    (`(version<= ,lhs ,rhs)
     (typespec-eval-op-version-compare lhs rhs #'version<=))
    (`(version= ,lhs ,rhs)
     (typespec-eval-op-version-compare lhs rhs #'version=))
    (`(copy-tree ,tree . ,rest)
     (typespec-eval-op-copy-tree tree (car rest)))
    (`(delete-dups ,list)
     (typespec-eval-op-delete-dups list))
    (`(delete-consecutive-dups ,list . ,rest)
     (typespec-eval-op-delete-consecutive-dups list (car rest)))
    (`(remove ,elt ,sequence)
     (typespec-eval-op-remove-like elt sequence #'remove))
    (`(remq ,elt ,list)
     (typespec-eval-op-remove-like elt list #'remq t))
    (`(string-pad ,string ,length . ,rest)
     (typespec-eval-op-string-pad string length (car rest) (cadr rest)))
    (`(string-remove-prefix ,prefix ,string)
     (typespec-eval-op-binary-string-op prefix string #'string-remove-prefix))
    (`(string-remove-suffix ,suffix ,string)
     (typespec-eval-op-binary-string-op suffix string #'string-remove-suffix))
    (`(string-to-char ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-to-char #'stringp nil 'integer #'typespec-eval-types-string-type-p))
    (`(string-to-list ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-to-list #'stringp nil '(list integer) #'typespec-eval-types-string-type-p))
    (`(string-to-vector ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'string-to-vector #'stringp nil '(vector integer) #'typespec-eval-types-string-type-p))
    (`(string-equal ,lhs ,rhs)
     (typespec-eval-op-string-equal lhs rhs))
    (`(string-prefix-p ,prefix ,string . ,rest)
     (typespec-eval-op-string-prefix-p
      prefix
      string
      (car rest)))
    (`(string-suffix-p ,suffix ,string . ,rest)
     (typespec-eval-op-string-suffix-p
      suffix
      string
      (car rest)))
    (`(string< ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-lessp 'boolean))
    (`(string> ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-greaterp 'boolean))
    (`(string= ,lhs ,rhs)
     (typespec-eval-op-string-equal lhs rhs))
    (`(string-lessp ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-lessp 'boolean))
    (`(string-greaterp ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-greaterp 'boolean))
    (`(string-equal-ignore-case ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-equal-ignore-case 'boolean))
    (`(string-search ,needle ,haystack . ,rest)
     (typespec-eval-op-string-search needle haystack (car rest)))
    (`(string-split ,string . ,rest)
     (typespec-eval-op-string-split string (car rest) (cadr rest) (caddr rest)))
    (`(string-replace ,from ,to ,string)
     (typespec-eval-op-string-replace from to string))
    (`(string-truncate-left ,string ,n)
     (typespec-eval-op-string-truncate-left string n))
    (`(string-match-p ,regexp ,string . ,rest)
     (typespec-eval-op-string-match-p regexp string (car rest)))
    (`(string-to-multibyte ,string)
     (typespec-eval-op-string-unary string #'string-to-multibyte t))
    (`(string-to-unibyte ,string)
     (typespec-eval-op-string-unary string #'string-to-unibyte t))
    (`(string-chop-newline ,string)
     (typespec-eval-op-string-unary string #'string-chop-newline))
    (`(string-clean-whitespace ,string)
     (typespec-eval-op-string-unary string #'string-clean-whitespace))
    (`(string-limit ,string ,n)
     (typespec-eval-op-string-limit string n))
    (`(string-distance ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-distance 'integer))
    (`(string-version-lessp ,lhs ,rhs)
     (typespec-eval-op-binary-string-compare lhs rhs #'string-version-lessp 'boolean))
    (`(char-to-string ,char)
     (typespec-eval-op-char-to-string char))
    (`(make-string ,length ,char)
     (typespec-eval-op-make-string length char))
    (`(+ . ,args)
     (typespec-eval-op-arith args #'+ 0))
    (`(* . ,args)
     (typespec-eval-op-arith args #'* 1))
    (`(- . ,args)
     (typespec-eval-op-arith args #'- 0))
    (`(/ . ,args)
     (typespec-eval-op-arith args #'/))
    (`(% . ,args)
     (typespec-eval-op-rem args))
    (`(mod . ,args)
     (typespec-eval-op-mod args))
    (`(logand . ,args)
     (typespec-eval-op-integer-variadic args #'logand -1))
    (`(logior . ,args)
     (typespec-eval-op-integer-variadic args #'logior 0))
    (`(logxor . ,args)
     (typespec-eval-op-integer-variadic args #'logxor 0))
    (`(lognot ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'lognot #'integerp nil 'integer #'typespec-eval-types-integer-type-p))
    (`(logcount ,arg)
     (typespec-eval-simplify-unary-const-fold arg #'logcount #'integerp nil '(integer 0 *)
                        #'typespec-eval-types-integer-type-p))
    (`(ash ,value ,count)
     (typespec-eval-op-ash value count))
    (`(zerop ,arg)
     (typespec-eval-op-zerop arg))
    (`(isnan ,arg)
     (typespec-eval-op-isnan arg))
    (`(cl-signum ,arg)
     (typespec-eval-op-numeric-unary arg #'cl-signum))
    (`(number-sequence ,from . ,rest)
     (typespec-eval-op-number-sequence from (car rest) (cadr rest)))
    (`(1+ ,arg)
     (typespec-eval-op-numeric-unary arg #'1+))
    (`(1- ,arg)
     (typespec-eval-op-numeric-unary arg #'1-))
    (`(max . ,args)
     (typespec-eval-op-minmax args #'max))
    (`(min . ,args)
     (typespec-eval-op-minmax args #'min))
    (`(concat . ,args)
     (typespec-eval-op-concat args))
    (`int 'integer)
    ((pred symbolp)
     (let ((norm (typespec-eval-types-normalize form)))
       (if (eq norm form)
           form
         (typespec-eval--eval norm))))
    (_ 'unknown)))

(defun typespec-eval (form)
  "Evaluate FORM in the typespec value/type evaluator."
  (typespec-eval--eval form))

(defun typespec-eval-call--normalize-argspecs (argspecs)
  "Normalize ARGSPECS and return (NORMALIZED ALLOW-OTHER-KEYS)."
  (let* ((allow-other-keys (memq '&allow-other-keys argspecs))
         (argspecs (mapcar (lambda (spec) (if (eq spec '&key) '&keys spec))
                           argspecs))
         (argspecs (delq '&allow-other-keys argspecs))
         (argspecs (typespec-eval-op-argspecs argspecs)))
    (list argspecs allow-other-keys)))

(defun typespec-eval-call--split-argspecs (argspecs)
  "Split normalized ARGSPECS into required/optional/rest/keys."
  (let (required optional rest-type keys-type state)
    (setq state 'required)
    (dolist (spec argspecs)
      (pcase spec
        ('&optional (setq state 'optional))
        ('&rest (setq state 'rest))
        ('&keys (setq state 'keys))
        (_
         (pcase state
           ('required (push spec required))
           ('optional (push spec optional))
           ('rest (setq rest-type spec state 'rest-done))
           ('keys (setq keys-type spec state 'keys-done))))))
    (list :required (nreverse required)
          :optional (nreverse optional)
          :rest rest-type
          :keys keys-type)))

(defun typespec-eval-call--type-compatible-p (value expected)
  "Return non-nil if VALUE is compatible with EXPECTED."
  (let ((value (typespec-eval--eval value))
        (expected (typespec-eval--eval expected)))
    (cond
     ((memq expected '(mixed unknown t)) t)
     ((and (symbolp value) (symbolp expected))
      (typespec-eval-types-type-subtype-p value expected))
     ((equal value expected) t)
     ((typespec-eval--const-p value)
      (let* ((val (typespec-eval--const-value value))
             (cat (typespec-eval-types-type-category-with-guard expected)))
        (pcase cat
          ('integer (integerp val))
          ('float (floatp val))
          ('number (numberp val))
          ('string (stringp val))
          ('symbol (symbolp val))
          ('list (listp val))
          ('vector (vectorp val))
          ('boolean (memq val '(t nil)))
          (_ nil))))
     ((and (consp expected) (eq (car expected) 'or))
      (seq-some (lambda (item)
                  (typespec-eval-call--type-compatible-p value item))
                (cdr expected)))
     ((and (consp expected) (eq (car expected) 'and))
      (seq-every-p (lambda (item)
                     (typespec-eval-call--type-compatible-p value item))
                   (cdr expected)))
     ((eq (typespec-eval-op-and (list value expected)) 'never) nil)
     (t t))))

(defun typespec-eval-call--check-key-args (keys-type args allow-other-keys)
  "Validate keyword ARGS against KEYS-TYPE.
Return nil on success or a `(:cause-error ...)` form."
  (let ((pairs (seq-partition args 2)))
    (catch 'error
      (dolist (pair pairs)
        (let* ((key (typespec-eval--eval (car pair)))
               (val (typespec-eval--eval (cadr pair))))
          (cond
           ((typespec-eval-struct-plist-form-p keys-type)
            (let ((key-type (typespec-eval-struct-plist-key-type keys-type))
                  (val-type (typespec-eval-struct-plist-value-type keys-type)))
              (unless (typespec-eval-call--type-compatible-p key key-type)
                (throw 'error
                       (typespec-eval--make-cause-error
                        (list 'wrong-type-argument key-type
                              (typespec-eval--unconst key)))))
              (unless (typespec-eval-call--type-compatible-p val val-type)
                (throw 'error
                       (typespec-eval--make-cause-error
                        (list 'wrong-type-argument val-type
                              (typespec-eval--unconst val)))))))
           ((typespec-eval-struct-plist-of-p keys-type)
            (let* ((keyval (and (typespec-eval--const-p key)
                                (typespec-eval--const-value key)))
                   (entry-type (and keyval
                                    (typespec-eval-struct-plist-of-entry-type
                                     keys-type keyval))))
              (cond
               (entry-type
                (unless (typespec-eval-call--type-compatible-p val entry-type)
                  (throw 'error
                         (typespec-eval--make-cause-error
                          (list 'wrong-type-argument entry-type
                                (typespec-eval--unconst val))))))
               (allow-other-keys nil)
               (t
                (throw 'error
                       (typespec-eval--make-cause-error
                        (list 'wrong-type-argument keys-type
                              (typespec-eval--unconst key))))))))
           (t nil))))
      nil)))

(defun typespec-eval-call--substitute (form sym value)
  "Substitute SYM with VALUE inside FORM."
  (cond
   ((eq form sym) value)
   ((consp form)
    (mapcar (lambda (item)
              (typespec-eval-call--substitute item sym value))
            form))
   (t form)))

(defun typespec-eval-call (funspec args)
  "Evaluate application of FUNSPEC to ARGS.
Return a typespec result or a `(:cause-error ...)' form."
  (declare (ftype (function (t list) t)))
  (cl-block typespec-eval-call--
    (let ((vars nil)
          (body funspec))
      (pcase funspec
        (`(:forall ,binders ,form)
         (setq vars binders)
         (setq body form)))
      (let ((func (typespec-eval--eval body)))
        (pcase func
          (`(function ,argspecs ,ret)
           (pcase-let* ((`(,norm-argspecs ,allow-other-keys)
                         (typespec-eval-call--normalize-argspecs argspecs)))
             (when (eq norm-argspecs :invalid)
               (cl-return-from typespec-eval-call-- 'unknown))
             (pcase-let* ((`(:required ,required :optional ,optional
                                       :rest ,rest-type :keys ,keys-type)
                           (typespec-eval-call--split-argspecs norm-argspecs))
                          (args (mapcar #'typespec-eval--eval args))
                          (nargs (length args))
                          (nreq (length required))
                          (nopt (length optional)))
               (when (< nargs nreq)
                 (cl-return-from typespec-eval-call--
                   (typespec-eval--make-cause-error
                    (list 'wrong-number-of-arguments nargs))))
               (let* ((positional (min nargs (+ nreq nopt)))
                      (pos-args (seq-subseq args 0 positional))
                      (rest-args (seq-subseq args positional))
                      (bindings nil))
               (let ((expected (append required optional)))
                 (cl-labels
                     ((bind-var (var value)
                        (when (and (symbolp var) (memq var vars))
                          (let ((prev (assoc var bindings)))
                            (if prev
                                (when (eq (typespec-eval-op-and
                                           (list (cdr prev) value))
                                          'never)
                                  (cl-return-from typespec-eval-call--
                                    (typespec-eval--make-cause-error
                                     (list 'wrong-type-argument var
                                           (typespec-eval--unconst value)))))
                              (push (cons var value) bindings))))))
                   (dotimes (idx positional)
                     (let ((exp (nth idx expected))
                           (arg (nth idx pos-args)))
                       (if (and (symbolp exp) (memq exp vars))
                           (bind-var exp arg)
                         (unless (typespec-eval-call--type-compatible-p arg exp)
                           (cl-return-from typespec-eval-call--
                             (typespec-eval--make-cause-error
                              (list 'wrong-type-argument exp
                                    (typespec-eval--unconst arg))))))))
                   (cond
                    (keys-type
                     (when (and rest-args (cl-oddp (length rest-args)))
                       (cl-return-from typespec-eval-call--
                         (typespec-eval--make-cause-error
                          (list 'wrong-number-of-arguments nargs))))
                     (when-let ((err (typespec-eval-call--check-key-args
                                      keys-type rest-args allow-other-keys)))
                       (cl-return-from typespec-eval-call-- err)))
                    (rest-type
                     (dolist (arg rest-args)
                       (unless (typespec-eval-call--type-compatible-p arg rest-type)
                         (cl-return-from typespec-eval-call--
                           (typespec-eval--make-cause-error
                            (list 'wrong-type-argument rest-type
                                  (typespec-eval--unconst arg)))))))
                    (t
                     (when rest-args
                       (cl-return-from typespec-eval-call--
                         (typespec-eval--make-cause-error
                          (list 'wrong-number-of-arguments nargs)))))))
                 (let ((ret (typespec-eval--eval ret)))
                   (dolist (binding bindings)
                     (setq ret (typespec-eval-call--substitute
                                ret (car binding) (cdr binding))))
                   (pcase ret
                     (`(:guard ,_) 'boolean)
                     (`(:guard! ,_) 'boolean)
                     (`(:assert ,type) type)
                     (_ ret))))))))
          (_ 'unknown))))))

(provide 'typespec-eval)
;;; typespec-eval.el ends here
