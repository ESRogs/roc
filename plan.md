# Optimized Callable-State Lowering Plan

## Goal

Convert the current branch to the final optimized callable-state and
control-boundary specialization design.

This plan targets the long-term architecture directly. The implementation may
land in checkpoints, but each checkpoint must be a strict subset of the final
design. Do not add a temporary iterator-specific system, cleanup pass, fallback
path, or source-form rule with the expectation that it will be replaced later.

The target is Rust-like generated code for Roc `Iter` and `Stream` consumers:
private cursor state, direct stepping, and no heap allocation for public
iterator or callable wrappers in consuming hot paths. Roc must keep its public
API: `Iter(item)` and `Stream(item)` remain ordinary concrete Roc records whose
step fields are ordinary Roc lambdas. The compiler uses existing lambda-set
facts, captures, known values, checked identities, layouts, and explicit result
demand to specialize optimized code. It does not introduce iterator plans,
source-level adapter-chain types, traits, public `Append` variants, or
iterator-specific backend rules.

This design is enabled only by `--opt=size` and `--opt=speed`. It is not enabled
because the target is wasm, because the program uses `Iter`, because the source
contains `for`, or because Rocci Bird benefits from it. Dev builds, `roc check`,
compile-time finalization, interpreter paths, and every non-optimized build mode
use ordinary public-value lowering and construct no optimized demand/private
state/worker data.

That mode boundary is the first implementation milestone. Until it is
structural, every later optimization result is suspect: a helper could be paying
optimized-mode cost in a fast-feedback path, or a supposedly optimized build
could still be materializing public wrappers and relying on cleanup. The
conversion must therefore start by making ordinary lowering and optimized
lowering different construction paths with different owned state, then move the
current specialization machinery behind the optimized path.

The mode restriction is part of the target design, not a temporary performance
guard. Callable-state specialization is a generated-code optimization. It is
allowed to allocate demand graphs, sparse private-state tables, loop fixed-point
work, and demand-keyed workers only after the post-check driver has selected an
optimized lowering entrypoint. Non-optimized paths must not construct dormant
versions of those structures and must not enter helpers that can create them.

`--opt=size` and `--opt=speed` use the same callable-state specialization
semantics. Any focused optimizer-shape regression must run in both modes with
the same expected optimizer-owned facts unless the test is explicitly about a
later backend size-vs-speed preference.

## Current Branch Starting Point

Useful pieces already exist on this branch:

- public `Iter` and `Stream` are back to the three-step public shape
- the public `Append` experiment has been removed
- explicit iterator-plan IR has been removed
- an optimized post-check mode exists
- primitive known-value leaves exist
- private state-loop IR exists before LIR
- state loops lower to ordinary LIR joins and blocks
- ARC has focused coverage for forward sibling joins

The remaining work is to make those pieces one coherent optimized lowering path.
The current implementation still has places where dense public values can leak
into optimized state:

- ordinary and optimized lowering ownership is not yet fully separated
- loop-state construction can start from whole public known values
- private state can accidentally encode omitted children as dense unknown public
  children
- `continue` edges can materialize a next public wrapper instead of carrying
  demanded private state
- callable alternatives can widen to public callables when capture shapes differ
- unobserved iterator fields such as `len_if_known` can remain in hot loops
- temporary diagnostics, probes, or relaxed assertions can hide real leakage

The conversion is complete only when optimized lowering clones producers under
explicit demand before public wrappers are created, and when public
materialization happens only at explicit public observation boundaries.

The current implementation must therefore be changed by moving ownership, not by
adding another optimizer beside it. The shared lowering/cloning state should be
classified into three groups:

- ordinary public-value lowering data that remains available in every build mode
- optimized-only demand/private-state/worker data that moves behind the
  `--opt=size`/`--opt=speed` entrypoint
- neutral checked, known-value, layout, and lambda-set facts that are produced
  before lowering and consumed explicitly by either lowering family

Every existing helper in `src/postcheck/monotype_lifted/spec_constr.zig` must be
classified the same way. A helper that creates or consumes result demand,
demanded known values, sparse private state, loop fixed points, finite callable
alternatives, or demand-keyed workers belongs to optimized lowering and must
take the optimized context directly. A helper that materializes an ordinary Roc
value belongs to ordinary lowering and may also be called by optimized lowering
only at an explicit materialization boundary. A helper that currently does both
must be split; leaving a mode flag inside it is not the target design.

