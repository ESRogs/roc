# Bug Backlog

## Active

- [fuzz_crash_085.md](test/snapshots/fuzz_crash/fuzz_crash_085.md)
  - Target: canonicalize fuzzer (`fuzz-canonicalize`)
  - Repro: `C(_,b):()D:C(a,b)E:{b:r}F:e r={(){}}`
  - Notes: snapshot is marked `skip=true` because processing currently reaches an assertion in `generateAnnoTypeInPlace`.
