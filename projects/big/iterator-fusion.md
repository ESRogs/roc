# Iterator Minting: Bounded Iterators to Zero Allocation

## Problem

Roc's `Iter(item)`/`Stream(item)` allocates once per element for any adapter
chain. `Iter(item)` is a recursive nominal — its `step` returns `rest :
Iter(item)` — so `map`'s step captures the inner iterator as a same-nominal
field, forming a layout self-edge that the compiler boxes. Measured on the
committed allocation gate (`src/eval/test/eval_iter_alloc_tests.zig`, across
interpreter / dev / wasm):

- `Iter.fold(Iter.map(Iter.exclusive_range(0, 5), |n| n + 1), 0, +)` —
  **18 heap allocations**, expected 0 (`:44-46`).
- `Iter.fold(Iter.keep_if(Iter.exclusive_range(0, 6), |n| n > 2), 0, +)` —
  **21** (`:49-51`).
- `Iter.fold(Iter.exclusive_range(0, 5), 0, +)` (base, no adapter) — **0**
  (`:39-41`; Slice 1, commit `4c391bee43`, kept the base step inline).

A `range` source's state is two integers, so none of the 18/21 are list buffers
— every one is the iterator machinery boxing a fresh successor per step. The same
box drives the `--opt=size` premium of an `.iter()` Rocci Bird build over the
direct-`List` loop.

**Scope: every bounded iterator must reach zero allocations, in every usage** —
local (`for`/`fold`/`collect`) and escaping (returned across a boundary, stored,
consumed elsewhere) alike. The sole permitted allocation is a heap box for
genuinely runtime-unbounded nesting depth (`wrap` in a runtime-count loop;
recursive descent over runtime-shaped data), which Rust also boxes
(`Box<dyn Iterator>`).

**The mechanism: per-chain minting, as the single uniform internal
representation.** Compile each statically-known chain to a distinct internal
nominal per adapter — `MapIter(item, inner, f)`, `KeepIfIter(item, inner, p)`,
… — whose `inner` names the *concrete* predecessor nominal by value
(`MapIter{inner: RangeIter, f}`), never the recursive surface `Iter`. Because the
inner is a *different* nominal, the layout self-edge never forms, so the state is
flat and there is no box. The public `Iter(item)` surface stays frozen. This is
Rust's representation (`Map<Range, F>`) reached under a frozen API — and, like
Rust, the loop-collapse is left to LLVM (see Background).

**Hard invariants (from `iter_fusion_design.md`, non-negotiable):** (1) the public
`Iter(item)`/`Stream(item)` API stays one concrete nominal — no trait/typeclass,
no chain type params on the surface — internals free; (2) purity — no eager
mutation; (3) no algebraic rewrites; (4) element order and effect traces preserved
exactly, and a user `is_eq` never licenses value substitution. Correctness is
absolute for both the representation and any optional pass — which is itself a
reason to prefer one uniform representation (minting) over two mechanisms plus a
decision boundary.

## Background: the box, and the division of labor with LLVM

The box is decided at one place. Layout runs a Tarjan SCC over the type graph
(`src/layout/store.zig:772-957`), and `shouldBoxRecursiveSlotEdge` (`:1046`) boxes
a slot edge exactly when `component_ids[parent] == component_ids[child]` (`:1061`)
— an SCC id that follows **nominal reference structure, never backing** — inserting
the box at `:1086`. Under the surface nominal, `map`'s `rest : Iter(item)` is the
same nominal as its parent, so they share a component → box. Minting makes the
inner a *distinct* nominal (`RangeIter`), so `component_ids` differ → no box. This
is why the fix must be a distinct nominal per adapter, not a smarter single layout
(see Approaches ruled out).

**What Roc must do vs. what LLVM does.** `--opt=size` and `--opt=speed` compile
through LLVM (`src/cli/cli_args.zig:432` — size is "LLVM optimized for binary
size"), including the wasm32 target Rocci uses; `--opt=dev` and the interpreter do
not.

- **The box is a Roc-IR-level `roc_alloc`, opaque to LLVM** — LLVM cannot remove
  it. So *zero allocation is minting's job* (remove the box by flattening the
  nominal), and it holds on **every** backend, including the interpreter/dev/wasm
  backends the allocation gate runs on.
