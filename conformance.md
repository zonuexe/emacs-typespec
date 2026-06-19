# Reference Implementation Conformance

This document tracks how the bundled reference evaluator (`typespec-eval`,
implemented across `typespec-eval*.el`) conforms to the language defined in
[`typespec.md`](typespec.md) and
[`type-level-evaluation.md`](type-level-evaluation.md).

**Scope note.** `typespec-eval` is a *type-level evaluator* — it performs
constant folding, type inference, and range arithmetic. It is **not** a full
type checker. Several constructs are intentionally passed through for a
downstream checker to handle (`:class`, `:forall` outside call sites, `var`,
`benevolent`, and the *refinement effects* of `:guard`/`:guard!`/`:assert`).
Those are marked **checker-level** below; they are not defects.

The relation `S <: T` and the normalization rules in `typespec.md` describe the
*language*. A conforming tool must keep the relation **sound** (never claim
`S <: T` unless it holds). Where the current evaluator violates that, it is
listed under *Known soundness bugs*, and the spec — not the code — is taken as
correct.

Legend:

- ✅ implemented and consistent with the spec
- ◑ partially implemented
- ⬚ checker-level — intentionally deferred to a full type checker
- ✗ not implemented
- ⚠ implemented but currently **unsound** (a known bug; see that section)

## Subtyping / assignability

Compatibility is decided by two category-driven functions:
`typespec-eval-types-type-subtype-p` (`typespec-eval-types.el`) and
`typespec-eval-call--type-compatible-p` (`typespec-eval.el`). Both collapse a
type to one of ~15 coarse *categories* and accept when the categories match or
are related by a small hand-coded lattice. The Emacs type hierarchy lives
inline in `typespec-eval-types.el` (there is no `elisp_type_hierarchy.txt`
file; the link in `typespec.md` points at the upstream Emacs source only).

| Spec rule | Status |
| --- | --- |
| `unknown` is top (`T <: unknown`) | ✅ |
| `unknown <: T` only when `T` is `unknown`/`mixed` | ✅ |
| `fixnum <: integer`, `bignum <: integer` | ✅ |
| `integer`/`float` disjoint; `real`/`number` ≡ `(or integer float)` | ✅ |
| `marker`, `integer-or-marker`, `number-or-marker` placement | ✅ |
| `hook <: list <: sequence` | ✅ |
| Container **kind** relations (`vector <: array <: sequence`, `list <: sequence`) | ✅ |
| `never` is bottom (`never <: T`) | ✅ |
| `mixed`/`t` are bidirectional (assignable *from* as well as *to*) | ✅ |
| `character <: fixnum` | ✅ |
| Range containment (`(integer a b) <: (integer c d)`) | ✅ |
| Container element types compared (invariant) | ✅ |
| Parametric cross-kind containers (`(list E) <: (sequence E)`, `string <: (sequence character)`, …) | ✅ |
| Tuple subtyping (`(:tuple …)` elementwise; `(:tuple …) <: (list T)`) | ✅ |
| `cons` / `:alist` / `:plist` structural subtyping (invariant) | ✅ |
| `(list+ T) <: (list T)` only (not the reverse) | ✅ |
| Function variance (params contravariant, return covariant) | ✅ |
| `(or A1…An) <: T` iff every `Ai <: T` (value-side union) | ✅ |
| `(const v) <: T` iff `v` inhabits `T` (range/bounds checked) | ✅ |
| `fixnum`/`bignum` disjoint | ✅ — handled explicitly (`bignum` is the integers outside the fixnum range) |

## Normalization and equivalence

Implemented in `typespec-eval-simplify.el` and `typespec-eval-numeric.el`.

