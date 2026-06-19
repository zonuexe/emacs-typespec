# Alternative Syntax Ideas

This document records potential alternative surface syntax for typespec.
These ideas are not part of the current specification.

## Function Type: `::` separator

The current canonical form is:

```lisp
(function (TYPE...) TYPE)
```

An alternative is to separate parameters and return type with `::`:

```lisp
(TYPE... :: TYPE)
```

### Side-by-side examples

```lisp
(function (integer) boolean)
(integer :: boolean)

(function (integer string) boolean)
(integer string :: boolean)

(function (&rest integer) boolean)
(&rest integer :: boolean)

(function (&keys (:plist-of (:name string)) ) (:plist-of (:name string)))
(&keys (:plist-of (:name string)) :: (:plist-of (:name string)))

(function ((list a)) a)
((list a) :: a)

(function ((function (a) b) (list a)) (list b))
((function (a) b) (list a) :: (list b))
```

Notes
- `::` makes the return boundary visually prominent.
- `(function ...)` makes it clearer that the expression is a function type.

### Pros/Cons by Approach

#### 1) Top-level `::`, nested `(function ...)`

Pros
- Return boundary is obvious for top-level signatures.
- Nested types stay explicit and less ambiguous.

Cons
- Mixed notation requires an extra rule to learn.
- `::` can still be confused with type annotation syntax.

#### 2) Top-level `(function ...)`, nested `::` shorthand

Pros
- Canonical form remains stable; shorthand is optional.
- Reduces noise in nested function types.

Cons
- Readers must know that `::` is just a shorthand.
- Argument modifiers like `&rest`/`&keys` can be harder to scan.

#### 3) `::` for both top-level and nested function types

Pros
- Consistent visual emphasis on return types.
- More compact overall.

Cons
- Higher risk of confusing `::` with annotation syntax.
- Less explicit than `(function ...)` in dense type expressions.

## Optional type shorthand

Idea: shorthand for optional types as a replacement for `(or T nil)`.
`(:optional T)` is not implemented; it would be a higher-level alias for
`(or T nil)`.

- `(? T)` — very short but may clash with the Lisp character literal reader.
- `(:? T)` — consistent with `(:? KEY TYPE)` and more self-explanatory.