Tests must prove this ownership change directly before relying on Rocci Bird or
wasm output. A focused mode-boundary fixture must lower the same source through
dev/check-style paths, `--opt=size`, and `--opt=speed`, then assert compiler-owned
facts: no optimized context or optimized-owned nodes in non-optimized modes, and
the same optimized entrypoint plus the same demand/private-state facts in both
optimized modes. Final byte size and disassembly are integration evidence after
those compiler invariants pass.

## Implementation Transition Map

The current branch should be moved to the target design by replacing ownership
boundaries, not by adding another layer beside the existing one.

- `src/postcheck/lir_lower.zig` and `src/postcheck/solved_lir_lower.zig` own the
  post-check lowering choice. Add a small classifier there, pass the result as
  explicit data, and construct either ordinary public-value lowering or
  optimized callable-state lowering. Do not let deeper helpers infer the answer
  from target settings, wasm settings, builtin names, or final backend choices.
- `src/postcheck/monotype_lifted/spec_constr.zig` owns the current optimized
  specialization machinery. Split its ordinary public-value lowering state from
  optimized-only state. Demand arenas, demanded-known values, sparse private
  state, loop fixed-point work, and worker queues must exist only behind the
  optimized context.
- Existing private state-loop lowering should remain the pre-LIR shape, but its
  inputs must become sparse demanded facts. Whole public known values may be
  used only to satisfy explicit materialization demand.
- Existing known-value and lambda-set facts remain the only source of private
  callable shape. Do not create iterator plans, source adapter-chain types,
  public `Append` variants, or iterator-specific lambda-set variants.
- Existing LIR, ARC, interpreter, LLVM, wasm, Binaryen, and linker paths should
  stay generic. If any of those consumers need to know about iterator, stream,
  private cursor, or callable-state rules, optimized lowering has failed to emit
  ordinary scope-closed LIR.
- Existing focused optimizer tests should become mode-parameterized where the
  property is optimizer-owned. The same source should prove ordinary lowering
  in dev/check/interpreter-style paths and the same optimized facts in both
  `--opt=size` and `--opt=speed`.

The implementation order below is the landing order. Later steps should not be
started by adding a workaround around an earlier missing invariant; the earlier
producer must be fixed so later consumers receive explicit data.

Each step should land with focused tests that prove compiler-owned facts, not
final backend artifacts. Disassembly, wasm size, and Rocci Bird behavior are
integration evidence after the compiler invariant is covered. They must not be
used as the only proof that an optimizer path ran, that wrapper allocation was
avoided, or that a source-form difference is gone.

The implementation must not add a separate plan-value IR or an
eliminate-then-materialize pass before LIR. Temporary demand, private-state,
loop-graph, and worker data may exist inside optimized lowering, but each
optimized clone must either emit ordinary LIR directly, carry compiler-owned
private state to the next optimized clone, or materialize the public Roc value
because the active demand explicitly asks for it.

The first hard boundary to land is the mode/cost boundary. The optimizer may be
more expensive than ordinary lowering because it solves exact demand graphs,
revisits provisional loop-edge clones, and creates demand-keyed workers. That
cost is acceptable only in `--opt=size` and `--opt=speed`. Dev builds,
`roc check`, compile-time finalization, interpreter paths, and other
non-optimized modes must not allocate dormant optimizer data or enter helpers
that can create it. The rest of this plan assumes that boundary has already
been implemented and tested.

## Design Rationale

The Rust comparison is the performance reference, not the source-language
model. Rust gets tight iterator code because each adapter chain is represented
as a distinct monomorphized type, and consuming code calls `next(&mut state)` on
that private state. Roc must keep the public type `Iter(item)` or
`Stream(item)` as a concrete Roc record with an ordinary zero-argument step
lambda, so Roc cannot copy Rust's trait/type-level encoding.

Roc's corresponding private identity is already present in ordinary compiler
facts: lambda sets, callable captures, known records/tags/tuples/nominals,
checked identities, and monomorphic layout decisions. Optimized lowering should
consume those facts under exact result demand and defunctionalize them into
private state machines before public wrappers are created. That is how Roc gets
Rust-like generated code while keeping Roc's pure public API and preserving
branch unification without adapter-chain types.

This is not a loop-to-recursive-function source transform. Optimized lowering
may emit direct workers or LIR joins for compiler-created private state, but a
source loop still has source loop semantics. Source mutable variables, branch
conditions, match scrutinees, guards, appended item expressions, stream
effects, `dbg`, `expect`, `crash`, `break`, and `return` remain ordinary
checked control flow. The optimizer may mutate only private cursor state that it
created while satisfying exact demand.

