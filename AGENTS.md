# Implementation Guide for typespec.el and typespec-eval.el

This document summarizes the implementation details of the typespec type system for AI agents working on this codebase.

## Overview

The typespec system consists of two main components:

1. **`typespec.el`** - High-level macro for registering type specifications
2. **`typespec-eval.el`** - Type-level evaluator for constant folding and type inference

## typespec.el

### Purpose

The `typespec` macro attaches type specifications to function symbols via function properties. The stored spec is literal (not evaluated) so tooling can read and interpret it without executing arbitrary forms.

### Implementation

```elisp
(defmacro typespec (function spec &rest options)
  "Attach SPEC to FUNCTION as a `typespec' function property."
  `(function-put ,function 'typespec
                 ',(typespec--make-record spec)))
```

### Key Points

- Uses `function-put` to store the typespec as a function property
- The spec is stored as literal data (quoted)
- `typespec--make-record` (from `typespec-core.el`) processes the spec
- Options are reserved for future use

### Example Usage

```elisp
(typespec #'jp-postal-code-p
  (function (unknown)
            (:guard (rx string-start "〒" (= 3 digit) "-" (= 4 digit) string-end))))
```

This registers `jp-postal-code-p` with a `:guard` return type that specifies it accepts strings matching a Japanese postal code pattern.

## typespec-eval.el

### Purpose

Type-level evaluator that performs constant folding and type inference for typespec expressions. It evaluates expressions at "type time" to derive more specific types or constant values.

**Note**: This evaluator focuses on **type-level evaluation** (constant folding, type inference, and range arithmetic). Some type constructs that require full type checking (e.g., `(:class CLASS)`, `(:forall ...)`, `(var SYMBOL)`, `(benevolent T)`) are passed through unchanged, as they are intended to be processed by full type checkers rather than the evaluator.

**Variable resolution**: `typespec-eval-var.el` avoids depending on `typespec-eval--eval`. It returns `(unresolved TYPE)` for defcustom-derived types and leaves `(var SYMBOL)` otherwise. The main evaluator resolves `(unresolved ...)` when it is safe to do so. This keeps dependencies one-way while still allowing type-level evaluation to collapse custom variable types.

**Nil normalization policy**: the evaluator treats `nil` as a constant value and normalizes it to `(const nil)` whenever possible. This keeps constant folding and `or`/`and` simplification consistent and avoids mixing raw `nil` with types. List-handling functions should explicitly return `(const nil)` when the value is known to be nil.

### Core Architecture

The logic below is implemented in `typespec-eval-types.el`, `typespec-eval-op.el`, `typespec-eval-numeric.el`, and related modules. For the actual function names and files, see “Module Layout and Function Naming”.

#### 1. Type Category System

The evaluator uses a **type category system** for efficient type comparisons:

```elisp
(defun typespec-eval--type-category (form)
  "Return the type category of FORM as a symbol, or nil if unknown."
  (cond
   ((typespec-eval--string-type-p form) 'string)
   ((typespec-eval--integer-type-p form) 'integer)
   ((typespec-eval--float-type-p form) 'float)
   ((memq form '(number real)) 'number)
   ((typespec-eval--list-type-p form) 'list)
   ((typespec-eval--vector-type-p form) 'vector)
   ...))
```

**Benefits:**
- Single-pass type classification
- Efficient comparison via category symbols
- Extensible for new types

#### 2. Guard Type Resolution

The system supports user-defined types via `:guard` and `:guard!` annotations:

```elisp
(defun typespec-eval--type-predicate-name (type-name)
  "Return the predicate function symbol for TYPE-NAME.
Follows `cl-typep' priority: TYPE-NAMEp, TYPE-NAME-p, TYPE-NAME.
Checks for `typespec' property first, then `fboundp'."
  ...)

(defun typespec-eval--get-guard-return-type (pred-symbol)
  "Get the :guard or :guard! return type from PRED-SYMBOL's typespec."
  ...)

