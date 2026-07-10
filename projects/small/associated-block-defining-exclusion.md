# Currently-Defining Exclusion for Associated Blocks

## Problem

Canonicalization excludes the declaration currently being defined from
satisfying its own right-hand side's name lookups, on both sides: the type
side via `defining_assoc_alias` (consulted by `activeDeclScopeDeclaresType`
and `typeBindingIsDefiningAssocAlias` in src/canonicalize/Can.zig), the
value side via `beginDefiningBoundVars`/`endDefiningBoundVars` wrapped
around associated decl bodies. What guards that exclusion against
regression is the test set alone: nothing in canonicalization OUTPUT
asserts that no manufactured self-cycle escapes. If a future
scope-resolution path resolves a def's RHS to the def itself again (the
roc-lang/roc#9961 / #9912 shape), the first symptom is downstream
misbehavior in whatever phase consumes the dependency graph, not an
assertion at the source.

## Background

The compiler pipeline: parse → canonicalize → type-check → postcheck.
Canonicalization owns scoping; a name-resolution error here must surface
as a canonicalization diagnostic, never as downstream misbehavior.
design.md (Canonicalization Policy Ownership) and AGENTS.md apply.

`buildDependencyGraph` (src/canonicalize/DependencyGraph.zig) collects a
demand summary per def and adds one graph edge per dependency. A def whose
summary contains itself is legitimate only when the def is a function
(recursion is legal); a value binding depending on itself is always a
manufactured self-cycle that canonicalization should have diagnosed.

## Evidence

- `buildDependencyGraph` and `DemandAnalyzer.collectDefDependencies`
  (src/canonicalize/DependencyGraph.zig) add edges with no self-edge
  check; `DependencyGraph.addEdge` accepts `from_def == to_def` for any
  def kind.
- The exclusion mechanisms and their pinning tests:
  `defining_assoc_alias` and the associated-body
  `beginDefiningBoundVars` wrapping in src/canonicalize/Can.zig; CLI
  tests named "issue 9961: ..." and "issue 9912: ..." in
  src/cli/test/parallel_cli_runner.zig; snapshots
  test/snapshots/assoc_value_self_reference.md,
  assoc_value_self_reference_qualified.md, assoc_forward_ref_sibling.md,
  assoc_recursive_nominal.md, assoc_value_shadows_top_level.md.

## Solution design

Add a debug assertion on canonicalization output: after a def's
dependencies are collected, assert the def's dependency summary does not
contain the def itself unless the def is a function. Place it where the
summary is complete (the per-def loop in `buildDependencyGraph`, or
`addEdge`) so any resolution path that manufactures a self-cycle trips in
debug builds at the producer, naming the offending def.

## What success looks like

- Debug builds assert during canonicalization whenever a non-function def
  depends on itself, identifying the def.
- Recursive function defs pass unchanged; the full snapshot corpus shows
  no diffs.

## How to evaluate the result

### Correctness ideal

The assertion fires at the producer, before any downstream phase consumes
the dependency graph, and its message names the def — the failure is
attributable to a scope-resolution path rather than recovered later from
graph shape or checker behavior.

### Performance ideal

A debug-only comparison per collected dependency; release builds are
byte-identical. Nothing to measure.

## Tests to add

- A test that the check trips for a non-function def whose summary
  contains itself: either construct one through test-only CIR building,
  or unit-test the check helper directly if no public path can produce
  the input.
- A recursive-function def test asserting the check does not trip.

## Related projects

- [../big/unify-build-pipelines.md](../big/unify-build-pipelines.md) —
  owns platform-root URL-package materialization, the error-recovery door
  through which the #9912 shape reached associated-item lookups.
