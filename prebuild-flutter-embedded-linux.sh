#!/bin/bash
# Verify pre-built Flutter release engine artifacts and copy libflutter_engine.so
# into the embedder source tree for the cmake library build.
set -e

ARCH="${ARCH:-amd64}"
ENGINE_DIR="${ROOT}/build/engine-artifacts/${ARCH}"

for artifact in libflutter_engine.so gen_snapshot icudtl.dat include/flutter_embedder.h; do
    if [ ! -f "${ENGINE_DIR}/${artifact}" ]; then
        echo "ERROR: ${ENGINE_DIR}/${artifact} not found."
        echo "Build the Flutter release engine first (see CI 'Build Flutter release engine' step)."
        exit 1
    fi
done

echo "Engine artifacts:"
ls -lh "${ENGINE_DIR}/"

# Copy libflutter_engine.so into the embedder source tree so cmake can find it
# (flutter-embedded-linux/cmake/build.cmake looks for build/libflutter_engine.so)
mkdir -p "${SRC_DIR}/build"
cp "${ENGINE_DIR}/libflutter_engine.so" "${SRC_DIR}/build/libflutter_engine.so"
