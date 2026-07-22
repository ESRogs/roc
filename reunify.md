# reunify.md — Eliminating Re-Unification After Type Checking

## 1. Summary

Roc's compiler type-checks every module exactly once, in `src/check/`. That pass
runs Hindley–Milner-style type inference using a mutable union-find data
structure and a unification engine, and it ends by *proving* that the program is
well-typed. At the end of checking, the compiler freezes everything it learned
into an immutable, serializable artifact (`CheckedModuleArtifact`, including a
`CheckedTypeStore` of resolved type payloads).

The stages that run *after* checking — collectively called "postcheck", which
monomorphize the program and lower it toward the backends — do **not** simply
read those proven facts. Today they re-derive them:

- `src/postcheck/monotype/solve.zig` builds a **fresh union-find graph per
  specialization** and re-runs unification over it (dozens of unification call
  sites).
- `src/postcheck/monotype/lower.zig` re-emits constraints that checking already
  solved (dozens more).
- `src/postcheck/lambda_solved/solve.zig` is a **second, independent
  unification engine** over its own type-variable store (dozens more).

This document describes a project — "reunify" is what we are *removing* — whose
goal is:

> **After checking finalization, the compiler must never run general
> unification again.** Every downstream stage consumes frozen, immutable,
> interned type facts, instantiates polymorphic types by *substitution*, and
> answers remaining questions (numeric defaulting, static dispatch resolution,
> lambda-set membership) with *directed* queries and *directed* dataflow — never
> by merging two unknowns.

Why this matters:

1. **Correctness.** Three separate unifiers means three implementations of
   Roc's type semantics (numeric defaulting, row extension, nominal equality,
   effectfulness, static-dispatch constraints). Any semantic nuance must be
   encoded consistently in all of them, and history shows they drift. A large
   fraction of recent miscompile-class bugs trace to a divergence between what
   `check` concluded and what a postcheck solver re-concluded.
2. **Performance.** Per-specialization union-find graphs, repeated constraint
   solving, and repeated structural digests re-pay costs the checker already
   paid. Substitution over frozen schemes is a memoizable, allocation-light
   copy; interned monotypes give O(1) equality where today equality requires
   structural digests or redirect-chain resolution.
3. **Simplicity.** The instantiation-graph machinery in `monotype/solve.zig`
   (evidence refill, cross-specialization snapshots, deferred template
   sealing) exists to manage the consequences of re-solving. When downstream
   types are ground (fully concrete) from the moment they are created, most of
   that machinery becomes unnecessary and can be deleted.

The compiler already contains two subsystems that prove the target pattern
works and should be treated as the models to generalize:

- **The static-dispatch registry** (`src/check/static_dispatch_registry.zig`,
  `src/check/dispatch_evidence.zig`): dispatch decisions are computed once at
  checking publication and read verbatim downstream. Postcheck consumes them;
  it does not re-resolve them. The header of
  `src/check/canonical_type_keys.zig` states the rule explicitly: *"Post-check
  stages consume the resulting keys; they must not recompute them from source
  syntax or from environment lookup."*
- **The layout store** (`src/layout/store.zig`): layouts are structurally
  interned once (`interned_layouts`, plus recursive-graph deduplication), and
  every backend and the interpreter reads the same interned `layout.Idx`
  values with no re-derivation.

This project extends that same discipline to the type structure itself.

---

## 2. Background: the pipeline, for readers new to this codebase

Roc is a pure functional language. Its compiler (in `src/`, written in Zig) is
organized as one build module per directory, with an explicitly declared
dependency graph (`src/build/modules.zig`). The stages relevant here:

```
source text
  │  src/parse            tokenize + parse → AST
  ▼
  │  src/canonicalize     name resolution, desugaring → CIR ("canonical IR"),
  │                       stored in a ModuleEnv (one per module)
  ▼
  │  src/check            Hindley–Milner type inference over the CIR,
  │                       using src/types (union-find store + unifier).
  │                       Ends in "checking finalization", which publishes
  │                       a frozen CheckedModuleArtifact.
  ▼
  │  src/postcheck        "Cor-style" lowering pipeline, driven from
  │                       src/lir/checked_pipeline.zig:
  │                         Monotype        (monomorphization begins)
  │                         MonotypeLifted  (closure/lambda lifting)
  │                         LambdaSolved    (lambda-set solving)
  │                         (LambdaMono     Debug-only, for the differential
  │                                         test harness)
  │                         SolvedLirLower  → LIR
  ▼
  │  src/lir              low-level IR + passes (TRMC, reachability, ARC
  │                       refcount insertion, etc.)
  ▼
  │  backends             interpreter (src/eval), dev/native (src/backend/dev),
  │                       wasm, LLVM — all four consume the same LIR and are
  │                       required by the test suite to produce byte-identical
  │                       results.
```

Key vocabulary:

- **CIR**: the canonicalized IR. Expressions and patterns are nodes in a
  `NodeStore`; every expression/pattern index has an associated type variable.
