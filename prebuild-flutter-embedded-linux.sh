#!/bin/bash
# Download libflutter_engine.so + headers from Flutter CDN for the cmake embedder build.
# Only libflutter_engine.so is needed here; libflutter_elinux_wayland.so is built
# by clickable's cmake library step using this engine as input.
set -e

ENGINE_HASH="4c525dac5ebe5971c5708ef73558ed8edcf4a362"
ENGINE_DIR="${ROOT}/build/engine-artifacts"
ARCH="${ARCH:-amd64}"

if [ "$ARCH" = "amd64" ]; then
    FLUTTER_ARCH="x64"
else
    FLUTTER_ARCH="arm64"
fi

BASE_URL="https://storage.googleapis.com/flutter_infra_release/flutter/${ENGINE_HASH}/linux-${FLUTTER_ARCH}"

if [ -f "${ENGINE_DIR}/libflutter_engine.so" ]; then
    echo "Engine artifacts already present at ${ENGINE_DIR}"
else
    echo "Downloading libflutter_engine.so for engine ${ENGINE_HASH} (${FLUTTER_ARCH})..."
    mkdir -p "${ENGINE_DIR}/include"

    # Download embedder zip: contains libflutter_engine.so + flutter_embedder.h
    TMP_ZIP="$(mktemp --suffix=.zip)"
    curl -L "${BASE_URL}/linux-${FLUTTER_ARCH}-embedder.zip" -o "${TMP_ZIP}"
    unzip -jo "${TMP_ZIP}" "libflutter_engine.so" -d "${ENGINE_DIR}/"
    unzip -jo "${TMP_ZIP}" "flutter_embedder.h"  -d "${ENGINE_DIR}/include/"
    rm -f "${TMP_ZIP}"

    # Download artifacts zip: contains icudtl.dat + gen_snapshot
    TMP_ZIP2="$(mktemp --suffix=.zip)"
    curl -L "${BASE_URL}/artifacts.zip" -o "${TMP_ZIP2}"
    unzip -jo "${TMP_ZIP2}" "icudtl.dat"    -d "${ENGINE_DIR}/"
    unzip -jo "${TMP_ZIP2}" "gen_snapshot"  -d "${ENGINE_DIR}/"
    chmod +x "${ENGINE_DIR}/gen_snapshot"
    rm -f "${TMP_ZIP2}"

    echo "Engine artifacts ready:"
    ls -lh "${ENGINE_DIR}/"
fi

# Copy libflutter_engine.so into the embedder source tree so cmake can find it
# (flutter-embedded-linux/cmake/build.cmake looks for build/libflutter_engine.so)
mkdir -p "${SRC_DIR}/build"
cp "${ENGINE_DIR}/libflutter_engine.so" "${SRC_DIR}/build/libflutter_engine.so"
