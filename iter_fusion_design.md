# Iterator Design Contract

This contract governs the internal representation of `Iter`/`Stream`. The
representation is **per-chain minting**: each statically-known iterator chain
compiles to a distinct internal type (one nominal per adapter) whose inner
iterator is embedded by value, with the public `Iter(item)`/`Stream(item)` API
frozen. Zero allocation is delivered at the Roc-IR level by minting (which
removes the recursive-nominal box); the hand-written-loop machine-code shape is
delivered by LLVM for optimized builds, exactly as it is for Rust. It is the
durable agreement; implementation slices must conform to it or change it
explicitly first.

## As-built status (2026-07)

Per-chain minting is **implemented and live**, not prospective. The three pieces
this contract once listed as "must be built" all exist: the construction-site →
backing channel and the surface↔internal bridge are the `generatedIterator*`
family in `postcheck/monotype/lower.zig` (a minted nominal reuses the public
`Iter` definition for unification/error boundaries while `def.generated` — a
digest of `(kind, item, component types)` — separates its identity; see
`generatedIteratorType`, `generatedIteratorContent`), and the widening cap is the
depth backstop `max_minted_iterator_chain_depth = 16` (`generatedIteratorType`,
with the bounded structural walk `mintedIteratorChainDepth`). The adapter
zero-allocation rows in `eval_iter_alloc_tests.zig` — `range map fold`,
`keep_if`, `drop_if`, `take_first`, `drop_first`, `concat`, `append`, and the
`for`-loop-driver rows — are **green** across interpreter/dev/wasm. The Rocci
Bird `.iter()` `--opt=size` build boots and plays identically to the direct-list
build; its size premium is not yet ≈0 (fusion, the optional pass below, has not
been built), so premium-tracking remains open.

The runtime shape is a `{ len_if_known, step }` minted nominal where `step` is
the adapter's inline closure (kept inline, not erased to a boxed callable);
`Iter.next(it)` lowers to `it.step()` (`lowerGeneratedIteratorNextData`); and a
`for` over a minted chain lowers to an explicit `.loop_` whose body matches
`step()`'s `One`/`Skip`/`Done` and threads the successor `rest` as the loop's
iterator state (`lowerIteratorFor`). The step closure carries the adapter's
per-instance state as its captures; after spec_constr inlines a step, the lifted
capture operands are re-derived by `recomputeCaptures` → `operandValueForSlotId`,
which must key an operand to a slot by its declared CaptureId when the operand's
value-local carries a different one (the successor `rest` re-fed into an
inner-iterator slot) — see that function's contract. Known open edges are tracked
outside this doc: `for`-consumed carts hang on the non-optimizing `--opt=dev`
backend (a backend drive/RC issue, not the representation), and
`iter.concat(Iter.single(x))` / nested concat need the bounded-union-at-merges
representation (below) for two differently-typed minted iterators combined by
value.

## Goals and Non-Goals

Goal: **every bounded iterator compiles to zero heap allocations, in every
usage** — local (`for`/`fold`/`collect`) and escaping (returned across a
boundary, stored, consumed elsewhere) alike. Allocation must not depend on how a
bounded iterator is consumed. The single permitted allocation is a heap box for
**genuinely runtime-unbounded nesting depth** — a chain whose number of adapter
layers is a runtime value (`wrap` in a runtime-count loop; recursive descent over
runtime-shaped data). Rust boxes here too (`Box<dyn Iterator>`).

Success criterion: the zero-allocation gate green across all backends, and a
Rocci Bird `.iter()`-build `--opt=size` premium over the direct-list build of
approximately zero.

Non-goals: infinite and custom iterators must be *possible* with the same public
API; their per-step throughput need not match a hand loop's, but they allocate
nothing unless their nesting depth is genuinely runtime-unbounded. No public API
change of any kind. Iterator *performance* on the non-optimizing backends (dev,
interpreter) is not a goal — those need only correctness.

## Hard Invariants

1. `Iter(item)` and `Stream(item)` keep their exact public APIs, including
   custom/unbounded iterator construction. Internals are free to change.
2. Purity semantics are untouched: no eager mutation; steps are pure (or
   effect-checked for Stream); opportunistic in-place mutation stays an
   orthogonal optimization applied where uniqueness licenses it.
3. No algebraic rewrite rules, ever. No transformation may claim a roundtrip
   identity (e.g. build-then-iterate cancellation), skip or duplicate a user
   computation's execution, or reorder anything. Any optional fusion pass (see
   below) is limited to (a) inlining the generated step, (b) match collapse on
   statically known tags, (c) constructor specialization of loop-carried state.
4. Materialization points are consumers and always execute: constructing a
   Set/Dict/List from an iterator really runs, so semantic effects of
   construction (deduplication, ordering) happen exactly where written.
