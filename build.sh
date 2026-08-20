#!/bin/bash
# Build FluffyChat for Ubuntu Touch using flutter-elinux
set -e

FLUTTER_VERSION="3.44.0"
FLUTTER_ARCH="$ARCH"
if [ "$ARCH" == "amd64" ]; then
    FLUTTER_ARCH="x64"
elif [ "$ARCH" == "armhf" ]; then
    FLUTTER_ARCH="arm"
fi

# Flutter SDK (standard Flutter 3.44.0)
FLUTTER_SDK_PATH="${ROOT}/build/flutter-elinux"
# flutter-elinux tool (community fork ported to Flutter 3.44.0)
FLUTTER_ELINUX_TOOL_PATH="${ROOT}/build/flutter-elinux-tool"
# Pinned: the tool's master follows newer Flutter SDKs than the one above (it is
# on 3.47 now, whose build_system API the 3.44 SDK does not have), and the
# patches below are written against this revision.
FLUTTER_ELINUX_TOOL_REV="11d98705806267afa8e5f24357be9c8d2b15938a"

if [ ! -d "$FLUTTER_SDK_PATH" ]; then
    echo "Cloning Flutter SDK ${FLUTTER_VERSION}..."
    git clone https://github.com/flutter/flutter.git \
        "$FLUTTER_SDK_PATH" --depth 1 -b "${FLUTTER_VERSION}"
fi

if [ ! -d "$FLUTTER_ELINUX_TOOL_PATH" ]; then
    echo "Cloning flutter-elinux tool at ${FLUTTER_ELINUX_TOOL_REV}..."
    git init -q "$FLUTTER_ELINUX_TOOL_PATH"
    git -C "$FLUTTER_ELINUX_TOOL_PATH" remote add origin \
        https://github.com/flutter-elinux/flutter-elinux.git
    git -C "$FLUTTER_ELINUX_TOOL_PATH" fetch -q --depth 1 origin \
        "$FLUTTER_ELINUX_TOOL_REV"
    git -C "$FLUTTER_ELINUX_TOOL_PATH" checkout -q FETCH_HEAD
fi

ELINUX_TOOL_STAMP="$FLUTTER_ELINUX_TOOL_PATH/bin/cache/flutter-elinux.snapshot"

# Always ensure the tool and SDK patches are applied (idempotent). A newly
# applied patch invalidates the compiled tool snapshot so it gets rebuilt.
apply_patch() {
    if patch -d "$1" -p1 --forward --reject-file=/dev/null \
        < "$2" >/dev/null 2>&1; then
        rm -f "$ELINUX_TOOL_STAMP"
    fi
}
# Flutter 3.44.0 compatibility
apply_patch "$FLUTTER_ELINUX_TOOL_PATH" "${ROOT}/patches/flutter-elinux-flutter-344.patch"
# 32-bit ARM (armhf) target support
apply_patch "$FLUTTER_ELINUX_TOOL_PATH" "${ROOT}/patches/flutter-elinux-armhf.patch"
# Run the packages' Dart build hooks (package:sqlite3 needs them)
apply_patch "$FLUTTER_ELINUX_TOOL_PATH" "${ROOT}/patches/flutter-elinux-native-assets.patch"
# android_arm stands in for 32-bit ARM Linux in the elinux build; drop its
# Android-only softfp gen_snapshot flags (UT armhf is hardfp).
apply_patch "$FLUTTER_SDK_PATH" "${ROOT}/patches/flutter-tools-arm32-hardfp.patch"
# Build hooks: no CMake app build to read a compiler config from
apply_patch "$FLUTTER_SDK_PATH" "${ROOT}/patches/flutter-tools-hooks-no-cmake.patch"
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

# Register a Matrix pusher against the UBports push gateway using the token
# from lomiri_push_client, and send the full payload format (not event_id_only)
# since the click's push helper renders the notification from those fields.
patch -p1 --forward --reject-file=/dev/null \
    < "${ROOT}/patches/fluffychat-lomiri-push.patch" 2>/dev/null || true

