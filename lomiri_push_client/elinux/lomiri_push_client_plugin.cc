#include "include/lomiri_push_client/lomiri_push_client_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <gio/gio.h>
#include <glib.h>

#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace lomiri_push_client {

class LomiriPushClientPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar* registrar);

  LomiriPushClientPlugin() = default;
  ~LomiriPushClientPlugin() override = default;

  LomiriPushClientPlugin(const LomiriPushClientPlugin&) = delete;
  LomiriPushClientPlugin& operator=(const LomiriPushClientPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

namespace {

constexpr char kChannelName[] = "lomiri_push_client";

// Bus names, interfaces and path prefixes of lomiri-push-service. Verified
// against client/service/{service,postal}.go: the object path is the prefix
// plus the nih-quoted *package* name, while the app id is passed as the first
// argument of every call. Register() lives on the push service; everything
// else on the postal service.
constexpr char kPushService[] = "com.lomiri.PushNotifications";
constexpr char kPushIface[] = "com.lomiri.PushNotifications";
constexpr char kPushPathPrefix[] = "/com/lomiri/PushNotifications/";
constexpr char kPostalService[] = "com.lomiri.Postal";
constexpr char kPostalIface[] = "com.lomiri.Postal";
constexpr char kPostalPathPrefix[] = "/com/lomiri/Postal/";

// Register() makes the service do an HTTP round-trip to the push server, so
// the default 25s D-Bus timeout is too tight on a slow mobile connection.
constexpr int kRegisterTimeoutMs = 60000;

// Reimplements libnih's nih_dbus_path element quoting, which the service
// reverses (nih.Unquote) to recover the package name from the object path.
// Alphanumerics pass through, everything else becomes _<2 hex digits>.
static std::string NihQuote(const std::string& in) {
  if (in.empty()) return "_";
  std::string out;
  out.reserve(in.size());
  for (unsigned char c : in) {
    if (g_ascii_isalnum(c)) {
      out.push_back(static_cast<char>(c));
    } else {
      char buf[4];
      g_snprintf(buf, sizeof(buf), "_%02x", c);
      out += buf;
    }
  }
  return out;
}

// Returns this process's AppArmor profile with the " (mode)" suffix stripped,
// e.g. "fluffychat.notkit_fluffychat_2.8.0-2". Empty if unconfined/unavailable.
static std::string GetAppArmorLabel() {
  std::string label;
  if (FILE* f = std::fopen("/proc/self/attr/current", "r")) {
    char buf[512];
    if (std::fgets(buf, sizeof(buf), f)) label = buf;
    std::fclose(f);
  }
  while (!label.empty() && (label.back() == '\n' || label.back() == ' ' ||
                            label.back() == '\0')) {
    label.pop_back();
  }
  auto paren = label.rfind(" (");
  if (paren != std::string::npos) label = label.substr(0, paren);
  if (label == "unconfined") return std::string();
  return label;
}

// Derives the click app id ("<package>_<app>") from the AppArmor profile,
// which is "<package>_<app>_<version>". Lets the Dart side stay free of a
// hardcoded id that would silently break if the manifest name changed.
static std::string DefaultAppId() {
  std::string label = GetAppArmorLabel();
  auto last = label.rfind('_');
  if (last == std::string::npos) return label;
  // Only strip the trailing component if what remains still has a "_<app>"
  // part; otherwise the label was not the expected three-part form.
  if (label.find('_') == last) return label;
  return label.substr(0, last);
}

// The package name is everything before the first underscore of the app id.
static std::string PackageOf(const std::string& app_id) {
  auto us = app_id.find('_');
  return us == std::string::npos ? app_id : app_id.substr(0, us);
}

// Blocking D-Bus call on the session bus. Returns nullptr on error, with
// *error set. Consumes a floating `params`.
static GVariant* CallSync(const char* bus_name, const std::string& path,
                          const char* iface, const char* method,
                          GVariant* params, const GVariantType* reply_type,
                          int timeout_ms, GError** error) {
  GDBusConnection* conn =
      g_bus_get_sync(G_BUS_TYPE_SESSION, /*cancellable=*/nullptr, error);
  if (!conn) {
    if (params) g_variant_unref(g_variant_ref_sink(params));
    return nullptr;
  }
  GVariant* reply = g_dbus_connection_call_sync(
      conn, bus_name, path.c_str(), iface, method, params, reply_type,
      G_DBUS_CALL_FLAGS_NONE, timeout_ms, /*cancellable=*/nullptr, error);
  g_object_unref(conn);
  return reply;
}

using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

// Reports a GError to Dart under `code` and frees it.
static void FailWith(const Result& result, const char* code, GError* error,
                     const char* fallback) {
  result->Error(code, error ? error->message : fallback);
  if (error) g_error_free(error);
}

static void DoRegister(std::string app_id, Result result) {
  GError* err = nullptr;
  GVariant* reply =
      CallSync(kPushService, kPushPathPrefix + NihQuote(PackageOf(app_id)),
               kPushIface, "Register", g_variant_new("(s)", app_id.c_str()),
               G_VARIANT_TYPE("(s)"), kRegisterTimeoutMs, &err);
  if (!reply) {
    FailWith(result, "REGISTER", err, "Register failed");
    return;
  }
  const gchar* token = nullptr;
  g_variant_get(reply, "(&s)", &token);
  std::string out = token ? token : "";
  g_variant_unref(reply);

  if (out.empty()) {
    result->Error("REGISTER", "Push service returned an empty token");
    return;
  }
  result->Success(flutter::EncodableValue(out));
}

static void DoUnregister(std::string app_id, Result result) {
  GError* err = nullptr;
  GVariant* reply =
      CallSync(kPushService, kPushPathPrefix + NihQuote(PackageOf(app_id)),
               kPushIface, "Unregister", g_variant_new("(s)", app_id.c_str()),
               G_VARIANT_TYPE("()"), kRegisterTimeoutMs, &err);
  if (!reply) {
    FailWith(result, "UNREGISTER", err, "Unregister failed");
    return;
  }
  g_variant_unref(reply);
  result->Success();
}

// Sets the launcher emblem counter. The push helper already sets it for
// notifications that arrive while the app is closed; this keeps it in sync
// once the app is running and rooms are read.
static void DoSetCounter(std::string app_id, int count, Result result) {
  GError* err = nullptr;
  GVariant* reply = CallSync(
      kPostalService, kPostalPathPrefix + NihQuote(PackageOf(app_id)),
      kPostalIface, "SetCounter",
      g_variant_new("(sib)", app_id.c_str(), count, count != 0),
      G_VARIANT_TYPE("()"), /*timeout_ms=*/-1, &err);
  if (!reply) {
    FailWith(result, "SET_COUNTER", err, "SetCounter failed");
    return;
  }
  g_variant_unref(reply);
  result->Success();
}

// Lists the tags of notifications still shown in the messaging menu.
static void DoListPersistent(std::string app_id, Result result) {
  GError* err = nullptr;
  GVariant* reply = CallSync(
      kPostalService, kPostalPathPrefix + NihQuote(PackageOf(app_id)),
      kPostalIface, "ListPersistent", g_variant_new("(s)", app_id.c_str()),
      G_VARIANT_TYPE("(as)"), /*timeout_ms=*/-1, &err);
  if (!reply) {
    FailWith(result, "LIST_PERSISTENT", err, "ListPersistent failed");
    return;
  }

  flutter::EncodableList tags;
  GVariant* array = g_variant_get_child_value(reply, 0);
  GVariantIter iter;
  g_variant_iter_init(&iter, array);
  const gchar* tag = nullptr;
  while (g_variant_iter_loop(&iter, "&s", &tag)) {
    tags.push_back(flutter::EncodableValue(std::string(tag ? tag : "")));
  }
  g_variant_unref(array);
  g_variant_unref(reply);

  result->Success(flutter::EncodableValue(std::move(tags)));
}

// Dismisses notifications by tag; an empty tag list clears all of them.
static void DoClearPersistent(std::string app_id, std::vector<std::string> tags,
                              Result result) {
  std::vector<const gchar*> strv;
  strv.reserve(tags.size() + 1);
  for (const auto& tag : tags) strv.push_back(tag.c_str());
  strv.push_back(nullptr);

  GError* err = nullptr;
  GVariant* reply = CallSync(
      kPostalService, kPostalPathPrefix + NihQuote(PackageOf(app_id)),
      kPostalIface, "ClearPersistentList",
      g_variant_new("(s^as)", app_id.c_str(), strv.data()),
      G_VARIANT_TYPE("(u)"), /*timeout_ms=*/-1, &err);
  if (!reply) {
    FailWith(result, "CLEAR_PERSISTENT", err, "ClearPersistentList failed");
    return;
  }
  guint32 cleared = 0;
  g_variant_get(reply, "(u)", &cleared);
  g_variant_unref(reply);

  result->Success(flutter::EncodableValue(static_cast<int>(cleared)));
}

}  // namespace

// static
void LomiriPushClientPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrar* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<LomiriPushClientPlugin>();
  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

void LomiriPushClientPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  // Arguments are optional throughout: appId defaults to the AppArmor-derived
  // click app id, so a caller may pass no arguments at all.
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  auto lookup = [&](const char* key) -> const flutter::EncodableValue* {
    if (!args) return nullptr;
    auto it = args->find(flutter::EncodableValue(key));
    return it == args->end() ? nullptr : &it->second;
  };

  std::string app_id;
  if (const auto* v = lookup("appId")) {
    if (const auto* s = std::get_if<std::string>(v)) app_id = *s;
  }
  if (app_id.empty()) app_id = DefaultAppId();
  if (app_id.empty()) {
    result->Error("NO_APP_ID",
                  "Not running under an AppArmor profile; pass appId explicitly");
    return;
  }

  if (method == "appId") {
    result->Success(flutter::EncodableValue(app_id));
    return;
  }

  // Every remaining method blocks on D-Bus (Register additionally on the
  // network), so run it off the platform thread.
  if (method == "register") {
    std::thread([id = std::move(app_id), res = std::move(result)]() mutable {
      DoRegister(std::move(id), std::move(res));
    }).detach();
    return;
  }

  if (method == "unregister") {
    std::thread([id = std::move(app_id), res = std::move(result)]() mutable {
      DoUnregister(std::move(id), std::move(res));
    }).detach();
    return;
  }

  if (method == "setCounter") {
    int count = 0;
    if (const auto* v = lookup("count")) {
      if (const auto* i = std::get_if<int>(v)) count = *i;
    }
    std::thread([id = std::move(app_id), count,
                 res = std::move(result)]() mutable {
      DoSetCounter(std::move(id), count, std::move(res));
    }).detach();
    return;
  }

  if (method == "listPersistent") {
    std::thread([id = std::move(app_id), res = std::move(result)]() mutable {
      DoListPersistent(std::move(id), std::move(res));
    }).detach();
    return;
  }

  if (method == "clearPersistent") {
    std::vector<std::string> tags;
    if (const auto* v = lookup("tags")) {
      if (const auto* list = std::get_if<flutter::EncodableList>(v)) {
        for (const auto& item : *list) {
          if (const auto* s = std::get_if<std::string>(&item)) {
            tags.push_back(*s);
          }
        }
      }
    }
    std::thread([id = std::move(app_id), tags = std::move(tags),
                 res = std::move(result)]() mutable {
      DoClearPersistent(std::move(id), std::move(tags), std::move(res));
    }).detach();
    return;
  }

  result->NotImplemented();
}

}  // namespace lomiri_push_client

void LomiriPushClientPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  static auto* plugin_registrar = new flutter::PluginRegistrar(registrar);
  lomiri_push_client::LomiriPushClientPlugin::RegisterWithRegistrar(
      plugin_registrar);
}
