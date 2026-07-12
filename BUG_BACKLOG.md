# Fuzzing backlog

## Session: 2026-07-12 (parser + canonicalize fuzzing, 10 minutes each)

### Completed

- Ran parser and canonicalize fuzzers for 10 minutes each.
- Parser fuzzer found reproducible crashes. Canonicalize fuzzer found no crashes or hangs.

### Findings

#### Parser fuzz — Formatting not stable

- Severity: High (panic)
- Repro snapshot: `test/snapshots/fuzz_crash/fuzz_crash_105.md`
- Source (minimal):
  - A minimal crash input is a Roc module beginning with a leading newline and a tab-separated where-clause layout.
- Root cause class: `panic: Formatting not stable` from `src/fmt/fmt.zig` (`moduleFmtsStable`).
- Original fuzzer artifacts:
  - `/tmp/parse-fuzz-run-5/default/crashes/id:000000,...`
  - `/tmp/parse-fuzz-run-5/default/crashes/id:000001,...`
  - `/tmp/parse-fuzz-run-5/default/crashes/id:000002,...`

#### Parser fuzzer — formatter output re-parse failure

- Severity: High (panic)
- Repro snapshot: `test/snapshots/fuzz_crash/fuzz_crash_106.md`
- Source (minimal):
  - `a=0O0<CR>.0` (carriage return in numeric method access path)
- Root cause class: `panic: Parsing of formatter output failed` from `src/fmt/fmt.zig` (`moduleFmtsStable`).
- Original fuzzer artifact:
  - `/tmp/parse-fuzz-run-5/default/crashes/id:000006,...`

#### Duplicate crash artifacts

- The following crash files did not reproduce on strict `repro-parse` replay and were not promoted into separate snapshots:
  - `id:000003`
  - `id:000004`
  - `id:000005`