# package:sqlite3 no longer dlopens by name: it declares a native asset built by
# its own hook, which by default downloads a prebuilt SQLCipher for the target.
# Point it at the system instead, so it resolves libsqlcipher.so - the one this
# script builds and installs below - through a plain dlopen.
python3 - << 'PY'
path = 'pubspec.yaml'
with open(path) as f:
    text = f.read()
want = "    sqlite3:\n      source: system\n      name: sqlcipher\n"
have = "    sqlite3:\n      source: sqlcipher\n"
if want not in text:
    if have not in text:
        raise SystemExit(
            'ERROR: the sqlite3 hook user_defines block in pubspec.yaml is not '
            'what this script expects; check what upstream changed'
        )
    with open(path, 'w') as f:
        f.write(text.replace(have, want))
PY

# Add content-hub file picker plugin (elinux-only; not in FluffyChat's pubspec).
# Guard against re-runs: flutter pub add fails if the dep is already present.
if ! grep -q 'content_hub_file_picker' pubspec.yaml; then
    flutter pub add content_hub_file_picker --path="${ROOT}/content_hub_file_picker"
fi

# Add the elinux url_launcher native backend (elinux-only). It supplies the
# native handler for url_launcher_linux's pigeon channels, which is otherwise
# missing on elinux (the GTK url_launcher_linux plugin is never compiled here),
# so tapping links does nothing. Routes via the Ubuntu Touch URL dispatcher.
if ! grep -q 'url_launcher_elinux' pubspec.yaml; then
    flutter pub add url_launcher_elinux --path="${ROOT}/url_launcher_elinux"
fi

# Add a no-op elinux backend for window_to_front. flutter_web_auth_2's SSO/OIDC
# server flow calls WindowToFront.activate() right after capturing the login
# token; window_to_front's GTK linux plugin isn't compiled for elinux, so that
# channel would throw MissingPluginException and abort the login. This shim
# answers the channel as a no-op so the flow completes.
if ! grep -q 'window_to_front_elinux' pubspec.yaml; then
    flutter pub add window_to_front_elinux --path="${ROOT}/window_to_front_elinux"
fi

# Add the Lomiri push notification client (elinux-only). Registers with
# lomiri-push-service to get this device's push token, which background_push
# then hands to the homeserver as the Matrix pushkey.
if ! grep -q 'lomiri_push_client' pubspec.yaml; then
    flutter pub add lomiri_push_client --path="${ROOT}/lomiri_push_client"
fi

# Get dependencies
flutter pub get

# webrtc-sdk publishes no 32-bit ARM libwebrtc prebuilt, so the flutter_webrtc
# native plugin cannot link on armhf. Strip its elinux platform entry from the
# pub-cache pubspec so the plugin registrant and native build skip it; the
# Dart side stays bundled and calls fail with a missing-plugin error only when
# (experimental, off by default) VoIP is actually used.
if [ "$ARCH" == "armhf" ]; then
    python3 - << 'PY'
import json, os, re
cfg = json.load(open('.dart_tool/package_config.json'))
pkg = next(p for p in cfg['packages'] if p['name'] == 'flutter_webrtc')
root = pkg['rootUri']
if root.startswith('file://'):
    root = root[7:]
elif not root.startswith('/'):
    root = os.path.normpath(os.path.join('.dart_tool', root))
path = os.path.join(root, 'pubspec.yaml')
with open(path) as f:
    text = f.read()
text, n = re.subn(r'\n      elinux:\n(        .*\n)+', '\n', text)
if n:
    with open(path, 'w') as f:
        f.write(text)
    print('Stripped elinux platform from', path)
# Assert the invariant rather than the substitution count: the pub cache
# persists, so a rebuild finds it already stripped (n == 0, still fine).
if re.search(r'\n      elinux:\n', text):
    raise SystemExit(f'ERROR: could not strip the elinux platform from {path}')
PY
fi

# Copy elinux-specific project files (runner, CMakeLists, etc.)
cp -rT "${ROOT}/fluffychat-elinux" elinux

# Per-arch dirs prevent parallel amd64/arm64 builds from clobbering each other.
ARCH_ZIPS_DIR="${ROOT}/build/elinux-artifact-zips/${ARCH}"
if [ ! -d "$ARCH_ZIPS_DIR" ] || [ ! -f "$ARCH_ZIPS_DIR/elinux-${FLUTTER_ARCH}-release.zip" ]; then
    echo "ERROR: elinux artifact zips not found at ${ARCH_ZIPS_DIR}"
    echo "The flutter_elinux library must be built first (clickable builds libraries before the main app)."
    exit 1
