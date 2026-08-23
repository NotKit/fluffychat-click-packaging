// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_WINDOW_
#define FLUTTER_WINDOW_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "app_url_service.h"

class FlutterWindow {
 public:
  explicit FlutterWindow(
      const flutter::FlutterViewController::ViewProperties view_properties,
      const flutter::DartProject project);
  ~FlutterWindow() = default;

  // Prevent copying.
  FlutterWindow(FlutterWindow const&) = delete;
  FlutterWindow& operator=(FlutterWindow const&) = delete;

  bool OnCreate();
  void OnDestroy();
  void Run();

  // URL the app was launched with, delivered to Dart once it asks for it.
  void SetInitialUrl(const std::string& url) { initial_url_ = url; }

 private:
  void DeliverUrl(const std::string& url);

  flutter::FlutterViewController::ViewProperties view_properties_;
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_view_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> url_channel_;
  AppUrlService url_service_;
  std::string initial_url_;
};

#endif  // FLUTTER_WINDOW_
