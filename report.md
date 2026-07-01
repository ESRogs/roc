# Roc WASM-4, Rocci Bird, and Optimized Callable-State Lowering Report

## Current State At This Checkpoint

This report was written after stopping implementation on request.

Current branch:

```text
wasm-changes
```

Most recent implementation checkpoint before this report:

```text
ac8c4bda0e Fix demanded loop entry state shape
```

The tracked working tree was clean before adding this file. `plan.md` is
intentionally ignored locally and was not committed with this report.

The current active compiler regression is:

```sh
zig build run-test-zig-lir-inline -- --test-filter "imported iterator producer keeps finite step callables"
```

Immediately before this report, that regression no longer failed at loop entry
state selection. It now fails later with:

```text
postcheck invariant violated: sparse private callable was missing a demanded capture
```

That is the correct next invariant to investigate. It means optimized lowering
has reached a private callable call under result demand, has derived that the
callable body needs a particular capture, and then found that the sparse private
callable state does not carry that capture. The intended fix is not to
materialize the callable, not to infer a missing capture at the call site, and
not to force a source-specific inline path. The intended fix is an explicit
producer-owned fact: a demanded callable capture can be supplied by active loop
state.

## Executive Summary

The original task was narrow: make a current local build of Rocci Bird work,
then build it with size optimization and understand why the resulting WASM-4
module was much larger than an older compiler output. That exposed several
layers of compiler and platform work.

The platform side showed that Roc and the WASM-4 host were wasting space by
emitting large active zero-filled data segments for memory that WASM-4 already
requires to be zeroed at startup. The long-term design there is that the
platform explicitly declares the memory import contract, including whether the
imported memory is zero-filled, while the Roc compiler remains target-generic
and only consumes that explicit contract. The compiler should not know what
WASM-4 is, and the WASM-4 platform should not know about Rocci Bird. The memory
contract should be general enough for any WASM platform with imported memory.

The binary-size investigation showed that Binaryen's `wasm-opt` is the normal
tooling used by small WASM-4 projects to get tight output. Roc cannot search
the user's `PATH`, so the long-term design is to bundle a library integration
for Binaryen in the Roc toolchain, alongside the already-bundled LLVM/lld
tooling, and call it as a library in optimized WASM builds. A separate
roc-bootstrap change was opened and merged to make Binaryen available. A later
Roc build was verified against the published bootstrap artifact for both glibc
and musl, and the ReleaseFast `roc` binary size increase for the custom
Binaryen integration was measured at roughly the expected order of magnitude
for this feature.

The application side showed that Rocci Bird could be made to run again, but
that the size gap against a Rust port remained large. A Rust port was built and
optimized with Rust's normal release settings plus Binaryen. That gave a
baseline for what a small WASM-4 game can look like when iterators and state
machines lower well. Rocci Bird in Roc improved substantially, but it still
carried more code than the Rust version. The remaining gap was no longer
explained by obvious host exports, debug symbols, or the original giant zero
segment. The largest design issue moved into Roc's optimized lowering of
iterator/callable state.

A number of smaller compiler and app improvements were made along the way:
snake_case cleanup in Rocci Bird, `Flags` as an opaque-style record-backed U32
API instead of a list of flag values, use of bulk memory ops in WASM codegen,
host wrapper export cleanup, builtin additions such as `minus_saturated`, and
replacement of local Rocci Bird helper functions with builtins where
appropriate. Some of those changes are useful independent wins, but they do
not close the remaining Rust-size gap.

The current central compiler project is optimized callable-state lowering. The
long-term ideal is Rust-like generated code for `Iter`, `Stream`, and similar
callable-state values, without adopting Rust's public type-system design.
Rust gets tight iterators by making each adapter chain a distinct
monomorphized static type. Roc must keep `Iter(item)` and `Stream(item)` as
ordinary concrete public Roc types whose `step` or `step!` fields are ordinary
Roc lambdas. The optimizer should use existing lambda-set data, captures,
known values, exact consumer demand, and loop fixed-point demand to
defunctionalize reachable callable/capture graphs into private cursor state in
`--opt=size` and `--opt=speed` builds.

The most important lesson so far is that this work must be producer-driven.
Every optimization must consume explicit data produced by an earlier compiler
stage or by an earlier step of optimized lowering. Late cleanup passes,
source-shape rewrites, "just inline it", recursive expansion, materialization
as recovery, and call-site guessing all lead to fragile hacks. The correct
design is to represent the needed compiler facts directly:

- exact demand on values and continuations
- known producer structure
- sparse private state by checked child identity
- finite callable alternatives with per-alternative capture demand
- loop-demand graph nodes for recursion
- public-boundary demand when ordinary public values are required
- loop-supplied callable captures as explicit private-state data

The current implementation has already had several failed partial attempts
deleted. The most recent verified change fixed one concrete invariant: loop
entry state identity and loop entry value splitting now come from the same
demanded private representation. That moved the focused regression to the next
expected invariant: missing demanded callable capture. The next real work
should implement loop-supplied callable captures explicitly and prove it with a
focused regression before broadening back to Rocci Bird.

## Project Goals

### User-Visible Goal

The visible goal is to build Rocci Bird locally with the current Roc compiler,
using size optimization, and get a valid WASM-4 game binary whose size is in
the same broad range as comparable hand-tuned WASM-4 projects.

That includes:

- a normal clone of the Rocci Bird repository
- a current local Roc compiler build
- a WASM-4 platform build that follows WASM-4's memory rules
- a `--opt=size` or equivalent size-focused Roc build
- Binaryen optimization for optimized WASM outputs
- a working local WASM-4 server so the game can be manually tested
- a clear binary-size comparison against the old Rocci Bird WASM and against a
  Rust port

### Platform Goal

The WASM-4 platform should follow WASM-4's rules in a general way. It should
not contain any Rocci Bird-specific choices. Rocci Bird should not pass special
memory settings to its platform. The default WASM-4 platform configuration
should be correct for normal WASM-4 games.

The platform should express target facts that are true for the platform:

- whether linear memory is imported or defined by the module
- when memory is imported, which host module/name pair is used
- whether startup memory is known to be zero-filled
- what memory size limits or initial pages are required

The platform should not encode compiler-specific cleanup hacks, and the Roc
compiler should not know what WASM-4 is.

### Compiler Goal

The Roc compiler should stay generic. It should not have WASM-4-specific
branches, Rocci Bird-specific branches, source-name recognition, or backend
heuristics for one game.

Compiler work should be based on explicit facts:

- platform memory contract facts
- checked and monomorphized value facts
- exact demand facts
- explicit layout/runtime encoding decisions
- explicit LIR statements, including ARC statements

The compiler should not recover information late by scanning source-like
syntax, emitted LIR, symbol names, disassembly, or target bytes.

### Optimized Iterator/Callable-State Goal

The long-term ideal for Roc iterators and streams is:

- `Iter(item)` remains an ordinary public Roc type.
- `Stream(item)` remains an ordinary public Roc type.
- The public step result stays `One`, `Skip`, or `Done`.
- There is no public or private `Append` step variant.
- Adapters such as `.map`, `.append`, `.filter`, `.concat`, ranges, and custom
  iterators remain ordinary Roc functions.