fi

# flutter-elinux precache requires all arch+mode zips; stub the other arches
# with copies of the current one (stubs are never executed on the device).
ZIPS_DIR="${ROOT}/build/elinux-artifact-zips-merged"
rm -rf "$ZIPS_DIR"
mkdir -p "$ZIPS_DIR"
cp "${ARCH_ZIPS_DIR}/"*.zip "${ZIPS_DIR}/"
for OTHER_ARCH in x64 arm64 arm; do
    [ "${OTHER_ARCH}" = "${FLUTTER_ARCH}" ] && continue
    for MODE in release debug profile; do
        cp "${ARCH_ZIPS_DIR}/elinux-${FLUTTER_ARCH}-${MODE}.zip" \
           "${ZIPS_DIR}/elinux-${OTHER_ARCH}-${MODE}.zip"
    done
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

# The engine and gen_snapshot in build/engine-artifacts must both come from the
# same --runtime-mode=release engine build (the one CI does). Flutter's official
# linux artifacts are a JIT engine plus a non-product gen_snapshot, and either one
# mixed in builds a click that aborts on the device, so check the flags the
# snapshot asks the VM for here instead.
python3 - "${INSTALL_DIR}/lib/libapp.so" "${FLUTTER_ARCH}" << 'PY'
import re, sys
path, arch = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    m = re.search(rb'(?:product|release)[ a-z0-9_-]*no-asan no-msan[ a-z0-9_-]*', f.read())
flags = m.group().decode() if m else '<not found>'
want = f'{arch} linux no-compressed-pointers'
if not (flags.startswith('product ') and flags.endswith(want)):
    sys.exit(
        f'ERROR: libapp.so was produced by the wrong gen_snapshot.\n'
        f'  snapshot requires: {flags}\n'
        f'  expected:          product ... {want}\n'
        f'  libflutter_engine.so and gen_snapshot in build/engine-artifacts/ must\n'
        f'  both come from the release engine build in .github/workflows/build.yml.'
    )
PY