5. Element order is preserved exactly. The observable effect trace of a Stream
   pipeline is defined by unfused pull execution (per-element, innermost-first)
   and every representation must reproduce it exactly.
6. The optimizer must never use a user `is_eq` result to justify substituting one
   value for another. Only structural identity licenses value merging (CSE,
   known-value propagation).
7. Effectful steps (Stream) forbid the pure-only licenses: no dead-code
   elimination of unused effectful computation, no CSE of effectful calls, no code
   motion of effects across conditions (`discardedExprIsEffectFree` and friends).

## Why per-chain minting is the whole design (and why it is optimal)

Per-chain minting is not one option among several; it is *the* representation,
for *every* iterator — local, escaping, all of it. Four points, each detailed in
the sections below:

1. **It is the only representation that removes the box.** The box is decided at
   one line — the layout self-edge test keys on **nominal identity, not backing**
   (`store.zig:1061`) — so only a *distinct nominal per adapter* moves the inner
   iterator into a different SCC and escapes the box. No smarter single layout
   can; varying the backing under one nominal cannot change which nominal the
   inner presents (see Rejected Approaches).

2. **Minting does exactly the job LLVM cannot, and LLVM does the rest — so
   minting alone is the whole goal.** The box is a `roc_alloc`, opaque to LLVM, so
   zero allocation must be won at the Roc-IR level — which minting does, on every
   backend. The *loop-collapse* is LLVM's job, and `--opt=size`/`--opt=speed`
   (Rocci's path, including wasm32) go through LLVM, which dissolves the flat
   monomorphized state machine into the hand-written loop exactly as it does for
   Rust's `Map`/`Filter`. So minting delivers zero-alloc, minting + LLVM delivers
   the hand-written-loop machine code, and no second mechanism is needed. This is
   Rust's own architecture — always materialize the iterator struct, let LLVM
   dissolve it — reached under a frozen surface API.

3. **One uniform representation is the *smaller* correctness surface.** Everything
   in this compiler must be perfectly correct, and minting is held to that bar
   regardless — so "the machinery is new or large" is no reason to confine it. Two
   representations plus a decide-which procedure is more to keep correct than one,
   and a rarely-taken second path hides bugs; one representation exercised on every
   chain surfaces them. Correctness-first argues *for* always-mint, not against it.

4. **Any additional analysis must therefore beat minting-plus-LLVM on a measured
   number, or it is pure cost.** Because LLVM already collapses the minted
   representation to the loop, a Roc-level fusion pass that eliminates a local
   chain produces *equivalent machine code* on `--opt` builds — so it buys nothing
   for the binary and costs build time plus a second correctness surface. Fusion is
   therefore an *optional*, measurement-justified optimization (plausible only under
   `--opt=size`'s conservative inlining), never part of the representation.

## Internal Representation: per-chain minting

The surface `Iter(item)` is a seed+step pair (frozen). Internally, each
statically-known chain is a distinct **minted nominal per adapter**:

- Base sources — `RangeIter{start, end}`, `ListIter{list, index}`; a custom
  source captures a finite `seed`. These are the leaves and are already flat
  (base `range fold` is zero-alloc today, `eval_iter_alloc_tests.zig:39-41`).
- Adapters — `MapIter(item, inner, f)`, `KeepIfIter(item, inner, p)`,
  `ConcatIter(first, second)`, … where `inner` names the **concrete predecessor
  nominal by value** (`MapIter{inner: RangeIter, f}`), never the recursive
  surface `Iter`. Adapter closure arguments become capture-struct fields via the
  already-solved lambda sets. A minted nominal's identity is a function of its
  full capture types, so two chains with layout-relevant capture differences are
  distinct nominals with distinct layouts.

Because each adapter's `inner` is a *different* nominal, parent and child fall in
different strongly-connected components, so the layout self-edge test —
`shouldBoxRecursiveSlotEdge` (`layout/store.zig:1046`), which boxes only when
`component_ids[parent] == component_ids[child]` (`:1061`, a Tarjan-SCC id keyed on
nominal reference structure, never on backing) — does not fire, and the inner
embeds flat, by value. This is the uniform representation for every iterator;
Stream shares it (effectfulness is a checker property with no codegen footprint).

## Consumers, and the division of labor with LLVM

Consumers (`next`, `fold`, `for`, `collect`) are where-bounded generics over the
internal-nominal family — the shape `collect : Iter(item) -> output where
[output.from_iter : Iter(item) -> output]` already type-checks (`Builtin.roc:2864`).
Each specializes per concrete chain nominal — a distinct compiled `fold` for a
`MapIter` chain vs a `KeepIfIter` chain — because the specialization digest keys
on nominal identity (`monotype/type.zig:942`, hashing module / `source_decl` /
`type_name`) and dispatch keys on owner. Each nominal's step is generated from a
small per-adapter template; custom iterators call the user's step lambda through
its lambda set.

**What Roc must do and what LLVM does (the load-bearing fact).** `--opt=size` and
`--opt=speed` compile through LLVM (`cli_args.zig:432` — size is "LLVM optimized
for binary size"), including the wasm32 target Rocci Bird uses; `--opt=dev` and
the interpreter do not.

- **The box is a Roc-IR-level fact LLVM cannot remove**: it is a `roc_alloc`
  call, opaque to LLVM. So *zero allocation is minting's job* — removing the box
  by giving each chain a flat nominal — and it holds on **every** backend,
  including the interpreter/dev/wasm backends the allocation gate runs on.
- **The loop-collapse is LLVM's job**: given the flat monomorphized nominals,
  LLVM inlines each per-chain step into the consumer loop and dissolves the state
  machine into the hand-written loop — exactly as it does for Rust's `Map`/`Filter`
  structs, since Rust uses the same optimizer. This happens for `--opt` builds; on
  the non-optimizing backends the minted state machine is stepped as-is, which is
  correct and allocation-free (performance there is a non-goal).

So minting alone delivers the zero-allocation goal on all backends, and minting +
LLVM delivers the hand-written-loop machine code for the optimized builds that
matter. This is Rust's architecture (always materialize the iterator struct; let
LLVM dissolve it), reached under a frozen surface API.

## The box: the widening cap

Every chain is minted. A runtime-unbounded construction — `wrap = |it,n| if n==0
it else wrap(map(it,f), n-1)` — mints a strictly deeper nominal per level, which
would never terminate specialization (`reserveTemplateWithMonoFor`,
`monotype/lower.zig:1487`, dedups on a digest with no ancestor lineage). An
**ancestor-widening cap** detects same-shape growth against a chain's own lineage
and collapses that occurrence to the *declaration* backing — the plain recursive
`Iter(item)`. Because the layout self-edge is keyed on the name-fixed nominal,
collapsing to the declaration backing re-creates the `Iter` self-edge →
`insertBox` (`store.zig:1086`) → the one sanctioned allocation, and past the cap
the deepest type is a fixed point so specialization terminates. The cap's collapse
*is* the box; run in reverse it is the very mechanism that keeps bounded chains
flat, and it gives genuinely unbounded chains Rust's own `Box<dyn>` outcome. A
too-eager cap boxes a legitimate bounded chain (a safe degradation), a too-lax cap
hangs the compiler, so it ships with a hard depth backstop before its shape
predicate is tightened.

## Optional fusion — must earn its keep by measurement

A Roc-IR-level fusion pass (SpecConstr: inline the step, collapse known tags,
scalarize loop state — Invariant 3) can eliminate a *locally-visible* chain
before layout, so no nominal is minted for it. This is **not required** and is
**not** part of the representation: minting + LLVM already delivers both goals for
optimized builds. Fusion is justified only where it produces a **measured** binary
or build-time win over always-mint-then-LLVM. The one plausible case is
`--opt=size`, where LLVM inlines conservatively and may not fully collapse a deep
minted chain, leaving call overhead a Roc-level pre-collapse would remove — but
that is true of Rust under `-Os` too, and it is decided by measuring Rocci, not by
reasoning about which chains "deserve" fusion. Absent a measured win, fusion is
pure build-time cost plus a second correctness surface, and is not added.

## Rejected Approaches (and why)

Explored and ruled out; recorded so they are not re-proposed. Each rejection is
source-verified — the runtime allocation count is the only acceptance evidence.

1. **A trait/typeclass `Iterator`, or chain type parameters on the public type
   (`Map<Range, F>` as the surface type).** Violates Invariant 1. This is how Rust
   gets a zero-alloc escaping `map` — `impl Iterator` monomorphizes to a concrete
   `Map<…>` — so Rust's result is a *consequence* of the surface type-family the
   invariant forbids. We recover it internally (per-chain minting), never at the
   API.

2. **Eager mutation (Rust's `&mut self` stepping).** Violates Invariant 2, and is
   orthogonal to the allocation problem (the box is stored recursive *data*, not a
   stepping discipline).

3. **One uniform layout for every `Iter(item)`** — any design that keeps a
   *single* internal layout unable to tell chains apart. This includes the
   one-nominal, vary-only-the-backing form ("Form A") and the
   flat-max-union / coinductive-record forms. All are foreclosed at the same line:
   the layout self-edge test keys on **nominal identity**, not backing
   (`store.zig:1061`), so a `map` whose inner is the same surface `Iter` nominal is
   always a self-edge → box, no matter how the backing varies. A materialized
   `Iter(b)` from `map : Iter(a),(a->b)->Iter(b)` cannot name its `a ≠ b` inner by
   value under one nominal. (flat-max-union additionally: a type-changing `map` is
   not authorable as a flat stage — an `Iter(a)` body does not unify with the
   declared `Iter(b)` return; its args-only layout key `type_layout_resolver.zig:786`
   is a silent-miscompile hazard, Blocker B; and its stage-slot budget is
   unenforceable under the unbounded frozen API, Blocker C.) The fix is not one
   smarter layout — it is a *distinct nominal per adapter* (per-chain minting),
   which is the only thing that changes which SCC the inner lands in.

4. **Porting LSS's `handler-simple` continuation flattening to unbox `map`.** A
   category error, verified against the LSS reference. LSS flattens recursion that
   sits behind a function *return* (a continuation); `map`'s box is recursion
   stored as a captured *data field* (the inner iterator) — LSS's own linked-list
   `Cons` / `roc-issue-5464` shape, which LSS *boxes*, even for a bounded chain.

5. **Any proxy for the allocation goal.** A passing differential test proves fused
   output equals naive output (a correctness floor), not zero allocation; a
   matching Rocci size or an identical draw fingerprint proves neither. Each has
   read "green" while iterators still allocated (`range map fold` = 18 with the
   differential passing). Only the runtime allocation count is acceptance.

## The three pieces minting required (all built)

The representation was verified feasible (consumers *do* specialize per concrete
nominal — `type.zig:942`, `Builtin.roc` `collect` where-bound — and the box breaks
at `store.zig:1061` for distinct nominals) and all three enabling pieces now
exist:

- **The construction-site → backing channel** — a minted nominal is substituted
  as a builtin iterator call's result monotype in the `generatedIterator*` family
  (`monotype/lower.zig`): `generatedIteratorType` mints/deduplicates a per-chain
  nominal keyed on `generatedIteratorDigest(kind, item, components)`, and
  `generatedIteratorContent`/`generatedIteratorBackingType` build its `{len, step}`
  backing with the recursive `rest` rewritten from the public `Iter` to the minted
  self-type. Without this a nominal's backing would be a pure function of
  `(declaration, args)` and `make()` returning `Iter(U64)` would carry the
  declaration's backing, not the concrete chain.
- **The surface↔internal bridge** — the minted nominal reuses the public `Iter`
  definition (so it satisfies a surface `Iter(b)` position for unification and
  error boundaries) while `def.generated` separates its layout identity from the
  public recursive `Iter` and from sibling chains. Invariant 1 holds; the split is
  entirely internal.
- **The widening cap** (above) — the `max_minted_iterator_chain_depth = 16`
  backstop.

The de-risking spike is long past: the `range map fold` row and every other
adapter row in `eval_iter_alloc_tests.zig` are green at 0 allocations, and the
Rocci `.iter()` build boots and plays.

## Acceptance

**Core (delivered by minting):**

1. Differential harness: every pipeline runs both the minted output and the naive
   unfused lowering and requires identical results — values, crash-versus-no-crash,
   and for Stream the full ordered effect trace against a mock host. Mandatory
   cases include Set/Dict materialization mid-pipeline with a deliberately coarse
   custom `is_eq` and representative-distinguishing observers, plus two
   deliberately different-capture chains sharing an adapter (asserting distinct
   layouts and correct values — the Blocker-B guard).
2. Zero-allocation gate: the adapter rows in `eval_iter_alloc_tests.zig`
   (`range map fold`, `range keep_if fold`) read zero allocations across
   interpreter/dev/wasm, alongside the base row.
3. Escaping gate: a bounded chain returned across a boundary and consumed
   elsewhere reads `box_box_count == 0` (`lir_inline_test.zig`, "iterator returned
   from a function" and its passed-to-non-inlined and branch-chosen variants); only
   genuinely runtime-unbounded nesting depth boxes.
4. Rocci Bird: the `.iter()` build's `--opt=size` premium over the direct-list
   build is approximately zero (minting removes the box; LLVM collapses the loop).

**Optional fusion (only if built, and only if measured to help):** tier-one LIR
identity (`list.iter().map(f).collect()` LIR equivalent to the hand-written loop)
and the adapter-erasure tests are acceptance for the *fusion pass*, gating nothing
in the core.

## Baseline

Per-chain minting is the delivered representation. Base `range fold` is zero-alloc
(Slice 1, commit `4c391bee43`, kept the base step inline) and the adapter rows are
green — the RED gate was closed as minting landed. The demand-driven
sparse-private-callable machinery was dropped when origin/main's postcheck rewrite
was merged; main's spec_constr survives as the substrate for the *optional* fusion
pass, and its inline-then-recompute-captures path is where the `for`-driver capture
join (`operandValueForSlotId`) must route each step's successor `rest`. Rocci's
`.iter()` build compiles, boots, and plays at zero adapter allocation; the
remaining size premium over the direct-list build is the fusion pass's target, not
the representation's.
