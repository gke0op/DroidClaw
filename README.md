# DroidClaw

A full AI agent that runs on an Android phone from one APK: no Termux, no root, no curl, no companion server.

DroidClaw's core is [nullclaw](https://github.com/nullclaw/nullclaw), a Zig agent runtime, ported to **Zig 0.17.1** and made to work natively on Android (bionic). The APK ships the agent binary and runs it the way Android allows: as a native library in the app's own library directory.

> Status: **early, working prototype.** Everything below was measured, mostly on one phone (Samsung Galaxy S24 Ultra, Android 15). Misses and open problems are listed too.

## What works today (measured)

| | result |
|---|---|
| nullclaw core on Zig 0.17.1 | `zig build test`: **7,493/7,507 pass, 14 skipped**, the same as upstream on Zig 0.16 |
| Android build | `aarch64-linux-android.29` dynamic PIE, 4.7 MB, loaded by `/system/bin/linker64` |
| Runs from inside the APK | `--version`, `--help`, `status`: exit 0, 8–48 ms on the S24 Ultra |
| **Agent turn on the phone** | `nullclaw agent -m …` → OpenRouter → reply in **3.1 s**, exit 0 |
| Zig HTTPS on Android | stock Zig fails 29/29 heartbeats (`NameServerFailure`); with DroidClaw's DNS fix, **29/29 succeed** (167–492 ms) |
| Staying alive | one process lived **16.5 h** with no kill (foreground service + "Unrestricted" battery) |
| Surviving app updates | the service restarts itself after an update (`MY_PACKAGE_REPLACED`) |

## Why stock Zig can't do HTTPS on Android

Zig's resolver reads `/etc/resolv.conf` and then asks 127.0.0.1:53. Android has neither, because apps resolve names through `getaddrinfo` in bionic/netd. Every Zig HTTP request therefore fails with `NameServerFailure`, which is why nullclaw used to shell out to Termux's `curl` on Android.

DroidClaw changes one function. Zig 0.17's `std.Io` is an interface, so `compat.io()` copies the platform vtable and replaces only `netLookup` with a call to bionic's `getaddrinfo` (`core/src/compat/shared.zig`). Everything else is stock `std.http`. Building with `-Dandroid-curl=true` restores the old curl path for Termux users.

## Open problems

- **Waking a locked phone.** In Doze, a plain timer fired only every 1–1.6 hours (gaps up to 5,992 s). The current build tests an exact allow-while-idle alarm mode and a wakelock mode; the results will be added to `docs/FIELD_TESTS.md`.
- **The agent isn't in the service yet.** The agent runs on a button press. The next milestone is the always-on service plus a chat channel (Telegram first).
- **Memory backend.** A fresh workspace logs `SqliteOpenFailed` for the `hybrid` memory backend. Upstream 0.16 does the same.
- **Size.** The binary is 4.7–5.4 MB, not the 678 KB that older nullclaw READMEs quote. The app process (Android runtime) is about 120–130 MB of RSS; the agent core is a small part of that.
- **Tested phones:** a Samsung S24 Ultra only (an S20+ is next). Phone makers' battery managers vary; see dontkillmyapp.com.

## Build

```sh
# core only (native)
cd core && zig build -Doptimize=ReleaseSmall          # Zig 0.17.1
cd core && zig build test --summary all

# APK (arm64): needs Android SDK 35, build-tools 35.0.0, NDK r29, JDK 17+
cd android && ZIG=zig ANDROID_HOME=… ANDROID_NDK=… ./build.sh   # -> android/out/droidclaw.apk
```

There's no Gradle: the script uses `aapt2`, `javac`, `d8`, `zipalign` and `apksigner` directly. A debug keystore is generated locally and never committed.

## Layout

```
core/      nullclaw fork on Zig 0.17.1 (+ Android: bionic DNS, dynamic PIE, PIC C libs, std.http default)
core/deps/ vendored websocket + wasm3, ported to 0.17
android/   APK: foreground service, wake modes, survival probe, buttons to run nullclaw
docs/      PORT_ZIG_0_17.md: how the port was done and graded, with its misses
```

## Credits and license

MIT. `core/` is a fork of nullclaw (MIT); `core/deps/*` keep their MIT licenses.

The Zig 0.17 port was done as a graded "port olympics": each changed file had to keep every test, `expect`, literal and public name of the original and pass `ast-check` on 0.17, and the whole suite had to match the 0.16 baseline exactly. The athletes were a regex bot, the crouton-alpha model, and the orchestrator. See `docs/PORT_ZIG_0_17.md`.
