# Compiler Improvement Projects

This folder contains self-contained project specifications for structural
improvements to the compiler. Each `.md` file is written so that someone brand
new to the codebase (human or agent) can read that one file and understand the
problem, the solution approach, what success looks like, how to evaluate the
result for long-term correctness and performance, and what tests to add.

- `small/` — localized, mostly additive checks or deletions, low design risk.
  Several of these are the remaining slivers of larger projects that have
  otherwise shipped, so they range from hours to days each.
- `big/` — projects on the order of weeks each: cross-cutting, and several
  require a design decision before implementation starts.

The projects came out of a root-cause analysis of eight weeks of bug fixes
(May–June 2026). The recurring disease across independent bug clusters was:
facts proven during checking get re-derived downstream from type, name, or
structure content instead of traveling as explicit data, keyed by fragile
identity (name strings, positional order, mutable keys) and enforced only by
panics at the consumption site. These projects either move a fact into an
explicit artifact, assign an identity once and carry it, or delete a
duplicated computation. `design.md` at the repo root is the authoritative
post-check design; these projects implement its stated principles more
completely.

## Recommended order

### Start here

1. [small/cross-phase-coverage-parity-tests.md](small/cross-phase-coverage-parity-tests.md)
   — the divergence-classification parity suite; cheap insurance that gives
   the big lowering projects below a focused regression net.

### Big projects

- [big/arc-inserter-join-summaries.md](big/arc-inserter-join-summaries.md)
  — applies the certifier's finite-summary/dataflow discipline to production
  ARC insertion, replacing join and liveness re-walks that make generated
  structural encoders compile in minutes. Independent of everything else.
- [big/unify-build-pipelines.md](big/unify-build-pipelines.md) — one
  orchestration core behind check/run/test; the run path still hand-wires
  coordinator setup and report rendering.
- [big/decision-tree-match-compiler.md](big/decision-tree-match-compiler.md)
  — benefits from landing the coverage-parity harness first, and pairs
  naturally with pipeline unification since today every match-lowering
  change must be made twice.

### Small follow-ups — start any time, in any order

Each closes out the remaining piece of an otherwise-shipped project:

- [small/shared-checked-type-traversal.md](small/shared-checked-type-traversal.md)
  — the traversal utility exists; migrate the platform-relation walks onto
  it and collapse the remaining ad-hoc visited/active sets.
- [small/pin-deferred-spec-requests.md](small/pin-deferred-spec-requests.md)
  — the pin is in; audit the one remaining propagation hole
  (`unifyThroughBacking` never pairs named type arguments) with seal-time
  instrumentation.
- [small/glue-consumes-committed-layouts.md](small/glue-consumes-committed-layouts.md)
  — glue reads committed layouts; turn the unresolved-by-value invariant
  panic into a reported error naming the type, and close issue 9824.
- [small/associated-block-defining-exclusion.md](small/associated-block-defining-exclusion.md)
  — both scope-exclusion fixes are in; add the dependency-graph debug
  assertion that no non-function def depends on itself.

### Suggested overall sequence

If one person or agent works through everything serially, this order
front-loads leverage and keeps prerequisites satisfied:

1. `small/cross-phase-coverage-parity-tests.md`
2. `small/shared-checked-type-traversal.md`
3. `big/arc-inserter-join-summaries.md`
4. `big/unify-build-pipelines.md`
5. `big/decision-tree-match-compiler.md`
6. `small/pin-deferred-spec-requests.md`
7. `small/glue-consumes-committed-layouts.md`
8. `small/associated-block-defining-exclusion.md`
