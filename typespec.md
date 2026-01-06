# Emacs Typespec Specification

This document proposes an S-expression type notation that is practical for
Emacs Lisp and informed by the existing ecosystems. The goal is not a compact
native-compiler type system; instead, it aims to make a dynamic language
practical by combining TypeScript/PHPStan experience with Lisp best practices
into a rich, usable type vocabulary.

- [**`cl-typep`**](https://www.gnu.org/software/emacs/manual/html_node/cl/Type-Predicates.html) (predicate-style types)
- [**`defcustom`***](https://www.gnu.org/software/emacs/manual/html_node/elisp/Customization-Types.html) (user customization type expressions; optional extensions)
- [**Elsa**](https://github.com/emacs-elsa/Elsa) (static analyzer type language)

The goal is a single *pragmatic* type language: it accepts a curated subset of
`cl-typep` and Elsa, and it allows optional `defcustom`-style extensions.
Compatibility is one-way: all supported `cl-typep` forms should be accepted by
this language, but not every expression in this language must be valid in those
systems.

## Goals

- S-expression syntax with small surface area.
- Readable by Lisp users; no reader macros required.
- Avoid type-theory contradictions where practical.
- Keep a clear escape hatch for “any” and “unknown” values.

## Non-goals

- Full `cl-typep` coverage.
- Full `defcustom` coverage.
- Full Elsa coverage as-is; we keep only the parts that compose well.

## Core Syntax

Types are written as symbols or lists.

```
TYPE ::= symbol
       | (const VALUE)
       | (or TYPE...)
       | (and TYPE...)
       | (not TYPE)
       | (function (TYPE...) TYPE)
       | (function (TYPE...) (:guard TYPE))
       | (function (TYPE...) (:assert TYPE))
       | (if PRED TYPE TYPE)
       | (list TYPE)
       | (vector TYPE)
       | (sequence TYPE)
       | (cons TYPE TYPE)
       | (hash-table TYPE TYPE)
       | (:tuple TYPE...)
       | (:tuple TYPE... . TYPE)
       | (:alist TYPE TYPE)
       | (:plist TYPE TYPE)
       | (:plist-of ENTRY...)
       | (:class CLASS)
       | (:forall (TYPEVAR...) TYPE)
       | (generalize TYPE TYPE)
       | (generalize-signed TYPE)
       | (downcast TYPE TYPE)
       | (benevolent TYPE)
       | (value-of TUPLE)
       | (var SYMBOL)
       | (plist-key-of PLIST)
       | (plist-value-of PLIST)

ENTRY ::= (KEY TYPE)
       | (:? KEY TYPE)
```

`(:tuple ...)` is the preferred tuple form because it avoids clashes with
general list syntax. We reserve `tuple` for the constructor only; there is no
standalone `tuple` base type (unlike `list`), so using a keyword makes the
intent explicit. Elsa's tuple shorthand `(T1 T2 T3)` is intentionally *not*
part of the core syntax because it is easily confused with list or cons
notation.

## Base Types

### Common `cl-typep` names

`t`, `nil`, `null`, `never`, `atom`, `cons`, `list`, `vector`, `sequence`,
`symbol`, `keyword`, `boolean`/`bool`, `integer`/`int`, `float`,
`real`, `number`, `character`, `string`, `hash-table`, `function`

Common numeric shorthand (recommended):

- `positive-int` — `(integer 1 *)`
- `non-negative-int` — `(integer 0 *)`
- `negative-int` — `(integer * -1)`
- `non-positive-int` — `(integer * 0)`
- `positive-float` — `(float (0) *)`
- `negative-float` — `(float * (0))`

Range notation uses `*` for an unbounded side. For example,
`(integer * 10)` means any integer <= 10, and `(integer 0 *)` means
any integer >= 0. Bounds are inclusive.

Notes:

- `nil` is the singleton type with the single value `nil`.
- `null` is an alias of `nil` (kept for `cl-typep` familiarity).
- `never` is the empty/bottom type: it has no inhabitants.
- `boolean`/`bool` is the set `{t, nil}`.
- `character` corresponds to `(integer 0 (max-char))`, i.e. 0..4194304.

### Elsa-inspired types

- `unknown` — the *top type*: accepts anything, but is not implicitly
  accepted by other types.
- `mixed` — the “escape hatch”: both top and bottom in practice, i.e.
  implicitly accepted by any type and accepts any type.

This mirrors the `unknown` vs `any` distinction in TypeScript.

### Void

- `void` — indicates a return value that must not be used, and *suggests
  the function exists for its side effects*.
  A function may evaluate to some value, but that value has no guaranteed
  meaning (it may be `nil` or non-`nil` arbitrarily). `void` is distinct
  from `unknown`: `unknown` can be refined via guards, while `void`
  should not be consumed or cast.

## Combinators (Type Theory Names)

- `(or T1 T2 ...)` — union
- `(and T1 T2 ...)` — intersection
- `(not T)` — complement (relative to the current universe; use with care)

These combinators intentionally use non-`:` forms to preserve `cl-typep`
compatibility and because they are logical operators rather than base types.

## Function Types

`(function (A1 A2 ...) R)` for functions with positional arguments.

Optional future extension:

- keyword args or rest args, e.g. `(function (A1 &optional A2 &rest R) R)`.

### Type Guards (TypeScript-style)

To model type-guard predicates (e.g., `x is string` in TypeScript),
use a `:guard` return type:

```
(function (unknown) (:guard string))
```

This means the function returns a boolean value, and on success it
refines the checked value to `string` in the caller context. The
`boolean` return is implicit; you do not need to write it separately.

### Assertion Guards

For assertion-style helpers that signal an error on failure and refine
the argument on success, use `:assert` as the return type:

```
(typespec #'assert-int (function (unknown) (:assert integer)))
```

This means the function either signals an error or returns normally,
and on the normal path the argument is treated as `integer`.

### Conditional Return Types (Restricted)

To keep conditional types predictable, only a small, safe predicate
language is allowed. The condition can use these operators:

`if`, `null`, `eq`, `eql`, `equal`, `equal-including-properties`,
`=`, `/=`, `>`, `>=`, `<`, `<=`, `value<`, `char<`, `char<=`, `char>`,
`char>=`, `char=`, `char/=`, `string<`, `string<=`, `string>`,
`string>=`, `string=`, `string/=`, `string-lessp`, `nth`, `nthcdr`,
`car`, `cdr`, `car-safe`, `cdr-safe`, `plist-get`, `plist-member`,
`alist-get`, `assoc`, `assq`, `rassoc`, `memq`, `member`,
`member-ignore-case`, `aref`, `elt`, `length`, `stringp`, `integerp`,
`symbolp`, `butlast`, `kbd`, `last`,
`log10`, `lsh`, `macrop`,
`make-composed-keymap`, `mouse-event-p`, `number-sequence`,
`provided-mode-derived-p`,
`sha1`, `string-equal-ignore-case`, `string-greaterp`, `string-lines`,
`string-match-p`, `string-prefix-p`, `string-replace`, `string-suffix-p`,
`string-to-list`, `string-to-vector`, `string-trim-right`, `syntax-class`,
`version-list-<`, `version-list-<=`, `version-list-=`,
`version-list-not-zero`, `version-to-list`, `version<`, `version<=`,
`version=`, `zerop`, `cl-plusp`, `cl-minusp`, `cl-evenp`, `cl-oddp`,
`cl-equalp`, `cl-endp`, `cl-first`, `cl-second`, `cl-third`,
`cl-fourth`, `cl-fifth`, `cl-sixth`, `cl-seventh`, `cl-eighth`,
`cl-ninth`, `cl-tenth`, `cl-list-length`, `seq-empty-p`, `seq-length`,
`seq-elt`.

The operands are limited to `&args`, `&rest`, and `&keys` (and values
derived from them), plus literal constants such as quoted symbols,
keywords, strings, and numbers.

Form:

```
(if PRED THEN ELSE)
```

Example:

```
(typespec #'is-string
  (function (value &keys)
    (if (plist-get &keys :assert)
        (:assert string)
      (:guard string))))
```

### Argument Tuples and `value-of`

`&args` and `&rest` are reserved keywords that refer to tuples of the
*actual* argument value types at a call site.

- `&args` — tuple of all argument value types
- `&rest` — tuple of the variadic portion, when applicable

`(value-of (:tuple T1 T2 ...))` is defined as `(or T1 T2 ...)`.
This allows types like `or` to describe “returns one of its arguments”
without naming each argument.

Example (two-argument `or`):

```
(typespec #'or
  (:forall (a b)
    (function (a b) (value-of &args))))
```

### `generalize` (widen literal types)

`(generalize T TARGET)` widens a precise type such as `(const 42)` into a
broader, user-chosen target type (for example `integer` or `positive-int`).
This is intended for cases where the strictest checker would infer a literal
type, but you want to declare a usable supertype instead.

### `generalize-signed` (sign-preserving widening)

`(generalize-signed T)` widens numeric literal types while preserving sign.

- `(const 42)` => `positive-int`
- `(const -42)` => `negative-int`
- `(const 42.0)` => `positive-float`
- `(const -42.0)` => `negative-float`
- `(const 0)` or `(const 0.0)` => `(const 0)` or `(const 0.0)`
- `integer`/`float`/`number` => unchanged
- `unknown`/`mixed` => `never`

The `unknown`/`mixed` case intentionally fails closed; use a separate
downcast helper if you want to relax that constraint.

### `downcast` (explicit type assertion)

`(downcast T TARGET)` explicitly treats `T` as `TARGET`. This is a deliberate
escape hatch, similar to a type assertion, and should be used sparingly.
Unlike `generalize`, `downcast` does not imply that `T` is a subtype of
`TARGET`; it simply asserts that it should be treated as such.

### `benevolent` (soundness trade-off)

`(benevolent T)` marks a type as intentionally permissive. It allows values to
flow into `T`-typed positions even when a strict checker would reject them.
This is a pragmatic escape hatch intended for real-world dynamic code where
exact type boundaries are difficult to enforce. Use it sparingly and only when
the trade-off is acceptable.

### Variable types (`var`) and constant values

`(var SYMBOL)` refers to the type of a Lisp variable by name.

- For `defconst` values, the variable is treated as a constant; a list
  of symbols expands to a union of `const` values.
- For `defcustom` values, use the declared `:type` if present.
- Otherwise, the variable type is `unknown`.

Example:

```
(defconst orders '(asc desc))
(value-of (var 'orders))
;; => (or (const asc) (const desc))
```

### Keyword Arguments (`&keys`) and plist helpers

When using `&keys`, treat keyword arguments as a plist:

- `&keys` is a plist type, typically `(:plist keyword mixed)` by default.
- `(plist-key-of P)` returns the key type of plist `P`.
- `(plist-value-of P)` returns the value type of plist `P`.

This allows a simple encoding of keyword-heavy functions without fixing
exact key sets in the core syntax.

Example with fixed keys:

```
(typespec #'make-user
  (function (&keys (:plist-of
                    (:name string)
                    (:age non-negative-int)
                    (:? :nickname string)))
            (:plist-of
             (:name string)
             (:age non-negative-int)
             (:? :nickname string))))
```

### Keyed plists (array-shapes)

`(:plist-of ...)` models a plist with fixed key names and per-key types,
similar to PHPStan array-shapes.

```
(:plist-of
  (:name string)
  (:age non-negative-int)
  (:tags (list string))
  (:? :nickname string))
```

Use `(:? KEY TYPE)` to mark an optional key.

## Container Types

- `(list T)` — homogeneous list of `T`
- `(vector T)` — homogeneous vector of `T`
- `(sequence T)` — homogeneous sequence of `T`
- `(cons A B)` — cons cell with `car` of `A` and `cdr` of `B`
- `(hash-table K V)` — hash table mapping `K` to `V`
- `(:alist K V)` — association list of key type `K` and value type `V`
- `(:plist K V)` — property list with key type `K` and value type `V`
- `(:plist-of (KEY T) ...)` — plist with fixed keys (PHPStan array-shapes)

## EIEIO Classes

`(:class CLASS)` denotes an EIEIO object that is an instance of `CLASS`
or any subclass of `CLASS`. This mirrors EIEIO method dispatch, which
considers inheritance.

## Other Emacs Lisp Type Sources

These are common places where type-like information appears in Emacs Lisp.
They are not part of the core syntax, but are useful for integration:

- `cl-defstruct` / `defstruct` — structure predicates (e.g. `foo-p`) imply a
  nominal type `foo`.
- `cl-declare` / `declare` — `type` / `ftype` declarations can be mapped to
  `typespec` entries. For example, `(declare (ftype (function (int) int) f))`
  corresponds to `(typespec #'f (function (integer) integer))`.
- `defcustom` — `:type` uses a separate expression language (see compatibility
  notes earlier in this document).
- `pcase` / `cl-typecase` — pattern or type branches can act as local type
  refinements.
- Native compilation — `subr-type` and `function-type` can provide inferred or
  declared function type specifiers (see `comp-function-type-spec`).

Note: `string` can be treated as a sequence of character codes, i.e.
`(sequence (fixnum 0 most-positive-fixnum))`, when a uniform sequence
view is useful.

### Sequences, Arrays, and Vectors

In Emacs Lisp, **sequence** is the union of **list** and **array**.

- **list**: cons-chain, variable length.
- **array**: fixed-length; includes strings, vectors, char-tables, and bool-vectors.
- **vector**: a kind of array.

Therefore, `(sequence T)` should be read as “either `(list T)` or an array of `T`”.
When element type matters for arrays, use `(vector T)` or a more specific array
type once it is introduced.

## Tuple Types

Use `(:tuple T1 T2 T3)` for a fixed-length *proper list* tuple.

Use `(:tuple T1 T2 . T3)` for a fixed-length *cons-chain* tuple,
equivalent to `(cons T1 (cons T2 T3))`.

If this dotted form proves too hard to read, we can add explicit
keywords such as `:list-tuple` and `:cons-tuple` as aliases later.

## Constant Types

`(const VALUE)` is the type with exactly that value.

Optional shorthand (Elsa-style):

- `"foo"` is shorthand for `(const "foo")`
- `1` is shorthand for `(const 1)`
- `sym` is shorthand for `(const sym)`

Shorthands are convenient but can conflict with `cl-typep`’s atom usage.
Use `(const ...)` in ambiguous contexts.

## Nullable Types

There is no special “nullable” marker. Use union:

- `(or string nil)` for nullable strings

## Defcustom Compatibility (Non-Core)

Defcustom-style forms are intentionally **not** part of the core typespec.
If a consumer chooses to support them, they should be treated as extensions
and documented separately to avoid confusion with `cl-typep` semantics.

## Polymorphism / Type Variables

To express OCaml-style polymorphism:

```
(:forall (a) (function (a) a))
```

`a` is a type variable; `:forall` binds it for the body.

## Compatibility Summary

- **cl-typep**: most common base types and `or/and/not` are supported.
- **defcustom**: not part of core syntax; treat as optional extensions.
- **Elsa**: function types, container types, constants, and `mixed/unknown`
  align well. Tuple shorthand is intentionally excluded from core syntax.

When a form exists in multiple systems but has different semantics, this spec
should prefer *explicit* constructors (`:tuple`, `const`, `function`) to avoid
silent misinterpretation.

## Examples

### Identity

```
(typespec #'identity (:forall (a) (function (a) a)))
```

### Max

```
(typespec #'max
  (function ((or number marker) &rest (or number marker)) number))
```

### Type guard predicate

```
(typespec #'stringp (function (unknown) (:guard string)))
```

### seq-map

```
(typespec #'seq-map
  (:forall (a b)
    (function ((function (a) b) (sequence a)) (list b))))
```

For example, strings are sequences of characters, so:

```
(seq-map #'identity "abc")
;; => (97 98 99)
```

### syntax-ppss

```
(typespec #'syntax-ppss
  (function (&optional (or integer marker))
            (:tuple integer
                    (or non-negative-int nil)
                    (or non-negative-int nil)
                    (or character t nil)
                    (or non-negative-int t nil)
                    (or t nil)
                    integer
                    (or nil 1 2 symbol)
                    (or non-negative-int nil)
                    (list non-negative-int)
                    (or non-negative-int nil))))
```

The [parser state] tuple corresponds to the 11 elements described in the
Emacs manual (depth, innermost paren start, last complete sexp start,
string/comment flags, minimum depth, comment style, comment/string
start, open paren stack, and last syntax code).

[parser state]: https://www.gnu.org/software/emacs/manual/html_node/elisp/Parser-State.html

### not / or

```
(typespec #'not (function (unknown) boolean))
```

`or` is a special form (not a regular function), but for documentation
purposes a coarse type can be written as:

```
(typespec #'or (function (&rest unknown) unknown))
```
