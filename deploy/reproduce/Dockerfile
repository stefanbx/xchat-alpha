# Canonical reproduction environment for the ӾChat Android APK.
#
# Why a container: the Dart AOT snapshot (libapp.so) embeds ONE absolute source path
# (.../.dart_tool/flutter_build/dart_plugin_registrant.dart). That makes an otherwise
# byte-identical build depend on WHERE it was built. Pinning the build to a fixed path
# inside a fixed image removes the last machine-dependent input, so every reproducer —
# on any host OS — gets the same content hash. Trust then rests on the public source +
# this public recipe, not on our machine.
#
# Everything is version-pinned: base image, JDK, Flutter revision, Android SDK packages,
# NDK. Gradle 9.1.0 / AGP 9.0.1 / Kotlin 2.3.20 come from the repo's wrapper + build files.
#
# Build the image, then build the APK at the canonical path /build/xchat:
#   docker build -t xchat-repro deploy/reproduce
#   docker run --rm -v "$PWD":/src:ro xchat-repro   # prints the content hash
# (reproduce-docker.sh wraps both steps.)

# eclipse-temurin 17 (JDK 17). Architecture is part of the reproduction contract: the
# PUBLISHED canonical hash is defined on linux/amd64 (see .github/workflows/reproduce.yml,
# which runs this on a native amd64 runner — the reproducible-builds.org / F-Droid
# convention). REPRO_PLATFORM lets a verifier pin the arch explicitly:
#   docker build --build-arg not needed — pass --platform to buildx, e.g.
#   docker buildx build --platform=linux/amd64 -t xchat-repro --load deploy/reproduce
# Without buildx (legacy builder), the image builds for the host arch; that reproduces a
# host-arch hash, which matches other reproducers on the same arch. For a fully reproducible
# base also pin by digest (docker buildx imagetools inspect eclipse-temurin:17-jdk-jammy).
FROM eclipse-temurin:17-jdk-jammy

# ---- pinned toolchain versions -------------------------------------------------
ENV FLUTTER_REVISION=6b182d2c75 \
    ANDROID_PLATFORM=android-36 \
    ANDROID_BUILDTOOLS=36.0.0 \
    ANDROID_NDK=28.2.13676358 \
    CMDLINE_TOOLS_VERSION=11076708 \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter \
    DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=$ANDROID_SDK_ROOT \
    PATH=$FLUTTER_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip xz-utils zip ca-certificates python3 libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

# ---- Android SDK (pinned command-line tools + packages) ------------------------
RUN mkdir -p $ANDROID_SDK_ROOT/cmdline-tools \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -o /tmp/cmdtools.zip \
    && unzip -q /tmp/cmdtools.zip -d $ANDROID_SDK_ROOT/cmdline-tools \
    && mv $ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools $ANDROID_SDK_ROOT/cmdline-tools/latest \
    && rm /tmp/cmdtools.zip \
    && yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install "platform-tools" \
        "platforms;${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILDTOOLS}" \
        "ndk;${ANDROID_NDK}" >/dev/null

# ---- Flutter at the pinned revision --------------------------------------------
RUN git clone https://github.com/flutter/flutter.git $FLUTTER_HOME \
    && git -C $FLUTTER_HOME checkout $FLUTTER_REVISION \
    && git config --global --add safe.directory $FLUTTER_HOME \
    && flutter config --no-analytics >/dev/null \
    && flutter precache --android >/dev/null \
    && flutter doctor -v || true

# The canonical build path — must be identical for every reproducer.
WORKDIR /build/xchat
COPY reproduce-inner.sh /usr/local/bin/reproduce-inner.sh
RUN chmod +x /usr/local/bin/reproduce-inner.sh
ENTRYPOINT ["/usr/local/bin/reproduce-inner.sh"]