- Step fields remain ordinary Roc lambdas.
- The optimizer uses lambda-set data, captures, known values, and demand to
  lower consuming hot paths to private cursor state.
- In optimized builds, iterator and stream pipelines should lower like Rust's
  monomorphized iterator state machines in the cases where Roc has enough
  finite callable data.
- In non-optimized builds, ordinary public-value lowering should remain the
  path. The optimized demand graph machinery should not be constructed.

The target generated shape is:

- no heap allocation for adapter wrappers in consuming hot paths
- direct stepping where possible
- sparse carried state containing only demanded children
- finite callable alternatives represented directly, not erased to runtime
  callable wrappers
- recursive loop-carried demand represented by graph nodes, not by infinitely
  expanding structural trees
- ordinary scope-closed LIR before ARC and backend codegen

### Hoisting and Static Data Goal

A related but separate compiler goal was identified during the Rocci Bird
investigation: every eligible top-level value, and hoisted top-level-equivalent
value, should be evaluated at compile time. Values whose final results are
reachable should be emitted into the static section of the binary. This should
include top-level sprites and derived sprites that depend only on compile-time
known values.

The ideal behavior is:

- all modules are considered, not only the root module
- top-level values are evaluated even if unreachable, so compile-time crashes,
  `dbg`, and `expect` behavior can be reported correctly
- only reachable evaluated values need to be stored in the final binary
- structural type shape, nominal/opaque wrappers, and similar source-level
  categories should not decide hoisting eligibility
- expressions with unresolved or erroneous subexpressions are not hoisted only
  for those erroneous expressions, not for the whole program
- effectful functions disqualify the containing expression from compile-time
  evaluation
- `crash`, `dbg`, and `expect` are not reasons to avoid compile-time
  evaluation; if they are reached during compile-time evaluation, their
  observable behavior should happen at compile time

This work matters for Rocci Bird because sprite sheets and sprite records
should not be recreated in update bodies or allocated on the heap at runtime
when they are compile-time constants.

## Non-Negotiable Constraints

The constraints below have become more important than the specific binary-size
number.

### Long-Term Ideal Only

The user repeatedly clarified that the project should always aim directly at
the long-term ideal. Temporary shortcuts, fallbacks, staged hacks, and "good
enough for now" designs are not acceptable.

That means:

- do not add a source-specific optimization because Rocci Bird happens to need
  it
- do not add an iterator-specific special case if the correct design is a
  general callable-state optimization
- do not add a wasm-specific branch if the correct design is an explicit
  platform memory contract
- do not add a cleanup pass if the correct design is to produce the right data
  earlier
- do not keep old and new paths alive unless both are permanent public paths
  described by the design

### No Workarounds, Fallbacks, Or Heuristics In Compiler Stages

The local project instructions explicitly forbid workarounds, fallbacks, and
heuristics in compiler stages outside parsing/error reporting.

For this work, that means:

- no hardcoded local ids
- no hardcoded symbols or names
- no builtin-name recognition to make one pipeline lower well
- no late LIR cleanup that guesses what an earlier stage meant
- no materialization fallback for sparse private state
- no recursive direct-call expansion as a substitute for loop-demand graph
  nodes
- no browser-based bug hunting as primary proof
- no disassembly-derived recognition rules

### Producer-Owned Facts

Every consumer must read explicit data from the producer that owns the fact.
Examples:

- the platform owns the imported-memory contract
- checking/solving owns lambda-set and inline-wrapper facts
- optimized lowering owns demand graphs and sparse private state
- ARC owns explicit reference-count statements
- backends lower what LIR and ARC tell them

If a later consumer finds itself trying to recover missing information, the
producer is incomplete.

### Public Shape Is Not An Optimization Knob

Roc public APIs should not be bent to make the optimizer easier. This came up
several times:

- `Iter` must not gain a public `Append` step variant.
- `Iter` must not become a Rust-style trait/interface.
- `Iter` must not expose adapter-chain identity in the public type.
- `Flags` in Rocci Bird should have a clean Roc API, not a shape selected only
  for codegen.
- Rocci Bird should use normal platform defaults, not special memory config.

Optimized lowering can use private representations, but the public Roc program
must remain ordinary Roc.

## WASM-4 Memory Work

### Original Observation

Rocci Bird's current optimized WASM was much larger than the older binary. One
obvious culprit was a giant active zero-filled data segment. That meant the
module was paying many kilobytes to explicitly initialize memory bytes to zero.

For WASM-4 this looked wrong because WASM linear memory starts zeroed, and
WASM-4 supplies/imports memory according to its own host contract. If the host
guarantees zero-filled startup memory, encoding a huge all-zero data segment is
wasteful.

### Design Question

The important design question was where the knowledge belongs:

- Is zero-filled memory a WASM-4 host fact?
- Is it a Roc compiler fact?
- Should the compiler post-process all-zero segments?
- Should the platform say something explicit?
- Does WASM itself define zero initialization?

The conclusion was that the platform should state the memory contract
explicitly, and the compiler should consume it generically.

### Import Memory Is A WASM Concept

Importing linear memory is an ordinary WebAssembly feature. A module can define
its own memory or import it from the host. With the common single-memory model,
there is one linear memory for the module. Multi-memory exists in real life,
but it is still uncommon in practice and not the typical shape for WASM-4.

The design can still leave room for multiple memories later, but the current
platform work should not over-engineer around a rare case. The important point
is that "import memory" is a general WASM concept, not a WASM-4-only idea.

### Zeroed Versus Uninitialized

The user questioned why zero-filled memory had to be a fact at all. The
specific answer is that static storage whose initial value is zero relies on
zero initialization. If the compiler assumes zero-initialized memory but the
host actually provides arbitrary bytes, then static zero values can be wrong.

Concrete examples include:

- a static integer value with initial value `0`
- a static pointer or nullable field represented as zero
- static aggregate fields omitted from active data because they are zero
- runtime state that expects BSS-like memory semantics

If the memory is known zeroed, the compiler can omit active data segments that
only write zeros. If memory is not known zeroed, omitting those segments would
be a correctness bug.

This is why the "zeroed" fact should exist. It is not an optimization for
Rocci Bird; it is a correctness contract between the module and the host.

### Chosen Shape

The design moved toward an enum-like memory import contract instead of a
separate boolean:

```text
import_memory = Zeroed | Uninitialized | No
```

Conceptually:

- `No`: the module defines memory itself
- `Zeroed`: memory is imported and startup bytes are known zero-filled
- `Uninitialized`: memory is imported but the compiler cannot assume bytes are
  zero-filled

The platform can then say what the host provides. The compiler can use that
contract without knowing what WASM-4 is.

### Removing The Memset

There had been a startup `memset` or equivalent zeroing path. Once the memory
contract says startup memory is zero-filled, that memset is unnecessary. It
only duplicates work and can add code size. The user asked to remove it, and
that is the right direction.

If a platform chooses `Uninitialized`, then it must either explicitly initialize
what it needs or accept that static zero assumptions are invalid. The compiler
should not silently guess.

### Post-Link Cleanup Concern

There was concern that doing both up-front memory configuration and a post-link
cleanup pass for all-zero data segments sounded like layered hacks.

The design distinction is:

- the platform contract is the source of truth
- the compiler/linker path may still produce active zero segments because LLVM
  and wasm-ld do not necessarily know Roc's higher-level memory contract in
  the exact way we need
