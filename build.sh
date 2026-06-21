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

# Drop the loading dialog around the interactive file picker so the content-hub
# picker route isn't covered by a modal (idempotent via --forward).
patch -p1 --forward --reject-file=/dev/null \
    < "${ROOT}/patches/fluffychat-content-hub-picker.patch" 2>/dev/null || true

# Add content-hub file picker plugin (elinux-only; not in FluffyChat's pubspec).
# Guard against re-runs: flutter pub add fails if the dep is already present.
if ! grep -q 'content_hub_file_picker' pubspec.yaml; then
    flutter pub add content_hub_file_picker --path="${ROOT}/content_hub_file_picker"
fi

# Get dependencies
flutter pub get

# Copy elinux-specific project files (runner, CMakeLists, etc.)
cp -rT "${ROOT}/fluffychat-elinux" elinux

# Per-arch dirs prevent parallel amd64/arm64 builds from clobbering each other.
ARCH_ZIPS_DIR="${ROOT}/build/elinux-artifact-zips/${ARCH}"
if [ ! -d "$ARCH_ZIPS_DIR" ] || [ ! -f "$ARCH_ZIPS_DIR/elinux-${FLUTTER_ARCH}-release.zip" ]; then
    echo "ERROR: elinux artifact zips not found at ${ARCH_ZIPS_DIR}"
    echo "The flutter_elinux library must be built first (clickable builds libraries before the main app)."
    exit 1
fi

# flutter-elinux precache requires all 6 arch+mode zips; stub the other arch
# with copies of the current one (stubs are never executed on the device).
ZIPS_DIR="${ROOT}/build/elinux-artifact-zips-merged"
rm -rf "$ZIPS_DIR"
mkdir -p "$ZIPS_DIR"
cp "${ARCH_ZIPS_DIR}/"*.zip "${ZIPS_DIR}/"
OTHER_ARCH="arm64"; [ "${FLUTTER_ARCH}" = "arm64" ] && OTHER_ARCH="x64"
for MODE in release debug profile; do
    cp "${ARCH_ZIPS_DIR}/elinux-${FLUTTER_ARCH}-${MODE}.zip" \
       "${ZIPS_DIR}/elinux-${OTHER_ARCH}-${MODE}.zip"
done
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

# flutter_webrtc ships libwebrtc.so as a symlink; CMake installs it verbatim so it
# arrives broken. Resolve and copy the real .so from the pub package cache.
WEBRTC_REAL="$(python3 -c "
import json, os, sys
cfg = json.load(open('.dart_tool/package_config.json'))
pkg = next((p for p in cfg['packages'] if p['name'] == 'flutter_webrtc'), None)
if not pkg:
    sys.exit(1)
root = pkg['rootUri']
if root.startswith('file://'):
    root = root[7:]
elif not root.startswith('/'):
    root = os.path.normpath(os.path.join('.dart_tool', root))
src = os.path.join(root, 'third_party/libwebrtc/lib/linux-${FLUTTER_ARCH}/libwebrtc.so')
if not os.path.isfile(src):
    sys.exit(1)
print(src)
" 2>/dev/null)"
if [ -z "$WEBRTC_REAL" ]; then
    echo "ERROR: could not locate libwebrtc.so in flutter_webrtc pub package" >&2
    exit 1
fi
cp --remove-destination "$WEBRTC_REAL" "${INSTALL_DIR}/lib/libwebrtc.so"

# flutter_vodozemac declares only a `linux` ffiPlugin (not `elinux`), so flutter-elinux
# never builds or bundles libvodozemac_bindings_dart.so. flutter_rust_bridge opens it via
# a CWD-relative path, so it must live at bundle root, not lib/.
VODOZEMAC_RUST="$(python3 -c "
import json, os, sys
cfg = json.load(open('.dart_tool/package_config.json'))
pkg = next((p for p in cfg['packages'] if p['name'] == 'flutter_vodozemac'), None)
if not pkg:
    sys.exit(1)
root = pkg['rootUri']
if root.startswith('file://'):
    root = root[7:]
elif not root.startswith('/'):
    root = os.path.normpath(os.path.join('.dart_tool', root))