- **The loop-collapse is LLVM's job** — given the flat monomorphized nominals,
  LLVM inlines each per-chain step into the consumer loop and dissolves the state
  machine into the hand-written loop, exactly as it does for Rust's iterator
  structs. On the non-optimizing backends the minted state machine is stepped
  as-is: correct and allocation-free (iterator performance there is a non-goal).

So minting alone greens the allocation gate on all backends, and minting + LLVM
gives the hand-written-loop machine code for the `--opt` builds that matter.

## Evidence

Symbols verified against the tree at HEAD.

- **Allocation gate** (`eval_iter_alloc_tests.zig`): `range map fold` 18, `range
  keep_if fold` 21, `range fold` 0. Confirmed by `zig build run-test-eval --
  --filter "iter alloc"`: 4 passed, 2 failed.
- **The box decision** (verified): SCC over the type graph
  (`store.zig:772-957`); box iff `component_ids[parent] == component_ids[child]`
  (`:1061`), keyed on nominal identity; `insertBox` at `:1086`. A distinct nominal
  inner puts parent and child in different components → no box.
- **Consumers already specialize per nominal** (the make-or-break, resolved
  YES): the specialization digest hashes nominal identity — module, `source_decl`,
  `type_name` (`monotype/type.zig:942`) — so distinct nominals get distinct `fold`
  specializations; and the where-bounded consumer shape already type-checks:
  `collect : Iter(item) -> output where [output.from_iter : ...]`
  (`Builtin.roc:2864`). The binding constraint was never consumer keying; it was
  the layout SCC (`store.zig:1061`), which only a distinct nominal breaks.
- **The construction-site erasure** (`callResultMonoType`, `monotype/lower.zig:14316`):
  a call's result type is `functionReturnType(mono_fn_ty)`, instantiated from the
  callee's *declared* signature; a nominal's backing is a pure function of
  `(declaration, args)` (`lowerNominalBackingType`, `:2126`). So `make()` returning
  `Iter(U64)` carries the declaration backing, not the concrete chain — the exact
  channel that must be built.
- **Blocker B** (`type_layout_resolver.zig:773-800`): the graph-builder layout
  cache `nominalVarMatches` keys on module/ident/args (`:786-796`), never backing —
  so two same-nominal chains with different capture sizes could collide. Minting
  closes this by construction: distinct nominals have distinct `ident_idx`, so the
  match fails (`:787`). The other layout cache is already backing-aware for
  iter/stream (`solved_lir_lower.zig:6666-6677`).
- **`--opt=size` uses LLVM** (`cli_args.zig:432`); the CLI suite builds
  `--target=wasm32 --opt=size` on the "LLVM size wasm backend".
- **Termination guard absent** (`reserveTemplateWithMonoFor`, `lower.zig:1487`):
  dedups on a digest with no ancestor lineage, so a recursively-constructed chain
  mints unbounded fresh templates — the widening cap's problem to solve.

## Solution design

Minting is the whole implementation; there is no separate "local" mechanism to
build. The pieces, ordered so each is a green checkpoint. The make-or-break is
already resolved against source (consumers specialize per nominal; the box breaks
for distinct nominals), so the first slice is an empirical de-risk of the one
unproven piece, the construction-site channel.

1. **Slice 1 — channel spike (de-risk first).** Hard-code the construction-site →
   backing channel for exactly `Iter.map` on a `RangeIter` receiver: mint and
   carry `MapIter(U64, RangeIter, F)` through `callResultMonoType`
   (`lower.zig:14316`) instead of the declaration-derived `Iter(U64)` backing.
   Gate: `range map fold` (`eval_iter_alloc_tests.zig:44`, RED) flips to 0 across
   interpreter/dev/wasm. **This one row greening is the whole approach made
   physical.** If it cannot green by the channel alone, stop and escalate (see
   Contingency).
2. **Slice 2 — surface↔internal bridge.** A one-directional coercion so a `MapIter`
   value satisfies a surface `Iter(b)` position, since the two are distinct
   non-unifying identities (`type.zig:942`) and `map : … -> Iter(b)` is frozen
   (`Builtin.roc:2800`). Invariant 1 holds; the coercion is internal. Prototype on
   the single Slice-1 case before touching consumers.