- a generic post-link rewrite can remove active all-zero data segments only
  when the explicit memory contract says startup memory is zero-filled

That cleanup is still less ideal than avoiding the segments at the producer,
but it is generic and contract-driven. Later, Binaryen becomes the more normal
place to perform this kind of WASM cleanup and optimization. The important
line is that cleanup cannot be based on "this is WASM-4" or "this is Rocci
Bird"; it must be based on the explicit zero-filled startup memory contract.

## Binaryen Integration

### Why Binaryen Came Up

Looking at other WASM-4 projects showed that small WASM binaries commonly use
Binaryen's `wasm-opt` to shrink and clean up output. Rust projects and WASM-4
examples are not hand-writing custom post-link zero-segment rewrites. They use
normal WASM optimization tooling.

This explained part of why the old or Rust WASM outputs were smaller. LLVM/lld
alone are not the whole optimized WASM toolchain story.

### No PATH Lookup

The user was explicit: Roc will not search the user's `PATH` for tools. That
rules out shelling out to a user-installed `wasm-opt`. The only acceptable
design is for Roc to bundle the relevant dependency and call it in a controlled
way.

That means:

- do not invoke `wasm-opt` from `PATH`
- do not make builds depend on the user's machine having Binaryen installed
- do not add ad hoc external process behavior
- integrate the Binaryen library version through the Roc bootstrap/toolchain
  path

### Library Integration

The direction chosen was to add Binaryen to `roc-bootstrap` alongside LLVM.
This keeps the dependency controlled and reproducible. The custom build avoids
parts that Roc does not need and keeps the integration focused on the Binaryen
library functionality needed by optimized WASM builds.

There was discussion about C++ standard library dependencies and musl. The key
point is that Roc already has a serious native dependency story because it
builds and bundles LLVM/lld. Binaryen is another C++ project, but that is not a
new category of problem. The right comparison is not "does Binaryen have a C++
build"; it is "can our controlled bootstrap build produce a working Roc binary
for the targets we ship."

The custom Binaryen build was verified as the relevant artifact, not upstream
`libbinaryen.a` in isolation. The custom build was the thing that mattered.

### Size Cost

The useful measurement was a ReleaseFast `roc` binary with and without the
custom Binaryen integration. The expected size increase was roughly around
10 MB for the final optimized compiler binary. That is significant but not out
of line for adding a WASM optimizer library to a compiler that already bundles
LLVM/lld.

The user was clear that measuring a non-working binary is irrelevant. The
measurement only matters if the resulting compiler builds and works. The custom
build did work in the verification path.

### Binaryen Optimization Levels

The relevant Binaryen optimization modes discussed were:

- `-O4`: aggressive optimization for performance and code simplification
- `-Os`: size optimization
- `-Oz`: more aggressive size optimization

For Roc's `--opt=size` or `--opt=small` WASM outputs, the expected Binaryen
setting is the size-focused one, typically `-Oz`. ReleaseSmall platform builds
and Roc size builds should use the size-focused Binaryen pass selection.

### Producer Sections

`--strip-producers` removes the custom "producers" metadata section from a
WASM module. That metadata records toolchain information such as languages and
tool versions. It is useful for diagnostics but not needed to run a WASM-4
game. Stripping it saves bytes and avoids exposing build metadata.

## Rocci Bird Application Work

### Repository And Build

The Rocci Bird repository was cloned normally, not shallowly, into:

```text
~/code/roc-wasm4
```

The compiler work happened in the Roc worktree:

```text
/home/rtfeldman/code/worktrees/roc/vivid-canyon/roc
```

Rocci Bird was built against the current local compiler after building the
compiler as needed.

### Regression Capture

Early on, the user asked to add a regression test for the current compiler
instead of minimizing the whole Rocci Bird setup. The goal was to capture the
exact failing code and platform situation so the bug could be investigated
later. That established an important pattern: before minimizing or refactoring,
capture the real failure in a reproducible test.

### Snake Case

The Rocci Bird `.roc` file was converted from camelCase to snake_case and run
through `roc fmt`. The generated temporary name `rocci-bird-snake` was just an
intermediate artifact from that conversion, not a design concept.

### Game Behavior Bug

An optimized Rocci Bird build initially showed an immediate "Game Over" after
clicking. The symptom was that the bird immediately entered the hit-a-pipe
animation and transitioned to game over.

The important diagnosis constraint was that this looked like an application
logic or compiler optimization issue around collision detection, not an exotic
WASM-4 host bug. The user specifically pointed to the collision calculation.

A dev build on another port worked while the optimized build did not, which
strongly suggested an optimization/codegen issue rather than app logic alone.
Disassembly comparison was used to track that down. A later compiler fix made
the optimized build work again.

### Bulk Memory Ops

One concrete compiler-side change that survived was to use WASM bulk memory
operations where appropriate, rather than byte-by-byte aggregate copying in
generated code. This was kept because it is the right long-term codegen shape,
not a Rocci Bird-specific hack.

The user later clarified not to force this everywhere beyond freestanding or
where LLVM would choose it. The direction became to keep the logic outside
vendored wrapper code when possible, so updating vendored code would not lose
Roc-specific build intent.

### Host Wrapper Exports

The disassembly showed unused host wrappers being exported. The user correctly
challenged this: host-provided functions that are merely exposed to the Roc app
do not need to be exported from the WASM module. Only functions that WASM-4
will call need to be exports. Hosted functions should be eligible for ordinary
section garbage collection if the app does not use them.

This is an example of a fast size win that is also semantically cleaner.

### Flags Refactor

Rocci Bird originally represented draw flags as a list. The user asked to make
flags a record-backed opaque-style value over a `U32`, with APIs such as:

```roc
Flags.default().flip_x().flip_y()
```

The correct Roc syntax constraints were clarified during implementation:

- use `::`, not `:=`
- backing shape should be `{ bits : U32 }`, not a bare `U32`
- `@Flags` is not valid Roc syntax in the current language
- destructuring should use `|{ bits }|`
- use `bits.bitwise_or(2)` style calls

This change reduced overhead and made the app code cleaner.

### Builtins

The user asked to add builtins for helpers Rocci Bird had locally:

- `minus_saturated` on number types, corresponding to the existing saturating
  subtraction behavior such as `sub_saturating_u64`
- `List.append_if_ok`, replacing the local Rocci Bird `append_if_ok`

The goal was to remove app-specific helper code and make the standard library
or builtins provide the general operation.

### Numeric Formatting

Numeric formatting was investigated as one of the code-size culprits. There was
discussion around manually fixing one case in the app while tracking the
compiler issue separately. A GitHub issue was opened for the broader compiler
bug when the observed behavior looked like a compiler optimization problem.

### Collision Points And `.iter()`

Rocci Bird's collision-point code became a central microbenchmark. The version
without `.iter()` was much smaller than the version with `.iter()`, even after
other fixes. Removing `.iter()` saved several kilobytes in optimized output.

The user wanted the list-style version restored because long-term hoisting and
iterator lowering should make it optimize well. That is the right design
stance: the app should not have to inline a hand-written boolean chain or
manually avoid iterator APIs to get reasonable code.

The current compiler work is largely about making that expectation true.

## Rust Port And Size Comparison

