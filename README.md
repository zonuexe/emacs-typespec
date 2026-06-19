# Emacs Typespec Overview

This is a draft specification for a practical, expressive type notation for
Emacs Lisp. It aims to make dynamic code more reliable by combining TypeScript
and PHPStan experience with Lisp best practices.

## Specification

The current draft lives in [**`typespec.md`**](docs/typespec.md).
Type-level evaluation semantics (guards, assertions, and conditional
return types) are documented in [**`type-level-evaluation.md`**](docs/type-level-evaluation.md).
How the bundled `typespec-eval` evaluator conforms to the spec — including
known gaps and soundness bugs — is tracked in
[**`conformance.md`**](docs/conformance.md).

> [!WARNING]
> This is an early draft. A type-level evaluator (`typespec-eval`) exists for
> constant folding and inference, but there is no full type checker yet; see
> [`conformance.md`](docs/conformance.md) for status. For property-based checking,
> [`ert-fnspec-check`][ert-fnspec-check] can be used.

[ert-fnspec-check]: https://github.com/zonuexe/ert-fnspec-check.el

## Usage

### About `typespec.el`

`typespec.el` provides the `typespec` macro. It is intentionally small and meant to be used as a compile-time helper, so prefer:

```elisp
(eval-when-compile
  (require 'typespec))
```

The macro stores a literal typespec on the function symbol and has no runtime execution logic, so annotating functions directly in implementation files should have negligible runtime cost.

### Annotate your functions

Simple function type:

```elisp
(eval-when-compile
  (require 'typespec))

(defun my-identity (argument)
  "Return the ARGUMENT unchanged."
  argument)

;; Simple and safe, but it cannot express that the output is the same value.
(typespec #'my-identity (function (unknown) unknown))

;; Use :forall to bind a type parameter and return the same type.
(typespec #'my-identity (:forall (a) (function (a) a)))
```

Let's consider a more complex example.

```elisp
(defun my-times2 (n)
  "Return N multiplied by 2."
  (+ n 2))

;; This looks reasonable, but it misses literal refinement: (my-times2 42)
;; can be inferred as (const 84), not just integer.
(typespec #'my-times2 (:forall (a) (function ((a number)) a)))

;; Use generalize-signed to widen literal results while preserving sign.
(typespec #'my-times2
  (:forall ((a number))
    (function (a) (generalize-signed a))))
```

Add `(declare (typespec-ftype ...))` inside a function to emit an `ftype`
declaration derived from typespec annotations.

``` elisp
(typespec #'my-times2
  (:forall ((a number))
    (function (a) (generalize-signed a))))

(defun my-times2 (n)
  "Return N multiplied by 2."
  (declare (typespec-ftype (function (number) number)))
  ;; (declare (ftype (function (number) number)))
  (+ n n))
```

> [!WARNING]
> `typespec-ftype` may become useful for compile-time optimization and
> performance, but it is still experimental and not strongly recommended yet.

### Property-based checks

Use `ert-fnspec-check` for property-based checking:

```elisp
(ert-fnspec-check (lambda (xs) (reverse (reverse xs)))  '(:xs (list integer))
 :test (lambda (actual xs) (equal actual xs)))
```

## Ideal Workflow (Planned)

When a function has a `typespec` annotation, a typed helper like
`ert-fnspec-check-typed` should be able to reuse it without repeating the spec:

```elisp
(typespec #'my-identity (:forall (a) (function (a) a)))

(ert-fnspec-check-typed #'my-identity)
```

This is a planned feature; the implementation does not exist yet.

### Planned: typespec + resolver snapshots in tests

`ert-fnspec-check-typed` can also use resolver snapshots embedded in the
typespec record. This allows tests to resolve newer utility types even when
the user's runtime typespec package is older, while still warning about
baseline mismatches.

## Copyright

This package is licensed under [GNU General Public License, version 3](https://www.gnu.org/licenses/gpl-3.0).

    parameterized-ert.el  Copyright (C) 2026  USAMI Kenta

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