src = os.path.join(root, 'rust')
if not os.path.isfile(os.path.join(src, 'Cargo.toml')):
    sys.exit(1)
print(src)
" 2>/dev/null)"
if [ -z "$VODOZEMAC_RUST" ]; then
    echo "ERROR: could not locate flutter_vodozemac rust crate" >&2
    exit 1
fi

# Ubuntu 20.04's apt rustc is too old for edition 2021 / flutter_rust_bridge; use rustup.
export RUSTUP_HOME="${ROOT}/build/rustup" CARGO_HOME="${ROOT}/build/cargo"
export PATH="${CARGO_HOME}/bin:${PATH}"
if [ ! -x "${CARGO_HOME}/bin/rustup" ]; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
fi
# Ensure a default toolchain: a cached rustup dir may have proxies but no configured default.
rustup default stable

CARGO_TARGET_DIR="${ROOT}/build/vodozemac-target" \
    cargo build --release --manifest-path "${VODOZEMAC_RUST}/Cargo.toml"
cp "${ROOT}/build/vodozemac-target/release/libvodozemac_bindings_dart.so" \
   "${INSTALL_DIR}/libvodozemac_bindings_dart.so"

# sqlcipher_flutter_libs is a linux-only plugin, skipped by flutter-elinux. Build the
# v4.6.1 amalgamation directly: it is the last version with OpenSSL 1.1 HMAC_CTX_new
# support (v4.7+ hard-codes EVP_MAC which doesn't compile against libssl-dev 1.1).
SQLCIPHER_SRC_URL="https://fsn1.your-objectstorage.com/simon-public/assets/sqlcipher/v4_6_1.c"
SQLCIPHER_SRC_SHA512="6c401bb020ceff69ea79dfde3f5ddf8802fb7dcd9da589b92de34a283a28f0802b98f28a87fbcb7b8bfa3bedb180dfd6d183eed567bbf12eea4f311e266f2e72"
SQLCIPHER_DIR="${ROOT}/build/sqlcipher-${ARCH}"
mkdir -p "$SQLCIPHER_DIR"
if [ ! -f "$SQLCIPHER_DIR/sqlcipher.c" ]; then
    curl -sSL "$SQLCIPHER_SRC_URL" -o "$SQLCIPHER_DIR/sqlcipher.c"
    echo "${SQLCIPHER_SRC_SHA512}  ${SQLCIPHER_DIR}/sqlcipher.c" | sha512sum -c -
fi
if [ ! -f "$SQLCIPHER_DIR/libsqlcipher.so" ]; then
    ${CC:-cc} -shared -fPIC -O3 \
        -DSQLITE_HAS_CODEC \
        -DHAVE_STDINT_H -DSQLITE_DQS=0 -DSQLITE_THREADSAFE=1 \
        -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_TEMP_STORE=2 -DSQLITE_MAX_EXPR_DEPTH=0 \
        -DSQLITE_OMIT_AUTHORIZATION -DSQLITE_OMIT_DECLTYPE -DSQLITE_OMIT_DEPRECATED \
        -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE \
        -DSQLITE_OMIT_TCL_VARIABLE -DSQLITE_OMIT_TRACE -DSQLITE_USE_ALLOCA \
        -DSQLITE_UNTESTABLE -DSQLITE_HAVE_ISNAN -DSQLITE_ENABLE_DBSTAT_VTAB \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE \
        "$SQLCIPHER_DIR/sqlcipher.c" \
        -o "$SQLCIPHER_DIR/libsqlcipher.so" \
        -lcrypto -lpthread -ldl -lm
fi
cp "$SQLCIPHER_DIR/libsqlcipher.so" "${INSTALL_DIR}/lib/libsqlcipher.so"

# Engine has no DT_RUNPATH; patch $ORIGIN so FFI bare-soname dlopens find lib/.
patchelf --set-rpath '$ORIGIN' "${INSTALL_DIR}/lib/libflutter_engine.so"

# Install packaging metadata
cp ${ROOT}/manifest.json ${INSTALL_DIR}/manifest.json
cp ${ROOT}/fluffychat.{desktop,apparmor} ${INSTALL_DIR}/
install -D ${FLUFFYCHAT_DIR}/assets/logo.svg ${INSTALL_DIR}/assets/logo.svg
