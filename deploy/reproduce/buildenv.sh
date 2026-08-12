# Sourced by reproduce.sh — the pinned build environment for ӾChat's Android APK.
# Edit these only when intentionally moving the pinned toolchain (and update TOOLCHAIN.md).
export FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$FLUTTER_HOME/bin:$JAVA_HOME/bin:$PATH"
