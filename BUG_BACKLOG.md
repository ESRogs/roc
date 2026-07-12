# BUG BACKLOG

## 2026-07-12 (Parser + Canonicalize fuzzer run)

Ran two 10-minute fuzz sessions:

- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-parse-corpus -o /tmp/fuzz-parse-out -- -t 5000+ -m none -- zig-out/bin/fuzz-parse`
- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-canonicalize-corpus -o /tmp/fuzz-canonicalize-out -- -t 5000+ -m none -- zig-out/bin/fuzz-canonicalize`

Totals observed:

- Parser fuzzer: `8` crash files, `0` hangs
- Canonicalize fuzzer: `11` crash files, `0` hangs

Unique confirmed issues:

No unresolved issues.

No hangs reproduced in either run.

Additional note:
- `/tmp/fuzz-parse-out/default/crashes/id:000006` no longer repros as a crash in direct `repro-parse` replay under `--v`.