Earlier iterator-specific approaches are not part of the target design:

- public or internal `Append` step variants encode optimization concerns into
  the iterator model
- iterator-plan IR creates a second representation beside ordinary lambdas and
  lambda sets
- source-form rules for `for`, `if`, or `match` would metastasize into syntax
  special cases
- cleanup passes that first materialize public wrappers and then remove them
  pay for the wrong representation and hide missing producer facts

The target design replaces all of those with one generic mechanism:
producer-under-demand lowering. It should optimize `Iter`, `Stream`, and any
ordinary callable-state value whose checked facts are precise enough. It should
not know Rocci Bird, wasm, generated symbol names, public builtin names, or
backend output.

Compile-time cost is intentionally paid only by optimized code-generation
modes. The optimizer creates extra work for distinct result demands, sparse
private-state nodes, loop-demand graph nodes, finite callable alternatives, and
demand-keyed workers. That work is acceptable for `--opt=size` and
`--opt=speed`, and it is not acceptable for dev/check/interpreter feedback
paths. There are no cutoffs or fallback paths: exact keys must share equivalent
work, and oversized graphs must be fixed by improving demand precision or
sharing, not by disabling the optimizer heuristically.

## Final Architecture

The post-check driver must classify lowering before any lowering context is
constructed:

```text
ordinary public-value lowering
optimized callable-state lowering
```

Only `--opt=size` and `--opt=speed` select optimized callable-state lowering.
Every other mode selects ordinary public-value lowering.

Ordinary public-value lowering owns public Roc value construction. It has no
result-demand arena, demanded-known-value arena, sparse private-state table,
loop fixed-point graph, or optimized worker queue. Optimized callable-state
lowering owns those structures and can be constructed only by the optimized
entrypoint.

The optimized entrypoint owns:

- demand frames over producer-consumer boundaries
- sparse demanded private-state nodes
- loop-demand graph nodes for recursive loop-carried demand
- finite callable alternatives from ordinary lambda-set facts
- demand-keyed direct-call workers
- scope-closure validation before ordinary LIR reaches ARC

Both lowering families emit ordinary LIR. LIR, ARC, LirImage, the interpreter,
LLVM, object, wasm, Binaryen, and linkers must not know iterator, stream, or
private-cursor rules.

## Core Invariants

- Public `Iter` and `Stream` remain ordinary three-step Roc records.
- Ordinary Roc lambdas and existing lambda-set facts are the only private
  adapter-shape source.
- There is no public `Append` step and no compiler-private iterator source type.
- There is no iterator-plan value and no adapter-chain IR.
- There is no late cleanup pass that first materializes public wrappers and then
  removes them.
- There is no source-form rule for `for`, `if`, `match`, `Iter`, `Stream`, wasm,
  Rocci Bird, generated symbols, object bytes, or disassembly.
- Result demand is explicit compiler data owned by optimized lowering.
- Sparse private state distinguishes omitted children from unknown-but-carried
  children.
- Public Roc values are materialized only under explicit materialization demand.
- Loop-carried demand is solved as graph fixed points, not recursive finite
  trees.
- Runtime leaves become state parameters, never finite-state dimensions.
- Optimized private state is scope-closed before LIR.
- ARC remains the only owner of reference-count insertion.
- Observable Roc behavior is identical in dev, `--opt=size`, and `--opt=speed`.

## Migration Sequence

### 0. Clean The Baseline

- Remove temporary debug prints, dumps, local probes, and relaxed optimizer
  assertions.
- Restore focused tests to strict expectations.
- Keep only in-progress compiler fixes that have a focused regression and fit
  the final design.
- Confirm there is no remaining public or internal `Append` step and no
  iterator-plan residue.

Tests:

- focused debug-print/probe scan is clean
- focused optimizer test exposes the current public-wrapper leakage before the
  fix
- no test accepts extra allocator wrappers, public iterator calls, or switch
  churn as a temporary threshold

Success criteria:

- the branch starts from strict tests and no diagnostic instrumentation
- current failures are represented by focused compiler regressions where
  feasible
- no temporary investigation code is committed

### 1. Split The Mode Gate And Context Ownership

- Add a small post-check lowering classifier near the driver boundary.
- Select ordinary public-value lowering or optimized callable-state lowering
  before constructing any lowering-owned state.
- Enter optimized callable-state lowering only for `--opt=size` and
  `--opt=speed`.
