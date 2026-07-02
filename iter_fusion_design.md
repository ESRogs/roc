# Iterator Fusion Design Contract

This contract governs the replacement of demand-driven callable-state
lowering for `Iter`/`Stream` with stream-fusion-style lowering over
defunctionalized state. It is the durable agreement; implementation slices
must conform to it or change it explicitly first.

## Goals and Non-Goals

Goal: a bounded iterator pipeline whose construction is statically known at
its consuming loop compiles to the same generated-code shape as the
hand-written loop — no adapter objects, no allocation, no indirect calls,
state flattened to scalar loop variables. This is the tier-one guarantee and
it is the project's success criterion.

Non-goals: infinite and custom iterators must be *possible* with the same
public API, not efficient. Dynamically nested or escaping iterators may pay
for their dynamism. No public API change of any kind.

## Hard Invariants

1. `Iter(item)` and `Stream(item)` keep their exact public APIs, including
   custom/unbounded iterator construction. Internals are free to change.
2. Purity semantics are untouched: no eager mutation; steps are pure (or
   effect-checked for Stream); opportunistic in-place mutation stays an
   orthogonal optimization applied where uniqueness licenses it.
3. No algebraic rewrite rules, ever. Fusion is exclusively the composition
   of three semantics-preserving transformations: (a) inlining of the
   generated step function, (b) match collapse on statically known tags,
   (c) constructor specialization of loop-carried state. No transformation
   may claim a roundtrip identity (e.g. build-then-iterate cancellation),
   skip or duplicate a user computation's execution, or reorder anything.
4. Materialization points are consumers and always execute: constructing a
   Set/Dict/List from an iterator really runs, so semantic effects of
   construction (deduplication, ordering) happen exactly where written.
5. Element order is preserved exactly by all tiers. The observable effect
   trace of a Stream pipeline is defined by unfused pull execution
   (per-element, innermost-first) and every tier must reproduce it exactly.
6. The optimizer must never use a user `is_eq` result to justify
   substituting one value for another. Only structural identity licenses
   value merging (CSE, known-value propagation). Custom `is_eq` is a
   quotient; substitution across it leaks representatives and breaks pure
   determinism.
7. Effectful steps (Stream) forbid the pure-only licenses: no dead-code
   elimination of unused effectful computation, no CSE of effectful calls,
   no code motion of effects across conditions. These gates already exist
   (`discardedExprIsEffectFree` and friends) and must guard every new
   transformation.

## Internal Representation

`Iter(item)` internally is a seed+step pair. The step is non-recursive:

    step : state -> [Yield(item, state), Skip(state), Done]

`Skip` exists so filter-like adapters return instead of looping; consumers
(`for`, `collect`, folds) contain the only loops in a pipeline. Stream is
the same representation with an effectful step; effectfulness is a checker
property with no codegen footprint, so Iter and Stream share the internal
representation, the generated dispatch, and the fusion pass.

Per monomorphized item type, every iterator construction site in the
program (each `.iter()`, each adapter application site, each custom
constructor) corresponds to a variant of a compiler-internal closed tag
union of states. A variant's payload embeds its inner iterator's state by
value; only dynamically recursive occurrences are boxed. Adapter closure
arguments (map's function, etc.) become capture-struct fields via the
already-solved lambda sets.

## Generated Step Functions

For each state union the compiler synthesizes an ordinary first-order
function (`step_T`) — one match over the variants, each arm instantiated
from a small closed per-adapter template set (same pattern as derived
structural equality), with custom iterators' arms calling the user's step
lambda through its lambda set. The generated step is ordinary LIR — never
an opaque low-level op — because the fusion transformations must see
through it. Low-level ops remain only at the leaves.

The public `Iter.next` is a generated wrapper looping over `step_T` until a
non-Skip result; compiler-driven consumers bypass it and drive `step_T`
directly so the Skip loop merges into the consumer loop.

## Escape-Based Materialization

Constructions start virtual: known constructor trees consumed at compile
time. A variant is minted — layout assigned, dispatch arm generated — only
for a construction that escapes into runtime: stored in a data structure,
crossed a boundary specialization declined, or merged at a join the
compiler chose not to split. The emitted union contains exactly the escaped
variants; the emitted step has exactly those arms; if nothing escapes,
nothing is emitted. Consequence for pipeline ordering: fusion decisions must
be made before these internal layouts are finalized.

## Tiers

- Tier one (the guarantee): construction statically known at the consuming
  loop. Result: fused loop, scalar state, no dispatch, no allocation,
  LIR-equivalent to the hand-written loop.
- Tier two: construction known up to a small runtime choice (branch joins).
  Result: per-branch specialization or a small tag discriminant consulted
  as rarely as the shared structure allows (e.g. only at Done transitions
  when cores are shared). Comparable to Rust's enum-of-iterators.
- Boxed tier: dynamically nested, escaping, custom, or infinite iterators.
  Result: by-value tagged state where possible, boxed at recursive
  occurrences, stepped through the generated dispatch. Correct, deliberately
  unoptimized. Heap allocation appears only here, and only for boxing.

A missed specialization degrades tier, never correctness: unfused code is
correct code. No invariant may exist whose violation means "the optimizer
was not smart enough."

## Acceptance

1. Differential harness: every pipeline test runs both the fused output and
   the naive unfused lowering and requires identical results — values,
   crash-versus-no-crash, and for Stream the full ordered effect trace
   against a mock host. Mandatory cases include Set/Dict materialization
   mid-pipeline with a deliberately coarse custom `is_eq` and
   representative-distinguishing observers.
2. Tier-one LIR identity: `list.iter().map(f).collect()` and the
   hand-written loop produce equivalent LIR (same op counts by shape
   helpers).
3. The four adapter-erasure tests (stream from iterator collect; static
   list iter append eliminates public adapters; optimized infinite custom
   iterator consumes finite prefix; dynamic static list iter append splits
   nested captures) pass.
4. Rocci Bird: the `.iter()` build's size premium over the direct-list
   build is approximately zero.

## Baseline

The branch's demand-driven sparse-private-callable machinery was dropped
when origin/main's postcheck rewrite was merged (see plan.md "Direction
Decision"); main's spec_constr is the starting point. The multi-use
control-flow sharing fact was ported forward with its regression test.
The four adapter-erasure tests may fail or crash at this baseline; they are
acceptance criteria for the fusion phases, not merge regressions. Rocci's
`.iter()` build may not compile at baseline; making it build (and play) is
Phase 1's correctness gate, owned by the new representation. Kept and
load-bearing from the existing tree: main's lambda-set machinery, loop
specialization machinery to the extent it survives on main, effect-order
gates, and the sharing fact.