- **Monomorphization / specialization**: Roc compiles polymorphic functions by
  generating a separate copy ("specialization") of each function body for each
  distinct concrete type it is used at. A polymorphic function body in the
  checked module acts as a **template**; postcheck instantiates templates on
  demand as calls to them are lowered.
- **Static dispatch**: Roc resolves method-style calls (including `where`
  -clause obligations) at compile time — there are no vtables. Checking
  records *which* function each dispatch site calls; that record is called
  dispatch evidence.
- **Lambda sets**: to compile first-class functions without universal boxing,
  the compiler computes, for each function-typed value, the set of concrete
  lambdas that can flow into it. This is what the LambdaSolved stage produces.

---

## 3. How types work during checking (`src/types` + `src/check`)

Understanding the checker's *mutable* representation explains why it must not
leak past checking.

### 3.1 The union-find store

`src/types/store.zig` implements the inference store:

- A type variable is `Var = enum(u32)` (`src/types/types.zig`).
- Each `Var` indexes a `Slot`, which is either
  - `root: DescStore.Idx` — this variable is the representative of its
    equivalence class and points at a `Descriptor`, or
  - `redirect: Var` — this variable has been unified into another class;
    follow the pointer.
- A `Descriptor` holds `content: Content` and `rank: Rank`. `Content` is a
  union: `flex` (unconstrained variable), `rigid` (user-annotation variable),
  `alias`, `structure: FlatType` (records, tag unions, functions, nominals,
  numbers…), and `err` (poison; see §3.4).
- `resolveVar` chases redirect chains to the root, with path compression
  (`resolveVarAndCompressPath`).

Equality between two checker types is **not** an integer comparison: you must
resolve both variables and compare structures. Identity is also *module-local*
— each `ModuleEnv` owns its own store, so a `Var` is meaningless outside its
module.

### 3.2 Unification

`src/check/unify.zig` implements unification as an explicit work-list machine
(`unify` → `runWorkLoop` over `WorkFrame`s) rather than native recursion, which
makes it stack-safe on deeply nested types. Merging two classes writes one
`Descriptor` and redirects the other class into it (`Store.union_`). Speculative
unification (e.g. trying a branch type against an expected type) is supported
via savepoints and a `MismatchHandling` mode that can roll back.

### 3.3 Generalization and instantiation

Roc uses rank-based generalization (`src/types/generalize.zig`): variables that
remain unconstrained at the binding level of a definition become
**generalized** ("for all" variables). When checking a *use* of a polymorphic
definition, `src/types/instantiate.zig` copies the type, replacing each
generalized variable with a fresh flex variable (memoized through a `var_map`
so shared/recursive structure is preserved).

