# A Shared Cycle-Guarded Checked-Type Traversal

## Problem

`src/check/checked_traverse.zig` provides the shared cycle discipline for
checked-type graph traversals: `BoolPredicateTraversal` (memoized boolean
predicate with an active-set short-circuit), `ReserveThenFillTraversal`
(memo written before descent, back-edges get the reserved result),
`DigestTraversal` (active-path depth maps for de Bruijn back-edge
encoding), a `PendingPolicy` for pending payloads, and the shared
`checkedTypeContainsIdentityVariables` / `...Slice...` / `...Payload...`
predicates.

Adoption is thin. The plain identity-variable scans in
`src/check/checked_artifact.zig` delegate to the utility (wrappers at
`checkedTypeContainsIdentityVariables` and siblings around lines 4407-4450,
5324, 5933-6043, and the resolver's pending-tolerant wrappers around
18193-18267), but that is the only production consumer:
`ReserveThenFillTraversal` and `DigestTraversal` have no callers outside
the utility's own unit tests. Meanwhile `checked_artifact.zig` still holds
**31** ad-hoc `AutoHashMap(_, void).init` visited/active sets (**105**
across `src/check`, `src/types`, `src/postcheck`), and the
platform-relation machinery still hand-rolls the exact walks the utility's
shapes exist to own.

When each traversal hand-rolls its guard, "forgot the `put`" compiles
cleanly and only fails on recursive inputs — the failure mode behind the
`test/cli/issue9717-platform` stack overflow that motivated this project.

## Background

Checked artifacts store types in a `CheckedTypeStore`
(`src/check/checked_artifact.zig`; ids in `src/check/checked_ids.zig` as
`CheckedTypeId`). Recursive types are cyclic `CheckedTypeId` graphs, so
every traversal must memoize visited roots or track an active path. The
store's house pattern for building possibly-recursive results is
reserve-then-fill (`reserveSyntheticTypeRoot` / `fillSyntheticTypeRoot`)
with content-addressed keys computed by a shadow digest traversal that
encodes back-edges as depth indices into the active path. `design.md`'s
"Type Alias Invariant" section describes the degenerate self-referential
backing case any such traversal must tolerate.

## Evidence

- `src/check/checked_traverse.zig`: the three shapes and the shared
  predicates; six unit tests (DAG memoization, active-cycle hit, true
  branch beside a cycle, memo rehash during recursion, reserved result on
  back edge, active depth on back edge).
- No production callers of `ReserveThenFillTraversal` or
  `DigestTraversal`: grep for those names outside `checked_traverse.zig`
  finds nothing.
- Hand-owned memo plumbing still in `checked_artifact.zig`:
  - `PlatformAppRelationTypeResolver` (line ~17294) owns
    `finalizing: AutoHashMap(PlatformAppRelationFinalizeInput,
    CheckedTypeId)` and `merging: AutoHashMap(PlatformAppRelationMergeInput,
    CheckedTypeId)` (~17298-17314) with manual put/remove/errdefer
    choreography at each recursion site (~17460-17705).
  - `PlatformAppRelationTypeDigestBuilder` (line ~18355) owns
    `source_active` / `finalizing` / `merging` depth maps (~18361-18402)
    and hand-rolls `activeDepth` back-edge bookkeeping (~18490-18626).
  - The digest builder carries a hand-rolled identity-scan family with its
    own active-set guards: `sourceTypeContainsIdentityVariables` (~19416),
    `finalizeContainsIdentityVariables` (~19472),
    `mergeContainsIdentityVariables` (~19551), plus slice/record/tag
    helpers (~19406-19680) and the `typeWriteContainsIdentityVariables`
    dispatcher (~19168).
  - Empty-normalization prescans (`typeWriteIsEmptyRecord` /
    `typeWriteIsEmptyTagUnion` and the `finalizeIsEmpty*` / `mergeIsEmpty*`
    walks they call) run on fresh digest-builder instances.
- Ad-hoc visited-set counts (grep `AutoHashMap(.*void).init`): 31 in
  `checked_artifact.zig`; 105 across `src/check`, `src/types`,
  `src/postcheck` (files include `Check.zig`, `exhaustive.zig`,
  `generalize.zig`, `monotype/lower.zig`, `monotype/type.zig`,
  `monotype/solve.zig`, `monotype_lifted/lift.zig`,
  `lambda_solved/solve.zig`, `solved_lir_lower.zig`).
- No enforcement note exists: there is no CONTRIBUTING.md, and neither
  `CheckedTypeStore` nor `checked_traverse.zig` states that new
  `CheckedTypeId` traversals must go through the utility.

## Solution design

Migrate the platform-relation walks — the proof case — onto the utility's
shapes, then chip away at the remaining ad-hoc sites:

1. Migrate the resolver's clone traversal
   (`PlatformAppRelationTypeResolver`, memo maps keyed by
   `PlatformAppRelationMergeInput` / `...FinalizeInput`) onto
   `ReserveThenFillTraversal`; DELETE the hand-owned `finalizing` /
   `merging` maps and their put/remove/errdefer choreography.
2. Migrate the shadow digest hasher
   (`PlatformAppRelationTypeDigestBuilder`) onto `DigestTraversal`;
   DELETE the hand-owned depth maps and `activeDepth` bookkeeping.
3. Migrate the empty prescans and the digest builder's
   source/finalize/merge identity-scan family onto
   `BoolPredicateTraversal` (keys are the composite merge/finalize
   inputs), collapsing them onto the shared pending-tolerance policy;
   DELETE the duplicates. After this, identity-variable logic exists once
   per payload policy.
4. Opportunistic migration of the remaining ~31 `checked_artifact.zig`
   sites (and the ~105 repo-wide) as they are touched.
5. Add the enforcement note: a doc comment on `CheckedTypeStore`
   (`checked_artifact.zig`) stating that new `CheckedTypeId` traversals
   must use `checked_traverse.zig`.

Keys stay caller-defined (plain `CheckedTypeId` or composite inputs like
`PlatformAppRelationMergeInput`) so multi-input walks fit.

## What success looks like

- The platform-relation clone traversal, digest hasher, empty prescans,
  and identity scans share one traversal skeleton; their memo maps are
  owned by `checked_traverse.zig`, not by hand.
- All `containsIdentityVariables` logic in `checked_artifact.zig` exists
  exactly once (per payload policy), parameterized over
  pending-tolerance.
- `ReserveThenFillTraversal` and `DigestTraversal` have production
  callers, so a regression in either is caught by real workloads, not
  only unit tests.
- The `AutoHashMap(_, void).init` count in `checked_artifact.zig` drops
  substantially from 31 and trends down repo-wide from 105.

## How to evaluate the result

### Correctness ideal

The `test/cli/issue9717-platform` suite passes before and after each
migration step, byte-identical artifacts. A memo write that user code can
skip is unrepresentable: the resolver expresses its walk through the
utility API, which writes the memo before user code can descend.

### Performance ideal

Memoized traversal stays O(nodes + edges) with one hash probe per node.
No digest recomputation for shared subgraphs. No regression in
checked-artifact publication time on the largest test platforms
(`test/cli/issue9717-platform` and the compiler's own corpus);
scratch-map reuse (retained-capacity reset) keeps allocation churn at or
below current levels.

## Tests to add

- Keep the utility's existing unit tests green; extend them alongside the
  resolver migration with composite-key (merge/finalize input) cases.
- A stress test with deep alias/backing chains and a wide
  mutually-recursive tag-union family, run in debug mode (catches both
  stack overflow and missing-memo livelock via a step budget).
- `test/cli/issue9717-platform` stays the end-to-end guard for every
  migration step.
