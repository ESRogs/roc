# Decision-Tree Match Compiler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-branch backtracking match chains in both LIR lowerers with one shared
Maranget-style decision-tree match compiler (`src/postcheck/match_tree.zig`), per
`projects/big/decision-tree-match-compiler.md`.

**Architecture:** A generic module `MatchTreeCompiler(comptime Ctx: type)` with two halves:
(1) pure tree construction — pattern matrix normalization, necessity-based column selection,
constructor specialization with exit-based sharing (linear statement guarantee), producing an
explicit arena-allocated tree; (2) LIR emission — continuation-style backward emission using the
host lowerer's existing primitives, with an occurrence table so each tested/destructured position
is read once per dominating scope. Both lowerers (`solved_lir_lower.zig`, `lir_lower.zig`)
instantiate the module with a thin Ctx adapter.

**Tech Stack:** Zig, comptime duck-typed generics; jj for VCS (never merge, commit-first scoping);
verification via `zig build run-test-zig-module-postcheck`, `run-test-eval` (5 executors),
`run-check-snapshots` (verify via `jj status`, not git), then full `zig build minici` piecewise.

---

## Semantics contract (from investigation)

Facts established by code reading; the tree must preserve all of these:

1. **CFG is built backward.** Statements chain via `next: CFStmtId`; lowering is
   continuation-style. `lowerMatchInto` wraps everything in a `done` join whose single param is
   the result local `target`; each branch body ends with `jump(done)`.
2. **Match-order semantics:** branches tried in source order; a guard is evaluated only after its
   branch's pattern fully matches (bindings visible to the guard); guard failure falls through to
   the *next branch in source order*.
   - **Known pre-existing hazard to fix:** `lowerStrPatternBranchGroup` sends guard-failure to the
     *group* miss join, so `match s { "a" if g => e1, "a" => e2, _ => e3 }` with `g` false gives
     `e3`, not `e2`. The chain semantics (and source-order rule) demand `e2`. Confirm on the old
     path, fix in the tree, and add a conformance test.
3. **Exhaustiveness is consumed, never re-derived.** The match node carries
   `comptime_site: ?ComptimeSiteId`. Terminal for an open match: `comptime_exhaustiveness_failed`
   (site present) or `runtime_error`. Checker-closed exhaustiveness is visible structurally: the
   committed union layout's variant set. If a tag switch's arms cover every variant of the
   scrutinee occurrence's layout, emit the last arm as the switch default (no Fail node, no
   terminal error statement). `comptime_branch_taken` markers are already inside branch bodies
   (emitted by Monotype), so body lowering preserves them for free.
4. **Monotype is a DAG; LIR re-lowers every expression reference.** Bodies and guards must each be
   lowered at most once per row-copy, and body sharing must go through join points. Guarded rows
   are never duplicated (their guard expression would be re-lowered).
5. **ZST rule:** `discriminantSwitch` returns the body directly for ZST sources; record/tuple/tag
   payload extraction is skipped for ZST field locals. Preserve (the tree's switch emission on a
   ZST occurrence degenerates to the sole arm's subtree — correctness: with a ZST scrutinee only
   one variant layout exists... follow existing behavior: `isZstLocal(source) => body`).
6. **Nominal patterns (PR 9849):** unwrap through the nominal operand:
   `nominalPatternBackingType`, fresh backing local, `assignNominalPatternBoundaryAtTypes`
   (record/tuple/tag-union boundary reorder or plain assign/box). The tree treats nominal as a
   destructuring (no-test) step with an occurrence for the backing value.
7. **Switch condition encoding:** `readSwitchValue` (interpreter) zero-extends at layout size
   (1/2/4/8); LLVM zero-extends to i64; dev compares 64-bit immediates; wasm uses per-arm equality
   tests. Int-literal multiway switch arms must encode `value = zext(bitcast-to-unsigned @ layout
   width)`. Only layouts of size ≤ 8 bytes may use `switch_stmt`; i128/Dec use equality chains;
   f32/f64 **must** keep IEEE `num_is_eq` chains (NaN/-0.0 semantics).
