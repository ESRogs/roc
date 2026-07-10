# Pin Deferred Spec Requests to Checked Use-Site Types

## Problem

Deferred template requests consume the checker's solved use-site type:
`pinDeferredTemplateRequestToCheckedRoot`
(`src/postcheck/monotype/lower.zig:2712`) instantiates the requested
template's checked function root into the requester's graph at request
creation (call sites at `lower.zig:2684` and `lower.zig:2790`), so
type-level-only facts such as phantom nominal type arguments reach the
request before sealing can default anything. Its doc comment asserts the
resulting invariant: a row that still takes its `row_default` at seal time
is genuinely unconstrained rather than starved.

Nothing enforces that invariant, and one known propagation hole remains
unaudited: `unifyThroughBacking` (`src/postcheck/monotype/solve.zig:735`)
relates a named node to a structural node through the *backing* type and
never pairs the named type arguments. The pin delivers checked facts to
deferred requests, but intra-graph nodes that connect only through a
backing can still be starved of named-argument evidence — and if one is,
seal time (`sealDeferredSpecRequestsFrom`, `lower.zig:2961`) silently
closes it to its `row_default`, reproducing the disease shape the pin
exists to kill: a fact proven during checking, lost in structural replay,
papered over by a default, and enforced only by a downstream panic
(`unifyRowWithEmpty`, `solve.zig:871`; conflict-over-rewrite doctrine in
the `solve.zig` header).

## Background

The compiler pipeline: parse → canonicalize → type-check (checked
artifacts; all user-facing failures end here) → postcheck: Monotype IR
(monomorphization; `src/postcheck/monotype/`) → Monotype Lifted → Lambda
Solved → Lambda Mono → LIR → ARC → backends. `design.md` is authoritative;
read "Monotype Instantiation" and "Row, Nominal, Alias, And Opaque
Authority" before starting.

Monotype lowering solves each specialization in a per-spec instantiation
graph (`solve.zig`). Template body requests discovered while lowering a
specialization are deferred to the end of the requesting specialization
and sealed then. Each `DeferredTemplate` (`solve.zig:~41`) carries the
checked identity of what it requests (`source_fn_ty`) and the requester's
live function type cell (`requester_fn_node`), through which callee body
evidence flows back before the requester seals its body draft. A row node
that no evidence has pinned by seal time takes its `row_default` — the
correct treatment for genuinely unconstrained rows only.

## Evidence

- `solve.zig:735` `unifyThroughBacking`: on the named↔structural path it
  appends the backing/other pair (or moves the structural content and
  unifies through the backing) without ever pairing `named.args`; named
  arguments are paired only on the named↔named path in `unifyConcrete`
  (`solve.zig:602`).
- `row_default` consumption: `solve.zig:90` (node field), `:1924`
  (materialization), `:2326` and `:2381` (row closing during seal).
- No counter, assert, or log anywhere observes "row node defaulted at seal
  while its checked counterpart was concrete" — grep for such
  instrumentation in `lower.zig`/`solve.zig` finds none.
- Regression coverage that must stay green while auditing:
  `test/cli/issue_9968_pin_deferred_spec_requests/` (phantom record row
  across interpreter/dev/speed, phantom tag row, phantom nested nominal,
  I64-argument variant, concrete-phantom control, cross-module
  `cli_repro_pkg`), registered in
  `src/cli/test/parallel_cli_runner.zig:852-858`.

## Solution design

Decide the `unifyThroughBacking` question with evidence instead of leaving
it as a doc-comment promise:

1. **Instrument seal-time defaulting.** In debug builds, when a row node
   closes to its `row_default` during sealing, compare against the checked
   type behind the request (`source_fn_ty` is in hand on the
   `DeferredTemplate`); count or assert when the checked counterpart of a
   defaulted row is concrete. This makes the pin's invariant — defaults
   only for genuinely unconstrained rows — checkable rather than asserted
   in prose.

2. **Run the corpus.** Snapshot corpus (`zig build run-snapshot-tool`),
   the CLI suite, `examples/`, and the roc-parser package suite, all in
   debug mode.

3. **Pair named arguments through the backing if any site fires.** If the
   instrumentation trips, extend `unifyThroughBacking` to pair
   `named.args` when relating a named node to a structural node, so
   intra-graph nodes reachable only through a backing receive
   named-argument evidence. If nothing fires, record the negative result
   where the next reader will look: the `unifyThroughBacking` doc comment.

4. **Enforcement stays.** The seal-time contradiction panic remains
   exactly as it is (debug assertion / release unreachable per design.md).
   It is the regression tripwire, not a condition to soften.

## What success looks like

- `row_default` at seal time is reachable only for rows the checker left
  genuinely unconstrained — enforced by the debug check, not by comment.
- The debug check fires nowhere on the snapshot corpus, the examples, the
  CLI suite, and the roc-parser package suite — or, where it fires,
  `unifyThroughBacking` pairs named arguments and the check then passes.
- The `test/cli/issue_9968_pin_deferred_spec_requests/` suite stays green.

## How to evaluate the result

### Correctness ideal

A deferred request's sealed type is a function of `source_fn_ty` plus
genuine defaults — never of which value-flow edges happened to exist. The
debug check is the enforcement; the solver's conflict-over-rewrite
doctrine is untouched.

### Performance ideal

The instrumentation is debug-only: zero release-build cost. If
named-argument pairing is added, it appends one pending pair per named
argument at named↔structural meets — bounded by data already in the node.
Measure Monotype lowering time on the specialization-heavy corpus
(roc-parser examples) and `examples/`; require parity within noise.

## Tests to add

- Debug-build corpus check: the item-1 check asserts zero
  defaulted-while-checked-concrete rows across
  `zig build run-snapshot-tool` and the CLI suite.
- If pairing is added: a repro where a phantom-carrying named type meets a
  structural type only through its backing inside one graph (no deferred
  request involved), asserting build + run output.