| Spec rule | Status |
| --- | --- |
| `(or)` ≡ `never` | ✅ |
| `(or T)` ≡ `T`; `(and T)` ≡ `T` | ✅ |
| `or` flatten + de-duplicate | ✅ |
| Constant equality via `equal` (`(const 1)` ≠ `(const 1.0)`) | ✅ |
| `and`: drop `mixed`; `never` collapses to `never` | ✅ |
| `nil` normalized to `(const nil)` | ✅ |
| Containers holding `never` are **not** auto-reduced | ✅ |
| `(diff A A)` ≡ `never` | ✅ |
| Float keyword aliases expand to range forms | ✅ |
| `(and)` ≡ top | ◑ — evaluator emits `mixed` (equivalent, since `t` ≈ `mixed`) |
| Integer keyword aliases (`positive-int`, `fixnum`, …) normalized | ◑ — only inside numeric ops, not at top level |
| `or` drops `never`; a top member (`mixed`/`t`/`unknown`) collapses the union | ✅ |
| `or` drops members subsumed by another (`(or fixnum integer)` ≡ `integer`) | ✅ — uses the raw elisp hierarchy, so same-category pairs like fixnum/integer reduce |
| `and` drops bare `t`; `and` is flattened | ✅ |
| Provably disjoint base types intersect to `never` (`(and integer string)`) | ✅ — `nil`-sharing categories (`symbol`/`list`/…) excluded |
| Intersection reduces identical and base-symbol subtype pairs (`(and vector array)` ≡ `vector`, `(and string string)` ≡ `string`) | ✅ — symbol-only (coarse `type-subtype-p` is imprecise for parametric forms) |
| Bare range literals normalized (`(integer n n)` ≡ `(const n)`, inverted ≡ `never`, `(integer * *)` ≡ `integer`) | ✅ |
| Integer range union merge | ✅ — overlapping/adjacent integer ranges in an `or` merge (`(or (integer 0 4) (integer 5 9))` ≡ `(integer 0 9)`); floats are not merged |
| `(:tuple)` ≡ `(const nil)`; `(list+ T)` / `(:alist K V)` expansion | ✗ (opt-in normalizations; surface form preserved) |
| `(not (not T))` ≡ `T`, `(not never)` ≡ `t`, etc. | ◑ — via the complement spelling `(diff mixed T)`; bare `(not T)` is the predicate (see *the `not` overload*) |

## Return-position evaluation

Implemented in `typespec-eval.el` (`typespec-eval-call`) and
`typespec-eval-op.el`.

| Spec rule | Status |
| --- | --- |
| `:guard T` / `:guard! T` actual return is `boolean` | ✅ |
| `:assert T` return is `T` | ✅ |
| `(if PRED THEN ELSE)` symbolic eval; unprovable ⇒ `(or THEN ELSE)` | ✅ |
| `(:cause-error INFO)` production; INFO shapes match the spec | ✅ |
| `(value-of (:tuple …))` ≡ `(or …)`; dotted tail included; `(var 'SYM)` resolved first | ✅ |
| `:forall` type-variable substitution at call sites | ✅ |
| Argument-refinement effect of `:guard`/`:guard!`/`:assert` (first positional arg) | ⬚ checker-level |
| `:guard!` false branch ⇒ `(not T)` (distinct from `:guard`) | ⬚/◑ — both currently collapse to `boolean` |
| Optional second slot `(:guard T RET)` / `(:guard! T RET)` | ✅ — RET is the true-branch return type (defaults to `boolean`) |
| `if` PRED rejects disallowed/state-dependent predicates | ✅ — denylist (`typespec-conditional-disallowed-functions`) yields `(:cause-error (invalid-predicate …))`; other forms keep the sound `(or …)` fallback |
| `(if …)`/`:guard`/`:guard!`/`:assert` valid only in the RETTYPE slot | ✅ — `typespec-eval` returns `(:cause-error (misplaced-rettype …))` when one appears in a container, union, or argument position |
| `&args` / `&rest` as meta-position actual-argument tuples | ✅ — substituted with the actual-argument tuples at the call site |

## Structural and utility types

Implemented in `typespec-eval-struct.el`, `typespec-eval-var.el`, and
`typespec-eval-op.el`.

| Spec rule | Status |
| --- | --- |
| `:plist-of` sealed by default; `&allow-other-keys` opens it | ✅ (enforced at call sites) |
| Optional `(:? KEY TYPE)` value type is `(or (const nil) TYPE)` for helpers | ✅ |
| `generalize T TARGET` | ✅ (returns `TARGET` for a const or proven subtype; otherwise conservatively preserves the wrapper) |
| `generalize-signed` (all sign/zero/numeric/`unknown`/`mixed` cases) | ✅ (also returns `never` for any non-numeric type) |
| `downcast T TARGET` ⇒ `TARGET` | ✅ |
| `benevolent T` ⇒ wrapper preserved, inner evaluated | ✅ |
| `(var 'SYM)` (`defconst` ⇒ const/tuple; `defcustom` ⇒ declared `:type`; else left as `(var 'SYM)`) | ✅ |
| `(:tuple)` / dotted-tuple / `list+` / `:alist` rewritten to equivalents | ✗ (opt-in; semantics honored, surface form preserved) |

