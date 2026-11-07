#!/usr/bin/env bash
# Build the DroidClaw APK (arm64) without Gradle:
#   core (nullclaw, Zig 0.17) -> libnullclaw.so ; probe.zig -> libhprobe.so ; aapt2 -> javac -> d8 -> zipalign -> apksigner
# Needs: Zig 0.17.1, Android SDK (platforms;android-35, build-tools;35.0.0), NDK r29, JDK 17+.
#   ZIG=/path/to/zig ANDROID_HOME=/path/to/sdk ANDROID_NDK=/path/to/ndk ./build.sh
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd)
ZIG=${ZIG:-zig}; SDK=${ANDROID_HOME:?set ANDROID_HOME}; NDK=${ANDROID_NDK:?set ANDROID_NDK}
BT=$SDK/build-tools/35.0.0; JAR=$SDK/platforms/android-35/android.jar
SYS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot; API=29
OUT=$H/out; rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/stage/lib/arm64-v8a"

# Zig libc file for bionic (Android API $API)
LIBC=$OUT/libc-android.txt
cat > "$LIBC" <<EOT
include_dir=$SYS/usr/include
sys_include_dir=$SYS/usr/include/aarch64-linux-android
crt_dir=$SYS/usr/lib/aarch64-linux-android/$API
cc_dir=$SYS/usr/lib/aarch64-linux-android/$API
msvc_lib_dir=
kernel32_lib_dir=
darwin_sdk_dir=
EOT

# 1. nullclaw core for Android (dynamic PIE, std.http + bionic DNS)
( cd "$ROOT/core" && ZIG_LIBC="$LIBC" $ZIG build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-android.$API \
    --libc "$LIBC" -p "$OUT/core" )
cp "$OUT/core/bin/nullclaw" "$OUT/stage/lib/arm64-v8a/libnullclaw.so"   # exec'd from nativeLibraryDir

# 2. survival-probe JNI library
( cd "$H/probe" && $ZIG build-lib -dynamic probe.zig -target aarch64-linux-android.$API -lc \
    --libc "$LIBC" -O ReleaseSafe -fPIC -fstrip --name hprobe -femit-bin="$OUT/stage/lib/arm64-v8a/libhprobe.so" )

# 3. APK
$BT/aapt2 link --manifest "$H/app/AndroidManifest.xml" -I "$JAR" -o "$OUT/base.apk"
javac -nowarn -encoding UTF-8 --release 11 -classpath "$JAR" -d "$OUT/classes" $(find "$H/app/src" -name '*.java')
$BT/d8 --min-api $API --lib "$JAR" --output "$OUT/stage" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/unsigned.apk"
( cd "$OUT/stage" && zip -q -0 -r "$OUT/unsigned.apk" lib && zip -q "$OUT/unsigned.apk" classes.dex )
$BT/zipalign -f -P 16 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Debug signing key: generated locally, never committed.
KS=$H/debug.keystore
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass droidclaw -keypass droidclaw -alias debug \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=DroidClaw debug" >/dev/null 2>&1
$BT/apksigner sign --ks "$KS" --ks-pass pass:droidclaw --out "$OUT/droidclaw.apk" "$OUT/aligned.apk"
$BT/apksigner verify "$OUT/droidclaw.apk" && ls -la "$OUT/droidclaw.apk"
