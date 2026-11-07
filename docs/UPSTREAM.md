# Upstream

- core/ = nullclaw @ 5f1cade (https://github.com/nullclaw/nullclaw), plus these port commits (oldest last):
  - 35f9ab3 android: std.http by default (DNS fixed in compat.io); -Dandroid-curl=true keeps curl path
  - df8a047 android: bionic getaddrinfo netLookup in compat.io(); dynamic PIE exe + PIC C libs for aarch64-linux-android
  - 1c4e630 wave3: test-only 0.17 fixes (enum/union field_names) + compat read keeps 0.16 readv semantics; zig build test == 0.16 baseline (7493/7507, 14 skip)
  - ccf73fd wave2: claude-orchestrator fixes (net io.operate, ascii.findIgnoreCase, HostName.fromUri, meta.declarations, rsa verify ptr, compat.ManagedMemoryPool) - exe builds on 0.17.1
  - 3a404d1 wave2: compat.fields for std.meta.fields, bufPrintZ->bufPrintSentinel, drop removed RunOptions.disable_aslr (gates pass)
  - bcd4db6 wave2: sed-bot dupeZ -> dupeSentinel(.., 0) (21 files, gates pass)
  - 85e9eb8 wave1: crouton-alpha athlete ports (23 files, orchestrator-regraded, all gates pass)
  - 3be722f wave1: @cImport of sqlite3/wasm3/libpq -> translate-c modules in build.zig (4 files + build)
  - 637c35f wave1: @cImport(stdlib.h) -> compat.c_stdlib (8 files, gates pass)
  - dc754db wave1: sed-bot ports of ** (16 files, all gates pass)
  - 360fe18 infra: 0.17 build.zig API fixes + compat.repeat for removed **
- core/deps/websocket = nullclaw/websocket @ 9151f70, plus 2 commits porting it to Zig 0.17.
- core/deps/wasm3 = nullclaw/wasm3 @ 8a29b00 (C, unchanged).
