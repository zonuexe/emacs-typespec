;;; typespec-eval-numeric.el --- Numeric range processing for typespec  -*- lexical-binding: t; -*-

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

;; Numeric range processing for typespec evaluation.
;; This module provides:
;; - Integer and float range construction and normalization
;; - Numeric range info plist extraction and conversion
;; - Range arithmetic operations
;; - Range comparison and bound helpers

;;; Code:

(require 'seq)
(require 'typespec-eval-core)
(require 'typespec-eval-types)
(require 'typespec-eval-simplify)

;;; Float bound helpers

(defun typespec-eval-numeric-float-range-bound (bound)
  "Normalize float range BOUND to a float or `*`."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) (float bound))
   ((and (consp bound) (numberp (car bound))) (float (car bound)))
   (t nil)))

(defsubst typespec-eval-numeric-float-bound-value (bound)
  "Return numeric value for float BOUND, or nil for `*`."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) (float bound))
   ((and (consp bound) (numberp (car bound))) (float (car bound)))
   (t nil)))

(defsubst typespec-eval-numeric-float-bound-exclusive-p (bound)
  "Return non-nil if float BOUND is exclusive."
  (and (consp bound) (numberp (car bound))))

(defsubst typespec-eval-numeric-float-bound-integer-p (bound)
  "Return non-nil if float BOUND is an exclusive integer boundary."
  (and (consp bound) (integerp (car bound))))

(defsubst typespec-eval-numeric-number-bound-value (bound)
  "Return numeric value for number BOUND, or nil for `*`."
  (cond
   ((eq bound '*) nil)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (car bound))
   (t nil)))

(defsubst typespec-eval-numeric-number-bound-exclusive-p (bound)
  "Return non-nil if number BOUND is exclusive."
  (and (consp bound) (numberp (car bound))))

(defsubst typespec-eval-numeric-number-range-bound (bound)
  "Normalize number range BOUND to a number or `*`."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) bound)
   ((and (consp bound) (numberp (car bound))) (car bound))
   (t nil)))

(defsubst typespec-eval-numeric-float-bound (value exclusive)
  "Return a float bound for VALUE with EXCLUSIVE."
  (if (eq value '*) '*
    (if exclusive (list value) value)))

(defsubst typespec-eval-numeric-float-bound-shift (bound delta)
  "Return BOUND shifted by DELTA, preserving exclusivity."
  (cond
   ((eq bound '*) '*)
   ((numberp bound) (+ bound delta))
   ((and (consp bound) (numberp (car bound)))
    (list (+ (car bound) delta)))
   (t nil)))

;;; Integer range construction

(defun typespec-eval-numeric-integer-range-from (form)
  "Return an `(integer LOW HIGH)` range for FORM, or nil."
  (cond
   ((typespec-eval--integer-range-p form) form)
   ((eq form 'positive-int) (typespec-eval--integer-range 1 '*))
   ((eq form 'non-negative-int) (typespec-eval--integer-range 0 '*))
   ((eq form 'negative-int) (typespec-eval--integer-range '* -1))
   ((eq form 'non-positive-int) (typespec-eval--integer-range '* 0))
   ((eq form 'fixnum)
    (typespec-eval--integer-range most-negative-fixnum most-positive-fixnum))
   ((memq form '(int integer bignum))
    (typespec-eval--integer-range '* '*))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (integerp val)
        (typespec-eval--integer-range val val))))
   (t nil)))

(defsubst typespec-eval-numeric-range-preserving-integer-type-p (form)
  "Return non-nil if FORM should preserve its integer range."
  (memq form '(positive-int non-negative-int negative-int non-positive-int)))

;;; Float range construction

(defsubst typespec-eval-numeric-float-range-includes-zero-p (range)
  "Return non-nil if float RANGE includes 0.0."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval-numeric-float-bound-value low))
         (highv (typespec-eval-numeric-float-bound-value high))
         (low-excl (typespec-eval-numeric-float-bound-exclusive-p low))
         (high-excl (typespec-eval-numeric-float-bound-exclusive-p high)))
    (and (or (null lowv) (< lowv 0.0) (and (= lowv 0.0) (not low-excl)))
         (or (null highv) (> highv 0.0) (and (= highv 0.0) (not high-excl))))))