## Soundness fixes (resolved)

The following unsoundness in `typespec-eval-call--type-compatible-p` has been
fixed (see `typespec-eval-call-soundness` in `typespec-eval-test.el`):

1. **`never` is now the bottom type** — assignable to any parameter.
2. **`mixed`/`t` values are assignable anywhere** (escape hatch / universal).
3. **Numeric range bounds are consulted** — `(integer 0 10)` is rejected where
   `(integer 2 5)` is required, and `(const 50)` where `(integer 0 10)` is.
4. **Container element types are invariant** — `(vector fixnum)` and
   `(vector integer)` no longer interchange.
5. **`(list T) <: (list+ T)` is rejected** (a possibly-empty list is not a
   non-empty list); `(list+ T) <: (list T)` still holds.
6. **`character` is in the hierarchy** as a subtype of `fixnum`.
7. **Function types use variance** — contravariant parameters, covariant
   return (simple positional signatures), with invariance as a sound fallback.
8. **Value-side `(or …)` is decomposed** — every member must be compatible.
9. **`(const v)` inhabitance honors range bounds**, not just the category.
10. **`fixnum`/`bignum` are disjoint.** `numeric-subtype-p` special-cases
    `bignum` (the integers outside the fixnum range), so `fixnum <: bignum`,
    `bignum <: fixnum`, and `(integer 0 5) <: bignum` are all rejected, while
    `bignum <: integer`/`number` hold.

## Spec features not yet implemented

- Argument-refinement effects of `:guard`/`:guard!`/`:assert` (checker-level).
- `:guard!` false-branch complement (distinct behavior from `:guard`).
- Bare `(not T)` as a **type complement** — intentionally not done; use
  `(diff mixed T)` (see below).

## Evaluator behaviors now documented

These were implemented before the spec described them, and are now written up:

- **`(or (const t) (const nil))` ≡ `boolean`** — `typespec.md` § Normalization.
- **`if`-rx narrowing** (`string-match-p`/`string-prefix-p`/`string-suffix-p`/
  `string=` synthesize an `(rx …)` THEN type) —
  `type-level-evaluation.md` § String-predicate narrowing.
- **Intersection range arithmetic** and the **range → `fixnum` collapse** —
  `typespec.md` § Normalization.
- **Rich `defcustom :type` → typespec translation** — `typespec.md` § Variable
  types.
- **`&allow-other-keys`** (open `:plist-of`) — `typespec.md` § Keyed plists.
- **`&key` → `&keys`** argument-list alias at call sites — the `cl-defun`
  convenience covered by `typespec.md` § cl-defun keyword annotations.

## The `not` overload

The symbol `not` is used in two roles:

- As a **type combinator**, `(not T)` is the complement (`(diff mixed T)`), per
  `typespec.md`.
- As a **boolean predicate** inside `if` PRED positions, `(not expr)` negates a
  truth value.

**Resolution.** The reference evaluator implements `not` as the **boolean
predicate** — and this is intentional, not a gap. `(not string)` folds to
`(const nil)` (a string is always non-nil), `(not (list T))` to `boolean`
(a list may be the empty list, i.e. `nil`), and so on. This reading is required
by the conditional predicate language (`(if (not x) …)`) and is locked in by
tests; overloading the same `(not X)` to also mean a type complement would
break it.

The type complement is therefore spelled `(diff mixed T)`, which the spec
defines as equivalent to `(not T)`. The evaluator handles it fully:
double-negation eliminates (`(diff mixed (diff mixed T))` ≡ `T`), subtracting a
top type yields `never` (`(diff mixed mixed)`/`(diff mixed t)`/
`(diff mixed unknown)`), and subtracting `never` yields `mixed`. See
`typespec-eval-diff-complement` in `typespec-eval-test.el`.
