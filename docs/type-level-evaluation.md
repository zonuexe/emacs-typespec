# Type-level Evaluation

This document defines how typespec evaluates predicate-like constructs
and conditional types. This is separate from the syntax overview in
`typespec.md`.

The constructs described here — `:guard`, `:guard!`, `:assert`, and the
conditional `(if PRED ...)` — are the `RETTYPE` forms in the grammar: they are
valid **only** as the return slot of a `(function ARGS RETTYPE)` type, never as
a general `TYPE` in arguments, containers, or unions.

## Type Guards (TypeScript-style)

To model type-guard predicates (e.g., `x is string` in TypeScript),
use a `:guard` return type:

```emacs-lisp
(function (unknown) (:guard string))
```

This means the function returns a boolean value, and on success it
refines the checked value to `string` in the caller context. The
`boolean` return is implicit; you do not need to write it separately.
So the *actual* return type is `boolean`, and `:guard` adds a refinement
effect on the first argument.

The refined value is the **first positional argument** of the function.
For multi-argument predicates, only the first argument is refined; the
others are unchanged.

Important: `:guard` narrows only on the *true* branch. The *false* branch
does not imply the complement type, because many predicates are not total
(e.g. a regexp-based predicate). If you want a predicate that partitions
the input type into true/false cases, use `:guard!` instead.

```emacs-lisp
(function (unknown) (:guard! string))
```

`(:guard! T)` means the true branch narrows to `T` and the false branch
narrows to `(not T)`. In Psalm, the default `assert-if-true` is exclusive,
and `=type` relaxes that; typespec keeps the TypeScript-style guard semantics
for `:guard` and uses `:guard!` to make exclusivity explicit.

Example: total predicate, use `:guard!`:

```emacs-lisp
(typespec #'stringp
  (function (unknown) (:guard! string)))
```

For a partial predicate example, see `jp-postal-code-p` in the `rx` section.

## Assertion Guards

For assertion-style helpers that signal an error on failure and refine
the argument on success, use `:assert` as the return type:

```emacs-lisp
(defun assert-int (value)
  "Signal an error unless VALUE is an integer; return VALUE."
  (unless (integerp value)
    (signal 'wrong-type-argument (list 'integerp value)))
  value)

(typespec #'assert-int (function (unknown) (:assert integer)))
```

This means the function either signals an error or returns normally,
and on the normal path the first argument is treated as `integer`.
The return value is also treated as that same refined type.
In other words, `:assert` is shorthand for “this function returns the
checked value and refines it on success.”

### Computing the refinement effect

The reference evaluator exposes `typespec-eval-call-narrowing` as a building
block for a flow-sensitive checker. Given a guard/assert function spec and the
actual argument types at a call site, it returns how the first positional
argument is refined per branch, computed from the argument's incoming type
`ARG0`:

- `:guard T` → true branch `(and ARG0 T)`; false branch unchanged (the
  predicate may be partial).
- `:guard! T` → true branch `(and ARG0 T)`; false branch `(diff ARG0 T)`.
- `:assert T` → success path `(and ARG0 T)`.

For example, narrowing `(:guard! string)` against an argument typed
`(or string integer)` yields `string` on the true branch and `integer` on the
false branch.