(defun typespec-eval--guard-type-base (guard-type)
  "Return the base type category for GUARD-TYPE.
For `(rx ...)' types, returns 'string."
  ...)
```

**Process:**
1. Type name → predicate function name (using `cl-typep` priority)
2. Predicate function → `typespec` property (via `function-get`)
3. Extract `:guard`/:guard!` return type
4. Resolve base type category (e.g., `(rx ...)` → `'string`)

**Example:**
```elisp
;; Registered via typespec macro
(typespec #'jp-postal-code-p
  (function (unknown) (:guard (rx ...))))

;; Evaluation
(typespec-eval '(stringp jp-postal-code))  ;; => (const t)
;; Because jp-postal-code has base type 'string
```

#### 3. Efficient Non-Type Predicates

The `non-*-type-p` functions use the category system for efficient disjoint type checks:

```elisp
(defun typespec-eval--non-string-type-p (form)
  "Return non-nil if FORM is a known non-string type.
Considers :guard-defined types via their base type."
  (and-let* ((cat (typespec-eval--type-category-with-guard form)))
    (not (eq cat 'string))))
```

**Key Design:**
- Uses `and-let*` for concise nil-checking
- `typespec-eval--type-category-with-guard` includes guard types
- Returns `nil` (not `t`) for unknown types (conservative)

#### 4. Predicate Evaluation

The `typespec-eval--eval-predicate` function handles built-in predicates with type checks:

```elisp
(defun typespec-eval--eval-predicate (arg pred &optional type-true-p type-false-p)
  "Evaluate predicate PRED over ARG with optional type check.
Also considers :guard-defined types via their base type."
  (let* ((arg (typespec-eval--eval arg))
         (guard-base (and (symbolp arg)
                          (typespec-eval--get-type-base-category arg))))
    (cond
     ((typespec-eval--const-p arg)
      (typespec-eval--make-const (funcall pred ...)))
     ((and type-true-p (funcall type-true-p arg))
      (typespec-eval--make-const t))
     ;; Check guard type's base
     ((and type-true-p guard-base
           (funcall type-true-p guard-base))
      (typespec-eval--make-const t))
     ...)))
```

**Features:**
- Constant folding for const values
- Type-based optimization (returns `(const t)` or `(const nil)` when possible)
- Guard type support via base type resolution
- Falls back to `'boolean` when type is unknown

### Evaluation Patterns

#### Constant Folding

```elisp
(typespec-eval '(stringp (const "hello")))  ;; => (const t)
(typespec-eval '(stringp (const 42)))       ;; => (const nil)
```

#### Type Inference

```elisp
(typespec-eval '(stringp string))           ;; => (const t)
(typespec-eval '(stringp integer))          ;; => (const nil)
(typespec-eval '(stringp unknown))          ;; => boolean
```

#### Guard Type Support

```elisp
;; After registering jp-postal-code-p with :guard (rx ...)
(typespec-eval '(stringp jp-postal-code))   ;; => (const t)
(typespec-eval '(integerp jp-postal-code))  ;; => (const nil)
```

### Unified Numeric Range System

The evaluator uses a unified `numeric-range-info` plist structure for efficient numeric range operations:

#### Range Info Structure

```elisp
;; plist with keys: :type, :low, :high, :low-excl, :high-excl
;; :type - 'integer or 'float
;; :low/:high - numeric value or nil (unbounded)
;; :low-excl/:high-excl - t if boundary is exclusive

(defun typespec-eval--numeric-range-info (form)
  "Return numeric range info plist for FORM with :type annotation."
  ...)
```

#### Range Operations

```elisp
(defun typespec-eval--numeric-range-shift (info delta)
  "Return INFO shifted by DELTA."
  ...)

(defun typespec-eval--numeric-range-abs (info)
  "Compute absolute value range for INFO."
  ...)

(defun typespec-eval--numeric-range-signum (info)
  "Return signum result options as a simplified or-form."
  ...)

(defun typespec-eval--numeric-range-unary (info fn)
  "Apply unary FN to numeric range INFO."
  ...)
```

#### Range to Form Conversion

```elisp
(defun typespec-eval--numeric-range-to-form (info)
  "Convert numeric range INFO back to a typespec form.
Returns simple type symbol for fully unbounded ranges.
Alias types are normalized to canonical range forms."
  ...)
```

**Normalization Policy:**

Alias type symbols are treated as **input aliases** and normalized to canonical range forms:
- `positive-int` → `(integer 1 *)`
- `non-negative-int` → `(integer 0 *)`
- `negative-int` → `(integer * -1)`
- `non-positive-int` → `(integer * 0)`
- `fixnum` → `(integer most-negative-fixnum most-positive-fixnum)`

**Benefits:**
- Single unified representation for integer and float ranges
- Type-preserving operations (integer stays integer, float stays float)
- Simplified internal processing (no special-case branches)
- Consistent handling of exclusive boundaries

### Generic Helper Functions

The evaluator uses generic helpers to reduce code duplication:

#### Numeric Operations

```elisp
(defun typespec-eval--eval-numeric-unary (arg fn)
  "Evaluate numeric unary FN over ARG, preserving numeric type."
  ...)

(defun typespec-eval--eval-numeric-compare (lhs rhs pred)
  "Evaluate numeric comparison PRED over LHS and RHS."
  ...)
```

#### String Operations

```elisp
(defun typespec-eval--eval-string-unary (arg fn &optional preserve-non-empty)
  "Evaluate string unary FN over ARG."
  ...)

(defun typespec-eval--eval-binary-string-compare (lhs rhs fn result-type)
  "Evaluate binary string comparison FN over LHS and RHS."
  ...)
```

#### Constant Folding

```elisp
(defun typespec-eval-simplify-unary-const-fold (arg fn pred &optional type-in type-out type-p fallback)
  "Apply unary FN over ARG with constant folding and type inference.
ARG is evaluated via `typespec-eval--eval' (declare-function in typespec-eval-simplify)."
  ...)
