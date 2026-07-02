# Iterator Fusion — Phase 2 Implementation Plan

Companion to `iter_fusion_design.md` (the contract) and `plan.md` (the running
log). This document reports what the merged tree already does for a bounded
iterator pipeline, where the contract's tier-one guarantee breaks, and the
smallest ordered set of changes that delivers it. All LIR excerpts were produced
by lowering small programs through the `lir_inline_test.zig` helper
(`lowerModuleWithOptions(..., .wrappers, .{ .proc_debug_names = true })`) and
dumping every reachable proc with `lir.DebugPrint.writeProc`. The probe was
temporary and has been stripped.

## Central finding (the design question)

Most of the contract's Phase 2 mechanism already exists in the merged tree — but
in a shape and at a pipeline position that defeat the tier-one goal.

`postcheck/lambda_solved` already produces, for `[1,2,3].iter().map(|n|n*2).collect()`:

- a **defunctionalized step-capture tag union per item type** (`tag_union#30`:
  variant `v0` = list-iter state, variant `v1` = map capture
  `struct(inner_iter, transform)`) — the contract's "closed tag union of states";
- **generated first-order step functions** (`p8` = map step, `p9` = list-iter
  step) — the contract's `step_T`;
- a **generated dispatch wrapper** (`p5` = `Iter.next`, a `switch` on the step
  discriminant) — the contract's public `Iter.next`.

So the "generated step functions" and "defunctionalized sum" of Phase 2 are not
missing. Three things are wrong:

1. The union carries the **inner iterator by box, not by value** (`Iter(item)`
   is a *recursive nominal* — `step` returns `rest: Iter(item)` — so its layout
   is a heap box, `low_level box_box`). The contract wants by-value embedding
   with boxing only at dynamically-recursive occurrences.
2. The union is produced **after** `SpecConstr` runs, so the fusion pass never
   sees it (pass order below).
3. Nothing is **virtual**: every construction is materialized (boxed)
   unconditionally; there is no escape-based minting.

The fusion transformations the contract names (inline step, collapse known tags,
scalarize loop-carried state) are exactly the three things `SpecConstr`
(`postcheck/monotype_lifted/spec_constr.zig`, Peyton-Jones call-pattern
specialisation) already does, and its own module doc-comment walks
`range().map().collect()` down to a scalar loop. The pass has all three
capabilities and they pass tests on non-iterator inputs. They do **not** fire on
iterators because (a) `Iter` is a recursive nominal `SpecConstr` cannot represent
as a finite known shape, and (b) when it does try, splitting a loop-carried
callable's captures breaks a capture-identity contract with `lambda_solved` and
**panics**.

Therefore the smallest path to tier-one is **not** a new defunctionalization
subsystem. It is: repair the `SpecConstr`↔`lambda_solved` capture-identity
contract, teach `SpecConstr`'s loop-state specialization to bound the
recursive-nominal successor to a finite "same variant, advanced scalar leaves"
fixpoint, and let its existing known-value substitution consume the construction
*before* `SolvedLirLower` ever assigns the boxed layout. In that design the
contract's "escape-based variant minting" maps onto **existing** structures:
minting = `SpecConstr` declining to substitute a construction that escapes,
leaving exactly the residual `lambda_solved` union arm for the escaped case.

## Pass order (where every decision lives)

`checked_pipeline.zig::lowerCheckedModulesToLir`:

```
Monotype.Lower              (monomorphize)
Lift.run                    (lifted IR)
SpecConstr.run              (only if inline_mode != .none)  <-- fusion lives here
Lift.recomputeCaptures      (capture fixpoint)              <-- capture contract
LambdaSolved.Solve.run      (defunctionalize step closures -> tag unions, step_T)
SolvedInline.analyze
SolvedLirLower.run          (assign layouts; recursive nominal -> box_box)  <-- layout
Trmc / ScalarizeJoins / TagReachability / ReachableProcs
Arc.insert                  (refcounting, last, on final LIR)
```

Consequences confirmed by evidence:

- **Escape / virtualization hook point = `SpecConstr` (lifted IR).** The box is
  *emergent* — `iter_from_step` in `Builtin.roc` just returns `{len_if_known,
  step}`; the `box_box` is `SolvedLirLower`'s layout choice for the recursive
  nominal. `SpecConstr` runs before that, so the contract's "fusion decisions
  before internal layouts are finalized" is satisfiable. `SpecConstr` already
  has the substrate: `bindPatToReusableValue` / known-value substitution decides
  when a construction is consumed locally vs. left materialized.