# Code assets from the packages' build hooks land beside the bundle, not in it.
# Put them with the other libraries, where the bare-soname dlopen the manifest
# asks for will find them (the engine's rpath is $ORIGIN).
if [ "$ARCH" != "armhf" ] && compgen -G "build/elinux/native_assets/linux/*.so" > /dev/null; then
    cp -a build/elinux/native_assets/linux/*.so "${INSTALL_DIR}/lib/"
fi

# flutter-elinux has no 32-bit ARM target platform (it maps arm to linux-x64),
# so the hooks ran, and the manifest was written, for x64. Retarget the entries
# that are only a dlopen by name - the SQLCipher one is - and drop the rest:
# those are real x86 libraries, and shipping them just moves the failure to the
# device.
if [ "$ARCH" == "armhf" ]; then
    python3 - << 'PY'
import json, os
path = os.path.join(
    os.environ['INSTALL_DIR'], 'data/flutter_assets/NativeAssetsManifest.json'
)
with open(path) as f:
    manifest = json.load(f)
assets = manifest['native-assets']
if list(assets) != ['linux_x64']:
    raise SystemExit(
        f'ERROR: expected a single linux_x64 entry in {path}, got {list(assets)}'
    )
portable = {}
for asset_id, value in assets['linux_x64'].items():
    if value[0] in ('system', 'process', 'executable'):
        portable[asset_id] = value
    else:
        print(f'Dropping x86 code asset {asset_id} from the armhf manifest')
manifest['native-assets'] = {'linux_arm': portable}
with open(path, 'w') as f:
    json.dump(manifest, f)
PY
fi

# Copy the real libwebrtc.so from the pub package cache over the bundled one.
# Its location moved in flutter_webrtc 1.5.2 (lib/libwebrtc.so) from the older
# arch-subdir layout (lib/linux-<arch>/libwebrtc.so); try both.
# armhf has no libwebrtc prebuilt and builds without the webrtc plugin.
if [ "$ARCH" != "armhf" ]; then
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
candidates = [
    os.path.join(root, 'third_party/libwebrtc/lib/libwebrtc.so'),
    os.path.join(root, 'third_party/libwebrtc/lib/linux-${FLUTTER_ARCH}/libwebrtc.so'),
]
src = next((c for c in candidates if os.path.isfile(c)), None)
if not src:
    sys.exit(1)
print(src)
" 2>/dev/null)"
if [ -z "$WEBRTC_REAL" ]; then
    echo "ERROR: could not locate libwebrtc.so in flutter_webrtc pub package" >&2
    exit 1
fi
cp --remove-destination "$WEBRTC_REAL" "${INSTALL_DIR}/lib/libwebrtc.so"
fi

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

# Build for an explicit target triple ($ARCH_RUST comes from clickable): cross
# containers (armhf, local arm64) are amd64 hosts with a cross gcc in $CC, where
# a bare `cargo build` would compile for the host triple while cc-rs shells out
# to the cross compiler.
RUST_TARGET="${ARCH_RUST:-}"
if [ -z "$RUST_TARGET" ]; then
    echo "ERROR: ARCH_RUST is not set; clickable should provide it" >&2
    exit 1
fi
rustup target add "$RUST_TARGET"
if [ -n "${CC:-}" ]; then
    RUST_TARGET_ENV="$(echo "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"
    export "CARGO_TARGET_${RUST_TARGET_ENV}_LINKER=$CC"
fi

CARGO_TARGET_DIR="${ROOT}/build/vodozemac-target" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "${VODOZEMAC_RUST}/Cargo.toml"
cp "${ROOT}/build/vodozemac-target/${RUST_TARGET}/release/libvodozemac_bindings_dart.so" \
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

# Install packaging metadata. Stamp the click version with the upstream
# FluffyChat version (from pubspec) instead of a fixed 1.0.0; strip the +build
# suffix so it's a clean Debian upstream version (e.g. 2.8.0). The packaging
# revision from ./packaging-revision is appended, so packaging-only fixes can
# ship as 2.8.0-2 without an upstream release.
FLUFFYCHAT_VERSION="$(grep -m1 '^version:' "${FLUFFYCHAT_DIR}/pubspec.yaml" \
    | sed -E 's/^version:[[:space:]]*//; s/\+.*//')"
if [ -z "$FLUFFYCHAT_VERSION" ]; then
    echo "ERROR: could not parse version from fluffychat/pubspec.yaml" >&2
    exit 1
fi
PACKAGING_REVISION="$(tr -d '[:space:]' < "${ROOT}/packaging-revision")"
if [ -z "$PACKAGING_REVISION" ]; then
    echo "ERROR: ./packaging-revision is empty" >&2
    exit 1
fi
CLICK_VERSION="${FLUFFYCHAT_VERSION}-${PACKAGING_REVISION}"
cp ${ROOT}/manifest.json ${INSTALL_DIR}/manifest.json
sed -i "s/@CLICK_VERSION@/${CLICK_VERSION}/" ${INSTALL_DIR}/manifest.json
cp ${ROOT}/fluffychat.{desktop,apparmor} ${INSTALL_DIR}/
cp ${ROOT}/url-dispatcher.json ${INSTALL_DIR}/

# Push helper: lomiri-push-service execs this with an input and an output file
# to turn a Matrix push gateway payload into a notification. It is a plain
# standalone binary — no Flutter, no Qt — so build it directly here rather than
# through the Flutter toolchain. "exec" in push.json is relative to this dir.
mkdir -p ${INSTALL_DIR}/push
${CXX:-c++} -std=c++11 -O2 -s -I ${ROOT}/push ${ROOT}/push/push.cpp \
    -o ${INSTALL_DIR}/push/push
cp ${ROOT}/push/push.json ${ROOT}/push/push-apparmor.json ${INSTALL_DIR}/push/
# logo.svg moved under assets/logo/vector/ in 2.8.0; install to the same
# destination the desktop file's Icon= still points at.
install -D ${FLUFFYCHAT_DIR}/assets/logo/vector/logo.svg ${INSTALL_DIR}/assets/logo.svg
