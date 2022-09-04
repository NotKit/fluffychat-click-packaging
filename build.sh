#!/bin/bash
set -e

RELEASE_TAG="$1"

FLUTTER_ARCH="$ARCH"
if [ "$ARCH" == "amd64" ]; then
    FLUTTER_ARCH="x64"
fi

FLUTTER_PATH="${ROOT}/build/flutter-elinux"

[ -d "$FLUTTER_PATH" ] || git clone https://github.com/sony/flutter-elinux.git "$FLUTTER_PATH" -b "$RELEASE_TAG" --depth 1

PATH="$PATH:$FLUTTER_PATH/bin"

flutter-elinux doctor

cd "$SRC_DIR"
cp -rT "${ROOT}/fluffychat-elinux" elinux

flutter-elinux pub get
flutter-elinux build elinux --target-arch=${FLUTTER_ARCH}

cp -r build/elinux/${FLUTTER_ARCH}/release/bundle/* ${INSTALL_DIR}/
cp ${FLUTTER_ELINUX_LIB_BUILD_DIR}/libflutter_elinux_wayland.so ${INSTALL_DIR}/lib/libflutter_elinux_wayland.so

cp ${ROOT}/manifest.json ${INSTALL_DIR}/manifest.json
cp ${ROOT}/fluffychat.{desktop,apparmor} ${INSTALL_DIR}/
install -D ${SRC_DIR}/assets/logo.svg ${INSTALL_DIR}/assets/logo.svg