### Purpose Of The Rust Port

The Rust port was created to answer a simple question: how small does this kind
of WASM-4 game get with another mature compiler stack and normal WASM
optimization?

The Rust version was built using Rust's optimizations and then Binaryen. It was
served locally on a different port from the Roc version so both could be tested
side by side.

### What Rust Shows

Rust's iterator optimization gives a useful target shape:

- iterator adapter chains are static types
- each adapter's state is stored directly
- `next` is usually inlined into a tight loop
- no heap allocation is needed for adapter wrappers
- closure captures become ordinary fields in the iterator state
- the optimizer can eliminate intermediate wrappers aggressively

Roc should not copy Rust's public typing model. Rust's `Iterator` is a trait
and adapter chains are represented in the type system. Roc's `Iter(item)` must
remain one concrete public type.

The relevant lesson is not "make Roc's type system like Rust." The lesson is
"make Roc's optimized private lowering reach the same generated-code shape."

### Why Roc Is Bigger Today

After the obvious WASM and platform issues were fixed, the remaining size gap
appeared to come from:

- iterator/callable adapter state not fully erased into private cursor state
- public wrapper records and callables surviving too long
- sparse demanded state missing some facts and falling back to less optimal
  paths or crashing on invariants
- allocation and refcounting around list/iterator state
- helper bodies and generic iterator support being retained
- closure/callable capture handling not yet equivalent to Rust's direct fields

The current work in `spec_constr.zig` is trying to fix that at the correct
level: optimized post-check lowering of callable-state values under exact
demand.

## Hoisting And Static Data

### Original Sprite Question

Rocci Bird had comments saying sprite data regenerated every frame due to a
compiler bug. The user questioned whether that was still true. The expectation
was that top-level sprite sheets and derived sprites should be compile-time
constants in static data.

The investigation showed that the compiler was far from the ideal:

- not every module was being handled
- top-level-equivalent expressions were not consistently evaluated
- static data emission was incomplete
- some constants were still being reconstructed or stored through runtime paths

### Correct Hoisting Design

The user clarified the desired design:

- every eligible top-level value in every module should be evaluated at compile
  time
- top-level-equivalent hoisted values should also be evaluated at compile time
- `crash`, `dbg`, and `expect` must run at compile time if reached
- effectful function calls disqualify the containing expression
- unreachable top-level values should still be evaluated for diagnostics and
  observable compile-time behavior
- only reachable evaluated values need to be emitted into the binary's static
  section

This avoids needing later dead-code elimination for static constants while
still ensuring compile-time behavior is checked.

### Effectfulness Bug

A soundness issue was investigated around effect propagation and static
dispatch. The key shape was a function with an ability member that could be
effectful depending on the resolved implementation.

The diagnosis was that effectfulness could not be treated as a purely syntactic
property without considering resolved dispatch/type information. The compiler
needs to propagate effectfulness through the actual resolved call graph,
including ability dispatch. If an ability implementation is effectful, generic
code that calls that ability method must be considered effectful for that
instantiation.

The user and agent discussed efficient invalidation/propagation. Union-find was
considered but not identified as the core solution. The more relevant shape is
a dependency graph between functions/ability dispatch slots/effect summaries,
with invalidation when a callee's effect summary changes. This should be
efficient enough for `roc check` because checking already walks expression
nodes.

### Hoisting Root Selection

The original hoisting code had multiple bad ideas:

- separate competing ideas of root eligibility
- multiple walks
- not hoisting crashes
- treating standalone leaves as not worth roots
- treating observable `dbg`/`expect`/`crash` behavior as a reason not to hoist
- confusing effectful functions with observable compile-time behavior

The long-term design should have a single source of truth and a single pass
where possible. During checking, the compiler already traverses expressions
and computes effect information. That traversal can also compute compile-time
evaluation candidates and parent/child relationships. Later, after effect
summaries are known, candidates that contain effectful calls can be rejected.

The important distinction is:

- an expression with unresolved/erroneous subexpressions should not be hoisted
  if those errors affect that expression
- errors elsewhere in the program must not globally disable hoisting

The compiler's broader design goal is to keep doing as much work as possible
in the presence of unrelated errors.

### Static Storage And Reachability

The ideal end state is:

- evaluate all eligible top-level/comptime expressions for all modules
- store all evaluated results in `ConstStore`
- emit only reachable static values into the final binary
- ensure reachable static values include their full data in static sections
- ensure derived static values share underlying byte data where appropriate
- ensure runtime code does not rebuild static records/lists every frame

For Rocci Bird specifically:

- sprite sheets should be static byte lists
- sprite records should be static records
- `Sprite.sub_or_crash(...)` results that depend only on static inputs should
  be evaluated at compile time
- those derived sprites should point to shared static byte data instead of
  copying it or rebuilding it

### Current Status Of Hoisting Work

There was a branch with hoisting fixes that was merged into this branch during
the broader work. After follow-up fixes, the optimized Rocci Bird build looked
good again in the browser. However, the iterator/callable-state work remains
separate and incomplete.

The hoisting design and plan were rewritten several times as the user pushed
for the real long-term ideal. `plan.md` is now local/ignored. `design.md`
contains the long-term design direction that should be treated as the durable
reference.

## Iterator Representation Experiments

### The `Append` Variant Experiment

At one point, an experiment changed the iterator step result shape by adding an
`Append` variant. The idea was that `.append()` could become faster if the step
result directly represented "before iterator plus appended item" or similar
state.

This was rejected. The user made it explicit that every `Iter` should have the
same public three-variant shape:

```roc
One(...)
Skip(...)
Done
```

There should be no public or private `Append` step variant in Roc source.

The deeper lesson was that changing public API shape to make the optimizer
easier is the wrong direction. `Iter` is a builtin, so the compiler may give
it a better private lowering, but the public-facing API should remain pure Roc
functions and ordinary lambdas.

### Rust Comparison

Rust does not have this problem because it does not erase every iterator chain
to one concrete runtime type. The adapter chain is part of the static type.
That allows inlining and scalar replacement to see concrete fields and produce
tight loops.

Roc intentionally does erase adapter identity from the public type:

```roc
Iter(item)
```

The way Roc can recover the optimized shape is through lambda sets. The step
field is an ordinary lambda. Lambda-set solving already tracks finite callable
alternatives and captures. Optimized lowering should use that existing
compiler data to defunctionalize the iterator state privately.

### Current Public Shape

The design now explicitly keeps the origin/main style public shape:

```roc
Iter(item) :: {
    len_if_known : [Known(U64), Unknown],
    step : () -> [One({ item : item, rest : Iter(item) }), Skip({ rest : Iter(item) }), Done],
}

Stream(item) :: {
    len_if_known : [Known(U64), Unknown],
    step! : () => [One({ item : item, rest : Stream(item) }), Skip({ rest : Stream(item) }), Done],
}
```

No iterator-specific plan IR, source-form rewrite, or public API change should
be introduced.

## Optimized Callable-State Lowering Design

### Why This Exists

Roc iterators and streams are ordinary records containing ordinary callables.
If lowering materializes those records and callables literally, then a loop
such as:

```roc
for point in iter {
    ...
}
```

can carry a public `Iter` value, call a public step closure, allocate wrapper
state, rebuild rest iterators, refcount intermediate values, and retain helper
bodies. That is correct but not competitive with Rust-like optimized iterator
code.