This is the crucial concept for this project: a polymorphic type is a **scheme**
— a type body plus the list of its generalized variables. Instantiating a
scheme means substituting types for those variables. During *checking* the
substituted values are fresh unknowns (because inference hasn't finished).
During *postcheck* the substituted values are **fully concrete types** —
which is exactly why postcheck does not need a solver at all (§6).

### 3.4 Poison

When checking finds a type error, it records exactly one diagnostic and then
unifies the offending variables with `content = .err` (the
`poison_to_err` behavior in `src/check/unify.zig`). `.err` unifies with
anything, so one error doesn't cascade. Separately, canonicalization can insert
`malformed`/runtime-error nodes so the program still lowers and runs (crashing
only if the erroneous code path executes). **Consequence:** postcheck can
legitimately encounter `.err` types in programs that are allowed to lower with
user errors (`problemAllowsLoweringWithUserErrors` in
`src/compile/compile_package.zig`). Any postcheck redesign must treat an error
type as a first-class ground type, never as a failure of the machinery.

---

## 4. What checking already publishes (the part that is done right)

Checking finalization produces a `CheckedModuleArtifact`
(`src/check/checked_artifact.zig`, with ids in `src/check/checked_ids.zig`).
This is a frozen, flat, serializable, relocatable artifact — it is what the
module cache stores and what postcheck consumes. The relevant contents:

### 4.1 `CheckedTypeStore`: frozen type payloads

`CheckedTypeStore` (checked_artifact.zig) holds immutable type payloads
addressed by `CheckedTypeId = enum(u32)`. Payload forms include:

- `CheckedTypeVariable` — a *residual* variable: its optional name, its
  static-dispatch constraints (`CheckedStaticDispatchConstraint`: method name +
  function type + origin), and — critically — its defaulting evidence:
  `numeric_default_phase: ?NumericDefaultPhase` and `row_default: ?RowDefault`
  (`empty_record` / `empty_tag_union`). In other words, when checking could not
  fully ground a variable (an unsuffixed numeric literal, an open record row),
  it recorded *how that variable defaults* right in the payload.
- `CheckedRecordType` (`fields` + `ext`), `CheckedTagUnionType`
  (`tags` + `ext`), `CheckedFunctionType` (`kind` ∈ pure/effectful/unbound,
  `args`, `ret`), nominal types, builtins, etc. Variable-length data lives in
  flat side pools (`type_id_pool`, `tag_pool`) referenced by `(start, len)`
  ranges — the store is plain-old-data and serializes by blitting.

### 4.2 `CheckedTypeScheme`: frozen polymorphic schemes

```zig
pub const CheckedTypeScheme = struct {
    id: CheckedTypeSchemeId,
    key: canonical.CanonicalTypeSchemeKey,
    root: CheckedTypeId,
    gv_start: u32,   // range into type_id_pool:
    gv_len: u32,     //   the scheme's generalized variables
};
```

A scheme is exactly the "∀ vars. body" pair described in §3.3, already frozen:
`root` is the body, `generalizedVars()` are the binders. **The scheme
representation this project needs already exists.** What does not yet exist is
a *substitution-based instantiation* of it downstream (§6).

### 4.3 Canonical type keys (digests)

`src/check/canonical_type_keys.zig` computes deterministic content digests
(`CanonicalTypeKey`, aliased as `TypeDigest` in `src/check/canonical_names.zig`)
for checked types, with a defined enumeration order for "identity variables"
(`identityVarsFromVar`) so that the same type produces the same key whether it
is read from solver variables or from `CheckedTypeStore` payloads. These keys
are the specialization-cache keys and the cross-module comparison currency.

### 4.4 Per-node type coverage

Every checked expression and pattern has a type: the artifact's
`LoweringModuleView` exposes `module.exprType(expr_idx)` /
`module.patternType(pattern_idx)`, and `checked_types.rootForSourceVar(...)`
maps those to `CheckedTypeId`s. So the frozen store is not just signatures —
**the whole body of every definition is type-annotated at CheckedTypeId
granularity.** This is the property that makes substitution-based lowering
possible: a template body's every sub-expression already carries a frozen type
whose leaves are either ground or scheme-bound variables.

### 4.5 Dispatch evidence

`StaticDispatchRegistry` / dispatch evidence: built once at publication;
postcheck resolves method calls by *lookup*, not re-inference. This is the
in-repo proof that "compute at check publication, read downstream" works at
scale.

---

## 5. What postcheck does today, and where re-unification lives

The pipeline entrance is `src/lir/checked_pipeline.zig`
(`lowerCheckedModulesToLir`), which drives `src/postcheck/mod.zig`:

```
CheckedModuleSet ──► Monotype ──► MonotypeLifted ──► LambdaSolved ──► SolvedLirLower ──► LIR
                     (solve.zig +                    (solve.zig,
                      lower.zig,                      second unifier)
                      union-find
                      per spec)
```

### 5.1 Monotype: instantiation graphs and evidence refill

`src/postcheck/monotype/lower.zig` ("Checked modules to Monotype IR") walks
checked definitions and lowers them to the Monotype IR (`monotype/ast.zig`,
types in `monotype/type.zig`). When it encounters a call to a polymorphic
function, it requests a **specialization** of that template at the call's
types.

`src/postcheck/monotype/solve.zig` is the machinery that makes that work
today. Its own module doc describes the design:

> "Checked types instantiate into union-find nodes with explicit row extension
> links; constraints unify nodes order-independently; Monotypes are
> materialized views of solved nodes, refilled in place when their node gains
> evidence. Cross-specialization edges import finished Monotypes as snapshots,
> so a specialization that needs more than its requested type is a unification
> conflict rather than a silent rewrite of another specialization's final
> type."

Unpacking that:

- For each specialization, checked types are **re-instantiated into a fresh
  union-find graph** (`NodeId = enum(u32)`, "instantiation graph" /
  `InstGraph`), with `InstVariable` nodes carrying the defaulting evidence
  (`numeric_default_phase`, `row_default`) copied from the checked payloads.
- The lowering then **re-unifies**: requested types against template types,
  argument nodes against parameter nodes, row extensions against rows. There
  are dozens of unification call sites across `solve.zig` and `lower.zig`.
- Monotype outputs are **mutable views** over graph nodes (`addMonoView`,
  `monoFor`, `fillMono`, `importMono` — a cluster the file itself flags:
  *"Current mutable Monotype output points to remove during graph sealing …
  Completed Monotype views must expose only `TypeId`s and durable AST ids,
  never these graph-local ids."*) — they get "refilled in place" as evidence
  arrives, and are only sealed at the end.
- Template body requests are **deferred** to the end of the requesting
  specialization (`DeferredTemplate`), because keys are only stable once that
  specialization's types stop moving: *"Requesting at final types keeps
  specialization keys stable: two requests whose types would later converge to
  one digest must resolve to one lowered body."*
- Finished specializations are imported into other graphs as **snapshots**, so
  one graph's continued solving can't mutate another's sealed answer.

Every one of those mechanisms — refill-in-place, deferral-until-stable,
snapshot-on-import, conflict-on-over-demand — is a defense against the same
root cause: **types keep changing during lowering because lowering re-solves
them.** If specialization types were final at creation, none of these defenses
would be needed.

### 5.2 LambdaSolved: a second unifier

`src/postcheck/lambda_solved/solve.zig` ("Lambda solving over lifted Monotype
IR") assigns every local/expression/pattern in the lifted program a
`Type.TypeVarId` in a *third* type store (`lambda_solved/type.zig`) and runs
its own unification (note the `UnifyPair` normalization and
`active_unifications` cycle guard in its `Solver`). Its real job is to compute
**lambda sets** — for each function-typed value, which concrete lambdas can
flow into it — but it does so by re-walking the entire program and re-unifying
types that Monotype already made concrete, merging lambda-set information as a
side effect of type merging.

### 5.3 After LambdaSolved

`SolvedLirLower` (`src/postcheck/solved_lir_lower.zig`) emits the final
`LirStore` plus one interned `layout.Store`, bundled as `LirProgram.Result`
(`src/lir/program.zig`). From that point on the compiler is healthy: all four
backends, the interpreter, and every LIR pass read those two stores by index
with no re-derivation. **The disease is confined to the region between
checking finalization and SolvedLirLower.**

### 5.4 Why this is the bug factory

A systematic review of recent hard bugs in this area shows the recurring
shape: checking concludes X; a postcheck solver, re-deriving X from partially
re-instantiated inputs, concludes X′ ≠ X; the backends faithfully compile X′.
Because the re-derivation is spread over three engines, a fix applied to one
(say, a numeric-defaulting nuance in `check/unify.zig`) does not automatically
apply to the others. The specialization-cache keying (§4.3) also depends on
digest stability across these engines, so drift can additionally poison
caching. Every semantic feature added to the language (new numeric rules, new
row behaviors, new dispatch forms) currently costs three implementations and
three chances to disagree.

---

## 6. The core insight: postcheck never needs to unify

Unification answers the question "can these two *partially unknown* types be
made equal, and what do we learn about the unknowns if so?" That question only
arises during inference.

After checking, the situation is fundamentally different:

1. **The program is proven well-typed.** Checking already established every
   equality that matters. Postcheck is not discovering whether types match;
   they do.
2. **Specialization inputs are ground.** Lowering starts from entry points
   (roots) whose types are concrete, and proceeds call-by-call. At every call
   site, the caller's argument monotypes are fully concrete *before* the
   callee specialization is requested (deferral-until-final in today's code is
   precisely a workaround to achieve this property late; substitution achieves
   it by construction).
3. **Binding a template's variables is matching, not unification.** Given a
   frozen scheme `∀ a, b. (a, List b) -> b` and a ground request
   `(Str, List U64) -> U64`, computing `{a ↦ Str, b ↦ U64}` is a *directed
   pattern match*: one side is a term with variables (the scheme body), the
   other side is ground. A single simultaneous walk suffices. On a well-typed
   program the walk cannot fail; a mismatch is a compiler bug and must be an
   invariant failure (loud, in Debug), not a recoverable "unification error".
4. **Everything the match doesn't determine has recorded defaults.** A
   generalized variable that no ground type reaches (e.g. the element type of
   an empty list at an unconstrained use, an unsuffixed literal, an open row
   with nothing flowing in) is exactly the case checking already annotated
   with `numeric_default_phase` / `row_default` on the `CheckedTypeVariable`
   payload (§4.1). Applying a default is a directed rewrite, not a solve.
5. **Dispatch is a lookup.** Once the receiver type is ground, resolving a
   static-dispatch constraint is a registry query (§4.5) — today's evidence
   system already treats it that way; it just currently runs against types
   that are still "gaining evidence".
6. **Lambda sets are dataflow, not inference.** "Which lambdas flow into this
   function-typed value" is a forward closure over ground types — a fixpoint
   of set-unions over a join-semilattice. Set-union propagation is directed
   and monotone; it is not general unification and does not need a
   type-variable store to express (§8.6).

Therefore the target architecture is:

> **Instantiate by substitution. Default by rewrite. Dispatch by lookup.
> Propagate lambda sets by directed dataflow. Intern everything. Never
> unify.**

---

## 7. Target architecture

### 7.1 The interned monotype pool

Introduce (or refactor `src/postcheck/monotype/type.zig`'s store into) a
**hash-consed monotype pool**:

- `MonoTypeId = enum(u32)`; the pool maps structural content → unique id
  (structural interning, the same technique `src/layout/store.zig` already
  uses via `interned_layouts` and its recursive-graph handling).
- All payloads are ground: records with concrete field lists, tag unions with
  concrete tag lists, functions with concrete args/ret and finalized kind
  (`finalizedFunctionKind` already collapses `unbound` → `pure` at this
  boundary), nominals, builtins, numbers — plus an `error` monotype (§3.4) and
  the recursion handling below.
- Equal id ⟺ equal type. This replaces digest computation for intra-run
  equality; canonical digests (§4.3) remain the *serialization/cache* currency
  and can be computed once per pool entry and memoized alongside it.
- Recursive types: intern via a recursion-binder representation (a μ-style
  back-reference id assigned during a canonical pre-order walk), mirroring how
  the layout store deduplicates recursive layout graphs. Interning a recursive
  type must produce the same id regardless of which node of the cycle you
  entered from — the canonical walk (lowest entry point by deterministic
  ordering) guarantees this; reuse the layout store's approach.

### 7.2 The substitution primitive

One function replaces the instantiation-graph machinery:

```
instantiate(scheme: CheckedTypeSchemeId,
            binding: gv_index -> MonoTypeId)   // dense array, gv_len entries
    -> MonoTypeId
```

- Walk the frozen scheme body (`CheckedTypeId` graph) once; at each
  `CheckedTypeVariable` leaf that is one of the scheme's generalized vars,
  emit the bound `MonoTypeId`; at ground leaves, emit the interned translation
  of the payload; at interior nodes, intern the reconstructed structure.
- Memoize per `(scheme id, binding digest)` — the binding digest is just the
  sequence of bound `MonoTypeId` u32s hashed, since ids are canonical. Two
  requests that today "would later converge to one digest" (the
  `DeferredTemplate` comment) converge *immediately* under substitution,
  because their bindings are identical ids. **This deletes the need for
  deferred template requests.**
- Memoize the translation of ground `CheckedTypeId`s globally (they never
  change), so repeated instantiation shares work.
- Handle shared and recursive structure with a seen-map keyed by
  `CheckedTypeId`, exactly as `src/types/instantiate.zig` does with its
  `var_map` (insert before recursing to tie cycles).

### 7.3 Binding computation: the matching walk

At a call site being lowered, the callee is a scheme and each argument already
has a `MonoTypeId`. Compute the binding with a directed simultaneous walk of
(scheme parameter types, ground argument types):

- Variable on the scheme side: record `gv ↦ ground id` (first write wins; a
  second, different write is an invariant failure — checking guaranteed
  consistency).
- Constructor on both sides: require identical head (invariant failure
  otherwise) and recurse into children.
- `error` on the ground side matches anything (poison propagates; §3.4).
- Rows: because the scheme is frozen *after* checking, a row extension
  variable on the scheme side is either a generalized var (bind it to the
  ground remainder — build/intern the remainder row) or was already closed by
  checking. There is no "solving" of row equations: the ground side dictates.

Variables not reached by the walk (nothing constrains them) get their recorded
default (§4.1): `numeric_default_phase` drives the numeric-defaulting oracle
(`src/types/literal_defaulting.zig`, re-exported through the artifact as
`literal_defaulting` precisely for this consumer), `row_default` produces the
empty record/tag-union, and a plain unconstrained var with no default is
lowered to the unit-like erased placeholder the current sealing logic already
uses (see `InstVariableOrigin`: a surviving compiler-owned `placeholder` is a
bug today and remains one).

### 7.4 Dispatch and `where`-clause obligations

A `CheckedStaticDispatchConstraint` on a scheme variable (§4.1) is discharged
at binding time: the variable is now bound to a ground `MonoTypeId`, so
resolve the method via the `StaticDispatchRegistry` at that ground type,
yielding (per today's evidence rules) the callee to lower — possibly
triggering another template instantiation, recursively, through the same
substitution path. The scoping rule already encoded in `DeferredTemplate`
(`method_scope: checked.ModuleId` — the checked module whose registry scope
the specialization must use) carries over unchanged: the *lookup* is scoped;
only the machinery around it changes.

### 7.5 Cross-module and cross-specialization reuse

- Cross-module: checked artifacts are per-module, and a scheme's body can
  reference imported types. The existing import-view mechanism
  (`checked.ImportedModuleView` in `CheckedModuleSet`) already lets postcheck
  read imported `CheckedTypeStore`s; translation into the (single, per-run)
  monotype pool erases module boundaries — two structurally identical types
  from different modules intern to the same `MonoTypeId`. Canonical keys
  (§4.3) already guarantee cross-module digest agreement; interning gives the
  same property to in-memory ids.
- Cross-specialization: today, importing a finished specialization's type into
  a live graph requires snapshotting so later solving can't corrupt it. Under
  substitution there is no later solving; a specialization's types are final
  `MonoTypeId`s at creation, and "importing" one is copying a u32. The
  snapshot machinery, the "refill on evidence" views (`fillMono`,
  `importMono`, `monoFor`, `addMonoView`), and the sealed/unsealed distinction
  all disappear — which is precisely the end-state the existing comment in
  `monotype/solve.zig` asks for ("Completed Monotype views must expose only
  `TypeId`s and durable AST ids, never these graph-local ids").
- The **specialization cache** (`SpecializationCacheControl`,
  `LoadedSpecializationShard` in `monotype/lower.zig`) keys on type digests
  and stays conceptually unchanged; its keys become cheaper (digest memoized
  per interned id) and *more* stable (no dependence on solve order).

### 7.6 Lambda sets without a unifier

Reframe `lambda_solved` from "unify a third type store, merging lambda info as
types merge" to **directed lambda-set dataflow over ground monotypes**:

- Every function-*typed* value position in the lifted program (local, expr,
  pattern, join-point param, return slot — exactly the slots the current
  `Solver` tracks in `local_tys`/`expr_tys`/`pat_tys`) gets a **set variable**
  holding a set of concrete lambda ids (lambda symbol + captures shape).
- Program edges (assignment, call argument→parameter, return→call result,
  join-point jump→param, the cases the current solver walks) become **directed
  set-flow edges**: source set ⊆ destination set.
- Solve by work-list fixpoint: propagate set additions along edges until
  stable. Sets over a finite lambda universe form a join-semilattice;
  propagation is monotone; termination is guaranteed. No occurs checks, no
  redirects, no descriptors.
- The *types* at these positions are already ground `MonoTypeId`s from the
  Monotype stage; lambda solving reads them (e.g. to know a position is
  function-typed and its signature) and never modifies them.
- Higher-order flow through data (a function stored in a record field / tag
  payload and taken out elsewhere) is handled the same way the current solver
  handles it — by connecting the positions the program actually connects —
  but expressed as set edges instead of type unification. Where the current
  solver relies on unifying two *container* types to connect the function
  types inside them, the dataflow version connects the corresponding
  positions directly during its walk of the (ground-typed) program; because
  both container types are identical interned ids, the correspondence of
  positions is purely structural and needs no solving.

This is a real redesign of `lambda_solved/solve.zig` (its `Solver` today leans
on `active_unifications` cycle guards and pairwise type merging), but it is the
smaller half of the project and can land after the Monotype half (§9).

### 7.7 The enforcement invariant

When the project is done, this must be mechanically true and mechanically
enforced:

> No code reachable from `src/postcheck/` or `src/lir/` calls a unification
> entry point or allocates a type-inference variable. The only writers of type
> facts are `src/check` (before finalization) and the interned monotype pool
> (append-only, hash-consed).

The repository already has the enforcement pattern for exactly this kind of
rule: the build gates wired into CI (`run-check-postcheck-architecture` —
"check that deleted post-check APIs stay gone" — and
`run-check-type-checker-patterns`). Add a gate that fails the build if
unification/unifier symbols are imported anywhere under `src/postcheck/`
(allowing them during the migration only behind an explicit, dated allowlist
that must shrink monotonically).

---

## 8. What gets deleted, what gets added

**Deleted (end state):**

- `src/postcheck/monotype/solve.zig`'s union-find: `NodeId`, `InstGraph`, slot
  arrays, node unification, row-extension link solving, evidence refill
  (`fillMono` / `monoFor` / `importMono` / `addMonoView`), snapshot import,
  `DeferredTemplate` deferral (replaced by immediate keying), and the
  conflict-on-over-demand pathway (over-demand becomes impossible: nothing can
  demand "more than the requested type" when types don't move).
- `src/postcheck/monotype/lower.zig`'s constraint re-emission sites.
- `src/postcheck/lambda_solved/type.zig`'s `TypeVarId` store as a *unification*
  store, and `solve.zig`'s `UnifyPair` / `active_unifications` machinery.
- `InstVariable` defaulting-evidence carrying (defaults apply at binding time;
  the evidence stays where it already lives, on `CheckedTypeVariable`).

**Added:**

- The interned monotype pool with recursive-type canonicalization (§7.1),
  or a refactor of the existing Monotype `Type` store into one.
- `instantiate` (substitution) + the matching walk + binding memoization
  (§7.2–7.3).
- Default-application at binding time (§7.3) — thin glue over the existing
  oracles (`literal_defaulting`, `RowDefault`).
- Lambda-set dataflow solver (§7.6).
- The CI enforcement gate (§7.7).
- Debug-build invariant checks: matching-walk head mismatch, double-binding
  disagreement, surviving `placeholder` origins — all fatal in Debug with rich
  context (follow the interpreter's `invariantFailed` style: print the ids
  involved), compiled out in release.

**Unchanged:**

- `src/check` semantics and its finalization outputs (this project *adds
  consumers* of `CheckedTypeScheme` / `CheckedTypeVariable` evidence; it
  should need no new checked-artifact fields beyond possibly widening what
  finalization records — see risks §10.4).
- `MonotypeLifted` (closure lifting is structural, not type-solving).
- `SolvedLirLower`, LIR, layout store, ARC, backends — everything downstream
  of the seam is already re-derivation-free.
- The Debug-only LambdaMono materialization and its differential harness —
  these are the primary safety net for the migration and must stay green
  throughout.

---

## 9. Implementation plan

Work in slices; each slice lands green on the full gate suite before the next
begins. The non-negotiable verification battery for every slice:

1. Full snapshot suite (`zig build run-snapshot-tool` regenerate + diff review
   — the `TYPES`/`MONO` sections will surface any typing change immediately).
2. Multi-backend eval differential suite (`zig build run-test-eval`, and the
   LLVM variant on at least one platform) — byte-identical output across
   interpreter/dev/wasm/llvm.
3. The Lambda-Mono differential runner and its mutation check
   (`ci/lambda_mono_mutation_check.sh`) — this is the harness specifically
   built to catch body-lowering divergence, i.e. exactly the class of bug this
   migration could introduce.
4. `zig build minici` locally; full CI before merge.
5. When any serialized shape changes (monotype store, specialization shards):
   bump `CACHE_VERSION` (`src/compile/cache_config.zig`) — the comptime layout
   hash will also catch layout drift, but the manual bump documents intent.
6. Performance: compare CI benchmark runs, not local timings.

**Slice 0 — Inventory and guardrail scaffolding.**
Enumerate every unification-entry call site under `src/postcheck/` (an
automated listing checked into the gate's allowlist). Land the CI gate in
"warn/allowlist" mode. This freezes the problem's size and prevents new sites
from appearing while the migration runs.

**Slice 1 — Interned monotype pool.**
Convert the Monotype type store to hash-consed interning with recursive-type
canonicalization; give every stored type a memoized canonical digest. No
behavior change intended; specialization-cache keys must be byte-identical
before/after (add a test asserting digest stability across the refactor).

**Slice 2 — Substitution for already-ground types.**
Route the translation of *non-template* checked types (concrete definitions,
annotations, literals) through `instantiate`-style direct translation into the
pool, bypassing graph nodes. The instantiation graph still exists for template
specialization. This exercises the translation + interning machinery broadly
while the risky path stays on the old code.

**Slice 3 — Matching-walk specialization.**
Implement binding computation + memoized scheme instantiation; switch template
specialization requests to it. Keep the old graph path compiled behind a
build option for one release cycle and add a Debug differential check: for
each specialization, assert the new path's type digest equals the old path's.
Delete `DeferredTemplate` deferral once digests are proven identical (the new
keys are available immediately).

**Slice 4 — Defaulting and dispatch at binding time.**
Move numeric/row defaulting from graph-sealing to binding-time application;
discharge dispatch constraints via registry lookup at ground bindings. Delete
`InstVariable` evidence plumbing. The snapshot suite's `PROBLEMS`/`MONO`
sections and the numeral-focused eval tests are the sensitive detectors here
(numeric defaulting is historically the subtlest semantics in this area —
treat any snapshot diff as a stop-and-investigate).

**Slice 5 — Delete the instantiation graph.**
Remove the union-find, node ids, refill views, snapshots. Flip the CI gate to
enforcing for `src/postcheck/monotype/`.

**Slice 6 — Lambda-set dataflow.**
Rebuild `lambda_solved` as the directed set-propagation pass (§7.6). This is
the largest single rewrite; the Debug LambdaMono materialization + two-engine
differential runner exist precisely to validate it. Flip the CI gate to
enforcing repo-wide under `src/postcheck/`. Delete the third type store's
unification surface.

**Slice 7 — Cleanup.**
Remove the migration allowlist, the old-path build option, and any
transitional shims. Update `src/postcheck/`'s README/module docs and
`design.md` to describe the substitution architecture as the architecture.

Slices 1–4 are individually revertible and each shrinks the re-derivation
surface; the project delivers value even if paused after Slice 4 (at that
point Monotype no longer re-unifies; only lambda_solved does).

---

## 10. Risks and edge cases

**10.1 Places where re-solving currently papers over checked-type
imprecision.** The migration's Debug invariants (matching-walk mismatch,
double-binding disagreement) will *find* any spot where checking's frozen
output is less precise than what the old graph re-derived. Each such find is a
checking-finalization bug to fix at the source — that is the point of the
project — but plan for a tail of them during Slices 3–4. The differential
digest check in Slice 3 converts these from silent miscompiles into loud
diffs.

**10.2 Recursive types.** Both the matching walk and interning must tie
cycles. Use insert-before-recurse seen-maps (the technique
`src/types/instantiate.zig` and the layout store already use). Depth guards:
keep a generous hard cap with an invariant failure (the checker's own
instantiation uses a guard of 8192), since checked structures are finite by
construction.

**10.3 Poison / lowering with user errors.** Programs that lower with user
errors (§3.4) put `.err` in type positions. The pool needs a first-class
error monotype; matching treats ground `error` as matching anything; defaults
never fire on it. Snapshot fixtures with deliberate type errors (the
`fuzz_crash` corpus and error-focused snapshots) are the regression net.

**10.4 Is finalization's output complete enough?** The design assumes every
fact postcheck needs is derivable from: scheme structure + generalized-var
bindings + recorded defaults + dispatch registry. The known-risky corners to
audit early (during Slice 0):
  - exactness of `NumericDefaultPhase` coverage for every literal position
    (the exact-numeral authority `src/types/numeral.zig` is re-exported
    through the artifact for precisely this consumer — verify all its inputs
    are frozen);
  - row-extension chains frozen through multiple levels of record/tag
    extension;
  - function-kind residue (`unbound` → `finalizedFunctionKind`) in
    higher-order positions;
  - identity-variable enumeration agreement between solver-side and
    payload-side digests (`identityVarsFromVar`'s ordering contract) — the
    binding digest (§7.2) must use the same enumeration order.
  If a gap is found, the fix is to record more at finalization (extending
  `CheckedTypeStore`), never to re-derive downstream.

**10.5 Specialization-cache compatibility.** Keys must remain stable across
the migration or shards will silently cold-miss (acceptable) or — worse —
falsely hit (not acceptable; prevented by the `CACHE_VERSION` bump whenever
any keyed shape changes). The Slice 3 digest-equality check protects the
warm-hit path.

**10.6 Performance regressions.** Substitution should win (less allocation, no
solving), but two spots need watching on CI benchmarks: binding-digest
computation on very wide instantiations (memoize aggressively; digests of
interned ids are cheap), and pool contention if postcheck ever parallelizes
(the pool is single-threaded today, matching the per-module worker model; if
intra-run parallel lowering arrives later, interning needs the same
treatment layouts would — out of scope here).

**10.7 Lambda-set expressiveness.** The dataflow reformulation must reproduce
current behavior for functions flowing through data structures, join points,
and recursive bindings. The LambdaMono differential harness plus the seeded
mutation patches (`ci/lambda_mono_mutations/`) are the acceptance oracle;
extend the mutation set with lambda-set-specific mutations (drop a set edge,
merge two sets) so the harness provably detects dataflow mistakes before
Slice 6 lands.

---

## 11. Acceptance criteria

The project is done when all of the following hold:

1. **Mechanical:** the CI gate proves no unification entry point and no
   inference-variable allocation is reachable from `src/postcheck/` or
   `src/lir/`. The gate runs in `check-once` alongside the existing
   architecture gates.
2. **Structural:** `src/postcheck/monotype/solve.zig`'s union-find and
   refill/snapshot machinery no longer exist; Monotype views expose only
   durable `TypeId`s (the file's own stated end-state). `lambda_solved` has no
   type-merging surface.
3. **Behavioral:** full snapshot suite byte-stable (or every diff explicitly
   reviewed and explained); 4-backend differential suite green including LLVM;
   Lambda-Mono differential runner green; mutation checks (including the new
   lambda-set mutations) all caught.
4. **Performance:** CI benchmarks show compile-time neutral-or-better on the
   standard corpus, with the expected improvement on
   specialization-heavy inputs.
5. **Documentation:** postcheck module docs and `design.md` describe
   substitution-based instantiation as the architecture; this file's plan
   sections are superseded by that documentation.

---

## 12. Glossary

- **CIR** — canonical IR produced by `src/canonicalize`; the checker's input.
- **Checked artifact / `CheckedModuleArtifact`** — the frozen, serializable
  output of checking finalization (`src/check/checked_artifact.zig`).
- **`CheckedTypeStore` / `CheckedTypeId`** — frozen, flat store of resolved
  type payloads inside the artifact; plain-old-data, id-addressed.
- **Scheme / `CheckedTypeScheme`** — a polymorphic type: a body
  (`CheckedTypeId`) plus its generalized variables (a range in the store's
  id pool).
- **Generalized variable** — a type variable bound by a scheme's ∀; the thing
  substitution replaces.
- **Ground type / monotype** — a type containing no inference variables.
- **Instantiation** — producing a copy of a scheme's body with its generalized
  variables replaced; by fresh unknowns during inference, by ground monotypes
  during lowering.
- **Matching (directed)** — computing variable bindings by walking a
  variable-bearing term against a ground term; cannot fail on well-typed
  input.
- **Unification** — merging two possibly-unknown types, learning constraints;
  needed only during inference.
- **Specialization** — a monomorphic copy of a polymorphic function body at
  specific ground types; produced by the Monotype stage.
- **Static dispatch** — compile-time resolution of method-style calls;
  recorded at checking as evidence in the `StaticDispatchRegistry`.
- **Lambda set** — the set of concrete lambdas that can flow into a
  function-typed value; computed by the LambdaSolved stage; consumed by
  closure representation decisions.
- **Interning / hash-consing** — storing each distinct structure once and
  addressing it by id, so structural equality becomes id equality.
- **Poison / `.err`** — the error type that checking substitutes at type
  errors so diagnostics don't cascade; a first-class ground type downstream.
- **`TypeDigest` / canonical key** — deterministic content hash of a checked
  type (`src/check/canonical_type_keys.zig`); the cross-module and
  specialization-cache identity.
