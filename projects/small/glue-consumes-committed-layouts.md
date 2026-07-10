# Glue Consumes Committed Layouts

## Problem

`roc glue` reads every layout number it emits from the compiler's
committed layout store: `src/glue/checked_artifact_layout_resolver.zig`
resolves checked types to `src/layout` store indexes, and
`attachAbiLayouts` in `src/glue/glue.zig` attaches per-width size,
alignment, and offset facts that the generator scripts format verbatim.
One gap remains: a type that reaches the glue type table with no
committed layout — an unresolved (`flex`/`rigid`) type variable used by
value — hits `glueInvariant("type with no committed layout reached glue
type table")` in `layoutFactsForCheckedType` (`src/glue/glue.zig`),
which is a panic in debug builds and `unreachable` in release builds.
That is not a reported error and it does not name the offending type.
Issue 9824 is still open upstream.

## Background

The layout resolver handles unresolved type variables two ways
(`src/glue/checked_artifact_layout_resolver.zig`):

- Behind a heap indirection (`Box`, `List`) they resolve to the
  committed `opaque_ptr` layout, so pointer-sized bindings and their
  size assertions agree at both pointer widths. This covers issue
  9824's reported repro — a platform whose entrypoint boxes an
  app-supplied `model`.
- Used by value they return `error.UnresolvedByValue`, which
  `layoutFactsForCheckedType` converts to the invariant panic above.

Whether a well-typed platform can expose an unresolved type by value at
the host boundary is unverified. If the checker rejects every such
program before glue runs, the invariant is correct as written; if a
user program can reach it, glue crashes instead of reporting.

## Evidence

- `src/glue/glue.zig`: `layoutFactsForCheckedType` maps
  `error.UnresolvedByValue` to `glueInvariant(...)`; `glueInvariant` is
  `std.debug.panic` in debug mode and `unreachable` otherwise.
- `src/glue/checked_artifact_layout_resolver.zig`: `.flex`/`.rigid`
  resolve to `.opaque_ptr` when `parent_context == .heap_indirect`,
  otherwise `error.UnresolvedByValue`.
- Issue 9824 (roc-lang/roc) is open: "roc glue mis-sizes unresolved
  type variables as zero-sized". The zero-sizing it describes does not
  exist in the tree; the issue has not been re-verified and closed.

## Solution design

1. **Decide reachability.** Determine whether any platform a user can
   write puts an unresolved type variable by value into a glue-visible
   signature (for example a `requires` model returned unboxed). If the
   checker already rejects every such program, document that at the
   `glueInvariant` call site and skip step 2.
2. **Report instead of panic.** If reachable, replace the invariant in
   `layoutFactsForCheckedType` with a reported glue error that names
   the type and its declaring module and exits nonzero — never a crash,
   never a fabricated layout.
3. **Close issue 9824.** Verify its repro (platform `requires` a
   `model`; entrypoint returns `Try(Box(Model), I32)`) generates
   bindings whose unknown-payload sizes agree at native and wasm32
   widths, then close the issue with that evidence.

## What success looks like

- A type with no committed layout reaching glue is either impossible
  (checker-rejected, documented at the invariant) or a reported glue
  error naming the type — never a panic and never a wrong-sized field.
- Issue 9824 is closed.

## How to evaluate the result

### Correctness ideal

Every glue exit on bad input is a named diagnostic: no input program
can make `roc glue` panic. `glueInvariant` remains only for states the
checker provably prevents.

### Performance ideal

No change: this is an error-path rewrite plus verification. The
committed-layout read path is untouched.

## Tests to add

- Issue 9824 repro: a platform that boxes an app-supplied model
  (`Box(Model)` across the host boundary) glues and byte-checks at
  native and wasm32 widths.
- If step 1 finds a reachable by-value case: that program run through
  `roc glue` exits with an error naming the type, with no panic.