8. **String patterns:** `str_match_set` arms are tried in order, first match wins. `str_lit` can
   become a set arm as `{prefix=lit, steps=[], end=.exact}` **only after verifying** interpreter
   `execStrMatchArm` equivalence with `Str` equality (verify; if not equivalent, str_lit stays an
   equality-chain arm kind). Rows with the *same* string pattern must merge into ONE arm whose
   body chains those rows (guard fallthrough inside the arm).
9. **List patterns:** one `list_len` read; exact rows need `len == n`, rest rows `len >= k`;
   element extraction via `list_get_unsafe` only after the length test; back elements indexed
   `len - (fixed_count - i)`; rest slice
   `take_first(take_last(source, len - rest.index), len - fixed_count)`; `[..]`/`[.. as r]` with
   no fixed elements is irrefutable.
10. **Type/layout plumbing:** extraction helpers resolve storage types from the *actual local*
    (`storageTypeOfLocalOr`); the emitter materializes occurrence locals top-down so these
    resolutions keep happening on real locals.
11. **ARC:** join params carry exactly the values that cross the join. Miss/exit joins use empty
    params (like today). The `done` join's param is `target`. Body joins (when a leaf is
    referenced ≥ 2×) carry the row's binding locals as params.

## Algorithm (grouped Maranget with exits; linear statement bound)

### Data structures

```zig
// Occurrences: interned paths into the scrutinee. Parent + step.
const Occ = struct { parent: OccId, step: Step };
const Step = union(enum) {
    root,
    field: u16,                       // record field index (resolved per source type) & tuple item
    tag_payload: struct { variant: u16, index: u16, single: bool },
    list_elem: union(enum) { front: u32, back: u32 },
    list_rest: struct { front: u32, back: u32 },  // rest.index fixed elems before, rest after
    nominal_backing,
    // derived scalars (memoizable, unconditional relative to parent):
    discriminant,                     // u16 read of parent tag union
    list_len,                         // u64 read of parent list
    str_capture: struct { arm_row: u32, step: u16 }, // bound inside str arms only
};

// A row of the matrix.
const Row = struct {
    cols: std.ArrayList(Col),          // (occ, pat) pairs, only REFUTABLE heads after normalize
    binds: std.ArrayList(Bind),        // (occ, lifted local, ty) — assigned at the leaf
    guard: ?ExprId,
    body: ExprId,
    branch_index: u32,                 // source order
};
const Col = struct { occ: OccId, pat: PatId, ty: TypeId };
const Bind = struct { occ: OccId, local: LocalId, ty: TypeId };

// The decision tree.
const Tree = union(enum) {
    leaf: *Leaf,                                  // binds + body(branch_index)
    guard: struct { leaf: *Leaf, otherwise: *Tree },
    test_: *Test,                                 // multiway test on one occurrence
    exit: ExitId,                                 // jump to a shared continuation
    fail,                                         // open-match terminal
};
const Test = struct {
    occ: OccId, ty: TypeId,
    kind: TestKind,
    arms: []Arm,                                  // per distinct constructor
    default: Tree,                                // remaining rows / exit / fail
    exhaustive: bool,                             // arms cover the full layout: last arm is default
};
const TestKind = enum { tag, callable, int, str_set, eq_chain /*dec, f32, f64, i128, (str_lit fallback)*/, list_len };
const Arm = struct { ctor: Ctor, subtree: Tree };
```

### Normalization (matrix canonical form)

For each row, repeatedly rewrite the col list until every head is refutable:
- `bind l` → record `(occ→l)` in `binds`, drop col. `wildcard` → drop col.
- `as(p, l)` → record bind, keep expanding `p` at same occ.
- `record fields` → one col per destruct at `occ.field(indexOf(name))` (index from *source type*).
- `tuple items` → cols at `occ.field(i)`.
- `nominal inner` → col at `occ.nominal_backing`.
- Irrefutable list (`[..]`, `[.. as r]`, no fixed elems) → optional rest bind, drop col.
- Refutable heads stay: `tag`, `callable` (LambdaMono only), `int_lit`, `dec_lit`,
  `frac_f32_lit`, `frac_f64_lit`, `str_lit`, `str_pattern`, `list` (with fixed elems or no rest).

