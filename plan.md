# Optimized Callable-State Lowering Plan

## Goal

Implement optimized callable-state lowering as the single long-term design for
turning Roc `Iter`, `Stream`, and other callable-state values into tight
generated code in optimized builds.

The generated-code target is Rust-like iterator lowering: private cursor state,
direct stepping, no heap allocation for adapter wrappers in consuming hot paths,
and no public wrapper churn when the source program does not observe the public
value. Roc keeps its public API. `Iter(item)` and `Stream(item)` remain ordinary
concrete Roc records whose step fields are ordinary Roc lambdas. The optimizer
uses checked identities, lambda-set facts, captures, known values, layouts, and
explicit result demand to specialize code during optimized lowering.

This optimizer runs only for Roc `--opt=size` and `--opt=speed`. Every other
mode uses ordinary public-value lowering and constructs no optimized demand
graphs, sparse private-state tables, loop fixed-point nodes, or demand-keyed
workers.

## Required Architecture

The post-check driver chooses one lowering family before constructing lowering
state:

```text
ordinary public-value lowering
optimized callable-state lowering
```

Ordinary lowering owns materialization of public Roc values. Optimized lowering
owns result demand, sparse private state, finite callable alternatives,
loop-demand fixed points, and demand-keyed workers. LIR, ARC, interpreters,
LLVM, wasm, Binaryen, and linkers see only ordinary LIR after lowering.

The optimizer is producer-under-demand lowering:

1. A consumer creates exact result demand.
2. The producer is cloned under that demand.
3. Known records, tuples, tags, nominals, primitive leaves, direct calls, and
   callable values expose only the demanded data.
4. Finite callable targets are defunctionalized into private alternatives.
5. Loops solve recursive carried demand as graph fixed points.
6. Public values are materialized only when source code observes the public
   representation.

There is no iterator-specific IR, no public or private `Append` step variant,
no source-form optimization rule, no late cleanup pass, and no target-specific
rule for wasm or Rocci Bird.

## Invariants

- `Iter` and `Stream` have the public three-step shape: `One`, `Skip`, `Done`.
- Ordinary Roc lambdas and existing lambda-set data are the only private
  adapter-shape source.
- Result demand is explicit data owned by optimized lowering.
- Private state is sparse and keyed by checked child identity.
- Missing sparse children mean "not carried"; unknown-but-carried children are
  explicit runtime leaves.
- Primitive demanded values optimize without requiring aggregate wrappers.
- Loop-carried demand is represented by loop graph nodes, not recursive finite
  trees.
- Runtime leaves are loop parameters, not finite-state dimensions.
- Public materialization is explicit and preserves public Roc immutability.
- `dbg`, `expect`, `crash`, branch conditions, scrutinees, guards, appended
  item expressions, stream effects, `break`, and `return` keep checked source
  order.
- Optimized workers are keyed by exact compiler data and are created only in
  optimized modes.
- Private-state bodies are scope-closed before ARC.
- ARC follows explicit LIR reference-count statements and does not know
  iterator, stream, callable-state, or private-cursor rules.

## Implementation Steps

### 1. Mode Gate And Context Ownership

- Compute the lowering family once at the post-check driver boundary from
  explicit Roc optimization mode.
- Construct either ordinary lowering state or optimized lowering state, never a
  shared context with nullable optimized fields.
- Make optimized-only helpers require optimized-owned data in their API.
- Prove dev/check/interpreter/compile-time-finalization paths construct zero
  optimized contexts and zero optimized-owned nodes.
- Prove `--opt=size` and `--opt=speed` enter the same optimized entrypoint and
  produce the same optimizer-owned facts before backend preferences.

### 2. Result Demand And Sparse Private State

- Represent demand for materialization, runtime leaves, record fields, tuple
  items, nominal backing data, tag choices and payloads, callable calls and
  captures, direct-call results, and loop-carried values.
- Merge demand deterministically and exactly.
- Store demanded children sparsely by checked identity.
- Treat public layouts as materialization data only.
- Add focused tests for primitive state, single-field-record state, sparse
  records, sparse tuples, sparse tags, sparse callables, sparse nominals, and
  explicit materialization.

