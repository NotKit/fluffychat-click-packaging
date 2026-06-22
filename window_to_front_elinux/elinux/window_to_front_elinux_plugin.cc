#include "include/window_to_front_elinux/window_to_front_elinux_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace window_to_front_elinux {

namespace {

// Must match the channel name used by the upstream `window_to_front` package's
// Dart side (MethodChannel('window_to_front')).
constexpr char kChannelName[] = "window_to_front";
constexpr char kActivateMethod[] = "activate";

}  // namespace

class WindowToFrontElinuxPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar* registrar);
  WindowToFrontElinuxPlugin() = default;
  ~WindowToFrontElinuxPlugin() override = default;

  WindowToFrontElinuxPlugin(const WindowToFrontElinuxPlugin&) = delete;
  WindowToFrontElinuxPlugin& operator=(const WindowToFrontElinuxPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

// static
void WindowToFrontElinuxPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrar* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<WindowToFrontElinuxPlugin>();
  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

void WindowToFrontElinuxPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == kActivateMethod) {
    // No-op: there is no portable elinux API to raise the window, and on Ubuntu
    // Touch the shell / url-dispatcher already returns focus to the app after a
    // browser round-trip. Reply with null so WindowToFront.activate() resolves
    // instead of throwing MissingPluginException (which would abort the
    // flutter_web_auth_2 SSO/OIDC flow after the token has been captured).
    result->Success(flutter::EncodableValue());
    return;
  }
  result->NotImplemented();
}

}  // namespace window_to_front_elinux

void WindowToFrontElinuxPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  static auto* plugin_registrar = new flutter::PluginRegistrar(registrar);
  window_to_front_elinux::WindowToFrontElinuxPlugin::RegisterWithRegistrar(
      plugin_registrar);
}
