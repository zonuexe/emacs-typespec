# AGENTS.md — emacs-typespec

Guidance for an AI agent working in this repo. (`CLAUDE.md` is a symlink to
this file.) Keep it accurate as the project evolves.

## What this is

emacs-typespec is a **type-operations foundation** for Emacs Lisp, plus the
`typespec` macro that attaches a type spec to a function. It is meant to be
*consumed* by other libraries: a type checker ([elistan](../elistan)) and a
property-based testing tool (an extension of zonuexe/parameterized-ert.el /
ert-fnspec-check).

## Scope boundary (read first)

- typespec owns the **meaning of the type notation**: the type algebra
  (`or`/`and`/`diff`/`not`), normalization, subtyping, type-level evaluation,
  the guard/assert **narrowing effect** (`typespec-eval-call-narrowing`), and
  typespec resolution. These are pure type operations.
- **Non-goals:** walking real Emacs Lisp source, macro expansion, call
  resolution. The evaluator processes **typespec forms** (the type DSL — a
  subset of Emacs Lisp), not Emacs Lisp programs.
- The type **checker** (orchestration over code: type environments, threading
  types through control flow) is a separate repo, `../elistan`. Do not build
  checker drivers here.
- Litmus: a pure function of types/values → belongs here; walks or drives a
  program / test process → belongs in a consumer.

## Layout

- `typespec.el`, `typespec-core.el` — the `typespec` macro and its record
  (carries a baseline version + resolver snapshot).
- `typespec-eval*.el` — the type-level evaluator, split by responsibility:

| Module | Prefix | Role |
|---|---|---|
| `typespec-eval.el` | `typespec-eval`, `typespec-eval--` | Entry `typespec-eval`; `pcase` dispatcher `typespec-eval--eval`; `typespec-eval-call`; `typespec-eval-call-narrowing`. |
| `typespec-eval-core.el` | `typespec-eval--` | const/nil helpers, range constructors. |
| `typespec-eval-types.el` | `typespec-eval-types-` | type category, `*-type-p`, `non-*-type-p`, subtype (`type-subtype-p`, `--elisp-subtype-p`), guard resolution, `disjoint-p`. |
| `typespec-eval-struct.el` | `typespec-eval-struct-` | list/alist/plist/cons/tuple `*-form-p` and accessors. |
| `typespec-eval-simplify.el` | `typespec-eval-simplify-` | `simplify-or`, `simplify-and`, intersect/merge. |
| `typespec-eval-numeric.el` | `typespec-eval-numeric-` | numeric range arithmetic & normalization. |
| `typespec-eval-op.el` | `typespec-eval-op-` | one op handler per typespec form (alphabetical); `if`, validation. |
| `typespec-eval-var.el` | `typespec-eval-var--` | `(var SYM)` resolution. |

## Key entry points consumers use

- `typespec-eval` — normalize/evaluate a typespec form.
- `typespec-eval-call` — type a function application (or `(:cause-error …)`).
- `typespec-eval-call-narrowing` — guard/assert refinement effect.
- `typespec-eval-simplify-or` / `typespec-eval-op-and` / `typespec-eval-op-diff`.
- `typespec-eval-types-type-subtype-p`.
- Resolve a function's declared spec: `(plist-get (function-get SYM 'typespec) :spec)`.

## Conventions

- Emacs 29.1+, `lexical-binding: t`. GPL-3.0-or-later; USAMI Kenta <tadsan@zonu.me>.
- Naming: `*-type-p` = type category (in `-types`); `*-form-p` = structure
  shape (in `-struct`); internal helpers use `--`.
- `nil` is normalized to `(const nil)`. Inference is conservative: unknown
  types yield `boolean`/`unknown`, never a false positive.
- `unknown` is the **gradual dynamic** (consistent with every type in *both*
  directions; never a `:cause-error`), conceptually separate from the **top**
  type `mixed`/`t`. See `docs/adr/0001-unknown-gradual-dynamic.md` (elistan
  depends on this).
- Pass-through forms (left for a full checker): `(:class …)`, `(:forall …)`,
  `(var …)`, `(benevolent …)`.

## Commands

- `make check` — clean → tests (source) → byte-compile → tests (compiled).
- `make test-core` / `make test-eval` / `make compile` / `make clean`.

## Docs (sources of truth — keep updated with changes)

- `docs/typespec.md` — the notation / grammar.
- `docs/type-level-evaluation.md` — guards, conditional return types, narrowing.
- `docs/conformance.md` — exactly what the evaluator implements, plus known gaps.
- `docs/adr/` — architecture decisions (e.g. `0001` `unknown` as the gradual
  dynamic; mirrors elistan's coordination ADRs).

## Extending (brief)

- New predicate: add a `pcase` arm in `typespec-eval--eval` calling
  `typespec-eval-op-unary-predicate`; define `*-type-p`/`non-*-type-p` in
  `typespec-eval-types.el` and a category entry.
- New operation: add a `typespec-eval-op-*` handler (alphabetical) + a `pcase`
  arm. Update `docs/conformance.md` and add a test.
- A new **pure type operation** a consumer needs → add it here, not in the
  consumer.
