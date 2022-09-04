#!/bin/bash
set -e

RELEASE_TAG="$1"
DST="$2"

FLUTTER_ARCH="$ARCH"
if [ "$FLUTTER_ARCH" == "amd64" ]; then
    FLUTTER_ARCH="x64"
fi

cd ${BUILD_DIR}
if [ ! -f "elinux-${FLUTTER_ARCH}-release.zip" ]; then
    wget "https://github.com/sony/flutter-embedded-linux/releases/download/$RELEASE_TAG/elinux-${FLUTTER_ARCH}-release.zip" -O elinux-${FLUTTER_ARCH}-release.zip
fi

mkdir -p "$DST"
cd "$DST"
unzip -o ${BUILD_DIR}/elinux-${FLUTTER_ARCH}-release.zip libflutter_engine.so