3. **Slice 3 — where-bounded consumer rewrite, `fold` first.** Move `fold`
   (`Builtin.roc:2849`) from concrete `Iter(a)` to a where-bounded generic over the
   internal-nominal family (the shape `collect` already proves, `:2864`). Confirm
   base `range fold` (already GREEN, `:39-41`) still specializes — a
   no-op-preserving checkpoint — then rewrite `next`/`for`/`collect`.
4. **Slice 4 — generalize the nominal family.** Extend the channel + minted family
   to `keep_if`/`drop_if`/`take`/`concat`. Gate: `range keep_if fold` (`:49-51`)
   flips to 0.
5. **Slice 5 — widening cap.** Add ancestor lineage to the deferred-template
   request (`reserveTemplateWithMonoFor`, `lower.zig:1487`); when a minted chain's
   backing shape matches an ancestor, collapse to the declaration backing, which
   re-creates the `Iter` self-edge → `insertBox` (`store.zig:1086`) → the one
   sanctioned box, and terminates as a fixed point. Ship a **hard depth backstop
   first** so a poorly tuned cap degrades to the box (safe), never hangs; then tighten
   the shape predicate. Gate: `wrap`/`leaves` box once per dynamic level and
   terminate; a finite-but-deep static chain does not trip the cap.
6. **Slice 6 — escaping gate.** The escaping static gates (`lir_inline_test.zig`,
   "iterator returned from a function" + passed-to-non-inlined + branch-chosen)
   reach `box_box_count == 0` once the channel carries the concrete backing across
   the `make`/`consume` boundary (the `body_uses_generated_evidence` seal/unify
   carry, `lower.zig:1448-1475`, gated by `isGeneratedOpaqueEvidenceType` `:9700`,
   enrolled for iter/stream).
7. **Slice 7 — Blocker-B guard.** Make a minted nominal's identity a function of
   its full capture types, and add a differential test with two deliberately
   different-capture chains sharing an adapter, asserting distinct layouts and
   correct values (the silent-wrong-size-store the alloc gate reads *greener* on).
8. **Slice 8 — measure Rocci.** `.iter()` vs direct-`List` `--opt=size` premium on
   CI benchmarks (no local benchmarking per standing guidance).

**Optional fusion — only if measured to help, never as a required mechanism.** A
Roc-IR-level SpecConstr pass can eliminate a *locally-visible* chain before layout,
so no nominal is minted for it. Minting + LLVM already delivers both goals for
optimized builds, so fusion earns its keep only where it produces a **measured**
`--opt=size` or build-time win over always-mint-then-LLVM — plausible only because
LLVM inlines conservatively under `-Os` and may not fully collapse a deep minted
chain. The substrate exists (`spec_constr.zig`: known-callable inlining, known-tag
collapse, loop-state leaf-splitting) but does not fire on iterators today (blocked
by a capture-identity panic, `solved_lir_lower.zig:2313`, and the recursive-nominal
successor). Do **not** build it on principle; build it only against a Rocci size
number that minting-plus-LLVM left on the table.

## What success looks like

- The `eval_iter_alloc_tests` adapter rows (`range map fold`, `range keep_if fold`)
  read 0 allocations on interpreter, dev, and wasm — the gate that reads 18/21
  today. Minting delivers this on every backend, LLVM not required.
- The escaping static gates in `lir_inline_test.zig` read `box_box_count == 0`;
  only genuinely-unbounded-depth nesting keeps a box (`wrap`/`leaves`), where Rust
  also boxes.
- Rocci Bird: the `.iter()` build's `--opt=size` premium over the direct-`List`
  build is approximately zero — minting removes the box (Roc level), LLVM collapses
  the flat struct to the loop.
- The differential harness stays green: minted output equals naive-unfused output
  on values and effect traces, including the different-capture Blocker-B case.

## How to evaluate the result

### Correctness ideal