### compile(rows, ctx) → Tree

1. `rows` empty → `fail` (emission maps it to terminal error / nothing when unreachable).
2. Row 0 has no cols → `leaf` (unguarded) or `guard{leaf, otherwise: compile(rows[1..])}`.
   Rows after an unguarded leaf row in this submatrix are dead here (do not compile).
3. Pick occurrence `occ` among row 0's cols (heuristic below). Walk rows top-down collecting the
   **group**: a row joins if
   - it has a constructor col at `occ` (goes to that constructor's arm submatrix), or
   - it lacks `occ` (wildcard there) AND is unguarded AND all its remaining cols are irrefutable
     (i.e. cols empty — pure leaf) AND `binds.len <= dup_leaf_bind_limit (4)`; such a row is
     appended to **every** arm's submatrix and to the default. (Cheap-leaf duplication: bodies are
     joined, so each copy is binds + one jump.)
   - otherwise the group **breaks**: remaining rows `rows[k..]` compile once as the shared
     **continuation**, wrapped as an exit join; the switch default and exhausted arm submatrices
     `exit` to it. (Guarded-wildcard rows and rows testing other occurrences are never duplicated
     → hard linear bound.)
4. Build arms per distinct constructor among the group's ctor rows (order of first appearance):
   - **tag/callable:** arm per discriminant; arm submatrix rows get payload cols
     (`occ.tag_payload(variant, i, single)`); `exhaustive` when distinct arm discriminants ==
     layout variant count (Ctx query) → last arm becomes emission default, no Fail. `default` else
     exit/fail.
   - **int (layout ≤ 8 bytes):** arm per distinct literal (u64-encoded); default exits.
   - **dec/f32/f64/i128 (& str_lit fallback):** `eq_chain` test — arms in first-appearance order,
     emitted as equality chain sharing ONE occurrence local; semantics per-row identical to today.
   - **str (str_pattern + verified str_lit):** `str_set` — one arm per distinct pattern
     (prefix/steps/end structural key); duplicate-pattern rows merge into one arm's submatrix,
     preserving row order; arm captures become `str_capture` occs bound inside that arm.
   - **list:** `list_len` test on `occ.list_len`: arms for each distinct exact length; rows with
     rest (min k) join every exact-length arm with `len >= k` **and** the default bucket; default
     = descending `len >= k` comparison chain over distinct rest minima, then exit/fail. Arm
     submatrices get element cols (`front i` / `back j` per rest index) and rest binds.
5. Column heuristic (measure on corpus, document): score each candidate col of row 0 by
   (a) group length (rows consumed before break) — longer is better;
   (b) smaller branching factor; (c) first-listed. Compare against Maranget f/d/b on the corpus
   via statement counts; keep the winner (implement both scorers, select by constant).

### Emission

`emit(tree, ectx)` returns `CFStmtId`, built backward. `ectx` carries:
- `occ_locals: map(OccId → LocalId)` — materialized occurrence locals valid in this scope.
  Continuation joins receive a **stripped** map: keep only constructor-independent occs (root,
  discriminant, list_len, record/tuple fields whose whole parent chain is unconditional, nominal
  backing); drop tag payloads, list elems/rests (validity depended on tests that the exit escaped).
- `fail_cont: CFStmtId` (terminal error stmt, created once per match).
- leaf refcounts (computed on the tree): body emitted inline when a leaf is referenced once;
  otherwise the body is lowered ONCE into a join whose params are the row's binding LIR locals,
  and every leaf copy assigns binds then jumps.

Materialization rules:
- `discriminant` occ: `addLocalForLayout(.u16)` + `assign_ref .discriminant` immediately before
  the first switch on it in this scope; reused thereafter (map hit).