This narrowing *effect* is a pure type operation, so it lives in the
foundation.  Orchestrating it over real code — a type environment
(`var -> type`), threading it through `if`/`cond`/`and`/`or`/`let`, and joining
at confluences — is a type-checker concern and lives in the separate
[elistan](https://github.com/zonuexe/elistan) project, which consumes
`typespec-eval-call-narrowing`.

### Optional result type for `:guard` / `:guard!`

Some predicates return a useful non-boolean value on the true branch
(`bound-and-true-p`-style helpers). You can express that with an
optional second component:

```emacs-lisp
(function (unknown) (:guard string STRING))
(function (unknown) (:guard! string STRING))
```

- The first slot (`string` above) is the refinement target for the
  *argument*.
- The optional second slot (`STRING` above) is the *returned* value type
  on the true branch. If omitted, it defaults to `boolean`.
- For `:guard!`, the false branch refines the argument to `(not string)`
  and the return is `nil` (or `boolean` if no return slot is given).

Example (true-branch returns the *bound value* of the symbol; the
argument itself is still the symbol):

```emacs-lisp
(typespec #'bound-and-true-p
  ;; bound-and-true-p returns the variable's value (unknown type here),
  ;; while refining that the symbol is non-nil and bound.
  (function (symbol) (:guard t unknown)))
```

## `:cause-error` (diagnostic pseudo-type)

Type-level evaluation can return `(:cause-error INFO)` when a call is
invalid (e.g. wrong number of arguments or wrong argument type). This
is a diagnostic marker, not a runtime value. Tools may treat it as
`never` for flow purposes, or preserve it to report detailed errors.

Another example with a state-dependent predicate (allowed here, but not
inside `if` predicates):

```emacs-lisp
(defun ensure-live-process (proc)
  "Signal an error unless PROC is a live process; return PROC."
  (unless (process-live-p proc)
    (signal 'wrong-type-argument (list 'process-live-p proc)))
  proc)

(typespec #'ensure-live-process (function (process) (:assert process)))
```

`process-live-p` is state-dependent, so it is not allowed in `if` predicates,
but it is fine inside `:assert` because the check happens at runtime.

## Function Call Evaluation (`typespec-eval-call`)

The `typespec-eval-call` function evaluates function application at the type
level. It takes a function type specification and a list of argument types,
and returns either the result type or a `(:cause-error ...)` form.

### Argument Validation

`typespec-eval-call` validates:
- **Argument count**: Checks that the number of arguments matches the function's
  required and optional parameters.
- **Argument types**: Validates that each argument type is compatible with the
  corresponding parameter type using subtype checking.
- **Keyword arguments**: For `&keys` parameters, validates that keyword-value
  pairs match the expected plist structure, with optional `&allow-other-keys`
  support.

### Type Variable Substitution

When the function type includes `:forall` (polymorphic types), `typespec-eval-call`
substitutes type variables with the actual argument types. For example:

```emacs-lisp
(typespec-eval-call '(:forall (a) (function (a) a)) '("foo"))
;; => (const "foo")
```

The type variable `a` is substituted with the argument type `(const "foo")`,
and the return type becomes `(const "foo")`.

### Error Reporting

When validation fails, `typespec-eval-call` returns `(:cause-error INFO)` where
`INFO` is a list describing the error:

- `(wrong-number-of-arguments N)` - Too few or too many arguments
- `(wrong-type-argument EXPECTED ACTUAL)` - Type mismatch

Example:

```emacs-lisp
(typespec-eval-call '(function (number) (const t)) '("foo"))
;; => (:cause-error (wrong-type-argument number "foo"))
```

### Subtype Checking

`typespec-eval-call` uses the Emacs Lisp type hierarchy (as defined in
`elisp_type_hierarchy.txt`) to determine type compatibility. For example,
`fixnum` is compatible with `integer`, which is compatible with `number`:

```emacs-lisp
(typespec-eval-call '(function (number) (const t)) '(fixnum))
;; => (const t)
```

## Downcast and Benevolent

### `downcast`

`(downcast VALUE TARGET)` is an explicit cast. At type-evaluation time it
reduces to `TARGET`, regardless of the inferred type of `VALUE`. This is
intentionally *unsafe* and is meant to be used only when you have
out-of-band knowledge that `VALUE` is compatible with `TARGET`.

Type checkers should treat `downcast` as an assertion: it does **not**
require `VALUE` to be a subtype of `TARGET`, but it should be visible in
diagnostics when a mismatch would otherwise be flagged.

### `benevolent`

`(benevolent T)` is a **soft constraint** that relaxes strict checking.
The evaluator preserves the wrapper and only evaluates the inner type:

```
(benevolent T) => (benevolent (eval T))
```

Type checkers should treat this as “accept `T` if possible, but allow
broader values without error.” A practical default policy is:

- If the value’s type is a subtype of `T`, accept it normally.
- Otherwise, allow it **without widening** the value’s inferred type.
  This keeps the exact type information while suppressing errors.

This is distinct from an explicit union like `(or T other)`; `benevolent`
is a *policy marker* rather than a concrete type expansion.

## Conditional Return Types (Restricted)

To keep conditional types predictable, only a small, safe predicate
language is allowed. The condition can use these operators:

Special forms:
- `if`

Predicates (type/shape checks):
- `stringp`, `integerp`, `symbolp`, `null`
- `consp`, `atom`, `listp`, `nlistp`
- `keywordp`, `vectorp`, `recordp`, `arrayp`, `sequencep`
- `bufferp`, `markerp`, `bool-vector-p`
- `integer-or-marker-p`, `numberp`, `number-or-marker-p`, `floatp`, `natnump`
- `booleanp`, `proper-list-p`, `fixnump`, `bignump`, `wholenump`
- `functionp`, `hash-table-p`
- `subrp`, `byte-code-function-p`, `interpreted-function-p`, `closurep`,
  `module-function-p`
- `char-or-string-p`, `char-table-p`, `char-uppercase-p`
- `string-empty-p`, `string-blank-p`, `string-or-null-p`
- `multibyte-string-p`, `vector-or-char-table-p`
- `bare-symbol-p`, `symbol-with-pos-p`

Comparators:
- `=`, `/=`, `>`, `>=`, `<`, `<=`
- `value<`
- `char-equal`
- `string<`, `string>`, `string=`
- `string-lessp`
- `equal`, `eql`, `eq`, `equal-including-properties`

Sequence and list accessors:
- `car`, `cdr`, `car-safe`, `cdr-safe`, `nth`, `nthcdr`, `elt`, `aref`, `length`
- `reverse`, `last`, `butlast`, `safe-length`, `copy-sequence`
- `memq`, `member`, `member-ignore-case`
- `assoc`, `assq`, `rassoc`, `alist-get`
- `plist-get`, `plist-member`

Numeric and math helpers:
- `zerop`, `number-sequence`
- `+`, `-`, `*`, `/`, `%`, `mod`, `1+`, `1-`, `abs`, `max`, `min`
- `floor`, `ceiling`, `round`, `truncate`, `isnan`, `cl-signum`
- `logand`, `logior`, `logxor`, `lognot`, `logcount`, `ash`

String helpers:
- `concat`, `string-bytes`
- `string-chop-newline`, `string-clean-whitespace`, `string-distance`
- `string-equal`, `string-equal-ignore-case`, `string-greaterp`, `string-lessp`
- `string-join`, `string-limit`, `string-lines`, `string-match`, `string-match-p`
- `upcase`, `downcase`, `capitalize`, `char-to-string`, `make-string`, `substring`
- `string-pad`, `string-prefix-p`, `string-remove-prefix`, `string-remove-suffix`
- `string-replace`, `string-search`, `string-split`, `string-suffix-p`
- `string-to-char`, `string-to-list`, `string-to-multibyte`, `string-to-number`
- `string-to-unibyte`, `string-to-vector`, `string-trim`, `string-trim-left`
- `string-trim-right`, `string-truncate-left`, `string-version-lessp`
- `number-to-string`

Version helpers:
- `version-list-<`, `version-list-<=`, `version-list-=`
- `version-list-not-zero`, `version-to-list`, `version<`, `version<=`, `version=`

CL and seq helpers:
- `cl-plusp`, `cl-minusp`, `cl-evenp`, `cl-oddp`, `cl-equalp`, `cl-endp`
- `cl-first`, `cl-second`, `cl-third`, `cl-fourth`, `cl-fifth`, `cl-sixth`
- `cl-seventh`, `cl-eighth`, `cl-ninth`, `cl-tenth`, `cl-list-length`
- `seq-empty-p`, `seq-length`, `seq-elt`

Other:
- `symbol-name`, `identity`, `not`, `type-of`, `cl-type-of`
- `kbd`, `make-composed-keymap`, `mouse-event-p`, `sha1`, `syntax-class`

The operands are limited to `&args`, `&rest`, and `&keys` (and values
derived from them), plus literal constants such as quoted symbols,
keywords, strings, and numbers.

Unsupported predicates (state-dependent): `macrop`, `provided-mode-derived-p`.
These depend on runtime loading state and should not be used in conditional
type predicates.

Not allowed: `intern`, `make-symbol`, `symbol-value`, `symbol-function`,
`boundp`, `fboundp`, `indirect-function`, `indirect-variable`, or other
environment-dependent symbol operations.
Not allowed in `if` predicates: buffer-, process-, or window-dependent queries
such as `current-buffer`, `buffer-name`, `buffer-live-p`, `process-status`,
`process-live-p`, `get-buffer`, `get-buffer-process`, `selected-window`,
`window-live-p`, and any other predicates that consult mutable editor state.
These are still allowed as type keywords elsewhere in a spec, but not in
conditional return predicates.

Special cases:
- `syntax-class` is supported only when its argument is a literal syntax
  descriptor, not when it depends on the current buffer's syntax table.
- `sha1` is supported only for string inputs (buffers and file names are
  state-dependent and are not allowed in type predicates).

Form:

```emacs-lisp
(if PRED THEN ELSE)
```

PRED is an s-expression built from the allowed operators and operands.
It is **not** evaluated at runtime; it is used only by type checkers to
refine types for THEN/ELSE. Implementations should treat PRED as a pure
expression with no side effects. A predicate that uses disallowed forms
or operands is invalid and should be rejected. The reference evaluator
rejects a PRED that calls a state-dependent or environment-dependent
function (the not-allowed lists below) by returning
`(:cause-error (invalid-predicate PRED))`; other unrecognized forms keep the
conservative `(or THEN ELSE)` result.

`(if PRED THEN ELSE)` is intended for **return positions** of function
types. It is not a general-purpose type constructor for arbitrary
sub-positions (for example, `(list (if ...))` is not supported).

Evaluation model (for type checkers):
- PRED is evaluated symbolically using the argument types (not values).
- If the checker can prove PRED is true, it uses THEN; if it can prove
  PRED is false, it uses ELSE; otherwise it should conservatively use
  `(or THEN ELSE)`.
- This is a compile-time/type-checking decision only; it does not affect
  runtime behavior.
For `&keys`, a checker typically treats the presence/absence of a keyword
as *unknown* unless it can prove a specific call site always supplies it.
That means `plist-get` conditions will often fall back to the conservative
`(or THEN ELSE)` result.
PRED is evaluated **after** the argument types are established for the
call site; it does not depend on the THEN/ELSE results, and checkers should
not attempt a fixed-point iteration across branches.

Example:

```emacs-lisp
(typespec #'is-string
  (function (value &keys)
    (if (plist-get &keys :assert)
        (:assert string)
      (:guard string))))
```

Explanation:
- `&keys` represents the keyword-argument plist passed to `is-string`.
- The predicate `(plist-get &keys :assert)` is evaluated by the type checker
  (not at runtime) to choose between two return-type behaviors.
- If the caller passes `:assert t`, the return type is treated as `:assert`,
  meaning the argument is refined on success and an error is expected on failure.
- Otherwise the return type is treated as `:guard`, meaning it only refines on
  the true branch and does not imply the false branch complement.

### String-predicate narrowing (`rx` synthesis)

As a special case of conditional return types, when the predicate is a string
test on the value that the THEN branch returns and the ELSE branch is `nil`,
the THEN branch is narrowed to a synthesized `(rx ...)` string type. The
reference evaluator recognizes:

- `(if (string-match-p (rx R) VAR) VAR nil)` and `(string-match …)` ⇒ `(rx R)`.
- `(if (string-prefix-p "P" VAR) VAR nil)` ⇒ `(rx bos "P")`
  (and `string-suffix-p` ⇒ `(rx "S" eos)`); a non-nil ignore-case argument
  weakens this to “a non-empty string”.
- `(if (string= "S" VAR) VAR nil)` / `string-equal` ⇒ `(rx bos "S" eos)`.

This lets a checker refine, for example, a value that has passed a prefix test
into a more precise string subtype on the success branch.

## Numeric Range Evaluation

Type-level evaluation uses a unified representation for numeric ranges to
enable efficient range arithmetic and type inference. Numeric keyword types
like `positive-int`, `non-negative-int`, `negative-int`, `non-positive-int`,
and `fixnum` are normalized to their canonical range forms during evaluation.

### Range Normalization

- `positive-int` → `(integer 1 *)`
- `non-negative-int` → `(integer 0 *)`
- `negative-int` → `(integer * -1)`
- `non-positive-int` → `(integer * 0)`
- `fixnum` → `(integer most-negative-fixnum most-positive-fixnum)`

This normalization ensures that:
- Range arithmetic operations (e.g., `1+`, `1-`, `abs`, `cl-signum`) can be
  applied uniformly to all numeric types.
- Type inference produces precise range results (e.g., `(1+ fixnum)` returns
  an expanded integer range rather than a generic `integer` type).
- Predicate evaluation (e.g., `fixnump`) correctly recognizes ranges that match
  the keyword's bounds.

### Range Operations

Numeric operations preserve range information when possible:
- Unary operations (`1+`, `1-`, `abs`, `cl-signum`) compute new ranges from
  input ranges.
- Binary operations (`+`, `-`, `*`, `/`, `%`, `mod`) combine ranges when both
  operands are range types.
- Comparison operations (`=`, `<`, `>`, etc.) can evaluate to `(const t)` or
  `(const nil)` when ranges are disjoint or fully contained.

When a range operation produces a result that exactly matches a keyword type's
bounds (e.g., `fixnum`), the evaluator may preserve the keyword symbol for
readability, but canonical range forms are preferred for precision and
consistency.