- Treat the compiler's own `ReleaseFast`/debug build mode as irrelevant to this
  decision; only the user's Roc optimization mode selects the lowering family.
- Thread the classifier through `src/postcheck/lir_lower.zig` and
  `src/postcheck/solved_lir_lower.zig` as explicit data.
- Represent the classifier as a small construction-time choice, not as a
  reusable global flag. It should be consumed before ordinary or optimized
  lowering state exists.
- Do not recover the answer from target triples, wasm settings, backend
  choices, builtin names, source syntax, or package metadata.
- Split context construction so ordinary lowering has no dormant optimized
  fields.
- Move existing demand/private-state/worker arenas behind an optimized context.
- Require optimized-only helpers to receive that optimized context directly.
- Keep compile-time evaluation and checking independent from optimized runtime
  private-state lowering.
- Make the optimized context the compile-time-cost boundary: ordinary lowering
  must not allocate, initialize, or retain demand/private-state/worker data.
- Make the boundary structural in the API. Optimized helpers should take an
  optimized context, not a shared lowering context plus a mode flag.
- Remove helper-level "if optimized" branches where the helper can instead be
  reachable only through the optimized context. Mode checks belong at the
  post-check construction boundary.
- Delete nullable optimized fields from ordinary lowering state rather than
  leaving them empty in non-optimized modes.
- Keep optimized temporary data local to optimized lowering. Do not add a stored
  plan-value layer that later needs an elimination or materialization pass.
- Move the current specialization data structures behind this optimized context
  before extending their behavior. Do not keep a shared lowering context with
  nullable demand/private-state fields while adding more optimizer features.
- Make the optimized context construction auditable from the post-check driver:
  one visible branch constructs ordinary lowering, and one visible branch
  constructs optimized lowering.
- Add debug counters or test-only construction hooks at the entrypoint boundary
  only if needed to prove that non-optimized paths never construct optimized
  state. Do not leave production logic dependent on those counters.
- Make any such counters report construction of the optimized context itself,
  not final wasm size, symbol names, disassembly patterns, or backend output.

Tests:

- dev lowering does not construct the optimized context
- `roc check` does not construct the optimized context
- compile-time finalization does not construct optimized private runtime state
- interpreter-style lowering does not allocate optimized structures
- wasm dev builds do not enter optimized specialization merely because the
  target is wasm
- `--opt=size` enters the optimized entrypoint
- `--opt=speed` enters the same optimized entrypoint
- a compiler built in debug mode and a compiler built in ReleaseFast choose the
  same lowering family for the same Roc `--opt` setting
- both optimized modes produce the same optimizer-owned facts for a small
  callable-state fixture before backend preferences
- an optimized worker/private-state helper cannot be called without an
  optimized context, by API shape or debug assertion
- a code audit or compile-time API test proves optimized-only helpers are not
  callable from ordinary lowering without first constructing optimized-owned
  data
- a non-optimized wasm build follows ordinary public-value lowering even though
  wasm is an important final integration target
- source using `Iter`, `Stream`, `for`, `if`, and `match` in dev mode does not
  construct optimized demand state merely because those constructs are present

Success criteria:

- the optimized entrypoint has exactly two mode callers: `--opt=size` and
  `--opt=speed`
- ordinary lowering cannot allocate or retain dormant optimizer state
- the current specialization machinery is unreachable from ordinary lowering
  except through ordinary public materialization APIs shared intentionally by
  both paths
- fast-feedback paths do not pay demand/private-state/worker allocation cost
- no new stored plan-value IR or post-lowering cleanup/materialization pass
  exists between Lambda Mono and LIR
- the mode decision can be audited at the post-check driver boundary without
  reading source syntax, target triples, wasm settings, or backend output
- every later optimizer test can assume the mode boundary is already proven
- a code search shows no deeper helper independently checking target triples,
  wasm settings, backend choices, builtin names, source syntax, or generated
  symbols to decide whether callable-state specialization is enabled
- any test-only counters used to prove the boundary are isolated from
  production lowering decisions

### 2. Define Demand Frames And Sparse Result Demand

- Define result demand local to optimized lowering.
- Define a demand frame containing result demand, checked control scope, and the
  optimized context.