- `tag_payload`: at arm entry, extract (`.tag_payload`/`.tag_payload_struct` via
  `assignTypedRefRead`) only occs actually used in the arm subtree (collect used-occs per
  subtree); ZST extraction skipped as today.
- `field`: extracted on demand (unconditional); `list_len` via `list_len` op; `list_elem` /
  `list_rest` inside length-checked arms exactly as the current `lowerListPatternThen` sequences.
- `nominal_backing`: fresh backing local + `assignNominalPatternBoundaryAtTypes`.
- Exit continuations: `join { params: empty, body: continuation, remainder: <group emission> }` —
  same shape as today's miss joins. Guard: lower guard into bool temp,
  `boolSwitchNoContinuation(guard, leaf_body, emit(otherwise))`.
- Statement-count lint (debug): the emitter counts every CFStmt it adds (delegated body/guard/
  scrutinee statements excluded); after each match assert
  `emitted <= LINT_MULT * total_pattern_nodes + LINT_BASE` (start MULT=24, BASE=16; tighten after
  corpus measurement). Panic in debug on violation.

### Ctx interface (both lowerers already have every capability)

```zig
// IR access:            patData(PatId) -> normalized view; spans for branches/pats/destructs/str steps
// Types/layout:         patTy, scrutineeTy, storageTypeOfLocal, layoutOf, layoutByteSize, isZstLayout,
//                       tagIndex(ty,name)->u16, tagVariantCount(ty), tagPayloadTypes(ty,variant),
//                       recordFieldIndex/recordFieldTy, tupleItemTys, listElemTy, nominalBackingTy,
//                       callableVariantIndex (LambdaMono ctx only; solved ctx handles callable pats too — verify)
// Emission primitives:  addTemp, addLocalForLayout, addCFStmt wrappers: jump/join/switchStmt/boolSwitch/
//                       assignRefRead(op)/strMatch(Set)/lowLevel(list_len,list_get_unsafe,take_first,
//                       take_last,num_minus,num_is_eq,num_is_gte)/u64Lit/literalInto/eqLocalsInto/
//                       nominalBoundary/bindLocal(lifted_local, ty, source, next)/freshJoinPointId
// Delegation:           lowerBodyInto(target, body, result_ty, next), lowerGuardInto(local, guard, next),
//                       guardTy(guard), lowerComptimeSite(site)
```