- **Refcounting is downstream and iterator-free.** `Arc.insert` is last and
  `src/lir/arc.zig`, `scalarize_joins.zig`, `trmc.zig` contain zero
  iterator/stream/cursor logic (verified). Scalar loop state (list + index)
  carries no box, so scalarization *removes* the per-element `incref/decref`
  churn automatically; ARC needs no iterator awareness. The one ARC coupling is
  a hazard, not a feature: `arc_certify`'s borrow rules reject a `SpecConstr`
  rewrite that leaves a dangling call to an un-specialized capturing worker (an
  unbound capture local), so `SpecConstr` must fully specialize, not partially.

## Current-state LIR (items 1–3)

### 1. Bounded pipeline `[1,2,3].iter().map(|n|n*2).collect()` at `.wrappers`

Ten procs; the root is a chain of three un-fused calls:

```
proc p0 args=[] ret=list#18
  l8:list#18  = list(1,2,3)
  l4:box#19   = call p3(l8)        ; List.iter  -> boxed Iter
  l1:box#19   = call p2(l4, l5)    ; Iter.map   -> boxed Iter
  l0:list#18  = call p1(l2)        ; List.from_iter (collect consumer)
```

The step closure is already the defunctionalized capture union — `Iter.map`
builds tag `v1` of `tag_union#30`, whose payload embeds the inner iterator **as a
box**:

```
proc p2 name=Builtin.Iter.map
  l21:struct_#29    = struct(l22:box#19 /*inner iter*/, l23:zst /*transform*/)
  l18:tag_union#30  = tag v1 d1 (l21)
  l91:box#19        = call p6(step_union, l18)   ; iter_from_step -> box
```

`iter_from_step` is the sole allocation site and it is called at construction and
on every step rebuild:

```
proc p6 name=iter_from_step
  l131:box#19 = low_level box_box(struct(len_if_known, step))   ; HEAP ALLOC
```

Dispatch is a runtime discriminant switch even though the construction is
statically known:

```
proc p5 name=Builtin.Iter.next
  l123 = ref.field(iter_box)[1]           ; the step union
  switch ref.discriminant l123
    case 0: call p9(...)   ; list-iter step
    case 1: call p8(...)   ; map step
```

The consumer loop carries the **boxed iterator** as a loop parameter and calls
`Iter.next` indirectly each iteration; on `One` it rebuilds a fresh successor box
(`p8`→`p2`, `p9`→`p7`, each re-`box_box`):

```
proc p1 name=Builtin.List.from_iter
  join j0 params=[l19 /*box iter*/, l20 /*list*/]
    incref l70 ; l30 = call p5(l70) ; decref l70         ; per-element indirect call
    switch (One/Skip/Done)
      One: list_append_unsafe($list,item); rebuild successor box; decref l30
```

**Every tier-one property is absent here:** step not inlined (consumer → next →
step, three call levels per element, plus `p8` re-enters `p5`); the known step
tag is not collapsed; loop state is a heap box, not scalars; `box_box` runs per
element; dispatch runs per element.

### 2. The hand-written loop is *also* un-fused today

`for n in [1,2,3] { $acc = List.append($acc, n*2) }` at `.wrappers` (seven procs)
lowers through the *same* Iter machinery — `for x in list` desugars to
`List.iter` + `Iter.next`:

```
proc p0
  l41:box#29 = call p3(l44)               ; List.iter -> boxed iter
  join j0 params=[l3 /*box iter*/, l4 /*list*/]
    l5 = call p2(l39)                      ; Iter.next
    ... One: list_append; rebuild list-iter box via p5->p6 box_box
proc p6 name=iter_from_step: low_level box_box(...)   ; STILL ALLOCATES
```