```

Lives in `typespec-eval-simplify.el`.  Uses `declare-function` for `typespec-eval--eval`.

### Main Evaluation Function

```elisp
(defun typespec-eval (form)
  "Evaluate FORM in the typespec value/type evaluator."
  (typespec-eval--eval form))
```

The `typespec-eval--eval` function uses `pcase` for pattern matching:

```elisp
(defun typespec-eval--eval (form)
  "Evaluate a typespec FORM into a simplified type/value expression."
  (pcase form
    (`(stringp ,arg)
     (typespec-eval-op-unary-predicate arg #'stringp
                       #'typespec-eval-types-string-type-p
                       #'typespec-eval-types-non-string-type-p))
    (`(+ . ,args)
     (typespec-eval-op-arith args #'+ 0))
    ...))
```

### Module Layout and Function Naming

Evaluator logic is split into modules by responsibility. Naming follows the module prefix.

| Module | Prefix | Role |
|--------|--------|------|
| **typespec-eval.el** | `typespec-eval`, `typespec-eval--` | Entry point `typespec-eval`, dispatcher `typespec-eval--eval` (pcase). |
| **typespec-eval-core.el** | `typespec-eval--` | Const, nil/non-nil, string helpers, range constructors. `const-p`, `make-const`, `always-nil-p`, `always-non-nil-p`, `non-empty-string-p`, `integer-range`, `float-range`, etc. |
| **typespec-eval-types.el** | `typespec-eval-types-` | Type category and type predicates. `type-category`, `type-category-with-guard`, `*-type-p` (e.g. `string-type-p`, `integer-type-p`), `non-*-type-p` (e.g. `non-string-type-p`), guard resolution (`type-predicate-name`, `get-guard-return-type`, `guard-type-base`, `get-type-base-category`). |
| **typespec-eval-struct.el** | `typespec-eval-struct-` | List/alist/plist/cons/tuple structure. **Form predicates** (structure shape): `alist-form-p`, `plist-form-p`, `cons-form-p`. Accessors: `alist-key-type`, `alist-value-type`, `plist-key-type`, `plist-value-type`, `list-elem-type`, `list-of-p`, `plist-append-entry-types`, `alist-entry-types`, `cons-key-type`, `cons-value-type`, tuple helpers. |
| **typespec-eval-simplify.el** | `typespec-eval-simplify-` | `simplify-or`, `simplify-and`, `unary-const-fold`, `const-string-options`, `const-regexp-options`, `concat-combinations`, `string-or-char-p`, intersect/merge helpers. |
| **typespec-eval-numeric.el** | `typespec-eval-numeric-` | Numeric range: `numeric-range-info`, `numeric-range-to-form`, `numeric-range-shift`, `numeric-range-abs`, `numeric-range-signum`, float/integer arith, `float-range-combine`, etc. |
| **typespec-eval-op.el** | `typespec-eval-op-` | One-to-one op handlers (e.g. `arith`, `cons`, `unary-predicate`, `numeric-unary`, `string-unary`, `if`, `equality`). Functions are alphabetically ordered. Uses `declare-function` only for `typespec-eval--eval`. |
| **typespec-eval-var.el** | `typespec-eval-var--` | Variable resolution: `var--eval`, `var--const-type`, defcustom/custom handling. |

**Naming rules**

- **`*-type-p`** (in `typespec-eval-types`): “is this a T type?” (type category). Used for inference and non-T checks.
- **`*-form-p`** (in `typespec-eval-struct`): “does this match the form of an alist/plist/cons?” (structure shape). Distinct from type-category predicates.
- **`always-nil-p` / `always-non-nil-p`**: in `typespec-eval-core` as `typespec-eval--always-nil-p` and `typespec-eval--always-non-nil-p`.

## Key Design Principles

### 1. Conservative Type Inference

- Unknown types return `'boolean` or `'unknown` (not false positives)
- Guard types are only recognized if registered via `typespec` macro
- Unregistered user-defined types are treated as unknown

### 2. Efficient Type Comparison

- Single-pass type categorization
- Category-based disjoint checks (`non-*-type-p`)
- Guard type base resolution cached via `type-category-with-guard`

### 3. Extensibility

- New types can be added to `type-category` function
- Guard types automatically inherit base type behavior
- Generic helpers reduce boilerplate for similar operations

### 4. Code Organization

- **Module layout**: See “Module Layout and Function Naming” in the typespec-eval section. `typespec-eval--eval` dispatches to `typespec-eval-op-*`; type predicates live in `typespec-eval-types-*`; structure form predicates in `typespec-eval-struct-*-form-p`; simplify/numeric/var in their own modules.
- Simple wrapper functions removed (direct calls in `pcase`)
- Generic helpers encapsulate common patterns
- `defsubst` used sparingly (only for simple, frequently-called functions)

## Testing

The test suite (`typespec-eval-test.el`) covers:

- Constant folding for predicates
- Type inference for built-in types
- Guard type resolution
- Generic helper functions
- Edge cases (unknown types, unregistered predicates)

**Test Count:** 131 tests (as of latest implementation)

### Makefile

`make test` / `make check` runs: **clean** → **test** (from .el) → **compile** → **test** (from .elc).

| Target | Description |
|--------|-------------|
| **test**, **check** | clean → test-core + test-eval → compile → test-core + test-eval |
| **test-core** | ERT for `typespec-core-test.el` |
| **test-eval** | ERT for `typespec-eval-test.el` |
| **clean** | Remove all `*.elc` |
| **compile** | Byte-compile `EL_SOURCES` (dependency order; excludes `*-test.el`) |

**Variables:** `EMACS ?= emacs`, `LOAD_PATH ?= -L .` (override when needed, e.g. `make test EMACS=emacs-29`).

**EL_SOURCES** (for `compile`): `typespec-core`, `typespec-resolver`, `typespec`, `typespec-elsa`, `typespec-eval-core`, `typespec-eval-types`, `typespec-eval-var`, `typespec-eval-simplify`, `typespec-eval-struct`, `typespec-eval-numeric`, `typespec-eval-op`, `typespec-eval`.

## Future Extensions

### Potential Improvements

1. **More Guard Type Support**
   - Support for nested guard types
   - Base type inference from complex guard expressions

2. **Type Narrowing**
   - Conditional type narrowing in `if` expressions
   - Pattern matching for union types

3. **Performance**
   - Caching of type category lookups
   - Lazy evaluation for complex types

## Common Patterns

### Adding a New Predicate

1. Add `pcase` entry in `typespec-eval--eval` (typespec-eval.el) that calls `typespec-eval-op-unary-predicate`:
   ```elisp
   (`(new-predicate ,arg)
    (typespec-eval-op-unary-predicate arg #'new-predicate
                      #'typespec-eval-types-new-type-p
                      #'typespec-eval-types-non-new-type-p))
   ```

2. Define type predicates in **typespec-eval-types.el** if needed:
   ```elisp
   (defsubst typespec-eval-types-new-type-p (form)
     "Return non-nil if FORM is a new-type."
     ...)
   (defun typespec-eval-types-non-new-type-p (form)
     "Return non-nil if FORM is a known non-new-type."
     (and-let* ((cat (typespec-eval-types-type-category-with-guard form)))
       (not (eq cat 'new))))
   ```
   Also add the category to `typespec-eval-types-type-category` and optionally `typespec-eval-types-type-predicate-name` / guard support.

### Adding a New Operation

1. Define the op handler in **typespec-eval-op.el** (alphabetically), using helpers from struct/simplify/numeric/types/core as needed:
   ```elisp
   (defun typespec-eval-op-new-op (arg1 arg2)
     "Evaluate new-op over ARG1 and ARG2."
     ...)
   ```

2. Add `pcase` entry in `typespec-eval--eval` (typespec-eval.el):
   ```elisp
   (`(new-op ,arg1 ,arg2)
    (typespec-eval-op-new-op arg1 arg2))
   ```

### Adding a Structure Form Predicate

To add a predicate that detects a **structure shape** (e.g. alist/plist/cons form) in **typespec-eval-struct.el**:

1. Define `typespec-eval-struct-*-form-p` (use `-form-p`, not `-type-p`, to distinguish from type-category predicates in typespec-eval-types):
   ```elisp
   (defsubst typespec-eval-struct-new-struct-form-p (value)
     "Return non-nil if VALUE matches the (new-struct ...) form."
     (and (consp value) (eq (car value) 'new-struct) ...))
   ```
2. Add accessors (e.g. `-key-type`, `-value-type`) and use them from `typespec-eval-op-*` as needed.

### Supporting Guard Types

Guard types are automatically supported if:
1. Predicate function is registered via `typespec` macro
2. Return type includes `:guard` or `:guard!`
3. Guard type's base can be resolved (currently supports `(rx ...)` → `'string`)

The system will automatically:
- Resolve predicate name from type name
- Extract guard return type from `typespec` property
- Use base type for type checks

### Pass-through Type Constructs

Some type constructs are passed through unchanged by the evaluator, as they require full type checking rather than type-level evaluation:

- `(:class CLASS)` - EIEIO class types (requires class hierarchy resolution)
- `(:forall (TYPEVAR...) BODY)` - Polymorphic types (requires type variable substitution)
- `(var SYMBOL)` - Variable types (requires symbol resolution and constant evaluation)
- `(benevolent T)` - Soundness trade-off markers (requires policy decisions from type checker)

These constructs are preserved in the output and should be handled by full type checkers that have access to the complete program context.

## References

- `typespec.md` - Type specification syntax
- `type-level-evaluation.md` - Type-level evaluation semantics
- `typespec-core.el` - Core type system definitions
- `typespec-eval-test.el` - Test suite
- `Makefile` - Test run (clean → test → compile → test), `clean`, `compile`

**typespec-eval modules:** `typespec-eval.el`, `typespec-eval-core.el`, `typespec-eval-types.el`, `typespec-eval-struct.el`, `typespec-eval-simplify.el`, `typespec-eval-numeric.el`, `typespec-eval-op.el`, `typespec-eval-var.el`. See “Module Layout and Function Naming” for prefixes and roles.
