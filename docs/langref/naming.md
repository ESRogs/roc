# Naming

## Identifiers

The name an [assignment](statements#assignment) gives must be a valid Roc _identifier_, which means:

- It's a combination of ASCII letters, numbers, and underscores.
    - Consecutive underscores are allowed, but discouraged stylistically.
- It must begin with either `_`, `$`, or a lowercase ASCII letter.
  - The `$` prefix is only for [reassignment with `var`](statements#reassignment), and must be followed by an ASCII lowercase letter
  - The `_` prefix is only for naming things that don't actually get used, and must be followed by an ASCII lowercase letter.
    - The compiler will give a warning if an identifier begins with `_` and is referenced again in the same scope.
    - Note that [the `_` pattern](pattern-matching#underscore) is not an identifier and doesn't actually name anything.
- It can optionally end with `!` if it's naming an [effectful function](functions#effectful-functions).

## Shadowing

TODO

## Constants

TODO

## Variables (with `var`)

### `var` keyword

TODO

### `$` prefix

TODO

## Type Variables

TODO

## Type Aliases

### Parameterized Type Aliases

TODO

## Module Names

TODO

## `as`

TODO