The differential harness (`expectSameObservationsAcrossInlineModes`,
`src/eval/test/lir_inline_test.zig`) runs every pipeline both minted and
naive-unfused and requires identical values, crash-versus-no-crash, and — for
`Stream` — the full ordered effect trace against a mock host. Element order is
preserved; materialization points (Set/Dict/List construction) always execute, so
deduplication and ordering effects happen where written. No transformation may
claim a round-trip identity, and a user `is_eq` never licenses value substitution.
A list held by a live iterator must not be mutated in place: the committed guard
(`eval_iter_alloc_tests.zig`, "list held by a live iterator is not mutated in
place") asserts the pre-mutation elements are observed — inverted for allocation,
since an in-place-mutation miscompile both corrupts the view and *lowers* the alloc
count, so a green alloc number is necessary but not sufficient.

### Performance ideal

Zero heap allocation on every bounded chain, every usage, every backend — the box
confined to genuinely runtime-unbounded nesting depth, where Rust also boxes. On
`--opt` builds LLVM dissolves the flat minted state machine into the hand-written
loop (Rust's own outcome); the residual versus a hand-written mutable loop is a
constant-factor 3-way `One`/`Skip`/`Done` dispatch, never asymptotic. Measure with
the `eval_iter_alloc_tests` cross-backend counts, a reachable-proc `box_box`-count
shape helper, and the Rocci Bird `--opt=size` premium (CI benchmarks).

## Contingency — if the Slice-1 channel spike is NO

If `range map fold` cannot be greened by the channel alone, escaping (and local)
type-changing `map` cannot be zero-alloc under the frozen surface API, and the
owner faces a constraint decision: **Option A** — relax Invariant 1 (expose the
chain type-family at the surface, Rust's `impl Iterator`; delivers it with zero
technical risk, at the cost of the simple monomorphic public type); or **Option B**
— accept the box for adapter chains (the current behavior; the adapter rows stay
RED and Rocci keeps a premium, but base/local-fused/escaping-endomorphic stay
correct). Relaxing Invariant 2 (eager mutation) does not help — the box is stored
recursive data, not a stepping discipline.

## Tests to add

- **Adapter allocation rows to green:** `range map fold` (18→0, Slice 1) and
  `range keep_if fold` (21→0, Slice 4) in `eval_iter_alloc_tests.zig`, cross-backend.
- **Escaping gate:** the "iterator returned from a function" + passed-to-non-inlined
  + branch-chosen cases in `lir_inline_test.zig` read `box_box_count == 0` (Slice 6).
- **Blocker-B guard:** two different-capture chains sharing an adapter → distinct
  layouts and correct values (Slice 7).
- **Widening cap:** `wrap`/`leaves` box once per dynamic level and terminate; a
  finite-but-deep static chain does not trip the cap (Slice 5).
- **No-op consumer-rewrite checkpoint:** base `range fold` still green after `fold`
  becomes where-bounded (Slice 3).
- **Rocci Bird size probe:** the `.iter()` vs direct-`List` `--opt=size` premium as
  a tracked number, target ≈ 0.

## Approaches ruled out

Source-verified dead ends, recorded so they are not re-explored; full "why" in
`iter_fusion_design.md` "Rejected Approaches."

- **A trait/typeclass `Iterator`, or chain type params on the public type** —
  violates the frozen-API invariant. It is Rust's surface design; we recover its
  effect internally via minting instead.
- **Eager mutation** — violates purity, and is orthogonal to the box.
- **One uniform layout for `Iter(item)`** — the one-nominal, vary-only-the-backing
  form and the flat-max-union / coinductive-record forms all die at the same line:
  the layout self-edge keys on nominal identity (`store.zig:1061`), so a same-nominal
  inner always boxes regardless of backing. Only a distinct nominal per adapter
  changes which SCC the inner lands in. (flat-max-union additionally: an
  un-authorable flat `map` stage, plus Blockers B and C.)
- **Porting LSS's continuation flattening to unbox `map`** — a category error:
  `map`'s box is stored recursive *data* (the captured inner iterator, LSS's own
  `Cons`), which LSS also boxes.
- **Any proxy for the allocation goal** (a passing differential test, matching
  Rocci size, an identical draw fingerprint) — each has read green while iterators
  still allocated; only the runtime allocation count is acceptance.

## Related projects

- [Immutable Specialization Identity](immutable-specialization-identity.md) — the
  monotype specialization surface (`monotype/lower.zig`, `specialize.zig`) that the
  minting channel and per-chain consumer specialization extend; keying stability
  there de-risks minting directly.
- Root design doc (authoritative, outside `projects/`): `iter_fusion_design.md` —
  the contract (goals, invariants, the per-chain-minting representation, the
  Roc/LLVM division of labor, rejected approaches, and acceptance).