### 3. Producer-Under-Demand Cloning

- Thread demand through field access, tuple access, tag matches, callable calls,
  direct calls, branches, matches, pending lets, and loops.
- Preserve source evaluation order by keeping condition, guard, payload, and
  pending-let scopes inside the cloned region that owns their locals.
- Materialize only when the active demand says the public Roc value is observed.
- Reject any optimized private-state body that references an out-of-scope
  local before LIR reaches ARC.
- Add tests for branch/match demand merging, public materialization after a
  private value, and equivalent source forms optimizing from facts rather than
  syntax.

### 4. Finite Callable-State Defunctionalization

- Preserve finite lambda-set alternatives under callable demand.
- Inline one known target directly.
- Dispatch over multiple known targets without widening to public callables
  merely because capture shapes differ.
- Carry only demanded captures as private state.
- Materialize public callables only at explicit public boundaries.
- Add tests for one target, multiple targets, differing capture counts, omitted
  captures, callable reuse after optimized call, and public callable crossing.

### 5. Loop Demand Fixed Points

- Represent loop-parameter demand with explicit graph nodes owned by the loop
  fixed point.
- Merge body observations and reachable `continue` edges monotonically.
- Clone loop initial values and `continue` values under final fixed-point
  demand.
- Recompute provisional edge clones when demand grows.
- Carry runtime leaves as state parameters.
- Keep unobserved fields such as `len_if_known` out of private stepping loops.
- Add tests for list iterators, iterator append/concat phase changes, runtime
  cursor leaves, mutually recursive loop parameters, `break`, `return`, source
  mutable variables, stream effects, and infinite iterator examples.

### 6. Demand-Keyed Direct-Call Workers

- Create optimized workers only while cloning a call under explicit optimized
  demand.
- Key workers by callee identity, split argument facts, result demand, and
  relevant type/layout decisions.
- Keep the original public-ABI body available.
- Share workers only when all correctness-relevant facts match.
- Add tests proving worker creation in both optimized modes, no worker creation
  in dev mode, public call correctness without workers, and deterministic worker
  reuse.

### 7. Public Boundaries And Effects

Materialize public values when source code observes them, including:

- returning, storing, or passing an iterator or stream
- reading `len_if_known`
- directly matching on public `Iter.next` or `Stream.next!`
- returning, storing, or passing a callable through a public/erased boundary

Add public-boundary tests for iterator reuse, storing in records/lists, passing
through unspecialized code, direct public `next` matches, length hints, stream
effect ordering, and custom unbounded iterators.

### 8. Generic LIR, ARC, And Backends

- Lower private state machines to ordinary LIR joins, blocks, switches, calls,
  and jumps.
- Validate scope closure before ARC insertion.
- Keep LIR, ARC, LirImage, interpreters, LLVM, object, wasm, Binaryen, and
  linkers free of iterator/stream/private-cursor rules.
- Add source scans or focused tests proving backend and ARC code do not know
  this optimizer's private concepts.

### 9. Rocci Bird And Rust Validation

Build and record:

- Rocci Bird with `.iter()` collision points using Roc `--opt=size`
- Rocci Bird with direct-list collision points using Roc `--opt=size`
- Rust Rocci Bird with Rust size optimizations and Binaryen

For each Roc build:

- record final wasm byte size
- disassemble `update`
- count normal-playing-path allocator wrapper calls
- count normal-playing-path public iterator/callable wrapper calls
- compare collision-loop control flow
- confirm static collision/sprite data is emitted as static data when eligible
- confirm unobserved `len_if_known` work is absent
- explain any remaining Roc-vs-Rust gap with concrete disassembly evidence and
  a compiler issue or follow-up plan when it violates this design

## Test Commands

Run focused tests first:

```sh
zig build run-test-zig-module-postcheck --summary all --color off
zig build run-test-zig-lir-inline --summary all --color off
zig build run-test-cli --summary all --color off
```

When `zig build minici` fails in one section, fix that section and rerun that
specific failing section until it passes. Return to full `minici` only after
the targeted section passes.