(defsubst typespec-eval-numeric-float-range-signum (range)
  "Return the `cl-signum` result for float RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval-numeric-float-bound-value low))
         (highv (typespec-eval-numeric-float-bound-value high))
         (low-excl (typespec-eval-numeric-float-bound-exclusive-p low))
         (high-excl (typespec-eval-numeric-float-bound-exclusive-p high))
         (can-neg (or (null lowv) (< lowv 0.0)))
         (can-pos (or (null highv) (> highv 0.0)))
         (can-zero (and (or (null lowv) (< lowv 0.0) (and (= lowv 0.0) (not low-excl)))
                        (or (null highv) (> highv 0.0) (and (= highv 0.0) (not high-excl)))))
         (opts nil))
    (when can-neg (push -1.0 opts))
    (when can-zero (push 0.0 opts))
    (when can-pos (push 1.0 opts))
    (when opts
      (typespec-eval-simplify-or
       (mapcar #'typespec-eval--make-const (nreverse opts))))))

(defun typespec-eval-numeric-float-range-from (form)
  "Return a `(float LOW HIGH)` range for FORM, or nil."
  (cond
   ((eq form 'positive-float)
    (typespec-eval--float-range '(0) '*))
   ((eq form 'negative-float)
    (typespec-eval--float-range '* '(0)))
   ((eq form 'non-negative-float)
    (typespec-eval--float-range 0.0 '*))
   ((eq form 'non-positive-float)
    (typespec-eval--float-range '* 0.0))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (numberp val)
        (typespec-eval--float-range (float val) (float val)))))
   ((typespec-eval--float-range-p form)
    (let ((low (typespec-eval-numeric-float-range-bound (cadr form)))
          (high (typespec-eval-numeric-float-range-bound (caddr form))))
      (when (and low high)
        (typespec-eval--float-range low high))))
   ((typespec-eval--integer-range-p form)
    (let ((low (cadr form))
          (high (caddr form)))
      (when (and (numberp low) (numberp high))
        (typespec-eval--float-range (float low) (float high)))))
   ((typespec-eval-types-float-type-p form)
    (typespec-eval--float-range '* '*))
   ((typespec-eval-types-integer-type-p form)
    (typespec-eval--float-range '* '*))
   (t nil)))

;;; Number/real range construction

(defun typespec-eval-numeric-number-range-from (form)
  "Return a `(number LOW HIGH)` or `(real LOW HIGH)` range for FORM, or nil."
  (cond
   ((typespec-eval--number-range-p form)
    (let ((low (typespec-eval-numeric-number-range-bound (cadr form)))
          (high (typespec-eval-numeric-number-range-bound (caddr form))))
      (when (and low high)
        (list 'number low high))))
   ((typespec-eval--real-range-p form)
    (let ((low (typespec-eval-numeric-number-range-bound (cadr form)))
          (high (typespec-eval-numeric-number-range-bound (caddr form))))
      (when (and low high)
        (list 'real low high))))
   ((memq form '(number real))
    (list form '* '*))
   ((typespec-eval--integer-range-p form)
    (let ((low (typespec-eval-numeric-number-range-bound (cadr form)))
          (high (typespec-eval-numeric-number-range-bound (caddr form))))
      (when (and low high)
        (list 'number low high))))
   ((typespec-eval--float-range-p form)
    (let ((low (typespec-eval-numeric-number-range-bound (cadr form)))
          (high (typespec-eval-numeric-number-range-bound (caddr form))))
      (when (and low high)
        (list 'number low high))))
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (numberp val)
        (list 'number val val))))
   (t nil)))

;;; Unified numeric range info

(defun typespec-eval-numeric-numeric-range-info (form)
  "Return numeric range info plist for FORM with :type annotation.
The plist contains :type (integer or float), :low, :high, :low-excl, :high-excl."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (numberp val)
        (list :type (if (integerp val) 'integer 'float)
              :low val :high val :low-excl nil :high-excl nil))))
   ((typespec-eval--float-range-p form)
    (let* ((low (cadr form))
           (high (caddr form))
           (lowv (typespec-eval-numeric-float-bound-value low))
           (highv (typespec-eval-numeric-float-bound-value high))
           (low-excl (typespec-eval-numeric-float-bound-exclusive-p low))
           (high-excl (typespec-eval-numeric-float-bound-exclusive-p high)))
      (list :type 'float :low lowv :high highv :low-excl low-excl :high-excl high-excl)))
   ((or (typespec-eval--number-range-p form)
        (typespec-eval--real-range-p form))
    (let* ((low (cadr form))
           (high (caddr form))
           (lowv (typespec-eval-numeric-number-bound-value low))
           (highv (typespec-eval-numeric-number-bound-value high))
           (low-excl (typespec-eval-numeric-number-bound-exclusive-p low))
           (high-excl (typespec-eval-numeric-number-bound-exclusive-p high)))
      (list :type (if (eq (car form) 'real) 'real 'number)
            :low lowv :high highv :low-excl low-excl :high-excl high-excl)))
   (t
    (let ((irange (typespec-eval-numeric-integer-range-from form)))
      (if irange
          (let ((low (typespec-eval-types-integer-bound-min (cadr irange)))
                (high (typespec-eval-types-integer-bound-max (caddr irange))))
            (list :type 'integer :low low :high high :low-excl nil :high-excl nil))
        (let ((frange (typespec-eval-numeric-float-range-from form)))
          (when frange
            (let* ((low (cadr frange))
                   (high (caddr frange)))
              (list :type 'float :low low :high high :low-excl nil :high-excl nil)))))))))

(defun typespec-eval-numeric-numeric-range-to-form (info)
  "Convert numeric range INFO back to a typespec form.
INFO must have :type, :low, :high, :low-excl, :high-excl.
Returns simple type symbol for fully unbounded ranges.
Alias types are normalized to canonical range forms."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (cond
     ;; Singleton value
     ((and (numberp low) (numberp high) (= low high)
           (not low-excl) (not high-excl))
      (typespec-eval--make-const (if (eq type 'float) (float low) low)))
     ;; Fully unbounded range -> simple type symbol
     ((and (null low) (null high))
      type)
     ;; Integer range (always use canonical form)
     ((eq type 'integer)
      (let ((lo (if low-excl (and (numberp low) (1+ low)) low))
            (hi (if high-excl (and (numberp high) (1- high)) high)))
        ;; Check if range matches fixnum bounds exactly
        (cond
         ((and (numberp lo) (numberp hi)
               (= lo most-negative-fixnum) (= hi most-positive-fixnum)
               (not low-excl) (not high-excl))
          'fixnum)
         (t
         (typespec-eval--integer-range (or lo '*) (or hi '*))))))
     ;; Number/real range
     ((memq type '(number real))
      (let ((lo (cond ((null low) '*)
                      (low-excl (list low))
                      (t low)))
            (hi (cond ((null high) '*)
                      (high-excl (list high))
                      (t high))))
        (if (eq type 'real)
            (typespec-eval--real-range lo hi)
          (typespec-eval--number-range lo hi))))
     ;; Float range - ensure float values
     (t
      (let ((lo (cond ((null low) '*)
                      (low-excl (list (float low)))
                      (t (float low))))
            (hi (cond ((null high) '*)
                      (high-excl (list (float high)))
                      (t (float high)))))
        (typespec-eval--float-range lo hi))))))

;;; Numeric range predicates

(defun typespec-eval-numeric-numeric-range-singleton-p (info)
  "Return non-nil if INFO describes a single numeric value."
  (let ((low (plist-get info :low))
        (high (plist-get info :high)))
    (and (numberp low)
         (numberp high)
         (= low high)
         (not (plist-get info :low-excl))
         (not (plist-get info :high-excl)))))

(defsubst typespec-eval-numeric-numeric-range-positive-p (info)
  "Return non-nil if INFO describes a positive range."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (numberp low)
         (or (> low 0) (and (= low 0) low-excl))
         (or (null high)
             (> high 0)
             (and (= high 0) high-excl)))))

(defun typespec-eval-numeric-numeric-range-negative-p (info)
  "Return non-nil if INFO describes a negative range."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (numberp high)
         (or (< high 0) (and (= high 0) high-excl))
         (or (null low)
             (< low 0)
             (and (= low 0) low-excl)))))

(defun typespec-eval-numeric-numeric-range-includes-zero-p (info)
  "Return non-nil if INFO includes zero."
  (let ((low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (and (or (null low) (<= low 0))
         (or (null high) (<= 0 high))
         (not (and (numberp low) (= low 0) low-excl))
         (not (and (numberp high) (= high 0) high-excl)))))

;;; Numeric min/max helpers

(defsubst typespec-eval-numeric-numeric-min (a b)
  "Return minimum of A and B when both are numbers."
  (cond
   ((and (numberp a) (numberp b)) (min a b))
   (a a)
   (b b)
   (t nil)))

(defsubst typespec-eval-numeric-numeric-max (a b)
  "Return maximum of A and B when both are numbers."
  (cond
   ((and (numberp a) (numberp b)) (max a b))
   (a a)
   (b b)
   (t nil)))

;;; Unified numeric range operations

(defun typespec-eval-numeric-numeric-range-shift (info delta)
  "Return INFO shifted by DELTA.
For float ranges, exclusivity is cleared when shifting since the exact
boundary value changes."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high)))
    ;; For floats, shifting clears exclusivity (conservative approach)
    ;; For integers, exclusivity can be preserved in concept but we clear it
    ;; since the shifted value is different
    (list :type type
          :low (and (numberp low) (+ low delta))
          :high (and (numberp high) (+ high delta))
          :low-excl nil
          :high-excl nil)))

(defun typespec-eval-numeric-numeric-range-abs (info)
  "Compute absolute value range for INFO."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl)))
    (cond
     ;; Unbounded on both sides
     ((and (null low) (null high))
      (list :type type :low 0 :high nil :low-excl nil :high-excl nil))
     ;; Unbounded below
     ((null low)
      (if (and high (<= high 0))
          ;; All non-positive -> [|high|, *)
          (list :type type :low (abs high) :high nil
                :low-excl high-excl :high-excl nil)
        ;; Crosses zero -> [0, *)
        (list :type type :low 0 :high nil :low-excl nil :high-excl nil)))
     ;; Unbounded above
     ((null high)
      (if (>= low 0)
          ;; All non-negative -> [low, *)
          (list :type type :low low :high nil :low-excl low-excl :high-excl nil)
        ;; Crosses zero -> [0, *)
        (list :type type :low 0 :high nil :low-excl nil :high-excl nil)))
     ;; Bounded
     ((and (numberp low) (numberp high))
      (cond
       ;; All non-negative: [low, high]
       ((>= low 0)
        (list :type type :low low :high high :low-excl low-excl :high-excl high-excl))
       ;; All non-positive: [|high|, |low|]
       ((<= high 0)
        (list :type type :low (abs high) :high (abs low)
              :low-excl high-excl :high-excl low-excl))
       ;; Crosses zero: [0, max(|low|, |high|)]
       (t
        (let* ((abs-low (abs low))
               (abs-high (abs high))
               (max-abs (max abs-low abs-high))
               (max-excl (cond
                          ((> abs-low abs-high) low-excl)
                          ((> abs-high abs-low) high-excl)
                          (t (and low-excl high-excl)))))
          (list :type type :low 0 :high max-abs :low-excl nil :high-excl max-excl)))))
     (t nil))))

(defun typespec-eval-numeric-numeric-range-signum (info)
  "Return signum result options as a simplified or-form for INFO."
  (let ((type (plist-get info :type))
        (low (plist-get info :low))
        (high (plist-get info :high))
        (low-excl (plist-get info :low-excl))
        (high-excl (plist-get info :high-excl))
        (opts nil))
    (when (memq type '(number real))
      (setq type 'number))
    ;; Check if range can be negative
    (when (or (null low) (< low 0))
      (if (eq type 'number)
          (setq opts (append opts '(-1 -1.0)))
        (push (if (eq type 'float) -1.0 -1) opts)))
    ;; Check if range includes zero
    (when (and (or (null low) (< low 0) (and (= low 0) (not low-excl)))
               (or (null high) (> high 0) (and (= high 0) (not high-excl))))
      (if (eq type 'number)
          (setq opts (append opts '(0 0.0)))
        (push (if (eq type 'float) 0.0 0) opts)))
    ;; Check if range can be positive
    (when (or (null high) (> high 0))
      (if (eq type 'number)
          (setq opts (append opts '(1 1.0)))
        (push (if (eq type 'float) 1.0 1) opts)))
    (when opts
      (typespec-eval-simplify-or
       (mapcar #'typespec-eval--make-const (nreverse opts))))))

(defun typespec-eval-numeric-numeric-range-unary (info fn)
  "Apply unary FN to numeric range INFO.
Returns a new info plist for shift operations, or a result form for signum/abs."
  (cond
   ((memq fn (list #'1+ #'1-))
    (let ((delta (if (eq fn #'1+) 1 -1)))
      (typespec-eval-numeric-numeric-range-shift info delta)))
   ((eq fn #'abs)
    (typespec-eval-numeric-numeric-range-abs info))
   ((eq fn #'cl-signum)
    (typespec-eval-numeric-numeric-range-signum info))
   (t nil)))

;;; Range comparison

(defun typespec-eval-numeric-numeric-range-disjoint-p (lhs rhs)
  "Return non-nil if numeric ranges LHS and RHS are disjoint."
  (let ((lhigh (plist-get lhs :high))
        (lhigh-excl (plist-get lhs :high-excl))
        (llow (plist-get lhs :low))
        (llow-excl (plist-get lhs :low-excl))
        (rhigh (plist-get rhs :high))
        (rhigh-excl (plist-get rhs :high-excl))
        (rlow (plist-get rhs :low))
        (rlow-excl (plist-get rhs :low-excl)))
    (or (and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow) (or lhigh-excl rlow-excl))))
        (and (numberp rhigh) (numberp llow)
             (or (< rhigh llow)
                 (and (= rhigh llow) (or rhigh-excl llow-excl)))))))

(defun typespec-eval-numeric-numeric-range-compare (lhs rhs pred)
  "Return t/nil if PRED is decidable for LHS and RHS, else `unknown`."
  (let ((llow (plist-get lhs :low))
        (llow-excl (plist-get lhs :low-excl))
        (lhigh (plist-get lhs :high))
        (lhigh-excl (plist-get lhs :high-excl))
        (rlow (plist-get rhs :low))
        (rlow-excl (plist-get rhs :low-excl))
        (rhigh (plist-get rhs :high))
        (rhigh-excl (plist-get rhs :high-excl)))
    (cond
     ((eq pred #'<)
      (cond
       ((and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow) (or lhigh-excl rlow-excl))))
        t)
       ((and (numberp llow) (numberp rhigh)
             (>= llow rhigh))
        nil)
       (t 'unknown)))
     ((eq pred #'>)
      (typespec-eval-numeric-numeric-range-compare rhs lhs #'<))
     ((eq pred #'<=)
      (cond
       ((and (numberp lhigh) (numberp rlow)
             (or (< lhigh rlow)
                 (and (= lhigh rlow)
                      (not lhigh-excl)
                      (not rlow-excl))))
        t)
       ((and (numberp llow) (numberp rhigh)
             (or (> llow rhigh)
                 (and (= llow rhigh) (or llow-excl rhigh-excl))))
        nil)
       (t 'unknown)))
     ((eq pred #'>=)
      (typespec-eval-numeric-numeric-range-compare rhs lhs #'<=))
     ((eq pred #'/=)
      (cond
       ((and (typespec-eval-numeric-numeric-range-singleton-p lhs)
             (typespec-eval-numeric-numeric-range-singleton-p rhs))
        (not (= llow rlow)))
       ((typespec-eval-numeric-numeric-range-disjoint-p lhs rhs) t)
       (t 'unknown)))
     (t 'unknown))))

;;; Float range absolute value

(defsubst typespec-eval-numeric-float-range-abs (range)
  "Return the absolute-value range for RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval-numeric-float-bound-value low))
         (highv (typespec-eval-numeric-float-bound-value high))
         (low-excl (typespec-eval-numeric-float-bound-exclusive-p low))
         (high-excl (typespec-eval-numeric-float-bound-exclusive-p high)))
    (cond
     ((and (null lowv) (null highv))
      (typespec-eval--float-range 0.0 '*))
     ((null lowv)
      (if (and highv (<= highv 0.0))
          (typespec-eval--float-range
           (typespec-eval-numeric-float-bound (abs highv) high-excl)
           '*)
        (typespec-eval--float-range 0.0 '*)))
     ((null highv)
      (if (>= lowv 0.0)
          (typespec-eval--float-range
           (typespec-eval-numeric-float-bound lowv low-excl)
           '*)
        (typespec-eval--float-range 0.0 '*)))
     ((and (numberp lowv) (numberp highv))
      (cond
       ((>= lowv 0.0)
        (typespec-eval--float-range
         (typespec-eval-numeric-float-bound lowv low-excl)
         (typespec-eval-numeric-float-bound highv high-excl)))
       ((<= highv 0.0)
        (typespec-eval--float-range
         (typespec-eval-numeric-float-bound (abs highv) high-excl)
         (typespec-eval-numeric-float-bound (abs lowv) low-excl)))
       (t
        (let* ((abs-low (abs lowv))
               (abs-high (abs highv))
               (max-abs (max abs-low abs-high))
               (max-excl
                (cond
                 ((> abs-low abs-high) low-excl)
                 ((> abs-high abs-low) high-excl)
                 (t (and low-excl high-excl)))))
          (typespec-eval--float-range
           0.0
           (typespec-eval-numeric-float-bound max-abs max-excl))))))
     (t nil))))

;;; Float rounding range

(defun typespec-eval-numeric-float-rounding-range (range kind)
  "Return an integer range for rounding KIND over float RANGE."
  (let* ((low (cadr range))
         (high (caddr range))
         (lowv (typespec-eval-numeric-float-bound-value low))
         (highv (typespec-eval-numeric-float-bound-value high)))
    (cond
     ((or (null lowv) (null highv)) 'integer)
     ((eq kind 'floor)
      (let* ((min (floor lowv))
             (max (floor highv)))
        (when (and (typespec-eval-numeric-float-bound-integer-p high)
                   (integerp max))
          (setq max (1- max)))
        (typespec-eval--integer-range min max)))
     ((eq kind 'ceiling)
      (let* ((min (ceiling lowv))
             (max (ceiling highv)))
        (when (and (typespec-eval-numeric-float-bound-integer-p low)
                   (integerp min))
          (setq min (1+ min)))
        (typespec-eval--integer-range min max)))
     ((eq kind 'truncate)
      (cond
       ((>= lowv 0.0)
        (typespec-eval-numeric-float-rounding-range range 'floor))
       ((<= highv 0.0)
        (typespec-eval-numeric-float-rounding-range range 'ceiling))
       (t
        (let* ((min (ceiling lowv))
               (max (floor highv)))
          (when (and (typespec-eval-numeric-float-bound-integer-p low)
                     (integerp min))
            (setq min (1+ min)))
          (when (and (typespec-eval-numeric-float-bound-integer-p high)
                     (integerp max))
            (setq max (1- max)))
          (typespec-eval--integer-range min max)))))
     ((eq kind 'round)
      (let* ((min (round lowv))
             (max (round highv)))
        (when (and (typespec-eval-numeric-float-bound-integer-p low)
                   (integerp min))
          (setq min (1+ min)))
        (when (and (typespec-eval-numeric-float-bound-integer-p high)
                   (integerp max))
          (setq max (1- max)))
        (typespec-eval--integer-range min max)))
     (t 'integer))))

;;; Float range arithmetic

(defun typespec-eval-numeric-float-range-combine (lhs rhs op)
  "Combine float ranges LHS and RHS using OP, returning a float range or nil."
  (let* ((low1 (cadr lhs))
         (high1 (caddr lhs))
         (low2 (cadr rhs))
         (high2 (caddr rhs)))
    (pcase op
      (`+
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range
            (if (or (eq low1 '*) (eq low2 '*)) '* (+ low1 low2))
            (if (or (eq high1 '*) (eq high2 '*)) '* (+ high1 high2)))
         (typespec-eval--float-range (+ low1 low2) (+ high1 high2))))
      (`-
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range
            (if (or (eq low1 '*) (eq high2 '*)) '* (- low1 high2))
            (if (or (eq high1 '*) (eq low2 '*)) '* (- high1 low2)))
         (typespec-eval--float-range (- low1 high2) (- high1 low2))))
      (`*
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (typespec-eval--float-range '* '*)
         (let* ((candidates (list (* low1 low2) (* low1 high2)
                                  (* high1 low2) (* high1 high2)))
                (minv (apply #'min candidates))
                (maxv (apply #'max candidates)))
           (typespec-eval--float-range minv maxv))))
      (`/
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           nil
         (let ((zero-in-range (and (<= (min low2 high2) 0.0)
                                   (<= 0.0 (max low2 high2)))))
           (unless zero-in-range
             (let* ((candidates (list (/ low1 low2) (/ low1 high2)
                                      (/ high1 low2) (/ high1 high2)))
                    (minv (apply #'min candidates))
                    (maxv (apply #'max candidates)))
               (typespec-eval--float-range minv maxv))))))
      (_ nil))))

(defun typespec-eval-numeric-number-range-combine (lhs rhs op)
  "Combine number ranges LHS and RHS using OP, returning a range or nil."
  (let* ((low1 (cadr lhs))
         (high1 (caddr lhs))
         (low2 (cadr rhs))
         (high2 (caddr rhs))
         (kind (if (or (eq (car lhs) 'number) (eq (car rhs) 'number))
                   'number
                 'real)))
    (pcase op
      (`+
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (list kind
                 (if (or (eq low1 '*) (eq low2 '*)) '* (+ low1 low2))
                 (if (or (eq high1 '*) (eq high2 '*)) '* (+ high1 high2)))
         (list kind (+ low1 low2) (+ high1 high2))))
      (`-
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (list kind
                 (if (or (eq low1 '*) (eq high2 '*)) '* (- low1 high2))
                 (if (or (eq high1 '*) (eq low2 '*)) '* (- high1 low2)))
         (list kind (- low1 high2) (- high1 low2))))
      (`*
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           (list kind '* '*)
         (let* ((candidates (list (* low1 low2) (* low1 high2)
                                  (* high1 low2) (* high1 high2)))
                (minv (apply #'min candidates))
                (maxv (apply #'max candidates)))
           (list kind minv maxv))))
      (`/
       (if (or (eq low1 '*) (eq low2 '*) (eq high1 '*) (eq high2 '*))
           nil
         (let ((zero-in-range (and (<= (min low2 high2) 0.0)
                                   (<= 0.0 (max low2 high2)))))
           (unless zero-in-range
             (let* ((candidates (list (/ low1 low2) (/ low1 high2)
                                      (/ high1 low2) (/ high1 high2)))
                    (minv (apply #'min candidates))
                    (maxv (apply #'max candidates)))
               (list kind minv maxv))))))
      (_ nil))))

(defun typespec-eval-numeric-number-range-arith (args op)
  "Try to compute a number/real range for ARGS using OP."
  (when (seq-some (lambda (arg)
                    (or (typespec-eval--number-range-p arg)
                        (typespec-eval--real-range-p arg)
                        (memq arg '(number real))))
                  args)
    (let ((ranges (mapcar #'typespec-eval-numeric-number-range-from args)))
      (when (seq-every-p #'identity ranges)
        (let ((result (car ranges)))
          (dolist (range (cdr ranges))
            (setq result (typespec-eval-numeric-number-range-combine result range op)))
          (if (and (consp result)
                   (memq (car result) '(number real))
                   (eq (cadr result) '*)
                   (eq (caddr result) '*))
              (car result)
            result))))))

(defun typespec-eval-numeric-float-range-arith (args op)
  "Try to compute a float range for ARGS using OP."
  (when (seq-some #'typespec-eval--float-range-p args)
    (let ((ranges (mapcar #'typespec-eval-numeric-float-range-from args)))
      (when (seq-every-p #'identity ranges)
        (let ((result (car ranges)))
          (dolist (range (cdr ranges))
            (setq result (typespec-eval-numeric-float-range-combine result range op)))
          result)))))

;;; Integer range arithmetic

(defun typespec-eval-numeric-const-integer-options (form)
  "Return a list of integer constants represented by FORM, or nil."
  (cond
   ((typespec-eval--const-p form)
    (let ((val (typespec-eval--const-value form)))
      (when (integerp val) (list val))))
   ((and (consp form) (eq (car form) 'or))
    (let ((values nil)
          (ok t))
      (dolist (item (cdr form))
        (let ((opts (typespec-eval-numeric-const-integer-options item)))
          (if opts
              (setq values (append values opts))
            (setq ok nil))))
      (when ok values)))
   ((typespec-eval--integer-range-p form)
    (let ((low (cadr form))
          (high (caddr form)))
      (when (and (integerp low)
                 (integerp high)
                 (<= 0 (- high low))
                 (<= (- high low) typespec-eval--arith-option-limit))
        (number-sequence low high))))
   (t nil)))

(defun typespec-eval-numeric-arith-const-options (args op)
  "Return a simplified `(or ...)` for ARGS and OP when options are finite.
Return nil when options cannot be enumerated or exceed the limit."
  (let ((options (mapcar #'typespec-eval-numeric-const-integer-options args)))
    (when (seq-every-p #'identity options)
      (catch 'typespec-eval--arith
        (let ((results (car options)))
          (dolist (opts (cdr options))
            (let ((next nil))
              (dolist (lhs results)
                (dolist (rhs opts)
                  (push (funcall op lhs rhs) next)
                  (when (> (length next) typespec-eval--arith-option-limit)
                    (throw 'typespec-eval--arith nil))))
              (setq results (nreverse next))))
          (let* ((uniq (delete-dups (sort results #'<)))
                 (consts (mapcar #'typespec-eval--make-const uniq)))
            (typespec-eval-simplify-or consts)))))))

(defun typespec-eval-numeric-integer-range-source-p (form)
  "Return non-nil if FORM should participate in integer range arithmetic."
  (or (and (typespec-eval--const-p form)
           (integerp (typespec-eval--const-value form)))
      (typespec-eval-numeric-range-preserving-integer-type-p form)))

(defun typespec-eval-numeric-integer-range-arith (args op)
  "Return an integer range for ARGS and OP, or nil if unknown."
  (when (and (memq op (list #'+ #'- #'*))
             (seq-every-p #'typespec-eval-numeric-integer-range-source-p args))
    (let* ((ranges (mapcar #'typespec-eval-numeric-integer-range-from args))
           (lo (cadr (car ranges)))
           (hi (caddr (car ranges))))
      (dolist (range (cdr ranges))
        (let ((low2 (cadr range))
              (high2 (caddr range)))
          (cond
           ((eq op #'+)
            (setq lo (if (or (eq lo '*) (eq low2 '*)) '* (+ lo low2))
                  hi (if (or (eq hi '*) (eq high2 '*)) '* (+ hi high2))))
           ((eq op #'-)
            (setq lo (if (or (eq lo '*) (eq high2 '*)) '* (- lo high2))
                  hi (if (or (eq hi '*) (eq low2 '*)) '* (- hi low2))))
           ((eq op #'*)
            (let ((bounds (list lo hi low2 high2)))
              (if (seq-some (lambda (bound) (eq bound '*)) bounds)
                  (setq lo '* hi '*)
                (let* ((cands (list (* lo low2) (* lo high2)
                                    (* hi low2) (* hi high2)))
                       (cmin (apply #'min cands))
                       (cmax (apply #'max cands)))
                  (setq lo cmin hi cmax))))))))
      (unless (and (eq lo '*) (eq hi '*))
        (typespec-eval--integer-range lo hi)))))

;;; Min/max range

(defun typespec-eval-numeric-minmax-range (ranges op)
  "Return a range for min/max over RANGES using OP."
  (let ((lows '())
        (highs '()))
    (dolist (range ranges)
      (push (cadr range) lows)
      (push (caddr range) highs))
    (cond
     ((eq op #'min)
      (let* ((low (let ((vals (delq '* lows)))
                    (if (null vals) '* (apply #'min vals))))
             (high (let ((vals (delq '* highs)))
                     (if (null vals) '* (apply #'min vals)))))
        (if (and (eq low '*) (eq high '*))
            nil
          (if (eq (car (car ranges)) 'integer)
              (typespec-eval--integer-range low high)
            (typespec-eval--float-range low high)))))
     ((eq op #'max)
      (let* ((low (let ((vals (delq '* lows)))
                    (if (null vals) '* (apply #'max vals))))
             (high (if (memq '* highs) '* (apply #'max highs))))
        (if (and (eq low '*) (eq high '*))
            nil
          (if (eq (car (car ranges)) 'integer)
              (typespec-eval--integer-range low high)
            (typespec-eval--float-range low high)))))
     (t nil))))

;;; Arithmetic type inference

(defun typespec-eval-numeric-arith-type (args)
  "Return the result type for arithmetic on ARGS."
  (cond
   ((seq-every-p #'typespec-eval-types-integer-type-p args) 'integer)
   ((seq-every-p #'typespec-eval-types-float-type-p args) 'float)
   ((seq-every-p #'typespec-eval-types-number-type-p args) 'number)
   (t 'unknown)))

(provide 'typespec-eval-numeric)
;;; typespec-eval-numeric.el ends here