The optimizer should instead lower under exact demand. If the loop only needs
the step callable result, then lowering should ask the producer for that
callable and the demanded captures/results directly. It should not build the
whole public `Iter` record and then later remove it.

### Mode Gate

This optimizer runs only in optimized code-generation modes:

- `--opt=size`
- `--opt=speed`

It should not run during:

- `roc check`
- compile-time evaluation
- dev builds
- interpreter preparation
- non-optimized lowering

This matters because optimized callable-state lowering builds demand graphs,
sparse private-state tables, loop fixed-point data, and worker queues. Those
data structures should not exist in modes that do not request optimized code.

### Core Data Concepts

The current implementation vocabulary includes:

- `ValueDemand`: what a consumer observes
- `KnownValue`: producer structure known to optimized lowering
- `DemandedKnownValue`: sparse demanded producer shape
- `PrivateStateValue`: optimized-only private state, not a public Roc value
- `PrivateStateCallable`: callable private state with demanded captures
- `LoopPattern`: ordinary loop specialization state
- `SparseStateLoopPattern`: optimized loop state with sparse demanded values
- `LoopLocalProvenance`: where a generated split local came from
- `DemandPathStep`: checked child identity path from a loop parameter

The design intent is that `DemandedKnownValue` describes the state product and
`PrivateStateValue` describes the values used while cloning bodies. LIR should
not contain these concepts; LIR should only see ordinary scope-closed
statements and values.

### Producer-Under-Demand

The key rule is:

```text
clone producers under exact consumer demand
```

For example, if code demands only `point.x`, then the producer should be cloned
under a record-field demand for `x`. If code demands a callable call result,
then demand should reach the callable result and the captures needed by the
callee body under that result.

This avoids materializing public values that are immediately deconstructed.

### Sparse Private State

Private state is sparse. A missing child means "not carried." A present
unknown child means "carried as a runtime leaf." This is essential because
callable captures, tuple items, tag payloads, and record fields can be demanded
independently.

Dense public shapes cannot represent:

- capture 2 present and capture 0 absent
- tag choice present but payload absent
- only record field `x` carried
- only one tuple item carried

Private state should be converted back to public values only at explicit
public observation boundaries.

### Finite Callable Alternatives

Lambda sets give finite callable alternatives. Different alternatives can have
different capture counts and capture indexes. Therefore capture demand cannot
be represented as one merged positional vector and applied to every
alternative.

The verified invariant is:

```text
callable capture demand must be keyed by the specific finite alternative being lowered
```

This fixed an earlier crash:

```text
callable demand capture index exceeded lifted function capture count
```

The related tests included:

```sh
zig build run-test-zig-lir-inline -- --test-filter "direct range map collect uses direct list loop"
zig build run-test-zig-lir-inline -- --test-filter "plant iter pipeline collect uses direct range map list loop"
zig build run-test-zig-lir-inline -- --test-filter "known-length List.iter collect specializes without unbound locals"
```

Those tests proved per-alternative capture demand and some generated-scope
closure cases. They did not prove the later loop-supplied capture invariant.

### Loop Demand Graphs

Iterator rest values are recursive. A step closure can return a `rest` iterator
that is structurally similar to the current loop-carried iterator. If optimized
lowering expands that structurally each time, it can grow forever:

```text
iter -> step -> rest -> step -> rest -> ...
```

The correct representation is a loop-demand graph node. Demand can point back
to a loop parameter by graph identity rather than expanding an infinite tree.

This is why recursive direct-call expansion is not acceptable. The recursion
must be represented explicitly in the demand graph.

### Public Boundaries

Sparse private state is not a public Roc value. Some boundaries require public
values:

- non-inlined direct calls
- hosted calls
- backend-visible runtime calls
- ordinary public callable materialization
- stored constants and final LIR

If a loop-carried value has both internal optimized uses and public observation
uses, the producer must know that before splitting it. Public materialization
must not attempt to reverse-engineer a full public value from sparse private
state after the fact.

This invariant was exposed by one failed path where the compiler moved past
loop state selection and then crashed with:

```text
sparse private state reached materialization
```

That failure was not fixed by adding materialization recovery. Instead, wrapper
analysis and public-boundary demand had to be clarified.

### Solved Inline Wrapper Facts

Some call-value wrappers are semantically transparent to optimized lowering.
However, they are not necessarily safe to inline in materialization contexts.

The design became:

- a `.call_value` wrapper can be optimized-inline eligible
- the same wrapper need not be materialize-inline eligible
- optimized structured-demand lowering may consume this fact
- late public-value lowering must not rediscover and inline the wrapper as a
  cleanup pass

The focused wrapper test passes:

```sh
zig build run-test-zig-lir-inline -- --test-filter "call value wrapper is optimized-inline eligible but not materialize-inline eligible"
```

This fact moved the current imported-iterator regression past a public wrapper
boundary and into the missing capture invariant.

### Loop Entry State Products

The most recent committed fix addressed loop entry state identity.

Before the fix, the focused imported-iterator regression crashed with:

```text
postcheck invariant violated: optimized loop entry values could neither select a state nor be emitted as ordinary loop initials
```

The diagnostic shape was:

```text
state 0: any leaf
entry: private_state(record) expr
```

That meant the state side had been keyed as an unknown public leaf while the
entry value side had already been demanded into sparse private record state.
Those cannot match, and the sparse private entry could not be emitted as an
ordinary public initial value.

The fixed invariant is:

```text
loop state products and entry products are a paired output of applying normalized demand to the original entry value
```

If applying demand to the loop entry produces sparse private state, the loop
state identity must be derived from that exact private-state shape. It must not
use a public `.any` placeholder of the same type.

The committed implementation was intentionally narrow:

```zig
const demanded_value = try self.applyValueDemand(value, demand);
if (demanded_value == .private_state) {
    return try self.demandedKnownValueFromPrivateStateLoopStateShape(demanded_value.private_state);
}
```

This belongs in `demandedKnownValueFromLoopEntryDemand`, where the loop entry
product is being produced. It is not a materialization rule and not a call-site
rule.

After that fix, the same focused test moved forward to:

```text
postcheck invariant violated: sparse private callable was missing a demanded capture
```

That is the current active failure.

## Failed Attempts And What They Taught

### Browser-Driven Debugging Was Wasteful

During the Rocci Bird game behavior investigation, localhost browser testing
was useful only as final validation. It was a poor primary debugging method.
The user explicitly called this out when the game was still visually corrupted.

The better workflow is:

1. reduce to a compiler regression
2. inspect LIR or disassembly only to classify codegen shape
3. fix the compiler invariant
4. then run the game in the browser once the targeted test passes

### Public `Append` Variant Was The Wrong Direction

Adding an iterator `Append` step variant tried to solve a private optimization
problem by changing public iterator shape. That violated the goal. It also
created confusing layout/compatibility problems because parts of the compiler
and library still expected the old step union shape.

The lesson:

```text
keep public Iter shape stable; make private optimized lowering better
```

### "Just Inline" Was The Wrong Direction

Several failures tempted a local inline fix. For example, a sparse private
value reached a call boundary, or a wrapper exposed the real producer too late.
Inlining could sometimes move the failure further, but it would not establish
the missing compiler fact.

