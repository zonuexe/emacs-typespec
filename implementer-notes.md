# Typespec Implementer Notes

This document collects guidance for implementers who need to reduce or
normalize rich typespec forms into simpler type systems.

These notes are not part of the core specification; they describe pragmatic
lowerings for tooling (e.g., Elsa) that cannot express every typespec feature.

## General approach

- Prefer **sound** or **fail-closed** reductions when information is missing.
- When in doubt, reduce to a broader type only if the target system treats it
  as safe (avoid introducing implicit downcasts).
- Keep a single direction of compatibility: accept typespec input, emit a
  simpler output that your tool understands.

## Suggested lowering rules (examples)

### Literal and range types

- `(const 42)` => `integer`
- `(const 3.14)` => `float`
- `positive-int` / `negative-int` / `non-negative-int` / `non-positive-int`
  => `integer`
- `positive-float` / `negative-float` => `float`
- `(integer LOW HIGH)` => `integer`
- `(float LOW HIGH)` / `(real LOW HIGH)` / `(number LOW HIGH)` => `number`

### Numeric helpers

- `(generalize T TARGET)` => `TARGET`
- `(generalize-signed T)` => sign-preserving numeric type when you can
  distinguish literals; otherwise `never` (fail closed)
- `(generalize-signed (const 42))` => `positive-int`
- `(generalize-signed (const -42.0))` => `negative-float`

### Generics and dependent utilities

- `(:forall (a b ...) BODY)` => `BODY` with type variables collapsed to
  `unknown` or `mixed` (pick one and be consistent)
- `(if COND T1 T2)` => `(or T1 T2)` (when `COND` cannot be evaluated)
- `(value-of (:tuple T1 T2 ...))` => `(or T1 T2 ...)`
- `(value-of ...)` (non-tuple) => `unknown`
- `(var SYMBOL)` => `unknown`

### Collections and structural types

- `(:tuple ...)` => `(list mixed)` or a fixed-length tuple if supported
- `(:alist K V)` => `(list (cons K V))` or `(list mixed)`
- `(:plist K V)` => `(list mixed)` (or a plist type if supported)
- `(:plist-of ...)` => `(plist ...)` or `(list mixed)`
- `(:class CLASS)` => a nominal class type if supported, otherwise `mixed`

### Guards, assertions, and permissive escapes

- `:guard` return types => `bool`
- `:assert` return types => the asserted type
- `(downcast T TARGET)` => `TARGET` (treat as explicit assertion)
- `(benevolent T)` => `T` but consider emitting a warning marker or lowering
  confidence if supported (this is an explicit soundness trade-off)
- `(:cause-error INFO)` => treat as `never` or preserve as an error marker
  (recommended: keep INFO for diagnostics, but exclude it from normal flows)

### Conditional return types (tooling caveat)

Many analyzers (including Elsa) do not support conditional return types as a
first-class feature. For such tools, treat conditional returns as unions:

- `(if COND T1 T2)` => `(or T1 T2)`

This preserves a safe over-approximation without requiring flow-dependent
return typing.

## Example: Elsa-style lowering

If your target system only supports basic primitives and simple function
types, a practical approach is:

- Collapse literals and numeric refinements to base numeric types.
- Turn complex list/tuple/plist structures into `list` or `mixed`.
- Treat `:forall` as an erasure step.
- Avoid implicit downcasts; prefer `unknown`/`mixed` only when necessary.

This yields stable, conservative types while still benefiting from
user-written typespecs.