- Represent materialization as an explicit demand.
- Represent primitive runtime leaves directly.
- Represent record demand by field name.
- Represent tuple demand by original item index.
- Represent tag demand by tag choice plus demanded payload indexes.
- Represent nominal demand by demanded backing data.
- Represent callable demand by target identity plus demanded capture indexes.
- Represent loop-carried recursive demand by loop-demand graph references.
- Make demand merge deterministic and exact.
- Store demanded children sparsely by checked child identity.
- Treat missing sparse children as "not carried," never "unknown dense child."
- Treat unknown-but-carried children as explicit runtime leaves.

Tests:

- primitive loop state optimizes without a record wrapper
- primitive loop state and equivalent single-field-record state optimize
  equivalently
- direct primitive state and single-field-record state are tested in both
  `--opt=size` and `--opt=speed`
- record demand omits unused sibling fields
- tuple demand omits unused sibling items and preserves original indexes
- tag demand can carry tag choice without unused payloads
- callable demand can omit unused captures
- nominal demand unwraps backing data only when demanded
- materialization demand rebuilds the ordinary public value
- omitted private state cannot be read as a dense public child

Success criteria:

- every optimized clone has an explicit result demand
- sparse demanded child identity is preserved for records, tuples, tags,
  nominals, callables, and primitive leaves
- aggregate wrapping is never required for a primitive value to become
  optimized private state
- public layouts are consulted only when materialization demand requires an
  ordinary public value
- demand frames are optimized-entrypoint data and do not become a persistent IR

### 3. Replace Dense Known State With Sparse Demanded State

- Audit `src/postcheck/monotype_lifted/spec_constr.zig` for whole-value state
  construction.
- Replace loop-state identity based on dense known values with sparse demanded
  private-state keys.
- Replace dense state argument extraction with extraction from demanded runtime
  leaves.
- Keep ordinary dense values only for public materialization.
- Forbid sparse private state from being forced through ordinary dense record,
  tuple, tag, nominal, or callable values.
- Convert sparse private state back to public values only at explicit
  materialization boundaries.
- Ensure finite state keys include only demanded known choices and demanded
  child facts.
- Ensure branch, match, pending-let, and loop predecessor locals are either
  bound inside the cloned state body or passed as explicit transition
  parameters.
- Add a debug validator before LIR lowering that rejects private-state bodies
  with out-of-scope local references.
- Convert no-constructor loop paths, branch results, match results, and pending
  lets to carry demanded private facts directly instead of temporarily building
  public wrappers.
- Treat primitive demanded values as first-class sparse private state, so a
  primitive loop cursor and a single-field-record wrapper around that primitive
  produce equivalent optimized state.

Tests:

- sparse record state carries only demanded fields
- sparse tuple state carries only demanded items
- sparse tag state carries tag choice without unused payloads
- sparse callable state carries only demanded captures
- demanded private state materializes correctly at a public boundary
- a known tag branch using payloads keeps payload binders in scope or passes
  them as explicit parameters
- a demanded value created in one branch cannot be reused by a sibling branch
  unless explicitly carried or materialized

Success criteria:

- optimized state identity is sparse demanded facts
- public materialization is the only path from sparse private state to ordinary
  public values
- finite state growth comes only from demanded known tag/callable alternatives
- every private state body is scope-closed before ARC

### 4. Thread Demand Through Producer-Consumer Boundaries

- Add or finish the demand-aware clone entrypoint for optimized lowering.
- Keep ordinary clone behavior for materialization demand.
- Field access clones the receiver under field demand.
- Tuple access clones the receiver under item demand.
- Tag matches clone scrutinees under tag-choice and payload demand.
- Callable calls clone callees under callable demand and results under caller
  demand.
- Direct-call results enter demand-keyed workers when worker creation is
  justified.
- Branch and match results merge consumer demand exactly.
- Preserve source evaluation order with pending-let/control-scope machinery.
- Do not move or duplicate branch conditions, scrutinees, guards, appended item
  expressions, stream effects, `dbg`, `expect`, or `crash`.
- Treat `for`, `if`, and `match` as ordinary lowered control flow, not
  optimization triggers.

Tests:

- field access of a direct-call result avoids unused field materialization
- tuple access of a direct-call result avoids unused item materialization
- tag match of a direct-call result keeps only demanded payloads
- known callable returned from a direct call can be called without public
  closure materialization
- branch result with one demanded field carries only that field
- branch result later returned materializes the public value
- `dbg`, `expect`, `crash`, stream effects, and branch guards keep source order
- equivalent `if` and `match` cases optimize from facts, not source-form rules

Success criteria:

- no optimized helper scans a finished body to rediscover demand
- materialization is explicit wherever public values are required
- optimized cloning never creates out-of-scope local references
- source control behavior is preserved

### 5. Defunctionalize Finite Callable State

- Treat known callable values as ordinary optimizer facts.
- Preserve finite callable alternatives until public callable materialization is
  demanded.
- Inline a known callable call when exactly one target remains.
- Dispatch over finite callable alternatives when multiple targets remain.
- Carry demanded captures as private state.
- Omit unused captures.
- Preserve target identity independently from capture shape.
- Keep erased callable materialization only for public callable boundaries.
- Do not change lambda-set solving and do not add an iterator-specific
  lambda-set variation.

Tests:

- single known callable target inlines under call demand
- two known callable targets become finite private alternatives
- demanded captures are preserved
- unused captures are omitted
- alternatives with different capture counts remain finite
- callable crossing a public boundary materializes normally
- callable reuse after an optimized call preserves public immutability

Success criteria:

- hot paths do not allocate public callable wrappers when finite lambda-set
  facts are available
- finite alternatives are not widened merely because capture shapes differ
- public callable behavior is unchanged

### 6. Build Loop Demand Graph Fixed Points

- Replace finite-tree recursive demand with explicit loop-demand graph nodes.
- Represent `continue` of loop parameter `i` as a reference to loop-demand node
  `i`.
- Allow nested field, tag, payload, callable, nominal, and direct-call result
  demand to point at loop-demand nodes.
- Merge loop-demand graph contents monotonically.
- Compute loop-parameter demand from body observations and reachable
  `continue` edges.
- Clone initial values under the final entry demand.
- Clone each `continue` value under the demand for the parameter it feeds.
- Recompute provisional edge clones when fixed-point demand changes.
- Split finite tag/callable alternatives only when demanded.
- Carry runtime leaves as state parameters, not state dimensions.
- Do not use state-count cutoffs, size cutoffs, or fallback materialization to
  escape recursive demand.
- Treat `len_if_known` as an ordinary record field that enters private state
  only if demanded.
- Preserve ordinary source mutable variables, stream effects, `break`, and
  `return` as ordinary control flow.
- Run the fixed point before state keys and state bodies are finalized. A state
  body must not discover a new callable capture, tag payload, field, tuple item,
  or runtime leaf after the key for that state has already been committed.

Tests:

- loop demand ignores unobserved carried public fields
- recursive iterator demand remains finite in the compiler representation
- loop fixed point terminates when loop parameters feed each other
- list iterator loop has no public wrapper allocation in the hot path
- list iterator plus append has no `Iter.append` allocation in the hot path
- append/concat phase changes become private-state transitions
- known tag/callable changes across `continue` remain finite
- runtime leaf values are join parameters, not state variants
- loops with `break`, `return`, mutable variables, and effectful streams preserve
  behavior in dev, `--opt=size`, and `--opt=speed`
- ARC never sees an unbound local from optimized private-state lowering

Success criteria:

- iterator stepping loops carry only demanded private state
- unobserved `len_if_known` bookkeeping does not appear in private stepping loops
- every `continue` edge is built from final fixed-point demand
- every loop state body is scope-closed before LIR

### 7. Add Demand-Keyed Direct-Call Workers

- Create optimized workers only while cloning a call under explicit optimized
  demand.
- Key worker identity by callee identity, split argument facts, result demand,
  and relevant type/layout decisions.
- Keep the original public-ABI body available.
- Lower a specialized call to the worker during the same clone that discovered
  the demand.
- Share workers only when all correctness-relevant facts match.
- Keep worker queues deterministic by stable function and demand ordering.
- Do not create workers in non-optimized modes.
- Do not add a later pass that scans finished code for calls to rewrite.

Tests:

- worker is created for a demanded split argument in `--opt=size`
- the same worker property holds in `--opt=speed`
- worker is not created in dev mode
- public function call still works when no split worker is demanded
- identical worker facts reuse the same worker
- different result demand creates a distinct worker only when required

Success criteria:

- optimized workers are generated only from explicit optimized call patterns
- worker identity contains all correctness-relevant facts
- the public-ABI body remains correct and available
- no post-clone call rewrite pass exists

### 8. Preserve Public Boundaries And Effects

Materialize public values when source code observes them, including:

- storing or returning an iterator or stream
- passing an iterator or stream to unspecialized code
- reading `len_if_known`
- directly matching on the public result of `Iter.next` or `Stream.next!`
- storing, returning, or passing a callable through a public/erased boundary

