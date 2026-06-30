# Optimized Callable-State Lowering Plan

## Goal

Implement optimized callable-state lowering as the compiler's single design for
turning Roc `Iter`, `Stream`, and other callable-state values into tight code in
optimized builds.

The target generated shape is Rust-like iterator lowering: private cursor
state, direct stepping, no heap allocation for adapter wrappers in consuming
hot paths, no unobserved public length-hint work, and ordinary LIR before ARC.
Roc does not adopt Rust's public typing model. `Iter(item)` and `Stream(item)`
remain concrete public Roc records whose step fields are ordinary Roc lambdas.
The optimizer uses existing lambda-set data, captures, known values, exact
result demand, and loop-demand graph nodes to reach the private cursor shape.

This optimizer runs only for `--opt=size` and `--opt=speed`. Every other mode
uses ordinary public-value lowering and constructs no optimized demand graphs,
sparse private-state tables, loop fixed-point nodes, or demand-keyed workers.

## Current Checkpoint

The debug and experimental WIP paths have been removed. The remaining direction
is the target design, not a fallback plan.

Deleted or verified absent:

- trace/debug instrumentation for specialization debugging
- hardcoded local-id tripwires
- compact-result demand-refinement experiments
- leaf conditional splitting fallback logic
- public or private `Append` step variants
- explicit iterator-plan or stream-plan IR
- source-form optimization rules for `for`, `if`, `match`, `Iter.append`, or
  `Stream.next!`
- recursive direct-call fallback as a substitute for loop-demand graph nodes

Added minimal contract tests:

- finite callable private state preserves differing demanded capture indexes
- loop-demand references can nest through callable step-result demand without
  requiring materialization or infinite structural expansion

## Target Contract

The optimized entrypoint owns builder-local optimizer data. That data is not a
stored public IR stage and must not escape into LIR, ARC, interpreters, LLVM,
wasm, Binaryen, or linkers.

Required internal data:

- `Demand`: exact continuation use of a value, including materialization,
  runtime leaves, fields, tuple items, nominal backing data, tag alternatives
  and payloads, callable captures and results, direct-call results, and
  loop-carried values.
- `KnownValue`: checked producer structure, including primitive leaves,
  records, tuples, tags, nominals, finite callable targets, and finite tag
  choices.
- `PrivateState`: optimized-only state with sparse demanded children. Missing
  children mean not carried. Present unknown children mean carried runtime
  leaves.
- `FiniteCallableState`: ordinary lambda-set target data plus demanded captures
  by original capture index. Alternatives may have different capture shapes.
- `LoopDemandNode`: graph identity for recursive loop-carried demand. A nested
  demand may refer back to a loop parameter while the owning fixed point is
  active; references must be resolved or closed before crossing worker,
  public-materialization, or LIR boundaries.
- `DemandFrame`: the transient producer-consumer boundary while cloning under
  demand, including the checked control scope that owns any locals introduced
  while satisfying that demand.
- `WorkerKey`: exact compiler data for optimized direct-call workers: callee
  identity, split argument facts, split capture facts, result demand, and
  relevant type/layout decisions.

Output:

- ordinary scope-closed LIR only
- explicit LIR ARC statements only
- no iterator, stream, private-cursor, demand, worker-key, or loop-demand-node
  concepts in LIR, ARC, or backend code

Forbidden shapes:

- public or compiler-private `Append` step variants
- explicit iterator plans, stream plans, or adapter-chain IR
- source-form rewrites for `for`, `if`, `match`, `Iter.append`, or
  `Stream.next!`
- target, wasm, Rocci Bird, generated-symbol, object-byte, or disassembly
  recognition rules
- late cleanup passes after public-value lowering
- state-count, size-count, or "try optimized then fall back" cutoffs
- dense private state that cannot distinguish omitted children from carried
  unknown children
- hidden mutation of public iterator, stream, callable, or source mutable values

## Implementation Plan

### 1. Preserve The Public Model

- Keep public `Iter` and `Stream` as the three-step shape: `One`, `Skip`,
  `Done`.
- Keep `len_if_known` as a public field that is demanded only when source code
  observes it.
- Keep adapter construction in Roc source as ordinary records and ordinary
  lambdas.
- Add architecture checks that reject any reintroduction of `Append` as an
  iterator step or any explicit iterator-plan IR.

### 2. Mode Gate And Context Ownership

- Compute the post-check lowering family once from explicit build mode.
- Construct ordinary public-value lowering for all non-optimized modes.
- Construct optimized callable-state lowering only for `--opt=size` and
  `--opt=speed`.
- Make optimized helpers require optimized-owned data in their API.
- Add tests proving dev/check/interpreter/finalization paths construct no
  optimized context and optimized modes enter the same optimized entrypoint.

### 3. Demand Model

- Make result demand explicit at every optimized producer-consumer boundary.
- Represent materialization, runtime leaves, records, tuples, nominals, tags,
  callables, direct-call results, and loop-carried values.
- Merge demand deterministically and exactly.
- Keep recursive loop demand as graph references, not copied trees.
- Close or resolve loop-demand references before worker, materialization, or
  LIR boundaries.
- Add tests for nested loop references, field/tuple/tag demand, callable
  result demand, and active-reference closure.

### 4. Known Values And Sparse Private State

- Treat primitive known leaves as first-class. A primitive loop cursor must
  optimize equivalently to a single-field record wrapping that primitive.
- Store demanded children sparsely by checked identity: record field name,
  tuple item index, tag payload index, nominal backing value, and callable
  capture index.
- Preserve the difference between omitted children and carried unknown
  children.
- Convert sparse private state to public values only at explicit
  materialization boundaries.