The lesson:

```text
if inlining is needed, the decision must be explicit producer data consumed at the right stage
```

Late inline cleanup is a hack if it exists only because earlier demand lowering
failed to represent the producer correctly.

### Recursive Direct-Call Fallback Was The Wrong Direction

When demand became recursive, one tempting idea was to recursively expand direct
calls or lower loops to direct recursive workers. That is not the long-term
design. Loops may interact with mutable variables and control regions; a
source-loop rewrite is not generally equivalent.

The correct approach is a demand graph with explicit loop-demand nodes.

### Clone-Site "Demand Changed, Try Again" Was The Wrong Direction

A failed WIP added broad behavior where body cloning could notice state-loop
demand changes and return uninitialized values or retry. This included:

- returning `bool` from `noteLoopDemandIfLocalExpr`
- clone-site uninitialized returns
- refreshing demanded known values from already-derived sparse private values
- mixed closure of function-demand refs and loop-demand refs
- broad late reaction to demand changes in consumers

This moved failures around but did not represent the missing fact. It also made
non-convergence more likely.

The failed WIP was deliberately deleted. The most recent commit
`ac8c4bda0e` includes that deletion along with the narrow state-key fix.

The lesson:

```text
demand growth must connect the demand owner to the original producer; consumers must not refresh missing pieces from sparse products
```

### Passing Tests That Do Not Fail First Are Not Regressions

Some tests added during investigation passed before the production change. They
can be useful coverage, but they are not regressions for the missing invariant.

The reset protocol now says:

- record exact failing command
- record expected failure class
- ensure the failure is the intended invariant
- only then edit production code

If a new test passes immediately, either keep it as secondary coverage or
delete it. Do not use it as proof for the fix.

## Current Active Failure In Detail

### Test

The current active regression is:

```sh
zig build run-test-zig-lir-inline -- --test-filter "imported iterator producer keeps finite step callables"
```

The test source shape is an imported module that exposes an iterator:

```roc
module [points]

Point : { x : I64 }

points : () -> Iter(Point)
points = || [{ x: 1.I64 }, { x: 2 }].iter().append({ x: 3 })
```

The consuming module imports that iterator and loops over it:

```roc
module [main]

import Points

main : I64
main = {
    iter = Points.points()
    var $sum = 0.I64
    for point in iter {
        $sum = $sum + point.x
    }
    $sum
}
```

The test expects optimized lowering to avoid reachable erased callable lowering
for this simple iterator producer.

### Previous Failure

Before commit `ac8c4bda0e`, it failed at loop entry state selection:

```text
postcheck invariant violated: optimized loop entry values could neither select a state nor be emitted as ordinary loop initials
```

That is fixed by deriving the loop state identity from the demanded private
entry shape.

### Current Failure

After the state-key fix, the same test fails at:

```text
postcheck invariant violated: sparse private callable was missing a demanded capture
```

The stack reaches:

```text
inlinePrivateStateCallableCallValueWithDemand
callKnownValueWithDemand
cloneExprValueWithDemand
inlineDirectCallValueWithDemand
cloneMatchScrutineeValue
cloneStateLoopFromDemandedKnownValues
```

Conceptually:

1. The loop state carries an iterator as sparse private state.
2. The loop body calls the iterator's `step` callable.
3. Result demand from the step call reaches the callable body.
4. The callable body needs a capture under that result demand.
5. The sparse private callable does not have that capture in its carried
   capture list.
6. The call-site consumer crashes because it cannot bind the capture.

The right fix is not to make `inlinePrivateStateCallableCallValueWithDemand`
invent the missing capture. At that point, the consumer is too late. The
private callable producer should have represented the demanded capture.

### Why The Capture Is Special

For ordinary captures, the private callable can carry a sparse captured value:

```text
capture index N -> private state child
```

For recursive iterator state, the demanded capture may be the current loop
state itself or a demanded path inside it. Carrying it structurally inside the
callable would recursively include the iterator inside its own step closure,
causing unbounded expansion.

The long-term design is a third option:

```text
capture index N -> supplied by active loop state at path P
```

This is neither omitted nor carried as a runtime leaf. It is an explicit
private-state supplier.

## Loop-Supplied Callable Capture Design

### Problem Statement

When a loop-carried callable's body needs a capture that is already owned by
the same active loop state, storing that capture structurally inside the
callable duplicates recursive state and can cause infinite demand growth. But
omitting the capture is wrong because the callable body needs it.

The correct representation is:

```text
this demanded callable capture is supplied by the active loop state
```

### Required Data

A supplier needs to identify:

- the active loop fixed point that owns the state
- the original loop parameter identity
- the demanded path from that loop parameter to the supplied value
- the type of the supplied value
- the demand that must be merged back into the owning loop parameter

The path uses checked child identities:

- record field name
- tuple item index
- tag payload name and index
- nominal backing
- callable capture index

The current code already has:

```zig
const LoopLocalProvenance = struct {
    local: Ast.LocalId,
    source_local: Ast.LocalId,
    path: []const DemandPathStep,
};

const DemandPathStep = union(enum) {
    record_field: names.RecordFieldNameId,
    tuple_item: u32,
    tag_payload: struct {
        name: names.TagNameId,
        index: u32,
    },
    nominal_backing,
    callable_capture: u32,
};
```

That is the right foundation. It records when generated split locals come from
a path inside an original loop parameter.

### Producer Responsibility

The producer of demanded private callable state must decide whether a demanded
capture is:

1. not demanded
2. carried as ordinary private state
3. carried as a runtime leaf
4. supplied by active loop state

If it is supplied by loop state, the producer must also merge the capture's use
demand back into the owning loop parameter at the recorded path:

```text
loop_param_demand = merge(loop_param_demand, demandAtPath(path, capture_demand))
```

After that merge, the supplier itself contributes no state slots. It is a
reference to state already carried by the loop.

### Consumer Responsibility

When inlining the private callable inside the owning loop fixed point, the
consumer binds the source capture local from the active loop state at the
supplier path.

This should happen in the private callable inlining path, currently around:

```zig
inlinePrivateStateCallableCallValueWithDemand
```

But the consumer should not infer the supplier. It should only consume explicit
supplier data placed in the private callable state by the producer.

### Where Supplier Data May Appear

Supplier data is legal only inside optimized private callable state owned by
the active loop fixed point.

It is illegal at:

- public materialization boundaries
- worker boundaries unless explicitly represented as parameters first
- ordinary public callable materialization
- stored constants
- LIR
- ARC
- backends

If a supplier reaches those boundaries, that is a compiler bug.

### Why This Is Not A Fallback

This is not "if capture missing, go find it." That would be a fallback and a
call-site guess.

The producer must explicitly store:

```text
capture index N has supplier S
```

The consumer then sees capture index N in the callable state and binds it. A
missing capture remains an invariant violation.

### Likely Implementation Shape

The implementation probably needs a new private-state shape, conceptually:

```zig
const PrivateStateValue = union(enum) {
    leaf: PrivateStateLeaf,
    tag: PrivateStateTag,
    record: PrivateStateRecord,
    tuple: PrivateStateTuple,
    nominal: PrivateStateNominal,
    callable: PrivateStateCallable,
    supplied: PrivateStateLoopSupplier,
    compact_finite_tags: PrivateStateCompactFiniteTags,
    compact_finite_callables: PrivateStateCompactFiniteCallables,
};
```