Preserve:

- public iterator and stream immutability
- stream effect ordering
- branch conditions, scrutinees, guards, appended item expressions, `dbg`,
  `expect`, and `crash`
- finite and infinite iterator behavior

Tests:

- iterator reuse after a consuming loop
- storing an iterator in a record/list and reading it later
- passing and returning iterators through unspecialized code
- direct public `Iter.next` match
- reading `iterator.len_if_known`
- equivalent public-boundary tests for `Stream`
- stream skipped-value effects run in source order
- unbounded range and Fibonacci-style custom iterator consumption still work

Success criteria:

- optimized private cursor mutation never mutates public Roc values
- public observations produce the public three-tag step result and public record
  layout
- effects and diagnostics preserve source behavior

### 9. Keep LIR, ARC, And Backends Generic

- Lower private state machines to ordinary LIR joins, blocks, switches, calls,
  and jumps.
- Validate scope closure before ARC insertion.
- Keep ARC as the only owner of reference-count insertion.
- Keep LIR, ARC, LirImage, interpreter, LLVM, object, wasm, and Binaryen free
  of iterator/stream/private-cursor rules.
- Fix any ARC certification failure by producing valid scope-closed LIR, not by
  adding ARC knowledge of optimizer-private state.

Tests:

- synthetic two-state private graph lowers to ordinary LIR
- primitive and record state loops have expected join parameters
- optimized hot path has no public `Iter.next` wrapper call
- optimized hot path has no public step-result tag churn
- materialized public iterator still lowers normally
- backend source scans find no iterator/stream rules

Success criteria:

- LIR and backends see ordinary control flow and values only
- no iterator-specific ARC or backend logic exists
- scope errors are caught before ARC

### 10. Prove Rocci Bird And Compare With Rust

Build and record:

- Rocci Bird with `.iter()` collision points using Roc `--opt=size`
- Rocci Bird with direct-list collision points using Roc `--opt=size`
- Rust Rocci Bird with Rust size optimizations and Binaryen
- the old comparison wasm

For each Roc build:

- record final wasm byte size
- disassemble `update`
- count allocator wrapper calls in the normal playing path
- count public iterator/callable wrapper calls in the normal playing path
- compare collision-loop control-flow shape
- compare static data size
- record whether `len_if_known` append bookkeeping appears in the hot path
- separate normal-playing-path allocation sites from game-over-only allocation
  sites
- explain any remaining `.iter()` vs direct-list size or allocation difference
  with concrete compiler-owned evidence

Success criteria:

- `.iter()` and direct-list collision-point forms have equivalent optimized
  hot-path control flow
- `.iter()` introduces no normal-path `Iter.append` allocation
- `.iter()` introduces no normal-path public wrapper allocation
- `.iter()` does not execute unobserved `len_if_known` bookkeeping
- final Roc wasm size is recorded next to Rust wasm size
- any remaining Roc-vs-Rust gap is explained with disassembly evidence and a
  compiler issue or follow-up plan when it violates this design

### 11. Measure The Mode Boundary

After the optimizer is functionally correct, measure the compile-time boundary
so the cost model stays honest.

- Add or reuse test instrumentation that counts optimized context construction,
  demand nodes, private-state nodes, loop-demand nodes, and demand-keyed
  workers for focused fixtures.
- Run the same fixture through dev/check-style lowering, `--opt=size`, and
  `--opt=speed`.
- Confirm non-optimized modes construct zero optimized contexts and zero
  optimized-owned nodes.
- Confirm `--opt=size` and `--opt=speed` enter the same optimized entrypoint
  and produce the same optimizer-owned facts before backend preferences.
- Record compile-time impact on a small fixture and on Rocci Bird so future
  changes can distinguish expected optimized-mode work from accidental
  non-optimized-mode cost.
- Treat unexpected optimized graph growth as a demand-precision or sharing bug,
  not as permission to add size cutoffs or fallbacks.

Tests:

- mode-boundary fixture with no optimized context in dev/check paths
- mode-boundary fixture with the same demand/private-state facts in both
  optimized modes
- focused fixture proving ordinary public-value lowering still materializes
  iterators/callables when source observes them
- focused fixture proving optimized lowering avoids public wrapper allocation
  without relying on final wasm size

Success criteria:

- non-optimized modes have zero optimized context constructions in focused
  instrumentation
- optimized modes share the same callable-state specialization path
- compile-time cost is paid only after the explicit optimized entrypoint is
  selected