- Add tests for primitive leaves, single-field records, sparse records, sparse
  tuples, sparse tags, sparse callables, sparse nominals, and public
  materialization.

### 5. Finite Callable-State Defunctionalization

- Use existing lambda-set data as the only source of finite callable targets.
- Carry demanded captures by original capture index.
- Inline a single known target directly when demand and scope allow it.
- Dispatch over multiple known targets without widening to a public erased
  callable merely because capture shapes differ.
- Keep callable alternatives private until source code observes a public
  callable boundary.
- Add tests for one target, multiple targets, differing capture counts,
  differing capture indexes, omitted captures, callable reuse after optimized
  call, and public callable crossing.

### 6. Loop Demand Fixed Points

- Represent loop-parameter demand with explicit graph nodes owned by the loop
  fixed point.
- Merge body observations and reachable `continue` edges monotonically.
- Reclone provisional edge values when demand grows.
- Carry runtime leaves as loop parameters, not finite-state dimensions.
- Keep known tag/callable choices as finite private states only when demanded.
- Keep branch, match, guard, stream effect, `dbg`, `expect`, `crash`,
  `break`, and `return` order exactly as checked source requires.
- Add tests for list iterators, iterator append/concat phase changes, runtime
  cursor leaves, mutually recursive loop parameters, source mutable variables,
  `break`, `return`, stream effects, and infinite iterators.

### 7. Control Boundaries

- Treat branches, matches, loops, and direct calls as the same
  producer-under-demand mechanism.
- Do not add source-specific rules for `if`, `match`, `for`, or iterator
  builtins.
- Keep branch-local and match-payload locals inside the cloned region that owns
  them.
- If a demanded private value crosses a control boundary, pass the needed value
  as an explicit runtime leaf or keep the binding inside the state body.
- Reject any private-state body that references an out-of-scope local before
  LIR reaches ARC.
- Add tests for if-joined state, match-joined state, branch-local payloads,
  pending lets, and scope-closed private-state bodies.

### 8. Demand-Keyed Direct-Call Workers

- Create optimized workers only while cloning a call under explicit optimized
  demand.
- Key workers by callee identity, split argument facts, split capture facts,
  result demand, and relevant type/layout decisions.
- Keep the original public-ABI body available.
- Share workers only when all correctness-relevant facts match.
- Add tests proving worker creation in both optimized modes, no worker creation
  in non-optimized modes, deterministic worker reuse, and public call
  correctness without workers.

### 9. Public Boundaries And Effects

Materialize public values when source code observes them, including:

- returning, storing, or passing an iterator or stream
- reading `len_if_known`
- directly matching on public `Iter.next` or `Stream.next!`
- returning, storing, or passing a callable through a public/erased boundary
- storing private candidates in records or lists that source later observes

Add tests for iterator reuse, storing iterators in records/lists, passing
through unspecialized code, direct public `next` matches, length hints, stream
effect ordering, and custom unbounded iterators.

### 10. Lower To Ordinary LIR

- Lower private state machines to ordinary joins, blocks, switches, calls, and
  jumps.
- Ensure every state body is scope-closed before ARC insertion.
- Keep ARC and backends limited to ordinary LIR and explicit RC statements.
- Add source scans or architecture checks proving backend and ARC code do not
  contain iterator, stream, private-cursor, demand, or worker-key concepts.

### 11. Rocci Bird And Rust Validation

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

## Completion Checklist

- [ ] Architecture checks reject `Append` iterator steps and explicit iterator
      plans.
- [ ] Optimized callable-state lowering is constructed only for `--opt=size`
      and `--opt=speed`.
- [ ] Non-optimized paths construct zero optimized demand/private-state/worker
      data.
- [ ] Result demand is explicit compiler data everywhere optimized lowering
      needs it.
- [ ] Loop-carried demand is represented by graph nodes and reaches a fixed
      point over body observations and reachable `continue` edges.
- [ ] Loop-demand references are closed or resolved before worker,
      materialization, and LIR boundaries.
- [ ] Primitive demanded values optimize without aggregate wrapping.
- [ ] Primitive and single-field-record loop state optimize equivalently.
- [ ] Sparse private state distinguishes omitted children from
      unknown-but-carried children.
- [ ] Finite callable alternatives remain finite across differing capture
      shapes.
- [ ] Public materialization is explicit.
- [ ] Private-state bodies are scope-closed before LIR.
- [ ] Demand is threaded through fields, tuples, tags, callables, direct calls,
      branches, matches, and loops.
- [ ] Public iterator reuse and public materialization boundaries are correct.
- [ ] Stream effect ordering is correct.
- [ ] Infinite iterator examples work.
- [ ] LIR, ARC, and backends contain no iterator/stream/private-cursor logic.
- [ ] Focused iterator allocation/control-flow regressions pass.
- [ ] Rocci Bird `.iter()` and direct-list collision loops have equivalent
      optimized hot-path disassembly.
- [ ] Rocci Bird `.iter()` has no normal-path `Iter.append` allocation.
- [ ] Rocci Bird `.iter()` has no normal-path public wrapper allocation.
- [ ] Rocci Bird `.iter()` has no unobserved `len_if_known` hot-path work.
- [ ] Rocci Bird final `--opt=size` wasm size is recorded.
- [ ] Rust comparison wasm size is recorded.
- [ ] Remaining Roc-vs-Rust size gap is explained with disassembly evidence.
- [ ] `zig build run-test-zig-module-postcheck --summary all --color off`
      passes.
- [ ] `zig build run-test-zig-lir-inline --summary all --color off` passes.
- [ ] `zig build run-test-cli --summary all --color off` passes.
- [ ] `zig build minici` passes.
