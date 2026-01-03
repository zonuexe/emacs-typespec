# Emacs Typespec Overview

This is a draft specification for a practical, expressive type notation for
Emacs Lisp. It aims to make dynamic code more reliable by combining TypeScript
and PHPStan experience with Lisp best practices.

## Specification

The current draft lives in [**`typespec.md`**](typespec.md).

> [!WARNING]
> This is an early draft with no full implementation yet. For now, [`ert-fnspec-check`][ert-fnspec-check] can be used for property-based checking.

[ert-fnspec-check]: https://github.com/zonuexe/ert-fnspec-check.el

## Usage

Simple function type:

```elisp
(defun my-identity (argument)
  "Return the ARGUMENT unchanged."
  argument)

(typespec #'my-identity (:forall (a) (function (a) a)))
```

Property-based check with `ert-fnspec-check`:

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
