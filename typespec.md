# Emacs Typespec Specification

This document proposes an S-expression type notation that is practical for
Emacs Lisp and informed by the existing ecosystems. The goal is not a compact
native-compiler type system; instead, it aims to make a dynamic language
practical by combining TypeScript/PHPStan experience with Lisp best practices
into a rich, usable type vocabulary.

- **`declare (ftype ...)`** and [elisp_type_hierarchy]
- [**`cl-typep`**](https://www.gnu.org/software/emacs/manual/html_node/cl/Type-Predicates.html) (predicate-style types)
- [**`defcustom`***](https://www.gnu.org/software/emacs/manual/html_node/elisp/Customization-Types.html) (user customization type expressions; optional extensions)
- [**Elsa**](https://github.com/emacs-elsa/Elsa) (static analyzer type language)

[elisp_type_hierarchy]: https://github.com/emacs-mirror/emacs/blob/master/doc/lispref/elisp_type_hierarchy.txt

The goal is a single *pragmatic* type language: it accepts a curated subset of
`cl-typep` and Elsa, and it allows optional `defcustom`-style extensions.
Compatibility is one-way: all supported `cl-typep` forms should be accepted by
this language, but not every expression in this language must be valid in those
systems.

## Emacs `declare (ftype ...)` Compatibility

Typespec aims to be a **100% superset** of Emacs Lisp `declare (ftype ...)`
as introduced in Emacs 29.1. Concretely:

- Any type accepted by the native compiler’s constraint system (via
  `comp-type-spec-to-cstr`) is valid typespec.
- Typespec may accept additional constructs beyond `ftype`/`comp-cstr`.

The canonical Emacs type hierarchy is included in [`elisp_type_hierarchy.txt`][elisp_type_hierarchy]
and should be treated as the ground truth for base type relationships.

The typespec evaluator implements subtype checking based on this hierarchy.
For example, `fixnum` is a subtype of `integer`, which is a subtype of `number`.
Similarly, `hook` is a subtype of `list`, which is a subtype of `sequence`.
This enables type-level evaluation to correctly handle subtype relationships
when checking function call compatibility and type inference.

We do not attempt to enumerate the full set of `ftype`-annotated functions in
this document; instead, we treat the Emacs native compiler's accepted type
specifications as the compatibility baseline and add typespec-only extensions
on top.

## Goals

- S-expression syntax with small surface area.
- Readable by Lisp users; no reader macros required.
- Avoid type-theory contradictions where practical.
- Keep a clear escape hatch for “any” and “unknown” values.
- Allow erasing advanced Typespec forms into `ftype`-compatible declarations.

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
       | (diff TYPE TYPE)
       | (function ARGS TYPE)
       | (function ARGS (:guard TYPE [RET]))
       | (function ARGS (:guard! TYPE [RET]))
       | (function ARGS (:assert TYPE))
       | (if PRED TYPE TYPE)
       | (integer LOW HIGH)
       | (float LOW HIGH)
       | (real LOW HIGH)
       | (number LOW HIGH)
       | (list TYPE)
       | (list+ TYPE)
       | (vector TYPE)
       | (sequence TYPE)
       | (cons TYPE TYPE)
       | (hash-table TYPE TYPE)
       | (hook FUNTYPE . REST)
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
       | (rx RX-EXPR)
       | (value-of TUPLE)
       | (var SYMBOL)
       | (plist-key-of PLIST)
       | (plist-value-of PLIST)

ARGS ::= (ARGSPEC...)

ARGSPEC ::= TYPE
          | &optional TYPE...
          | &rest TYPE
          | &keys KEYSPEC

KEYSPEC ::= (:plist-of ENTRY...)
          | TYPE

LOW  ::= * | NUMBER | (NUMBER)
HIGH ::= * | NUMBER | (NUMBER)

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
`real`, `number`, `character`, `string`, `hash-table`, `function`,
`marker`, `integer-or-marker`, `number-or-marker`, `hook`

Common numeric shorthand (recommended):

- `positive-int` — `(integer 1 *)`
- `non-negative-int` — `(integer 0 *)`
- `negative-int` — `(integer * -1)`
- `non-positive-int` — `(integer * 0)`
- `positive-float` — `(float (0) *)`
- `negative-float` — `(float * (0))`
- `fixnum` — `(integer most-negative-fixnum most-positive-fixnum)`

Composite types (Emacs Lisp built-in):
- `marker` — buffer position marker
- `integer-or-marker` — `(or integer marker)`
- `number-or-marker` — `(or number marker)`
- `hook` — `(hook (function () t))` (list of zero-arg functions)

Range notation uses `*` for an unbounded side. For example,
`(integer * 10)` means any integer <= 10, and `(integer 0 *)` means
any integer >= 0. Bounds are inclusive by default.
To indicate an exclusive bound, wrap it in a list: `(integer (0) *)`
means greater than 0, and `(integer * (10))` means less than 10.

**Normalization policy**: Keyword types like `positive-int`, `non-negative-int`,
`negative-int`, `non-positive-int`, and `fixnum` are treated as **input aliases**
and normalized to their canonical range forms during type-level evaluation.
For example, `positive-int` is normalized to `(integer 1 *)` internally, and
operations on these types return the canonical range forms rather than the
keyword symbols. This ensures consistent range arithmetic and simplifies
internal processing. Output types may preserve the original keyword when the
range exactly matches the keyword's bounds (e.g., `fixnum` is preserved when
the range is exactly `(integer most-negative-fixnum most-positive-fixnum)`),
but in general, canonical range forms are preferred for precision.

Notes:

- `t` is the `cl-typep` universal type: any value satisfies it. In this
  spec, `t` is treated like `mixed` for compatibility.
- `nil` is the singleton type with the single value `nil`.
- `null` is an alias of `nil` (kept for `cl-typep` familiarity).
- `never` is the empty/bottom type: it has no inhabitants.
- `atom` means any non-cons value; it is equivalent to `(not cons)`.
- `boolean`/`bool` is the set `{t, nil}`.
- `character` corresponds to `(integer 0 (max-char))`, i.e. 0..4194304.

Example usage:

```emacs-lisp
;; A function that never returns normally.
(typespec #'error (function (&rest mixed) never))
```

Note: container types are **not** automatically reduced when they contain
`never`. For example, `(list never)` means “a (proper) list whose elements
would have to be `never`”, which is only satisfied by the empty list. It is
therefore **not** equivalent to `never` (which has no inhabitants at all).
Similarly, `(:tuple never)` is an empty list tuple whose single element would
have to be `never`, which is uninhabited, but the rule is explicit: only the
empty list `(list)` is a value, and it does not satisfy `(:tuple never)`.
Implementations may choose to simplify such cases, but should do so
explicitly rather than implicitly.

### Elsa-inspired types

- `unknown` — the *top type*: accepts anything, but is not implicitly
  accepted by other types.
- `mixed` — the “escape hatch”: both top and bottom in practice, i.e.
  implicitly accepted by any type and accepts any type.

This mirrors the `unknown` vs `any` distinction in TypeScript.
In this spec, `t` is treated like `mixed` for `cl-typep` compatibility.

Example usage:

```emacs-lisp
;; `unknown` for untrusted input or values that must be refined.
(typespec #'read (function (string) unknown))

;; `mixed` for dynamic values you intentionally pass through unchecked.
(typespec #'eval (function (mixed) mixed))
```

### Type Guards

`(:guard TYPE [RET])` and `(:guard! TYPE [RET])` allow an optional
**return type on the true branch**. If RET is omitted, the return type
defaults to `boolean`.

```emacs-lisp
;; True branch: ARG is string, return value is the same string.
(function (unknown) (:guard string string))

;; Total predicate: true branch returns symbol, false branch returns nil,
;; argument is refined to symbol / (not symbol).
(function (symbol) (:guard! t symbol))

;; True branch returns the *bound value* (unknown type), while the
;; argument is known to be a bound, non-nil symbol.
(function (symbol) (:guard t unknown))  ; e.g. bound-and-true-p
```

For `:guard!`, the false branch refines the argument to `(not TYPE)` and
the return is `nil` (or `boolean` if RET is omitted).

### Void

- `void` — indicates a return value that must not be used, and *suggests
  the function exists for its side effects*.
  A function may evaluate to some value, but that value has no guaranteed
  meaning (it may be `nil` or non-`nil` arbitrarily). `void` is distinct
  from `unknown`: `unknown` can be refined via guards, while `void`
  should not be consumed or cast.

Example usage:

```emacs-lisp
(typespec #'message (function (string &rest mixed) void))
```

## What counts as a “type”

Typespec recognizes several ways to define “a type”:

- Predicate-defined types: names like `string` map to predicates such as
  `stringp`. This also covers EIEIO classes via `(:class CLASS)` and
  user-defined predicates via `:guard`/`:guard!` (e.g. `jp-postal-code-p`).
- Structure-defined types: shapes such as `(:tuple ...)`, `(:alist K V)`,
  `(:plist K V)`, `(:plist-of ...)`, `list`, `vector`, `sequence`, `cons`,
  and `hash-table`.
- Logical types: `(or ...)`, `(and ...)`, `(not ...)`, and `(diff ...)`.
- Utility/meta types: `(const ...)`, `(rx ...)`, `(generalize ...)`,
  `(generalize-signed ...)`, `(downcast ...)`, `(benevolent ...)`,
  `(value-of ...)`, `(var ...)`, `(plist-key-of ...)`, `(plist-value-of ...)`,
  `(list+ ...)`.

Types that do not fit the predicate/structure/logical buckets are typically
utility/meta types or higher-order function types:

- Function types `(function ...)` are higher-order types; they are not defined
  by a predicate or structure, but by input/output constraints.
- `unknown`, `mixed`, `never`, and `void` are special-purpose meta types.

## Combinators (Type Theory Names)

- `(or T1 T2 ...)` — union
- `(and T1 T2 ...)` — intersection
- `(not T)` — complement (relative to the current universe; use with care)
- `(diff A B)` — difference (values in `A` that are not in `B`)

These combinators intentionally use non-`:` forms to preserve `cl-typep`
compatibility and because they are logical operators rather than base types.

`(not T)` is shorthand for `(diff mixed T)` in non-conditional contexts.
`(diff A B)` does not require `B` to be a subtype of `A`; it is simply
“values in `A` that are not in `B`”.

Example usage:

```emacs-lisp
;; Any non-nil value.
(diff mixed nil)

;; Any value that is not a string.
(not string)
```

## Function Types

`(function (A1 A2 ...) R)` for functions with positional arguments.

The argument list uses a `defun`-style order: positional args, then
`&optional`, then `&rest`, then `&keys`. `&keys` accepts either a plist
shape (typically `(:plist-of ...)`) or a broader plist type such as
`(:plist keyword mixed)`. This is a **conventional default** used by type
checkers when no more specific plist shape is provided. It is not a language
guarantee; implementations may allow configuration, but callers should not
rely on a custom default in type declarations.

### Variance (Subtyping)

For function types, parameter types are **contravariant** and return types
are **covariant**. Informally:

`(function (A1 ... An) R)` is a subtype of `(function (B1 ... Bn) S)` when
each `Bi` is a subtype of `Ai`, and `R` is a subtype of `S`.

Example:

```emacs-lisp
;; Can accept any input, so it can stand in for a string-only function.
(function (unknown) integer) <: (function (string) integer)
```

Concrete expectations:
- `(function (positive-int) int)` is **not** a subtype of `(function (int) int)`.
- `(function ((or int string)) int)` **is** a subtype of `(function (int) int)`.
- `(function (int) (or int string))` is **not** a subtype of `(function (int) int)`.

Tools that do not implement variance should treat function types as invariant.
This follows the Liskov Substitution Principle: any value of the subtype
must be safely usable wherever the supertype is expected. Contravariant
parameters and covariant returns preserve that substitutability.

For mutable containers (`list`, `vector`, `sequence`, `cons`, `hash-table`,
`alist`, `plist`), treat element types as **invariant** by default, because
mutation can break covariant assumptions.

For `&optional` and `&rest`, treat omitted optional parameters as if they
were supplied with `nil`, so their types are compared as `(or T nil)` in
subtyping. `&rest` is contravariant in its element type.

For `&keys`, subtyping should compare plist key sets structurally:
required keys are contravariant in their value types, optional keys are
contravariant when present, and additional keys in the subtype are allowed
only if the supertype permits them (e.g. via a broader plist type).
Implementations may conservatively fall back to invariance here.

## Polymorphism (Conceptual)

Typespec provides parametric polymorphism via `:forall`. This is the primary
form of polymorphism in the system: type variables are introduced and then
propagate through inputs and outputs without depending on values.

Other helpers such as `generalize`, `generalize-signed`, `downcast`, and
`value-of` are not polymorphism. They are pragmatic tools for widening,
escaping, or refining types in dynamic code.

### Type-level Evaluation

Type-level evaluation (guards, assertions, and conditional return types)
is defined in `type-level-evaluation.md`.

### Argument Tuples and `value-of`

`&args` and `&rest` are reserved keywords that refer to tuples of the
*actual* argument value types at a call site.

- `&args` — tuple of all argument value types
- `&rest` — tuple of the variadic portion, when applicable

`(value-of (:tuple T1 T2 ...))` is defined as `(or T1 T2 ...)`.
This allows types like `or` to describe “returns one of its arguments”
without naming each argument. Use `value-of` when you want to treat a
tuple (or proper list) as a set of *choices*.

If a proper list is supplied, it is treated as `(:tuple ...)` for this
purpose. For dotted tuples, `value-of` includes the tail type as an additional
union member (e.g., `(:tuple a b . c)` => `(or a b c)`).

When combined with `(var SYMBOL)`, a type checker should first resolve
`(var SYMBOL)` to its concrete type (for example, a tuple for a `defconst`
list) and then apply `value-of` to that expanded type.

Example (two-argument `or`):

```emacs-lisp
(typespec #'or
  (:forall (a b)
    (function (a b) (value-of &args))))
```

Example with `&rest`:

```emacs-lisp
;; &args includes all args; &rest includes only the variadic tail.
(typespec #'sum
  (:forall (a)
    (function (a &rest a) a)))
```

### `generalize` (widen literal types)

`(generalize T TARGET)` widens a precise type such as `(const 42)` into a
broader, user-chosen target type (for example `integer` or `positive-int`).
This is intended for cases where the strictest checker would infer a literal
type, but you want to declare a usable supertype instead.

Design note: `generalize` is explicit because the desired target type is
context-dependent (e.g. `integer` vs `positive-int`). In contrast,
`generalize-signed` encodes a single, fixed widening rule for numeric
literals, so it does not take an explicit target.

Example usage:

```emacs-lisp
;; A predicate that returns a literal when true; generalize it for usability.
(typespec #'okp
  (function (unknown) (generalize (const t) boolean)))
```

### `list+` (non-empty list)

`(list+ T)` describes a proper list with at least one element of type `T`.
It is shorthand for `(cons T (list T))`.

Example usage:

```emacs-lisp
;; Requires at least one element.
(typespec #'first (function ((list+ integer)) integer))

;; Accepts empty lists as well.
(typespec #'safe-first (function ((list integer)) (or integer nil)))
```

### `generalize-signed` (sign-preserving widening)

`(generalize-signed T)` widens numeric literal types while preserving sign.

- `(const 42)` => `positive-int`
- `(const -42)` => `negative-int`
- `(const 42.0)` => `positive-float`
- `(const -42.0)` => `negative-float`
- `(const 0)` or `(const 0.0)` => `(const 0)` or `(const 0.0)`
- `integer`/`float`/`number` => unchanged
- `unknown`/`mixed` => `never`

The `unknown`/`mixed` case intentionally **fails closed**. Here, “fails
closed” means the type checker does not guess a looser numeric type when
there is insufficient information; it returns the empty type instead.
“Uninhabited” in this spec means the same as `never`: no values satisfy
that type.

This is a **type-safety** choice. Allowing `unknown` to become a signed
refinement would assert information that is not justified by the input,
which can hide bugs. The practical impact is that `generalize-signed` is
only safe for literal or already-numeric inputs; if you apply it to
`unknown`/`mixed`, the result becomes `never`, and a type checker should
report an error if that value is used where a real value is required.
This is a compile-time/type-checking concern, not a runtime error.

Example (failure case):

```emacs-lisp
;; Bad: the return becomes `never`, so callers should get a type error.
(typespec #'some-func
  (function (unknown) (generalize-signed unknown)))
```

This mistake often appears when a function signature is written before the
input type is known (e.g. you start with `unknown` and later plan to refine
it), or when a dynamic value is passed through without an explicit cast.
In those cases, either refine the input with a guard/assert first, or use
`downcast` to document your intent explicitly.

Example (use downcast to override):

```emacs-lisp
;; Explicitly assert a numeric type when you have out-of-band knowledge.
(typespec #'some-func
  (function (unknown) (downcast unknown number)))
```

Example usage:

```emacs-lisp
;; Preserve sign when widening.
(typespec #'negate
  (function (number) (generalize-signed (const -1))))
```

### `:cause-error` (pseudo-type)

`(:cause-error INFO)` is a pseudo-type returned by type-level evaluation
for invalid calls (e.g. wrong arity or wrong argument type). It is not a
runtime value, but a diagnostic marker that tools can surface. Static
analyzers may treat it as equivalent to `never`, or preserve it to keep
error context.

### `downcast` (explicit type assertion)

`(downcast T TARGET)` explicitly treats `T` as `TARGET`. This is a deliberate
escape hatch, similar to a type assertion, and should be used sparingly.
Unlike `generalize`, `downcast` does not imply that `T` is a subtype of
`TARGET`; it simply asserts that it should be treated as such. The name
does not imply a direction (narrowing vs widening); it is an explicit
cast that may be used to *narrow* or *widen* depending on context.

Example usage:

```emacs-lisp
;; Force a narrower type when you have out-of-band knowledge.
(typespec #'trust-int
  (function (unknown) (downcast unknown integer)))
```

### `rx` (regexp via `rx` syntax)

`(rx RX-EXPR)` is a type that accepts values matching the regexp produced by
`rx`. Any [`rx` form](https://www.gnu.org/software/emacs/manual/html_node/elisp/Rx-Notation.html)
is allowed, but for type usage it is recommended to anchor the whole string, for example:

```emacs-lisp
(rx string-start (+ (any "0-9")) string-end)
```

Non-string values never match; `(rx ...)` is a string subtype.

Example: Japanese postal codes with a leading "〒" and no spaces:

```emacs-lisp
(defun jp-postal-code-p (value)
  "Return non-nil when VALUE is a Japanese postal code string."
  (and (stringp value)
       (string-match-p
        (rx string-start "〒" (= 3 digit) "-" (= 4 digit) string-end)
        value)))

(typespec #'jp-postal-code-p
  (function (unknown)
            (:guard (rx string-start "〒" (= 3 digit) "-" (= 4 digit) string-end))))

;; Note: this is intentionally `:guard`, not `:guard!`.
;; If the predicate fails, the value is either a non-string or a string
;; that does not match the postal-code pattern, so the false branch
;; cannot be narrowed to `(not string)`.
```

### `benevolent` (soundness trade-off)

`(benevolent T)` marks a type as intentionally permissive. It allows values to
flow into `T`-typed positions even when a strict checker would reject them.
This is a pragmatic escape hatch intended for real-world dynamic code where
exact type boundaries are difficult to enforce. Use it sparingly and only when
the trade-off is acceptable.

Example usage:

```emacs-lisp
;; Allow a pragmatic widening for real-world numeric results.
;; For example, multiplying a large fixnum can produce a bignum or
;; exceed a narrow `positive-int` expectation; `benevolent` avoids
;; flagging those cases as errors.
;; This is different from `(or positive-int bignum)` because `benevolent`
;; is a deliberate *policy* choice: it relaxes strict checking without
;; committing to a precise widened union in every call site. In practice,
;; the “right” union may vary by implementation (fixnum vs bignum ranges),
;; or be too verbose to maintain; `benevolent` communicates intent without
;; overfitting the type.
(typespec #'times2
  (function (number) (benevolent positive-int)))
```

### Variable types (`var`) and constant values

`(var SYMBOL)` refers to the type of a Lisp variable by name.
It is intended for **globally defined** variables (`defconst`, `defcustom`,
or other global `defvar`-style bindings). It does **not** refer to lexical
or dynamically bound local variables.

- For `defconst` values, the variable is treated as a constant; a list
  of symbols is treated as a tuple of `const` values.
- For `defcustom` values, use the declared `:type` if present; this covers
  values that can change at runtime or be dynamically bound.
- Otherwise, the variable type is `unknown`.

Example:

```emacs-lisp
(defconst orders '(asc desc))
(var 'orders)
;; => (:tuple (const asc) (const desc))
(value-of (var 'orders))
;; => (or (const asc) (const desc))

(defun my-sorted-list (items order)
  "Return ITEMS sorted by ORDER."
  (let ((items (copy-sequence items)))
    (cl-sort items
             (if (eq order 'asc)
                 #'value<
               (lambda (a b) (value< b a))))))

(typespec #'my-sorted-list
  (:forall (a)
    (function ((list a) (value-of (var 'orders)))
              (list a))))
```

### Keyword Arguments (`&keys`) and plist helpers

When using `&keys`, treat keyword arguments as a plist:

- `&keys` is a plist type, typically `(:plist keyword mixed)` by default.
- `(plist-key-of P)` returns the key type of plist `P`.
- `(plist-value-of P)` returns the value type of plist `P`.
Note: the `(:plist keyword mixed)` default is a convention used by type
checkers when no more specific plist shape is provided. It is not a language
guarantee.

This allows a simple encoding of keyword-heavy functions without fixing
exact key sets in the core syntax.

Example with fixed keys:

```emacs-lisp
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

Example with `plist-key-of` / `plist-value-of`:

```emacs-lisp
;; Return the keys of a plist.
(typespec #'plist-keys
  (function (&keys) (list (plist-key-of &keys))))

;; Return the values of a plist.
(typespec #'plist-values
  (function (&keys) (list (plist-value-of &keys))))
```

### `cl-defun` keyword annotations and `&keys`

If a `cl-defun` uses keyword parameter annotations such as
`&key (:name string) (:age positive-int)`, a typespec consumer **may**
reflect those annotations into the `&keys` plist type. This syntax is
**not** standard `cl-defun`; it is an example of a *typespec-aware
annotation convention* that tools may support (for example, via
`cl-defun` metadata or out-of-band annotations). It does not change
runtime behavior.

If a keyword parameter has no default value, a type checker should
treat its type as `(or T nil)` *inside the function body*, because the
caller may omit the keyword. This rule applies to analysis of the
implementation, not to the external call signature.

Implementation sketch:

```emacs-lisp
(cl-defun make-user (&key (name "Anonymous") (age 0))
  (list :name name :age age))

;; The tool derives:
;; &keys => (:plist-of (:name string) (:age positive-int))
(typespec #'make-user
  (function (&keys (:plist-of
                    (:name string)
                    (:age positive-int)))
            (:plist-of
             (:name string)
             (:age positive-int))))
```

### Keyed plists (array-shapes)

`(:plist-of ...)` models a plist with fixed key names and per-key types,
similar to PHPStan array-shapes.

```emacs-lisp
(:plist-of
  (:name string)
  (:age non-negative-int)
  (:tags (list string))
  (:? :nickname string))
```

Keys are typically keywords, but any literal key is allowed (e.g. symbols
or strings) if that matches the actual plist usage. Use `(:? KEY TYPE)`
to mark an optional key.
When a key is optional, its value type is treated as `(or (const nil) TYPE)`
for plist helpers like `plist-get`/`plist-value-of`.

## Container Types

- `(list T)` — homogeneous list of `T`
- `(vector T)` — homogeneous vector of `T`
- `(sequence T)` — homogeneous sequence of `T`
- `(cons A B)` — cons cell with `car` of `A` and `cdr` of `B`
- `(hash-table K V)` — hash table mapping `K` to `V`
- `(:alist K V)` — association list of `(cons K V)` pairs
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

Note: `string` is a sequence and can be treated as a sequence of
character codes, i.e. `(sequence (fixnum 0 most-positive-fixnum))`.
This is a **structural view** that is useful for sequence-processing
code; it does not change the fact that `string` is also a distinct
base type. Therefore, `(sequence integer)` **does include** strings,
because strings are arrays whose elements are character codes.

### Sequences, Arrays, and Vectors

In Emacs Lisp, **sequence** is the union of **list** and **array**.

- **list**: cons-chain, variable length.
- **array**: fixed-length; includes strings, vectors, char-tables, and bool-vectors.
- **vector**: a kind of array.

Therefore, `(sequence T)` should be read as “either `(list T)` or an array of `T`”.
When element type matters for arrays, use `(vector T)` or a more specific array
type once it is introduced.

Example usage:

```emacs-lisp
;; Accepts any sequence (list, vector, string, etc).
(typespec #'seq-length (function ((sequence mixed)) integer))

;; Requires a proper list, not a vector or string.
(typespec #'car (function ((list mixed)) mixed))
```

## Tuple Types

Use `(:tuple T1 T2 T3)` for a fixed-length *proper list* tuple.

Use `(:tuple T1 T2 . T3)` for a fixed-length *cons-chain* tuple,
equivalent to `(cons T1 (cons T2 T3))`.

If this dotted form proves too hard to read, we can add explicit
keywords such as `:list-tuple` and `:cons-tuple` as aliases later.

Example usage:

```emacs-lisp
;; Proper-list tuple of two elements.
(typespec #'pair
  (function (unknown unknown) (:tuple unknown unknown)))

;; Cons-chain tuple: (a . (b . c)) where c is not necessarily a list.
(typespec #'cons-chain
  (function (unknown unknown unknown) (:tuple unknown unknown . unknown)))

;; Concrete dotted tuple example.
;; Value shape: (cons 'asc (cons 42 'done))
;; This is useful when the tail is *not* a proper list; it lets you
;; describe a fixed-length cons chain that ends in a non-list atom.
(typespec #'make-status
  (function (unknown) (:tuple (const asc) integer . (const done))))
```

## Constant Types

`(const VALUE)` is the type with exactly that value.

Optional shorthand (Elsa-style):

- `"foo"` is shorthand for `(const "foo")`
- `1` is shorthand for `(const 1)`
- `sym` is shorthand for `(const sym)`

Shorthands are convenient but can conflict with `cl-typep`’s atom usage.
Use `(const ...)` in ambiguous contexts. Type checkers should interpret
bare symbols as **types**, not literal constants. That means `string`
refers to the `string` type, while `(const string)` refers to the literal
symbol `string`.

## Nullable Types

There is no special “nullable” marker. Use union:

- `(or string nil)` for nullable strings

## Defcustom Compatibility (Non-Core)

Defcustom-style forms are intentionally **not** part of the core typespec.
If a consumer chooses to support them, they should be treated as extensions
and documented separately to avoid confusion with `cl-typep` semantics.

When interpreting defcustom types, `:completions` (added in Emacs 31) may be
treated as a fixed value set; in this case the values are used as a concrete
union of allowed constants. `:complete` (a completion function hook) is **not**
compatible with typespec evaluation and should be ignored by type consumers.
If a safe, deterministic mapping is proposed, support for `:complete` may be
added as an optional extension.

### Hook Types

`hook` is a special list type that represents a list of functions (typically
used for Emacs hooks). The canonical form is `(hook FUNTYPE . REST)` where
`FUNTYPE` specifies the function signature and `REST` may contain additional
metadata such as `:options`.

For defcustom `hook` types, interpret them as a hook type with explicit
arity. The default is a normal hook (zero-arg functions):
`hook` ⇒ `(hook (function () t))`.

If `:options` is present, it may be recorded as a value constraint without
changing the core type:

```emacs-lisp
(hook (function () t) :options (member foo bar))
```

The `:options` list is treated as UI metadata; it does not change the
callability rules.

Note: `hook` is a subtype of `list` in the Emacs type hierarchy, so it can
be used wherever a list is expected, but it carries additional semantic
meaning for hook-specific operations.

## Polymorphism / Type Variables

To express OCaml-style polymorphism:

```emacs-lisp
(:forall (a) (function (a) a))
```

`a` is a type variable; `:forall` binds it for the body.

### `:forall` Scope and Nesting

`(:forall (a b ...) BODY)` introduces type variables that are in scope
**only inside** `BODY`. Type variables are lexical: they do not leak to
surrounding forms.

Nested `:forall` forms shadow outer variables of the same name. For example,
the inner `a` is distinct from the outer `a`:

```emacs-lisp
(:forall (a)
  (function (a) (:forall (a) (function (a) a))))
```

To avoid shadowing, use distinct names or keep `:forall` at the outermost
function type where possible.

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

```emacs-lisp
(typespec #'identity (:forall (a) (function (a) a)))
```

### Max

```emacs-lisp
(typespec #'max
  (function ((or number marker) &rest (or number marker)) number))
```

### seq-map

```emacs-lisp
(typespec #'seq-map
  (:forall (a b)
    (function ((function (a) b) (sequence a)) (list b))))
```

For example, strings are sequences of characters, so:

```emacs-lisp
(seq-map #'identity "abc")
;; => (97 98 99)
```

### syntax-ppss

```emacs-lisp
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

```emacs-lisp
(typespec #'not (function (unknown) boolean))
```

`or` is a special form (not a regular function), but for documentation
purposes a coarse type can be written as:

```emacs-lisp
(typespec #'or (function (&rest unknown) unknown))
```
