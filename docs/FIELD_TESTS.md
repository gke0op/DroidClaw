# Field tests

Raw logs come from the in-app survival probe (`android/probe`, `HeartbeatService`). Each heartbeat runs three network tests:
- **A:** stock Zig `std.http`.
- **B:** bionic `getaddrinfo`.
- **C:** `std.http` with DroidClaw's bionic `netLookup`.

## 2026-11-07, Samsung Galaxy S24 Ultra (SM-S928B), Android 15 (SDK 35)

Setup: battery "Unrestricted", foreground service (`specialUse`), Samsung power saving **on**, unplugged, wake mode `sleep` (a `Thread.sleep(60 s)` loop).

| metric | value |
|---|---|
| run | 02:29 → 19:03 (16.5 h), **one PID, never killed or restarted** |
| A: stock Zig | 0 successes; always `NameServerFailure` after ~5 s |
| B: getaddrinfo | 100% |
| C: DroidClaw lookup + std.http | **100%** of heartbeats; HTTPS 204 in 167–510 ms |
| RSS (whole app process) | 120–132 MB, flat |
| heartbeat gaps, screen off | Doze began about 1 min after screen-off; gaps then reached 683, 2,173, 3,672, 5,742 and **5,992 s** |
| battery (whole phone, 02:29 → 13:39) | 32% → 26% |

**What this shows:** surviving is solved on this phone. Waking is not: plain timers don't fire in Doze. Next test: `alarm` mode (exact allow-while-idle alarm every 60 s, short wakelock per beat) against `wakelock` mode (CPU held). Measure the gap distribution and battery cost of each.

### Executing the agent from the APK (same phone)
- `libnullclaw.so --version` → exit 0, 48 ms; `--help` → exit 0, 18 ms; `status` → exit 0, 8 ms.
- `agent -m … --provider openrouter --model stealth/crouton-alpha` → exit 0, **3,093 ms**, model reply received. The `SqliteOpenFailed` memory warning also appears on upstream 0.16.
