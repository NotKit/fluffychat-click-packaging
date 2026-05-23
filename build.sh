#!/bin/bash
# Build FluffyChat for Ubuntu Touch using flutter-elinux
set -e

FLUTTER_VERSION="3.44.0"
FLUTTER_ARCH="$ARCH"
if [ "$ARCH" == "amd64" ]; then
    FLUTTER_ARCH="x64"
fi

# Flutter SDK (standard Flutter 3.44.0)
FLUTTER_SDK_PATH="${ROOT}/build/flutter-elinux"
# flutter-elinux tool (community fork ported to Flutter 3.44.0)
FLUTTER_ELINUX_TOOL_PATH="${ROOT}/build/flutter-elinux-tool"

if [ ! -d "$FLUTTER_SDK_PATH" ]; then
    echo "Cloning Flutter SDK ${FLUTTER_VERSION}..."
    git clone https://github.com/flutter/flutter.git \
        "$FLUTTER_SDK_PATH" --depth 1 -b "${FLUTTER_VERSION}"
fi

if [ ! -d "$FLUTTER_ELINUX_TOOL_PATH" ]; then
    echo "Cloning flutter-elinux tool..."
    git clone https://github.com/flutter-elinux/flutter-elinux.git \
        "$FLUTTER_ELINUX_TOOL_PATH" --depth 1
fi

# Always ensure the Flutter 3.44.0 compatibility patch is applied (idempotent)
patch -d "$FLUTTER_ELINUX_TOOL_PATH" -p1 --forward --reject-file=/dev/null \
    < "${ROOT}/patches/flutter-elinux-flutter-344.patch" 2>/dev/null || true

ELINUX_TOOL_STAMP="$FLUTTER_ELINUX_TOOL_PATH/bin/cache/flutter-elinux.snapshot"
if [ ! -f "$ELINUX_TOOL_STAMP" ]; then
    # Symlink the Flutter SDK into the tool directory (expected by flutter-elinux)
    ln -sfn "$FLUTTER_SDK_PATH" "$FLUTTER_ELINUX_TOOL_PATH/flutter"
    # Bootstrap the Flutter SDK (populates bin/cache/dart-sdk)
    "$FLUTTER_SDK_PATH/bin/flutter" --version > /dev/null
    # pub get + compile the flutter-elinux snapshot
    (cd "$FLUTTER_ELINUX_TOOL_PATH" && \
        "$FLUTTER_SDK_PATH/bin/flutter" pub get && \
        mkdir -p bin/cache && \
        "$FLUTTER_SDK_PATH/bin/cache/dart-sdk/bin/dart" \
            --disable-dart-dev --no-enable-mirrors \
            --snapshot="bin/cache/flutter-elinux.snapshot" \
            --packages=".dart_tool/package_config.json" \
            bin/flutter_elinux.dart)
fi

# Wrapper script to invoke the flutter-elinux snapshot via the bundled dart
FLUTTER_ELINUX_BIN="$FLUTTER_ELINUX_TOOL_PATH/bin/flutter-elinux-run"
cat > "$FLUTTER_ELINUX_BIN" << 'WRAPPER'
#!/usr/bin/env bash
set -e
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
exec "$ROOT_DIR/flutter/bin/cache/dart-sdk/bin/dart" \
    --disable-dart-dev \
    --packages="$ROOT_DIR/.dart_tool/package_config.json" \
    "$BIN_DIR/cache/flutter-elinux.snapshot" "$@"
WRAPPER
chmod +x "$FLUTTER_ELINUX_BIN"

export FLUTTER_ROOT="$FLUTTER_SDK_PATH"
export PATH="$PATH:$FLUTTER_SDK_PATH/bin"

FLUFFYCHAT_DIR="${ROOT}/fluffychat"
cd "$FLUFFYCHAT_DIR"

# Get dependencies
flutter pub get

# Copy elinux-specific project files (runner, CMakeLists, etc.)
cp -rT "${ROOT}/fluffychat-elinux" elinux

# Point flutter-elinux at the locally built artifact zips
# (assembled by postbuild-flutter-embedded-linux.sh after the cmake library build)
ZIPS_DIR="${ROOT}/build/elinux-artifact-zips"
if [ ! -d "$ZIPS_DIR" ] || [ ! -f "$ZIPS_DIR/elinux-${FLUTTER_ARCH}-release.zip" ]; then
    echo "ERROR: elinux artifact zips not found at ${ZIPS_DIR}"
    echo "The flutter_elinux library must be built first (clickable builds libraries before the main app)."
    exit 1
fi
export ELINUX_ENGINE_BASE_LOCAL_DIRECTORY="$ZIPS_DIR"

# Populate the flutter-elinux tool's artifact cache from local zips.
# Clear ephemeral dir and elinux precache first so the correct arch is used.
rm -rf "${FLUFFYCHAT_DIR}/elinux/flutter/ephemeral"
rm -rf "${FLUTTER_ELINUX_TOOL_PATH}/flutter/bin/cache/artifacts/engine/elinux-"*
"$FLUTTER_ELINUX_BIN" precache --elinux --no-android --no-ios --no-web \
    --no-linux --no-macos --no-windows --no-fuchsia

# Build — produces build/elinux/<arch>/release/bundle/
# Suppress -Werror in the elinux CMakeLists.txt so third-party plugins compile
# cleanly (APPLY_STANDARD_SETTINGS sets -Wall -Werror which triggers in some plugins).
sed -i 's/-Wall -Werror/-Wall/' "${FLUFFYCHAT_DIR}/elinux/CMakeLists.txt"
"$FLUTTER_ELINUX_BIN" build elinux --release --target-arch=${FLUTTER_ARCH}

cp -r "build/elinux/${FLUTTER_ARCH}/release/bundle/"* "${INSTALL_DIR}/"

# Install packaging metadata
cp ${ROOT}/manifest.json ${INSTALL_DIR}/manifest.json
cp ${ROOT}/fluffychat.{desktop,apparmor} ${INSTALL_DIR}/
install -D ${FLUFFYCHAT_DIR}/assets/logo.svg ${INSTALL_DIR}/assets/logo.svg