```sh
zig build minici
```

Rocci Bird validation uses identical wasm and Binaryen tooling for `.iter()`
and direct-list Roc builds so the comparison isolates compiler behavior.

## Completion Checklist

- [x] Public `Iter`/`Stream` use the three-step shape.
- [x] Public `Append` step variant is absent.
- [x] Iterator-plan IR is absent.
- [x] Pipeline has an explicit optimized post-check mode.
- [x] Primitive known-value leaves exist.
- [x] Private state-loop IR exists before LIR.
- [x] State loops lower to ordinary LIR joins/blocks.
- [x] Generic ARC forward-sibling-join behavior has focused coverage.
- [x] Optimized callable-state specialization is entered only for `--opt=size`
      and `--opt=speed`.
- [x] Non-optimized paths construct zero optimized demand/private-state/worker
      data.
- [x] Ordinary lowering has no dormant optimized fields.
- [x] Optimized-only helpers require an optimized context.
- [x] No deeper helper independently checks target/backend/source facts to
      enable callable-state specialization.
- [ ] Result demand is explicit compiler data everywhere optimized lowering
      needs it.
- [ ] Every optimized-shape regression runs in both optimized modes.
- [ ] Primitive demanded values optimize without aggregate wrapping.
- [ ] Primitive and single-field-record loop state optimize equivalently.
- [ ] Sparse private state distinguishes omitted children from
      unknown-but-carried children.
- [ ] Sparse private state is used for loop construction.
- [ ] Public materialization is explicit.
- [ ] Private state bodies are scope-closed before LIR.
- [ ] Demand is threaded through fields, tuples, tags, callables, direct calls,
      branches, matches, and loops.
- [ ] Finite callable alternatives remain finite across differing capture
      shapes.
- [ ] Loop demand is a graph fixed point over observations and reachable
      `continue` edges.
- [ ] Runtime leaves are state parameters, not state dimensions.
- [ ] Demand-keyed direct-call workers are created only in optimized modes.
- [ ] Public iterator reuse and public materialization boundaries are correct.
- [ ] Stream effect ordering is correct.
- [ ] Infinite iterator examples work.
- [ ] LIR, ARC, and backends contain no iterator/stream-specific logic.
- [ ] Focused iterator allocation/control-flow regressions pass.
- [ ] Rocci Bird `.iter()` and direct-list collision loops have equivalent
      optimized hot-path disassembly.
- [ ] Rocci Bird `.iter()` has no normal-path `Iter.append` allocation.
- [ ] Rocci Bird `.iter()` has no normal-path public wrapper allocation.
- [ ] Rocci Bird `.iter()` has no unobserved `len_if_known` hot-path work.
- [ ] Rocci Bird final `--opt=size` wasm size is recorded.
- [ ] Rust comparison wasm size is recorded.
- [ ] Remaining Roc-vs-Rust size gap is explained with disassembly evidence.
- [ ] Rocci Bird optimized-mode compiler cost and optimizer-node counts are
      recorded.
- [ ] `zig build run-test-zig-module-postcheck --summary all --color off`
      passes.
- [ ] `zig build run-test-zig-lir-inline --summary all --color off` passes.
- [ ] `zig build run-test-cli --summary all --color off` passes.
- [ ] `zig build minici` passes.
- [ ] Stable compiler changes are committed and pushed in small checkpoints.

## Forbidden Shapes

- No explicit iterator plans.
- No public or compiler-private `Append` step variant.
- No source-form rule for `for`, `if`, or `match`.
- No Rocci Bird, wasm, generated-symbol, object-byte, disassembly, or backend
  output rule.
- No trait/interface encoding for `Iter`.
- No adapter-chain encoding in public Roc types.
- No hidden mutation of public iterator or stream values.
- No reference-count uniqueness test for iterator optimization.
- No late cleanup pass after public-value lowering.
- No optimized callable-state specialization in dev, interpreter, `roc check`,
  compile-time finalization, or non-optimized build modes.
- No state-count cutoff, size cutoff, or other optimization heuristic.
- No private state body may reference a local that is not bound in that body or
  passed as an explicit state parameter.