- no compile-time performance guard uses heuristic cutoffs or fallback
  materialization
- Rocci Bird compile-time and optimizer-node counts are recorded next to final
  wasm size for future comparison

## Test Matrix

Focused compiler tests first:

```sh
zig build run-test-zig-module-postcheck --summary all --color off
zig build run-test-zig-lir-inline --summary all --color off
zig build run-test-cli --summary all --color off
```

Focused optimizer tests that assert private-state shape, allocation-call
absence, wrapper-call absence, worker creation, or mode gating should use one
mode-parameterized fixture where possible:

```text
same Roc source
  dev/check/interpreter expectation: ordinary public-value lowering
  --opt=size expectation: optimized callable-state lowering
  --opt=speed expectation: optimized callable-state lowering
```

The `--opt=size` and `--opt=speed` expectations should be identical for
optimizer-owned facts: entrypoint selection, result demand, sparse private
state, finite callable alternatives, worker keys, loop fixed-point results, and
public materialization boundaries.

Regression tests should be added before each fix when practical:

- one minimal fixture for the current leakage or scope failure
- one equivalent source-shape fixture, such as primitive versus single-field
  record or inline value versus named top-level value
- one public-boundary fixture proving materialization still happens when source
  code observes the public value
- one mode-gating fixture proving the same source does not construct optimized
  state in non-optimized paths
- one paired optimized-mode fixture proving `--opt=size` and `--opt=speed`
  produce the same optimizer-owned facts for the same source

Disassembly and byte-size checks are final integration evidence, not the source
of truth for optimizer eligibility. A focused compiler test must own each
semantic or lowering invariant before the Rocci Bird comparison is accepted.

After focused tests:

```sh
zig build minici
```

When `minici` fails in one section, fix that section and rerun the targeted
section until it passes. Return to full `minici` only after the targeted section
passes.

Rocci Bird validation:

```sh
roc build --opt=size main.roc
wasm-tools print rocci-bird.wasm > rocci-bird.wat
```

Use identical wasm/Binaryen tooling for the direct-list and `.iter()` Roc builds
so the comparison isolates the source-form difference.

## Completion Checklist

- [x] Public `Iter`/`Stream` use the three-step shape.
- [x] Public `Append` step variant is removed.
- [x] Iterator-plan IR is removed.
- [x] Pipeline has an explicit optimized-post-check mode.
- [x] Primitive known-value leaves exist.
- [x] Private state-loop IR exists before LIR.
- [x] State loops lower to ordinary LIR joins/blocks.
- [x] Generic ARC forward-sibling-join behavior has focused coverage.
- [x] Temporary diagnostics and relaxed optimizer assertions are removed.
- [x] Optimized callable-state specialization is entered only for `--opt=size`
      and `--opt=speed`.
- [x] Dev/check/interpreter/compile-time-finalization paths do not build
      optimized demand/private-state/worker data.
- [x] Ordinary lowering has no dormant optimized fields.
- [x] Optimized-only helpers require an optimized context.
- [x] No deeper helper independently checks target/backend/source facts to
      enable callable-state specialization.
- [x] Mode-boundary instrumentation proves non-optimized modes construct zero
      optimized contexts.
- [ ] Result demand is explicit compiler data.
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
- [ ] Infinite iterator examples still work.
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

## Non-Negotiable Rules

- Do not reset this branch to `origin/main`.
- Do not reintroduce explicit iterator plans.
- Do not add an `Append` step variant.
- Do not infer iterator behavior from names, generated symbols, wasm bytes,
  object bytes, backend output, or source method names.
- Do not special-case source `for`, `if`, or `match` for iterator performance.
- Do not make `Iter` a trait or interface.
- Do not encode adapter chains in Roc source types.
- Do not mutate public iterator or stream values.
- Do not use reference counting to detect iterator uniqueness.
- Do not move or duplicate `dbg`, `expect`, `crash`, branch conditions,
  scrutinees, guards, appended item expressions, or stream effects.
- Do not let LIR, ARC, or backends know iterator or stream rules.
- Do not keep iterator plans and generalized callable-state specialization as
  competing systems.
- Do not add a late cleanup pass after public-value lowering.
- Do not run optimized callable-state specialization in dev, interpreter,
  `roc check`, compile-time finalization, or non-optimized build modes.
- Do not add state-count cutoffs, size cutoffs, or other optimization
  heuristics.
- Do not allow private state to reference a local that is not bound in that
  state body or passed as an explicit state parameter.
