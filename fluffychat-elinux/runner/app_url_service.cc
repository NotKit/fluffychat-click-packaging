#include "app_url_service.h"

#include <cstdio>
#include <cstdlib>

namespace {

constexpr char kIntrospectionXml[] =
    "<node>"
    "  <interface name='org.freedesktop.Application'>"
    "    <method name='Activate'>"
    "      <arg type='a{sv}' name='platform_data' direction='in'/>"
    "    </method>"
    "    <method name='Open'>"
    "      <arg type='as' name='uris' direction='in'/>"
    "      <arg type='a{sv}' name='platform_data' direction='in'/>"
    "    </method>"
    "    <method name='ActivateAction'>"
    "      <arg type='s' name='action_name' direction='in'/>"
    "      <arg type='av' name='parameter' direction='in'/>"
    "      <arg type='a{sv}' name='platform_data' direction='in'/>"
    "    </method>"
    "  </interface>"
    "</node>";

// APP_ID to object path, the same escaping lomiri-app-launch uses: everything
// outside [A-Za-z0-9] becomes _<hex>, so fluffychat.notkit_fluffychat_2.9.1-1
// is served at /fluffychat_2enotkit_5ffluffychat_5f2_2e9_2e1_2d1.
std::string AppIdToObjectPath(const std::string& app_id) {
  std::string path = "/";
  for (unsigned char c : app_id) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9')) {
      path.push_back(static_cast<char>(c));
    } else {
      char buf[4];
      std::snprintf(buf, sizeof(buf), "_%02x", c);
      path.append(buf);
    }
  }
  return path;
}

}  // namespace

AppUrlService::AppUrlService() = default;

AppUrlService::~AppUrlService() {
  if (loop_) {
    g_main_loop_quit(loop_);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  if (registration_id_ && connection_) {
    g_dbus_connection_unregister_object(connection_, registration_id_);
  }
  if (connection_) {
    g_object_unref(connection_);
  }
  if (loop_) {
    g_main_loop_unref(loop_);
  }
  if (context_) {
    g_main_context_unref(context_);
  }
}

bool AppUrlService::Start() {
  const char* app_id = getenv("APP_ID");
  if (!app_id || !*app_id) {
    return false;
  }
  const std::string object_path = AppIdToObjectPath(app_id);

  context_ = g_main_context_new();
  g_main_context_push_thread_default(context_);

  GError* error = nullptr;
  connection_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (!connection_) {
    g_printerr("app_url_service: no session bus: %s\n",
               error ? error->message : "unknown");
    g_clear_error(&error);
    g_main_context_pop_thread_default(context_);
    return false;
  }

  GDBusNodeInfo* node = g_dbus_node_info_new_for_xml(kIntrospectionXml, &error);
  if (!node) {
    g_printerr("app_url_service: bad introspection data: %s\n",
               error ? error->message : "unknown");
    g_clear_error(&error);
    g_main_context_pop_thread_default(context_);
    return false;
  }

  static const GDBusInterfaceVTable vtable = {HandleMethodCall, nullptr,
                                              nullptr, {nullptr}};
  registration_id_ = g_dbus_connection_register_object(
      connection_, object_path.c_str(), node->interfaces[0], &vtable, this,
      nullptr, &error);
  g_dbus_node_info_unref(node);

  if (registration_id_ == 0) {
    g_printerr("app_url_service: cannot export %s: %s\n", object_path.c_str(),
               error ? error->message : "unknown");
    g_clear_error(&error);
    g_main_context_pop_thread_default(context_);
    return false;
  }

  loop_ = g_main_loop_new(context_, FALSE);
  g_main_context_pop_thread_default(context_);

  thread_ = std::thread(&AppUrlService::Run, this);
  return true;
}

void AppUrlService::Run() {
  g_main_context_push_thread_default(context_);
  g_main_loop_run(loop_);
  g_main_context_pop_thread_default(context_);
}

void AppUrlService::PushUrl(const std::string& url) {
  std::lock_guard<std::mutex> lock(mutex_);
  urls_.push_back(url);
}

std::vector<std::string> AppUrlService::TakeUrls() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<std::string> taken;
  taken.swap(urls_);
  return taken;
}

void AppUrlService::HandleMethodCall(GDBusConnection* connection,
                                     const gchar* sender,
                                     const gchar* object_path,
                                     const gchar* interface_name,
                                     const gchar* method_name,
                                     GVariant* parameters,
                                     GDBusMethodInvocation* invocation,
                                     gpointer user_data) {
  auto* self = static_cast<AppUrlService*>(user_data);

  if (g_strcmp0(method_name, "Open") == 0) {
    GVariantIter* iter = nullptr;
    g_variant_get(parameters, "(asa{sv})", &iter, nullptr);
    const gchar* uri = nullptr;
    while (iter && g_variant_iter_loop(iter, "&s", &uri)) {
      if (uri && *uri) {
        self->PushUrl(uri);
      }
    }
    if (iter) {
      g_variant_iter_free(iter);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Activate") == 0 ||
      g_strcmp0(method_name, "ActivateAction") == 0) {
    // Nothing to do: lomiri has already raised the window by this point.
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  g_dbus_method_invocation_return_error(
      invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
      "Unknown method %s", method_name);
}
