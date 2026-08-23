// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter_window.h"

#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr char kUrlChannelName[] = "fluffychat/url";
}  // namespace

FlutterWindow::FlutterWindow(
    const flutter::FlutterViewController::ViewProperties view_properties,
    const flutter::DartProject project)
    : view_properties_(view_properties), project_(project) {}

bool FlutterWindow::OnCreate() {
  flutter_view_controller_ = std::make_unique<flutter::FlutterViewController>(
      view_properties_, project_);

  // Ensure that basic setup of the controller was successful.
  if (!flutter_view_controller_->engine() ||
      !flutter_view_controller_->view()) {
    return false;
  }

  // Register Flutter plugins.
  RegisterPlugins(flutter_view_controller_->engine());

  // Channel for URLs dispatched to the app (a tapped push notification). Dart
  // pulls the launch URL with getInitialUrl, because it only installs its
  // handler once the app is up, and later ones arrive as openUrl.
  url_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_view_controller_->engine()->messenger(), kUrlChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  url_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialUrl") {
          if (initial_url_.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(initial_url_));
            initial_url_.clear();
          }
          return;
        }
        result->NotImplemented();
      });

  url_service_.Start();

  return true;
}

void FlutterWindow::DeliverUrl(const std::string& url) {
  if (!url_channel_) {
    return;
  }
  url_channel_->InvokeMethod(
      "openUrl", std::make_unique<flutter::EncodableValue>(url));
}

void FlutterWindow::OnDestroy() {
  if (flutter_view_controller_) {
    flutter_view_controller_ = nullptr;
  }
}

void FlutterWindow::Run() {
  // Main loop.
  auto next_flutter_event_time =
      std::chrono::steady_clock::time_point::clock::now();
  while (flutter_view_controller_->view()->DispatchEvent()) {
    // URLs arrive on the D-Bus thread; hand them over here, on the platform
    // thread, which is the only one allowed to touch the channel.
    for (const auto& url : url_service_.TakeUrls()) {
      DeliverUrl(url);
    }

    // Wait until the next event.
    {
      auto wait_duration =
          std::max(std::chrono::nanoseconds(0),
                   next_flutter_event_time -
                       std::chrono::steady_clock::time_point::clock::now());
      std::this_thread::sleep_for(
          std::chrono::duration_cast<std::chrono::milliseconds>(wait_duration));
    }

    // Processes any pending events in the Flutter engine, and returns the
    // number of nanoseconds until the next scheduled event (or max, if none).
    auto wait_duration = flutter_view_controller_->engine()->ProcessMessages();
    {
      auto next_event_time = std::chrono::steady_clock::time_point::max();
      if (wait_duration != std::chrono::nanoseconds::max()) {
        next_event_time =
            std::min(next_event_time,
                     std::chrono::steady_clock::time_point::clock::now() +
                         wait_duration);
      } else {
        // Wait for the next frame if no events.
        auto frame_rate = flutter_view_controller_->view()->GetFrameRate();
        next_event_time = std::min(
            next_event_time,
            std::chrono::steady_clock::time_point::clock::now() +
                std::chrono::milliseconds(
                    static_cast<int>(std::trunc(1000000.0 / frame_rate))));
      }
      next_flutter_event_time =
          std::max(next_flutter_event_time, next_event_time);
    }
  }
}