This matters for acceptance criterion 2 ("equivalent LIR to the hand-written
loop"): the hand-written loop is currently a *low* bar because it, too, boxes.
The real target is the contract's stated goal — both the pipeline **and** the
`for`/`collect` consumer fuse to scalar (list + index) state. Tier-one is not
"match the hand-written loop as it lowers today"; it is "both reach the
Rust-shaped loop." So `List.iter` consumed by `for`/`collect` must itself
scalarize (its `p9`/`p4` list-iter arm is a custom-iterator arm the fusion must
inline and scalarize).

### 3. Branch-chosen iterator (tier two)

`if t>3 { list.iter().map(..) } else { list.iter().keep_if(..) }` consumed by one
loop, at `.wrappers` (eleven procs): `SpecConstr` *does* recognize the branch and
emits `comptime_branch_taken site=0 branch=0/1`, but both arms box into the same
erased iterator type and join, and one polymorphic loop drives them:

```
proc p0
  join j5 params=[l36 /*box#17 iter*/]
    case 1: comptime_branch_taken site=0 branch=0 ; l36 = call p5(map over list)
    default: comptime_branch_taken site=0 branch=1 ; l36 = call p3(keep_if over list)
  body:
    join j0 params=[l3 /*box iter*/, ...]
      l5 = call p1(l27)     ; Iter.next, per-element dispatch on the joined union
```

The branch marker and known-construction tracking exist; the loop-over-join
**split** does not. This is the tier-two substrate that partially works.

## Gap analysis (per tier-one requirement)

| Requirement | Exists | Broken | Missing |
|---|---|---|---|
| Step inlined into consumer loop | `SpecConstr` known-callable inlining + generated `step_T` (`p8`/`p9`) | Doesn't reach iterators: state is a recursive nominal `SpecConstr` won't finitely represent | Finite-successor fixpoint so the step body can be inlined into the loop |
| Known-tag collapse | `SpecConstr` collapses matches on known tags (proven on non-iterator inputs) | The step discriminant switch (`p5`) survives because construction is boxed away from the consumer | Consume the construction virtually so the discriminant is statically known at the loop |
| Loop-state scalarization | `SpecConstr` loop-state leaf-splitting (`loopBackEdgesRecoverShapeLeaves`); "opaque callable field" case passes | "direct callable captures", "returned callable captures", "no single-field wrapper" cases **fail**; carried state stays a box | Split loop-carried callable **captures** across the `SpecConstr`↔`lambda_solved` boundary |
| Zero allocation | Box is emergent, not hardcoded; eliding it is a layout consequence of scalarizing first | `box_box` runs per element because state never scalarizes | Fusion must finish before `SolvedLirLower` assigns the boxed layout |
| Zero dispatch | Static callable identity is part of a `SpecConstr` call pattern | `Iter.next` discriminant switch survives per element | Same as known-tag collapse |

Two current failures are **correctness**, not missed optimization, and gate the
work:

- `optimized infinite custom iterator consumes finite prefix` — optimized output
  diverges from naive (entry-known loop-carried state re-read from the *original*
  captured seed → `0,0,0,…`).
- `keep_if` collect **hangs** under `.wrappers` (Skip never advances; the
  back-edge resets the source iterator to its entry box). Its differential test
  is committed-commented because a hanging test cannot run.

Confirmed baseline (`run-test-zig-lir-inline` filters):

- PASS: `iterdiff: bounded list map collect agrees` / `iterdiff: if-chosen chains
  agree` (correctness floor holds), `dynamic static list iter append splits
  nested callable captures`, `spec constr splits loop record state with opaque
  callable field`, `known-length List.iter collect specializes without unbound
  locals` (crash-only gate).
- PANIC (`solved_lir_lower.zig:2313` / `lambda_mono/lower.zig:885`, "callable
  capture payload fields differed from captured locals"): `plant iter pipeline
  specializes collect worker after inlining`, `plant iter pipeline collect uses
  direct range map list loop`.
- FAIL (shape/value): `static list iter append eliminates public iter adapters`,
  `static primitive list iter append avoids direct-list append allocation`,
  `optimized infinite custom iterator consumes finite prefix`, `spec constr
  splits loop record state with {direct,returned,annotated returned} callable
  captures`, `spec constr does not require single-field record wrapper`.

## Implementation plan (ordered small slices)

Each slice: the fact it establishes / owner / focused regression / gate. Slices
map to the contract's Phase 2 (defunctionalized state + generated step + escape
minting) realized as "make `SpecConstr`'s three transformations fire on
iterators," then Phase 3 (retire the superseded path).

**Slice A — Capture-identity contract repair.**
Fact: when `SpecConstr` clones a worker or splits loop state that carries a
callable whose captures are split into leaves, the capture list surviving
`recomputeCaptures` matches, by `(symbol, binder, capture_id)`, the
`capture_record` fields `lambda_solved` builds and `solved_lir_lower` checks.
Owner: `spec_constr.zig` capture cloning + `lift.zig::recomputeCaptures`;
coordinate with the `lambda_solved` capture solve (separate worktree) — the
`solved_lir_lower.zig:2313` invariant must be *satisfied by the producer*, never
relaxed. Regression: re-activate `spec constr splits loop record state with
direct callable captures` (currently failing) plus `plant iter pipeline
specializes collect worker after inlining` (currently panicking). Gate: those
stop panicking/failing; `postcheck` 98/98; no new `lir-inline` failures.

**Slice B — Finite-successor fixpoint for recursive-nominal loop state.**
Fact: a loop whose carried state is a known constructor that rebuilds a
same-shaped successor differing only in scalar leaves specializes to scalar loop
variables whose back edge carries the *advanced* leaves, never the entry value.
Owner: `spec_constr.zig` loop-state specialization
(`loopBackEdgesRecoverShapeLeaves` + back-edge value threading). Regression:
activate `optimized infinite custom iterator consumes finite prefix`
(correctness) and re-activate the `keep_if` collect differential. Gate: infinite
custom diverge test passes; `keep_if` differential activates and terminates.

**Slice C — List.iter leaf scalarization (base custom-iterator arm).**
Fact: `for x in list` and `list.iter()…collect()` carry the list-iter state
(list + index) as scalar loop variables with `list_get_unsafe` in the loop body —
no box, no `Iter.next` call. Owner: `spec_constr.zig` (recognize the list-iter
constructor as a splittable constructor whose successor is `index+1`). Regression:
re-activate `static primitive list iter append avoids direct-list append
allocation`; add a hand-written-loop equivalence probe. Gate:
`expectRangeMapCollectUsesDirectListLoop`-style shape (0 boxes, `list_get` in
loop) for a bare `list.iter().collect()`.

**Slice D — map adapter fusion (step inline + known-tag collapse).**
Fact: `list.iter().map(f).collect()` inlines map's `step_T` into the consumer
loop, collapses the statically-known step discriminant (no `Iter.next`), applies
`f` inline, and carries scalar state — op-count-equivalent to the hand-written
loop under the shape helpers. Owner: `spec_constr.zig` known-callable inlining +
known-tag match collapse (both already present). Regression: activate the
committed-commented tier-one LIR-identity acceptance test
(`list.iter().map(f).collect()` vs hand-written loop). Gate: acceptance test 2
passes; differentials stay green.

**Slice E — Zero-allocation assertion.**
Fact: no `box_box` appears in the reachable procs of a tier-one pipeline (the
recursive-nominal layout is never instantiated because state scalarized before
`SolvedLirLower`). Owner: emergent from A–D; add a reachable-proc `box_box`-count
shape helper. Regression: new "tier-one pipeline emits zero `box_box`" test over
map-collect at `.wrappers`. Gate: count is 0.

**Slice F — Tier-two branch-join split.**
Fact: a loop over a branch-chosen iterator either splits per branch (each its own
fused loop) or consults a discriminant only at Done transitions on a shared core,
never per element on the hot path. Owner: `spec_constr.zig` branch/join handling
(`comptime_branch_taken` already emitted; add loop-over-join split). Regression:
re-activate `static list iter append eliminates public iter adapters`; add a
shape gate to the `if-chosen` differential. Gate: branch-chosen hot path has no
per-element discriminant.

Ordering rationale: A unblocks everything (it is the panic). B fixes the two
correctness divergences and is a prerequisite for any scalar loop state. C is the
minimal fused case (no adapter). D is the headline tier-one case. E pins the
zero-allocation guarantee. F is tier two and can proceed in parallel once A/B
land.

## Escape-based minting: existing structures vs. new code

- **Reuses existing structures.** "A construction consumed at compile time is
  virtual" = `SpecConstr`'s known-value substitution
  (`bindPatToReusableValue`, `valueCanSubstitute`): the constructed
  `{len_if_known, step}` record + its capture union are propagated into the
  consumer and taken apart, never materialized. "A variant is minted for a
  construction that escapes" = `SpecConstr` *declining* to substitute; the
  residual `lambda_solved` union arm (which already exists — `tag_union#30`) is
  precisely the minted variant, and `SolvedLirLower`'s boxed layout is its
  runtime representation. "The emitted union contains exactly the escaped
  variants" = an emergent property of reachability
  (`TagReachability`/`ReachableProcs`) once the virtual arms are consumed. No new
  minting subsystem is required; the union, the step functions, and the dispatch
  are already generated by `lambda_solved`.
- **Needs new code.** (1) `SpecConstr` recognizing the iterator's
  recursive-nominal successor as a *finite fixpoint* (bounded self-reference
  whose only variation is advanced scalar leaves) — this is an extension of
  loop-state specialization, but genuinely new logic, because the pass today
  freezes or declines on recursive nominals (Slice B). (2) The capture-identity
  contract that lets callable captures be split without the `lambda_solved`
  invariant firing (Slice A) — new coordination logic straddling
  `spec_constr`/`recomputeCaptures`/`lambda_solved`.

## Risks (with evidence)

1. **Highest: the `SpecConstr`↔`lambda_solved` capture-identity contract.** Every
   tier-one slice requires splitting a loop-carried callable's captures, which
   today panics `callable capture payload fields differed from captured locals`
   (`solved_lir_lower.zig:2313`) on the plant/range pipelines and fails four
   loop-split-with-callable-capture tests. The producer side spans a module
   another agent owns (`postcheck/lambda_solved`). If the capture solve cannot be
   made to agree with `SpecConstr`'s leaf-split clones, tier-one is blocked at the
   first slice. This is the single item most likely to sink the schedule and must
   be de-risked first (Slice A) with cross-worktree coordination.
2. **Recursive-nominal finiteness vs. the entry-known freeze.** Bounding the
   same-shaped successor without freezing carried slots to their entry value is
   subtle — it is the exact bug behind both current correctness divergences
   (infinite-custom `0,0,0…`; `keep_if` hang). Evidence: `plan.md` "CRITICAL
   FINDING". Getting it wrong reintroduces a hang or a wrong sequence, not just a
   missed optimization.
3. **Layout ordering.** Fusion must complete in `SpecConstr` before
   `SolvedLirLower` assigns the recursive-nominal box; any escape (join not split,
   iterator stored) must route to the boxed tier, and that tier must stay correct.
   The differential harness (`expectSameObservationsAcrossInlineModes`) is the
   guard and currently passes for the escaped cases — keep it green on every slice.
4. **ARC borrow certification.** Low-severity but real: `arc_certify` rejected an
   earlier `SpecConstr` rewrite that left a dangling call to an un-specialized
   capturing worker referencing an unbound capture local (`plan.md`, "known-length
   List.iter collect" note). `SpecConstr` must specialize fully; a partially
   specialized worker is an ARC-visible error, not a silent slowdown.
5. **Stream effect gates.** Iter and Stream share the representation, dispatch,
   and fusion pass; the effectful step forbids the pure-only licenses. Every new
   transformation must remain guarded by the existing effect gates
   (`discardedExprIsEffectFree` and friends). Reusing `SpecConstr` inherits these,
   so the risk is confined to any new step-inlining code that must not hoist or
   drop an effectful step call.

## Phase 3 on this tree ("delete the demand-driven path")

On the merged tree there is **no demand-driven path left to delete**. Option B
(the `origin/main` postcheck adoption, `plan.md` "Direction Decision") already
dropped the branch's demand machinery: the `spec_constr` six-fact demand chain,
`LocalProcContext`, and the `fn_ref_captures`/`state_continue` variants are gone.
Main's `SpecConstr` is value-based (call-pattern specialisation), not
demand-based; `plan.md` records that main has "no value-flow let route and no
`.if_`/`.match_` Value variants," so the multi-use duplication hazard the old
sharing fact guarded is structurally impossible and its port was skipped.

So Phase 3 here is **rewiring, not deletion**, and its scope is one decision about
three dormant LIR passes. `BoxReuse`, `ReturnSlot`, and `StrAppend`
(`src/lir/box_reuse.zig`, `return_slot.zig`, `str_append.zig`) survive with green
tests but are **not invoked by `checked_pipeline.zig`** (verified: no
`.run` call sites outside their own tests). They are the natural homes for
two contract concerns once fusion lands:

- `BoxReuse` — opportunistic in-place reuse of step state when uniqueness
  licenses it (contract invariant 2's "orthogonal optimization"). If Phase 2
  scalarizes tier-one state, boxes only remain in the boxed tier, where reuse is
  where the win is.
- `ReturnSlot` / `StrAppend` — consumer-side materialization
  (`collect`/`from_interpolation`) writing directly into the output buffer.

Recommendation: **keep all three dormant until a measured need appears.** Do not
wire them speculatively. The tier-one guarantee is delivered entirely in
`postcheck` (`SpecConstr` + `lambda_solved` + layout); `arc.zig`, `trmc.zig`, and
`scalarize_joins.zig` contain no iterator logic and should stay that way. Once
Slices A–F land and Rocci sizes are measured, decide per-pass whether wiring
`BoxReuse` closes a remaining boxed-tier or opportunistic-mutation gap; if it does
not, delete the dormant pass rather than carry it. "Delete the demand-driven path"
concretely means: confirm nothing re-introduces a demand substrate, and resolve
the dormant-pass wiring question with evidence — not remove code that Option B
already removed.