Note: `solved_lir_lower` consumes Lifted patterns (no `callable` variant); `lir_lower` consumes
LambdaMono patterns (has `callable`). Verify during Task 3 how solved handles callable patterns
today (`lowerCallablePatternThen` exists in lir_lower; check solved's equivalent) and mirror.

## Tasks

### Task 1: Commit plan doc ✅(this file)

- [ ] `jj` change described; write this file; keep amending into this change via `jj squash`
      if refined later.

### Task 2: Baseline conformance corpus (green on the CURRENT chain)

**Files:** Modify `src/eval/test/eval_tests.zig` (or the file the harness includes for core
tests — follow existing structure).

- [ ] Add ~25 hand-written match cases exercising: N-branch tag matches (incl. payloads, nested
      tags), literals (int incl. negative i8/i32/i64 + u64 high-bit, dec, f32/f64 incl. -0.0 and
      NaN-adjacent comparisons if expressible, strings), records/tuples (nested, partial
      destructs), lists (exact lens, rest front/middle/back, nested list-of-tag), nominal
      records with declared order ≠ backing order (PR 9849 shape), `as` bindings visible in
      guards and bodies, guards in source order, wildcard rows *between* constructor rows,
      duplicate-string-with-guard case (semantics-defining; if it FAILS on current main, mark
      `.skip` for now with a comment, and un-skip in Task 6 when the tree fixes it — record
      finding in commit message), open matches producing crash diagnostics.
- [ ] Run: `zig build run-test-eval -- --filter <new-test-prefix>` → all pass on current chain
      (except possibly the documented str-guard case).
- [ ] Commit.

### Task 3: match_tree module — construction + unit tests

**Files:** Create `src/postcheck/match_tree.zig`; wire into `src/postcheck/mod.zig` if the
architecture check requires; tests inline in the module (picked up by
`run-test-zig-module-postcheck` — verify wiring via `run-check-test-wiring`).

- [ ] Module doc comment stating the sharing invariant (DAG duplication / join points) verbatim
      per project doc.
- [ ] Implement Occ interning, Row normalization, compile() per the algorithm above, generic over
      a minimal `TreeCtx` (IR access + type queries only — no emission).
- [ ] Unit tests with a mock ctx (hand-built tiny pattern stores):
      * N tag branches → single `test_` node, N arms, `exhaustive` set when layout count matches.
      * `A=>1; _=>2; B=>3` → one switch, arms A:{r0,r1}, B:{r1,r2}, default {r1} (cheap-leaf dup).
      * guarded wildcard row breaks group → exit node.
      * duplicate string rows merge into one arm (rows ordered).
      * list family: exact+rest bucketing; rest joins exact arms with compatible k.
      * guard: `guard{leaf, otherwise}` shape; unguarded-leaf kills lower rows in submatrix.
- [ ] `zig build run-test-zig-module-postcheck -- --test-filter match_tree` → pass. Commit.

### Task 4: Emission + solved_lir_lower integration (toggle default: chain)

**Files:** Modify `src/postcheck/match_tree.zig` (emitter), `src/postcheck/solved_lir_lower.zig`
(SolvedMatchCtx adapter + `lowerMatchInto` dispatch on toggle); toggle:
`pub var lowering_mode_for_tests: enum { chain, tree } = .chain;` in match_tree.zig (deleted in
Task 6).

- [ ] Emitter per spec (occurrence table, joins, lint counter, leaf refcounts, exhaustive-default).
- [ ] `SolvedMatchCtx` adapter using existing helpers (`addTemp`, `assignTypedRefRead`,
      `lowerEqLocalsInto`, `lowerLiteralInto`, `lowerStrPatternArm`, `discriminantSwitch`'s
      body-parts, `assignNominalPatternBoundaryAtTypes`, `bindLocalFromTyped`,
      `lowerExprIntoAtType`, ...).
- [ ] Verify str_lit ≡ str_match arm semantics in interpreter (`execStrMatchArm`); decide str_lit
      arm kind accordingly and record the finding in a comment.
- [ ] Statement-count tests via `src/compile/test/lower_to_lir_harness.zig`
      (`expectLirInspection`), with the toggle set to `.tree` in the test body (restore after):
      * N-branch tag match lowers to exactly ONE `switch_stmt` with N arms and ONE
        `.discriminant` assign_ref (count both).
      * 3/4/5-branch list-match family (PR 9707 shapes): statement counts linear — assert
        `count(5) - count(4) ≈ count(4) - count(3)` within a small tolerance AND each below a
        fixed cap (e.g. 200).
      * ARC certifier passes (harness runs it by default) for representative guard/list/string
        matches under `.tree`.
- [ ] Full postcheck+compile module tests green in BOTH toggle states:
      `zig build run-test-zig-module-postcheck && zig build run-test-zig-module-compile`. Commit.

### Task 5: lir_lower integration (toggle still chain-default)

**Files:** Modify `src/postcheck/lir_lower.zig` (LmMatchCtx adapter incl. `callable` arms),
`src/postcheck/structural_test.zig` expectations if they encode chain shapes.

- [ ] Adapter + dispatch mirroring Task 4; callable patterns → tag-like arms via
      `callableVariantIndex`.
- [ ] Check `structural_test.zig`: if it compares solved-vs-lambda-mono LIR structurally, run it
      in both toggle states. `zig build run-test-zig-module-postcheck`. Commit.

### Task 6: Differential corpus; flip default to tree; delete the chain

**Files:** Create differential test (location per harness conventions, e.g.
`src/compile/test/match_differential_test.zig` or extend the lower_to_lir harness); modify both
lowerers (DELETE `lowerBranchChain`, `strPatternBranchGroupStart`, `lowerStrPatternBranchGroup`,
chain-only helpers that become unused); delete the toggle; un-skip the str-guard test from Task 2.

- [ ] Seeded generator (fixed seeds, no wall-clock): random nesting of tags/records/tuples/lists
      (with rests)/strings/literals/guards; for each generated program: lower with chain and with
      tree, execute BOTH via the interpreter harness on generated scrutinee values, compare
      results + crash/exhaustiveness diagnostics. ~200 programs.
- [ ] Small-universe enumeration: for 2-3 small types (e.g. `[A, B(Bool), C(U8-ish small)]`,
      2-lists of Bool), enumerate all values × generated pattern sets; interpreter chain-vs-tree
      equality.
- [ ] Flip toggle default to `.tree`; run `zig build run-test-eval` (5 executors) — all green,
      including Task 2 corpus and the un-skipped str-guard test.
- [ ] Delete chain code + toggle from both lowerers; differential test now compares tree vs
      interpreter oracle only (keep generator + enumeration as engine-differential tests).
- [ ] `zig build run-test-zig-module-postcheck run-test-zig-module-compile run-test-zig-module-lir`
      green; `zig build run-test-eval` green. Commit (or two commits: flip+diff, then delete).

### Task 7: design.md invariant + docs

**Files:** Modify `design.md` (Pattern Lowering section: decision-tree description + the sharing
invariant + the lint); `projects/big/decision-tree-match-compiler.md` untouched (it's the spec).

- [ ] design.md: document (a) the DAG/join-point sharing invariant as a named invariant, (b) the
      decision-tree pattern lowering (one module, both pipelines), (c) the debug statement-count
      lint. Commit.

### Task 8: Heuristic + tag_reachability measurement; perf notes

- [ ] Measure column heuristics (group-length vs f/d/b) on the corpus via statement counts →
      pick, document in module comment.
- [ ] Measure tag_reachability on match-heavy programs at `--opt=speed`: pass time + edges
      removed, before/after tree (before = jj parent commit build). Record findings in the
      commit message + a short note in the project doc's evaluation section if warranted. Keep
      the pass.
- [ ] LIR-lowering compile-time sanity: time `run-test-zig-module-postcheck` match tests / lower
      a generated match-heavy module; assert no gross regression (>10%) vs chain (measure before
      deleting chain — do this measurement during Task 6 and record numbers here). Commit.

### Task 9: Full minici to green

- [ ] `zig build minici` once; for each failing step, iterate on ONLY that step
      (`zig build <step>`) until green; snapshot verification via `zig build snapshot` +
      `jj status` (no git). Re-run full `minici` at the end only if many parts changed.
- [ ] Review `jj log`: logically scoped commits, each described before work. Fold fixups into
      their logical commits via `jj squash`.

## Verification commands quick-reference

```
zig build run-test-zig-module-postcheck -- --test-filter match_tree   # module unit tests
zig build run-test-zig-module-compile                                  # harness statement tests
zig build run-test-eval -- --filter <prefix>                           # 5-executor conformance
zig build run-check-postcheck-architecture                             # module layering rules
zig build run-check-test-wiring                                        # new test files wired
zig build snapshot && jj status                                        # snapshot no-diff check
zig build minici                                                       # final gate (slow)
```

## Self-review notes

- Spec coverage: matrix/occurrences/tree nodes (Task 3-4), heuristics measured (Task 8), join-point
  body sharing + guard re-entry (algorithm §3/emission), checker-verdict defaults (contract §3,
  Task 4 tests), binding/guard order (contract §2, Tasks 2/6), invariant doc + lint (Tasks 4/7),
  migration order incl. flag and deletion (Tasks 4-6), tag_reachability re-measure (Task 8),
  statement-count regression tests (Task 4), differential + small-universe enumeration (Task 6),
  nominal 9849 tests (Task 2), str-group guard fix (Tasks 2/6).
- Known open verifications called out inline: str_lit≡str_match equivalence (Task 4), solved
  callable-pattern handling (Task 3/4), structural_test lockstep (Task 5), int-switch encoding on
  dev/wasm (Task 2 corpus covers negative/high-bit ints across engines).
