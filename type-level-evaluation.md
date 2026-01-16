# Type-level Evaluation

This document defines how typespec evaluates predicate-like constructs
and conditional types. This is separate from the syntax overview in
`typespec.md`.

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
- `log10`, `lsh`, `zerop`, `number-sequence`
- `+`, `-`, `*`, `/`, `%`, `mod`, `1+`, `1-`, `abs`, `max`, `min`
- `floor`, `ceiling`, `round`, `truncate`, `isnan`, `cl-signum`
- `logand`, `logior`, `logxor`, `lognot`, `logcount`, `ash`

String helpers:
- `concat`, `string-as-multibyte`, `string-as-unibyte`, `string-bytes`
- `string-chop-newline`, `string-clean-whitespace`, `string-distance`
- `string-equal`, `string-equal-ignore-case`, `string-greaterp`, `string-lessp`
- `string-join`, `string-limit`, `string-lines`, `string-match-p`
- `upcase`, `downcase`, `capitalize`, `char-to-string`, `make-string`, `substring`
- `string-pad`, `string-prefix-p`, `string-remove-prefix`, `string-remove-suffix`
- `string-replace`, `string-reverse`, `string-search`, `string-split`, `string-suffix-p`
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
or operands is invalid and should be rejected.

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
