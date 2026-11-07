# Zig Port Olympics: nullclaw 0.16 → 0.17.1 (overnight round, 2026-11-07)

## Result
- **`zig build test` on 0.17.1 matches the 0.16.0 baseline exactly: 7,493/7,507 tests pass, 14 skipped.** That holds per step: 19 / 7,379 + 14 skip / 95.
- Release exe builds and runs (`--help`, `--version`). It's 5.43 MB on 0.17, against 5.51 MB on 0.16.
- Cross-build for `aarch64-linux-android.29` works: a 4.66 MB dynamic PIE that uses `/system/bin/linker64`. **It hasn't been run on a device yet**; probe APK v0.3 bundles it to test that.
- Ported tree: `core/` in this repo (nullclaw upstream 5f1cade + the port), with the ported `websocket` dependency vendored under `core/deps/`.
- The diff from upstream is 76 files, +510/−449 lines.

## Grading
Every changed `.zig` file was graded against the untouched upstream file with `gate.py`, which is `port_grade.py` adapted to a multi-file package. The gates are:
- `parse`: `zig ast-check` passes on 0.17.
- `names`: every original test name is still present.
- `asserts`: no fewer `expect*` calls, and every literal in test blocks survives.
- `api`: every `pub` name is still present.
- `gut`: no new `unreachable`/`@panic`/`undefined`/`@compileError`/`@trap`.
- `size`: between 0.9× and 1.2× of the original.

The project-level gate was the full test suite matching the baseline.

The grader's sha256 was pinned and re-checked before each merge. My final re-grade passed **74/74 nullclaw files and 5/5 websocket files.**

## Leaderboard
| athlete | what | result |
|---|---|---|
| **crouton-alpha** (stealth, OpenRouter, via pi; 6 parallel workers) | wave 1: the 23 hardest `**` files, e.g. `.{null} ** N`, `(results.len + 1)` counts, mixed `++` | **23/23 pass after my re-grade**, using its own `check.sh` loop. That's pass with grader feedback, not strict pass@1. Largest diff: nostr.zig, 76 lines. 3 diffs read by hand: faithful, with a slightly redundant `@as`. |
| **sed-bot** (regex / bracket-aware rewrites) | `"lit" ** N`, `[_]T{v} ** N`, `dupeZ`→`dupeSentinel` (125 calls), `bufPrintZ`, `ascii.indexOfIgnoreCase`→`findIgnoreCase`, `uri.getHost`→`HostName.fromUri`, `std.meta.fields`/`Tuple` | 16/35 wave-1 files on its first pass; the other 19 went to crouton-alpha. Every later rule passed every file it touched. |
| **claude-orchestrator** (me) | build.zig on the 0.17 API, translate-c for sqlite3/wasm3/libpq, `compat` helpers, net I/O on `io.operate`, ~9 one-off semantic fixes | Same gates. Wave 2 surfaced 1–3 errors per build, so I fixed those myself instead of dispatching athletes. |

New shared helpers in `src/compat.zig`:
- `repeat`, for the removed `**`.
- `c_stdlib`, for the removed `@cImport(stdlib.h)`.
- `fields`/`Field`, for the removed `std.meta.fields`.
- `ManagedMemoryPool`, for the removed `memory_pool.Managed`.

## Misses (kept visible)
1. **Grader false fail.** Multi-line `\\` string literals threw off the literal scan. I fixed it by hashing all literals before scanning.
2. **Grader bug I introduced while fixing #1.** The char-literal pattern spanned newlines, swallowed test blocks, and **let two cheats past the asserts gate**. I caught it with the seeded cheats, fixed it, and verified test-block counts across all 293 files.
3. **My own regression.** In `compat/net.zig` I first ported `read` to 0.17's `net_read`, which uses `recvmsg`. That returns ENOTSOCK on pipes, and 2 websocket tests failed. I restored 0.16's `readv` semantics on POSIX, and the tests went back to baseline.
4. **A behaviour loss.** `RunOptions.disable_aslr` no longer exists in 0.17. nullclaw keeps the option field, but it's no longer forwarded.
5. **A documented gate exception.** Removed `@cImport` header names (`"stdlib.h"` and so on) may vanish from tests.
6. **What hasn't been exercised:**
   - The libpq translate-c path: Postgres is off by default, so it was compiled but never built against libpq.
   - The Windows branches.
   - The Android binary on a device.
7. **nullclaw on Android still forces its `curl` fallback** in `http_util.zig`. That's the code path whose cause we found last night. The bionic DNS fix now lives in `compat.io()`, so std.http should work there. Removing the forced curl is the next change, and the phone has to verify it.
8. The README's "678 KB" doesn't hold: the binary is 5.4 MB. Any benchmark table has to use measured numbers.

## Limits
- The gates are text-level, and the test suite is the behavioural check.
- I didn't run differential execution.
- crouton-alpha's prompts and outputs may be logged by the provider. Only public MIT code and the open reference pack were sent.