The actual name should follow the repository's naming rules. `Ref` and `Key`
suffixes are banned in new post-check code, so avoid names like
`LoopSupplierRef`. A name like `PrivateStateLoopSupplier` or
`LoopSuppliedState` is closer to the local vocabulary.

The supplier struct likely needs:

```zig
const PrivateStateLoopSupplier = struct {
    ty: Type.TypeId,
    source_local: Ast.LocalId,
    path: []const DemandPathStep,
};
```

It may also need an active loop identity beyond `source_local`, depending on
how nested loops and state-loop stacks are represented. The design says it is
keyed by active loop fixed point, original loop parameter identity, and path.
If active loop identity is implicit in the stack while supplier values are
created and consumed inside the same clone, `source_local + path` might be
sufficient for the first implementation. If suppliers can survive into worker
state or nested contexts, an explicit owner identity is required. The code
should not rely on incidental stack position if that value can cross a
boundary.

### Functions That Need To Understand Suppliers

Adding a private-state supplier is not just one match arm. Every function that
traverses `PrivateStateValue` must either:

- handle it explicitly, or
- reject it with an invariant because that boundary is illegal

Relevant functions include:

- private-state type queries
- private-state public materialization checks
- private-state matching against demanded known values
- demanded-known derivation from private state
- private-state argument counting
- private-state argument construction
- expression extraction from demanded known values
- local-demand propagation through private state
- value may-demand-local checks
- private callable capture lookup
- private callable inlining
- compact finite callable handling
- state continue splitting
- state loop key matching

This is why the next implementation should be careful and test-driven. A
supplier value is zero-slot state; it should not accidentally allocate a worker
argument or become a leaf.

### Tests Needed Before Production Edits

The current imported-iterator regression is a valid existing failing test for
the broad invariant, but the next production change should ideally also add a
smaller focused regression that proves supplier behavior directly.

The focused test should show:

- a loop-carried callable/iterator
- a callable result demand that demands a capture
- the capture is the current loop state or a path inside it
- lowering converges without structural expansion
- the resulting LIR is scope-closed
- no public callable materialization is used as recovery
- no erased callable lowering remains reachable in the hot path

The test should not rely on WASM-4, Rocci Bird, browser behavior, or binary
size. It should be a compiler test in the LIR inline/specialization area.

The existing imported-iterator test can remain the integration-style compiler
regression for imported modules.

## File-Level Implementation Notes

### Main File

Most current work is in:

```text
src/postcheck/monotype_lifted/spec_constr.zig
```

This file is already large and contains both older SpecConstr concepts and the
new optimized callable-state lowering machinery. This is risky because local
fixes can easily become hacks. The design docs and plan reset protocol are
important guardrails.

### Important Existing Types

Known producer shapes:

```zig
const KnownValue = union(enum) {
    any,
    leaf,
    tag,
    record,
    tuple,
    nominal,
    callable,
    finite_tags,
    finite_callables,
};
```

Demanded sparse producer shapes:

```zig
const DemandedKnownValue = union(enum) {
    any,
    leaf,
    tag,
    record,
    tuple,
    nominal,
    callable,
    finite_tags,
    finite_callables,
    compact_finite_tags,
    compact_finite_callables,
};
```

Private optimized state:

```zig
const PrivateStateValue = union(enum) {
    leaf,
    tag,
    record,
    tuple,
    nominal,
    callable,
    compact_finite_tags,
    compact_finite_callables,
};
```

The likely next change is to extend `PrivateStateValue` with a supplier shape
or extend callable captures with a supplier-capable value. A separate capture
union may be cleaner than making all private state values supplier-capable, but
the supplier can represent any demanded child path, so a general
`PrivateStateValue` variant may be simpler.

### Demand Propagation Helpers

Important helpers:

```zig
noteLoopDemandIfLocalExpr
mergeActiveStateLoopParamDemand
mergeLoopValueParamDemand
normalizeLoopValueParamDemand
demandAtPath
demandForSplitLocal
mergeProjectedPrivateStateDemand
mergeLocalDemandInPrivateStateValueAtPath
```

The current demand propagation already knows how to project missing private
state children back to a loop parameter through provenance:

```zig
mergeProjectedPrivateStateDemand(local, subst_local, path, demand, out)
```

That is close to the producer side needed for suppliers. The missing part is
that the private callable state itself must carry a supplier value for the
capture rather than omitting it.

### Current Inlining Failure Point

The current crash happens in:

```zig
inlinePrivateStateCallableCallValueWithDemand
```

The relevant logic currently says:

```zig
if (privateStateIndexedValueByIndex(callable.captures, index)) |capture| {
    bind capture from private state
} else {
    capture_demand = ...
    if capture_demand != .none {
        capture_value = privateStateCallableCaptureValue(callable, index)
            orelse invariant("sparse private callable was missing a demanded capture")
        bind capture from capture_value
    }
}
```

This should remain an invariant for truly missing captures. The long-term fix
is that a loop-supplied capture is not missing; it is present as supplier data
and can be resolved explicitly.

### State Key Fix Location

The state-key fix is in:

```zig
demandedKnownValueFromLoopEntryDemand
```

It now derives a demanded-known loop shape from the actual demanded private
entry value when `applyValueDemand` returns private state. That was the right
producer location for that invariant.

## What Has Worked Well

### Explicit Invariants

The best progress happened when a failure was named as a compiler invariant:

- cross-alternative callable demand
- generated-scope leak
- public-boundary demand
- stale demanded product
- loop-state key mismatch
- missing demanded callable capture

Once named, the implementation could be narrow and testable.

### Focused Compiler Tests

Focused Zig tests in `lir_inline_test.zig` were much better than browser
testing or Rocci Bird-only checks. They made it possible to distinguish:

- "moved past one invariant"
- "hit the next invariant"
- "introduced a non-convergence bug"
- "changed behavior but did not prove the intended fact"

### Deleting Bad WIP

Deleting failed WIP was necessary. The branch improved when bad partial paths
were removed instead of being kept as possible ingredients.

Commit `ac8c4bda0e` is an example: it both removed the failed clone-site demand
change experiment and kept the narrow loop-entry state shape fix.

### Design.md As A Contract

Updating `design.md` before code helped keep the work honest. It forced a
producer/consumer contract to be written down instead of inferred from the
current crash.

### Comparing Against Rust

The Rust port was valuable because it clarified the generated-code target.
Rust showed that the small-code path is possible, but also made clear that Roc
needs a different route because Roc's public type model is different.

## What Has Not Worked Well

### Optimizing From Rocci Bird Symptoms

Rocci Bird is a great integration target, but it is too large as the primary
debugging surface. Browser behavior and final WASM size are useful final
checks, not first principles.

### Source-Shape Thinking

Any thought process that starts with "when we see `.iter()`" or "inside a
`for` loop" tends to produce the wrong design. The optimizer should operate on
checked values, lambdas, demand, and loops after earlier compiler phases.

### Public API Changes For Private Optimization

The `Append` experiment showed that changing public iterator shape creates
more problems and violates the goal. The public shape should stay stable.

### Late Cleanup Thinking

