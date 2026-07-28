// Copyright 2022 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <stdlib.h>
#include <iostream>
#include <memory>
#include <string>

#include "flutter_embedder_options.h"
#include "flutter_window.h"

// AppArmor only lets a click app write under $HOME/{.local/share,.cache}/<pkg>.
// path_provider_linux asks GApplication for that name, but there is no
// GApplication on elinux, so it falls back to the executable name and lands on
// a denied path. Point the XDG dirs at the confined ones instead.
static void SetConfinedXdgDirs() {
  // ubuntu-app-launch exports APP_ID as <pkgname>_<appname>_<version>.
  const char* app_id = getenv("APP_ID");
  const char* home = getenv("HOME");
  if (!app_id || !home) {
    return;
  }
  const std::string package = std::string(app_id).substr(
      0, std::string(app_id).find('_'));
  if (package.empty()) {
    return;
  }
  setenv("XDG_DATA_HOME",
         (std::string(home) + "/.local/share/" + package).c_str(), 1);
  setenv("XDG_CACHE_HOME", (std::string(home) + "/.cache/" + package).c_str(),
         1);
}

int main(int argc, char** argv) {
  FlutterEmbedderOptions options;
  if (!options.Parse(argc, argv)) {
    return 0;
  }

  // Ubuntu Touch 16.04 workaround for libhybris/Wayland
  setenv("EGL_PLATFORM", "wayland", 0);

  SetConfinedXdgDirs();

  // Creates the Flutter project.
  const auto bundle_path = options.BundlePath();
  const std::wstring fl_path(bundle_path.begin(), bundle_path.end());
  flutter::DartProject project(fl_path);
  auto command_line_arguments = std::vector<std::string>();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  flutter::FlutterViewController::ViewProperties view_properties = {};
  view_properties.width = options.WindowWidth();
  view_properties.height = options.WindowHeight();
  view_properties.view_mode = options.WindowViewMode();
  view_properties.view_rotation = options.WindowRotation();
  view_properties.use_mouse_cursor = options.IsUseMouseCursor();
  view_properties.use_onscreen_keyboard = options.IsUseOnscreenKeyboard();
  view_properties.use_window_decoration = options.IsUseWindowDecoraation();
  view_properties.force_scale_factor = options.IsForceScaleFactor();
  view_properties.scale_factor = options.ScaleFactor();

  // The Flutter instance hosted by this window.
  FlutterWindow window(view_properties, project);
  if (!window.OnCreate()) {
    return 0;
  }
  window.Run();
  window.OnDestroy();

  return 0;
}
