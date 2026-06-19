# `unknown` is the gradual dynamic, conceptually separate from `mixed`/top

The **gradual dynamic** ("we don't know yet — treat as compatible, never an
error") and the **top** type (the universal supertype of all values) are
*separate concepts*. typespec's type system owns the distinction and gives them
separate spellings:

- **`unknown`** — the gradual dynamic. Consistent with every type in **both**
  directions: a value typed `unknown` is acceptable wherever any type is
  expected, and an `unknown` parameter accepts any argument. Unsound by design;
  it is *never* a provable incompatibility, so it is *never* a `:cause-error`.
- **`mixed`** (and the Emacs Lisp top `t`) — the top type, the universal
  supertype. On the expected side it soundly accepts anything.

This is the typespec-side half of the coordination recorded in elistan
[ADR-0003](../../../elistan/docs/adr/0003-elistan-holds-reins-typespec-toolkit.md)
("elistan holds the reins; typespec is a low-level type toolkit") and
[ADR-0004](../../../elistan/docs/adr/0004-robustness-posture.md) ("report only
provable incompatibilities"). elistan's "no information" default for every
un-narrowed variable **is** the gradual dynamic, spelled `unknown`; it relies on
typespec treating `unknown` as consistent in both directions so that the default
never produces a false positive.

## Decision

1. **Separate the dynamic from top.** `unknown` is the gradual dynamic;
   `mixed`/`t` is top. They are no longer conflated in the assignability check.
2. **`unknown` is consistent in both directions.**
   `typespec-eval-call--type-compatible-p` accepts `unknown` (or a union that
   *contains* `unknown`, per the gradual consistency rule) on either side. A new
   helper `typespec-eval-call--dynamic-p` recognises the dynamic structurally —
   `unknown`, or any `(or …)` with a dynamic member — so the rule holds even for
   an un-normalised union.
3. **`typespec-eval-call` never `:cause-error`s on a dynamic argument.** Because
   it validates arguments through `type-compatible-p`, an `unknown` argument
   (or `(or … unknown)`) now types the application instead of yielding
   `(:cause-error (wrong-type-argument …))`.
4. **The dynamic stays dynamic under set-difference.** `(diff unknown T) ≡
   unknown`, so the `:guard!` false branch of a narrowing on a not-yet-known
   value stays `unknown` rather than leaving a `(diff unknown …)` residue. (The
   true branch already refines: `(and unknown T) ≡ T`.) Contrast top: `mixed`'s
   complement `(diff mixed T)` is a real, subtractable universe.

## `mixed` value-side assignability: kept as an escape hatch (deliberate)

`mixed`/`t` remain **assignable from** as well as to — a value typed `mixed`/`t`
is still accepted wherever a concrete type is expected. This value-side
behaviour is unsound (a `mixed` value could be anything), and now that a proper
gradual dynamic exists we considered tightening it. We deliberately **do not**:

- `t` is the genuine Emacs Lisp top (`(t sequence atom)` in the hierarchy);
  every runtime value *is* a `t`. A great many operation handlers fall back to
  `mixed`/`t` when they cannot infer a result. Tightening would convert that
  whole class of "couldn't infer" results into false positives — the exact
  opposite of the robustness posture.
- The reason we needed a *separate* dynamic was so a consumer can choose the
  no-false-positive default (`unknown`) **without** conflating it with top.
  Soundness for the not-yet-known case is now carried by `unknown`; we do not
  need to tighten `mixed` to get it. Code that wants the never-an-error
  guarantee should use `unknown`, not `mixed`.
- Keeping `mixed`/`t` as an escape hatch preserves backward compatibility for
  consumers and the existing `typespec-eval-call-soundness` tests.

The conceptual line: `unknown` lives in the **consistency** relation (both
directions, unsound by design); `mixed`/`t` is top in the **assignability**
sense, with a retained value-side escape hatch. Neither participates in the
strict subtyping relation `typespec-eval-types-type-subtype-p` — there they are
simply outside the lattice (the strict relation is the sound one a consumer can
build on when it does *not* want the escape hatch).

In union normalisation both still absorb (`(or T unknown) ≡ unknown`, `(or T
mixed) ≡ mixed`, top winning over the dynamic): collapsing `(or T dynamic)` to
the dynamic loses no *checking* power, since the union is consistent with
everything either way.

## Consequences

- **Cross-repo dependency:** elistan depends on this behaviour. Its no-information
  default and consistency-based acceptance test (elistan ADR-0003 / ADR-0004)
  assume `unknown` is the both-direction dynamic and that `typespec-eval-call`
  does not reject `unknown` arguments. Changing the meaning of `unknown` here is
  a breaking change for elistan and must be coordinated.
- **One behaviour change in this repo:** under gradual consistent-subtyping a
  function with a concrete parameter is now assignable where a function with a
  dynamic (`unknown`) parameter is expected — e.g. `(function (string) integer)`
  is accepted where `(function (unknown) integer)` is required (the contravariant
  param check goes through `type-compatible-p`, and `unknown ~ string`). This was
  previously rejected; it is now consistent, not a provable incompatibility.
  (`typespec-eval-call-soundness`, `typespec-eval-call-gradual-dynamic`.)
- The strict subtyping relation is unchanged: `type-subtype-p` still treats
  `unknown` and `mixed` as outside the lattice.

(Derived from the positioning of [Rigor](https://rigor.typedduck.fail) and its
ADR-5 robustness principle, same author; mirrors elistan ADR-0003/ADR-0004.)