The user correctly objected to layered cleanup passes. Some cleanup may be
generic and contract-driven, such as Binaryen or zero-segment removal under an
explicit zeroed-memory contract. But cleanup should not compensate for missing
compiler facts when the producer stage could emit the right representation.

### Broad Retry Logic

Broad "demand changed, return uninitialized, try again" logic made the code
less principled and created non-convergence risk. Demand fixed points should
converge because graph identity and equality are correct, not because random
clone sites bail out.

## Lessons Learned

### Demand Graphs Must Be Stable By Meaning, Not Allocation

Demand fixed points should not grow because a new node was allocated, entries
were reordered, or temporary provenance differs. Equality must be semantic.
Iteration caps are debug assertions for compiler bugs, not optimization
policy.

### Sparse State Must Always Know Its Original Producer

A sparse private product is derived. It is not a source of truth. If demand
grows, rebuild from the original producer under the normalized new demand.
Do not try to refresh missing fields or captures from the sparse value.

### Public Observation Must Be Explicit

If a value crosses a public boundary, the producer must know that and carry a
public value or public leaf as needed. Sparse private state cannot be
materialized magically later.

### Wrapper Facts Are Contextual

A wrapper can be transparent for optimized structured demand but not for public
materialization. Inline facts need context. A fact consumed in the wrong stage
can erase useful destination-passing, Box update, ARC, or private-state
boundaries.

### Loop-Supplied Captures Are A Real Third Case

Callable captures are not only "stored" or "omitted." Recursive iterator state
needs "supplied by active loop state" as an explicit private-state case. This
is the next missing compiler fact.

### Hoisting Should Ignore Source-Level Wrapper Categories

Nominal, opaque, and structural distinctions should not decide hoisting. The
real questions are whether the expression is resolved/valid enough, whether it
depends on runtime inputs, and whether it calls effectful functions.

### Browser Testing Is Final Validation

Browser testing should happen only after compiler invariants are proven. It is
too noisy for root-cause work.

## Recommended Next Steps

### 1. Keep The Current State-Key Fix

Do not revert commit `ac8c4bda0e`. It fixed the loop-entry state identity
invariant and moved the focused regression to the next expected failure.

### 2. Add A Focused Supplier Regression

Before production edits for suppliers, add or identify a smaller compiler test
than the imported iterator test. It should fail with the current missing
capture invariant or a more direct supplier invariant.

The existing imported iterator test remains the broad regression:

```sh
zig build run-test-zig-lir-inline -- --test-filter "imported iterator producer keeps finite step callables"
```

### 3. Add Explicit Supplier Data

Represent a demanded callable capture supplied by active loop state as explicit
private-state data. Do not infer it in `inlinePrivateStateCallableCallValueWithDemand`.

The supplier should be produced from loop provenance and demand, not from:

- source names
- debug ids
- current subst contents alone
- structural equality with some private value
- call-site failure recovery

### 4. Merge Supplier Demand Into The Owning Loop Parameter

When the producer creates supplier data, it must also merge the capture demand
back into the loop parameter at the supplier path.

This is how the loop state knows it must carry the supplied value.

### 5. Resolve Supplier Only In The Owning Loop

The private callable inliner should resolve supplier data by reading active
loop state at the recorded path. If the owning loop is unavailable, that is an
invariant violation.

### 6. Audit All Private-State Traversals

Every `PrivateStateValue` traversal must handle or reject supplier data.
Especially audit:

- materialization
- argument counting
- demanded-known conversion
- matching/equality
- local-demand propagation
- state continue splitting
- compact finite callables
- LIR emission boundaries

### 7. Rerun Focused Tests

Minimum focused checks after supplier implementation:

```sh
zig build run-test-zig-lir-inline -- --test-filter "imported iterator producer keeps finite step callables"
zig build run-test-zig-lir-inline -- --test-filter "call value wrapper is optimized-inline eligible but not materialize-inline eligible"
zig build run-test-zig-lir-inline -- --test-filter "direct range map collect uses direct list loop"
zig build run-test-zig-lir-inline -- --test-filter "plant iter pipeline collect uses direct range map list loop"
zig build run-test-zig-lir-inline -- --test-filter "known-length List.iter collect specializes without unbound locals"
```

Then run the broader LIR inline target once focused tests pass.

### 8. Only Then Return To Rocci Bird

After the compiler invariants pass:

- rebuild Rocci Bird with `--opt=size` or the current equivalent size mode
- run Binaryen size optimization
- compare `.iter()` and non-`.iter()` versions again
- compare against the Rust port
- inspect disassembly only to explain remaining size differences
- run the browser server only as final validation

## Known Open Questions

### Exact Supplier Owner Identity

The design says a supplier is keyed by active loop fixed point, original loop
parameter identity, and path. The existing code has `source_local` and path
provenance. It needs to be decided whether `source_local + active stack` is
enough in the implementation or whether an explicit loop owner id must be
added.

Long-term ideal answer: use explicit owner identity if there is any chance the
supplier can cross nested loop or worker boundaries where stack position is not
sufficient.

### Supplier As PrivateStateValue Variant Or Capture-Specific Variant

Two possible shapes:

1. Add a general `PrivateStateValue` supplier variant.
2. Change callable captures from `[]PrivateStateIndexedValue` to a
   capture-specific union that can hold either private state or supplier data.

The first is simpler and makes supplier data usable for any demanded child. The
second may prevent supplier values from appearing where they are illegal. The
implementation should choose the shape that best encodes the invariant without
requiring scattered runtime checks.

### Worker Boundary Behavior

Supplier data is legal only inside the owning loop fixed point. If optimized
workers need to cross that boundary, the supplier must be converted into
explicit parameters before the boundary. The current focused regression may not
need this, but the design should not leave an ambiguous fallback.

### Interaction With Public-Boundary Demand

Some values may need both sparse private internal state and public boundary
state. Supplier implementation should not regress the public-boundary
invariant. Public materialization must still be explicit.

### Interaction With Box Reuse And Destination Passing

The broader size gap includes Box/update and destination-passing opportunities.
Supplier work is not the whole story. Once iterator/callable state lowers
properly, the next major size/performance wins may come from:

- updating through unique boxes
- destination-passing for returned aggregates/strings/lists
- better in-place update representation
- boxed lambda update where safe

Those are separate compiler designs and should not be mixed into the supplier
slice.

## Final Status

The project has made real progress:

- WASM-4 memory waste was diagnosed and redesigned around an explicit memory
  contract.
- Binaryen was identified as necessary normal WASM tooling and integrated
  through the bootstrap direction.
- Rocci Bird was made to run again in optimized builds after earlier
  corruption/miscompile work.
- Several app and compiler size wins were implemented.
- The remaining Rust-size gap was narrowed to a real compiler design problem:
  optimized lowering of callable/iterator state.
- The public iterator API direction is now clear: keep the three-step
  lambda-based public shape and optimize privately using lambda sets.
- Several bad implementation directions were tried, identified, and deleted.
- The latest committed compiler slice fixed loop entry state identity and moved
  the active regression to the next real missing fact.

The next long-term-ideal task is explicit loop-supplied callable captures. That
should be implemented as producer-owned private-state data, with a focused
regression proving convergence and scope-closed LIR before any return to
Rocci Bird binary-size work.
