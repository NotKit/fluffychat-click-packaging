#!/bin/bash
# Package the built libflutter_elinux_wayland.so (and engine artifacts) into
# the zip layout expected by flutter-elinux's ELINUX_ENGINE_BASE_LOCAL_DIRECTORY.
#
# Called by clickable as the library postbuild step.
# Environment: ROOT, BUILD_DIR, INSTALL_DIR, ARCH are set by clickable.
set -e

ENGINE_DIR="${ROOT}/build/engine-artifacts/${ARCH}"
ZIPS_DIR="${ROOT}/build/elinux-artifact-zips"
mkdir -p "${ZIPS_DIR}"

if [ "${ARCH}" = "amd64" ]; then
    FLUTTER_ARCH="x64"
else
    FLUTTER_ARCH="arm64"
fi

# Detect the host architecture.  gen_snapshot is a native host binary;
# flutter-elinux's elinux_artifacts.dart looks for it at
# elinux-{target}-{mode}/linux-{host_arch}/gen_snapshot, so the subdir
# in the zip must match the host we actually run on.
HOST_MACHINE="$(uname -m)"
if [ "${HOST_MACHINE}" = "x86_64" ]; then
    HOST_FLUTTER_ARCH="x64"
else
    HOST_FLUTTER_ARCH="arm64"
fi
GEN_SNAPSHOT_SUBDIR="linux-${HOST_FLUTTER_ARCH}"

# gen_snapshot was downloaded by prebuild from the target-arch artifacts.zip.
# For self-builds (host == target), this is the correct native binary.
GEN_SNAPSHOT="${ENGINE_DIR}/gen_snapshot"
if [ ! -f "${GEN_SNAPSHOT}" ]; then
    echo "ERROR: gen_snapshot not found at ${GEN_SNAPSHOT}"
    exit 1
fi
chmod +x "${GEN_SNAPSHOT}"

ENGINE_LIB="${ENGINE_DIR}/libflutter_engine.so"
if [ ! -f "${ENGINE_LIB}" ]; then
    echo "ERROR: libflutter_engine.so not found at ${ENGINE_LIB}"
    exit 1
fi

# libflutter_elinux_wayland.so is in the cmake build directory.
# (cmake installs libflutter_engine.so but not the embedder .so)
EMBEDDER_LIB="${BUILD_DIR}/libflutter_elinux_wayland.so"
if [ ! -f "${EMBEDDER_LIB}" ]; then
    echo "ERROR: libflutter_elinux_wayland.so not found in BUILD_DIR=${BUILD_DIR}"
    exit 1
fi
echo "Using embedder lib: ${EMBEDDER_LIB}"

echo "Packaging elinux artifacts into zip layout for flutter-elinux tool..."

make_arch_zip() {
    local ARCH_NAME="$1"   # x64 or arm64
    local MODE="$2"        # release, debug, profile
    local ZIP="${ZIPS_DIR}/elinux-${ARCH_NAME}-${MODE}.zip"
    local TMP
    TMP="$(mktemp -d)"
    mkdir -p "${TMP}/${GEN_SNAPSHOT_SUBDIR}"
    cp "${EMBEDDER_LIB}"  "${TMP}/libflutter_elinux_wayland.so"
    cp "${ENGINE_LIB}"    "${TMP}/libflutter_engine.so"
    cp "${GEN_SNAPSHOT}"  "${TMP}/${GEN_SNAPSHOT_SUBDIR}/gen_snapshot"
    (cd "${TMP}" && zip -r "${ZIP}" .)
    rm -rf "${TMP}"
    echo "  Created: ${ZIP}"
}

# flutter-elinux precache unconditionally downloads all 6 arch+mode zips.
# We only build for the target arch; the other arch zips are stubs
# (same libs reused) and are never used at runtime on the target device.
for ARCH_NAME in x64 arm64; do
    for MODE in release debug profile; do
        make_arch_zip "${ARCH_NAME}" "${MODE}"
    done
done

# --- elinux-common.zip ---
# Contents:
#   icu/icudtl.dat                (from Flutter CDN)
#   cpp_client_wrapper/           (C++ wrapper sources from flutter-embedded-linux)
#   flutter_elinux.h etc.         (public headers from flutter-embedded-linux)
COMMON_ZIP="${ZIPS_DIR}/elinux-common.zip"
COMMON_TMP="$(mktemp -d)"
mkdir -p "${COMMON_TMP}/icu"
cp "${ENGINE_DIR}/icudtl.dat" "${COMMON_TMP}/icu/icudtl.dat"

EMBEDDED_SRC="${ROOT}/flutter-embedded-linux"

# elinux public headers (flutter_elinux.h, flutter_platform_views.h)
if [ -d "${EMBEDDED_SRC}/src/flutter/shell/platform/linux_embedded/public" ]; then
    cp "${EMBEDDED_SRC}/src/flutter/shell/platform/linux_embedded/public/"*.h \
       "${COMMON_TMP}/" 2>/dev/null || true
fi
# Common public headers (flutter_export.h, flutter_messenger.h, etc.)
if [ -d "${EMBEDDED_SRC}/src/flutter/shell/platform/common/public" ]; then
    cp "${EMBEDDED_SRC}/src/flutter/shell/platform/common/public/"*.h \
       "${COMMON_TMP}/" 2>/dev/null || true
fi

mkdir -p "${COMMON_TMP}/cpp_client_wrapper"
# Common client_wrapper sources (core_implementations.cc, standard_codec.cc, etc.)
if [ -d "${EMBEDDED_SRC}/src/flutter/shell/platform/common/client_wrapper" ]; then
    cp -r "${EMBEDDED_SRC}/src/flutter/shell/platform/common/client_wrapper/." \
       "${COMMON_TMP}/cpp_client_wrapper/"
fi
# elinux-specific client_wrapper sources (flutter_engine.cc, flutter_view_controller.cc)
if [ -d "${EMBEDDED_SRC}/src/client_wrapper" ]; then
    cp -r "${EMBEDDED_SRC}/src/client_wrapper/." \
       "${COMMON_TMP}/cpp_client_wrapper/"
fi

(cd "${COMMON_TMP}" && zip -r "${COMMON_ZIP}" .)
rm -rf "${COMMON_TMP}"
echo "  Created: ${COMMON_ZIP}"

echo "Done. Artifact zips in: ${ZIPS_DIR}"
