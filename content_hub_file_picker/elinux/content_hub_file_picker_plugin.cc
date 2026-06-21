#include "include/content_hub_file_picker/content_hub_file_picker_plugin.h"

#include <com/lomiri/content/glib/content-hub-glib.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>

#include <cctype>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace content_hub_file_picker {

class ContentHubFilePickerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrar* registrar);

  ContentHubFilePickerPlugin() = default;
  ~ContentHubFilePickerPlugin() override = default;

  ContentHubFilePickerPlugin(const ContentHubFilePickerPlugin&) = delete;
  ContentHubFilePickerPlugin& operator=(const ContentHubFilePickerPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

namespace {

constexpr char kChannelName[] = "content_hub_file_picker";
constexpr char kListSourcesMethod[] = "listSources";
constexpr char kImportFromPeerMethod[] = "importFromPeer";
constexpr char kClearTempMethod[] = "clearTemporaryFiles";

// Well-known bus name + object path the content-hub daemon registers.
// Verified against lomiri-content-hub-service: registerService(
// "com.lomiri.content.dbus.Service") + registerObject("/", ...).
constexpr char kServiceBusName[] = "com.lomiri.content.dbus.Service";
constexpr char kServiceObjectPath[] = "/";

// Transfer::State enum values from transfer.h
constexpr gint kStateAborted = 5;

// -- Callback data passed into the GLib thread --

struct PickState {
  GMainLoop* loop;
  std::vector<std::string> uris;  // populated by on_handle_import
  bool aborted = false;
  std::string temp_dir;  // where collected files are moved before finalize
};

// Returns this process's AppArmor profile name, matching what content-hub
// reads from the bus (GetConnectionCredentials -> LinuxSecurityLabel). The
// service requires the app_id we supply to equal this profile unless it is
// "unconfined"; a click app runs under a named profile (e.g.
// "fluffychat.im_fluffychat_1.0.0") even when its template is "unconfined".
// /proc/self/attr/current holds the same context the bus reports.
static std::string GetOwnAppArmorLabel() {
  std::string label;
  if (FILE* f = std::fopen("/proc/self/attr/current", "r")) {
    char buf[512];
    if (std::fgets(buf, sizeof(buf), f)) label = buf;
    std::fclose(f);
  }
  while (!label.empty() &&
         (label.back() == '\n' || label.back() == ' ' || label.back() == '\0')) {
    label.pop_back();
  }
  // The label is "profile (mode)"; keep just the profile name.
  auto paren = label.rfind(" (");
  if (paren != std::string::npos) label = label.substr(0, paren);
  if (label.empty()) return "unconfined";
  return label;
}

// Strips a trailing null/newline/space and the " (mode)" suffix from an
// AppArmor context string.
static std::string CleanAppArmorContext(std::string label) {
  while (!label.empty() && (label.back() == '\0' || label.back() == '\n' ||
                            label.back() == ' ')) {
    label.pop_back();
  }
  auto paren = label.rfind(" (");
  if (paren != std::string::npos) label = label.substr(0, paren);
  return label;
}

// Returns our AppArmor profile exactly as content-hub sees it: the
// LinuxSecurityLabel of our own bus connection (GetConnectionCredentials),
// the same source content-hub queries. Falls back to /proc, then "unconfined".
static std::string GetAppArmorLabel(GDBusConnection* conn) {
  std::string label;
  const char* unique = g_dbus_connection_get_unique_name(conn);
  if (unique) {
    GError* e = nullptr;
    GVariant* reply = g_dbus_connection_call_sync(
        conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetConnectionCredentials",
        g_variant_new("(s)", unique), G_VARIANT_TYPE("(a{sv})"),
        G_DBUS_CALL_FLAGS_NONE, /*timeout=*/-1, /*cancellable=*/nullptr, &e);
    if (reply) {
      GVariant* dict = g_variant_get_child_value(reply, 0);
      GVariant* lsl = g_variant_lookup_value(dict, "LinuxSecurityLabel",
                                             G_VARIANT_TYPE_BYTESTRING);
      if (lsl) {
        gsize n = 0;
        const char* data = static_cast<const char*>(
            g_variant_get_fixed_array(lsl, &n, sizeof(char)));
        if (data && n > 0) label.assign(data, n);
        g_variant_unref(lsl);
      }
      g_variant_unref(dict);
      g_variant_unref(reply);
    }
    if (e) g_error_free(e);
  }

  label = CleanAppArmorContext(std::move(label));
  if (!label.empty()) return label;

  label = GetOwnAppArmorLabel();  // /proc fallback
  return label.empty() ? "unconfined" : label;
}

// Directory picked files are moved into. Based on g_get_user_cache_dir() which
// on Ubuntu Touch resolves to the app-namespaced cache (~/.cache/<pkg>), so the
// move stays on one filesystem and the files live within the app's own area.
static std::string TempDir() {
  return std::string(g_get_user_cache_dir()) + "/content_hub_file_picker";
}

// Recursively removes a directory tree (used by clearTemporaryFiles).
static void RemoveRecursive(const std::string& path) {
  GDir* dir = g_dir_open(path.c_str(), 0, /*error=*/nullptr);
  if (dir) {
    const gchar* name;
    while ((name = g_dir_read_name(dir))) {
      std::string child = path + "/" + name;
      if (g_file_test(child.c_str(), G_FILE_TEST_IS_DIR)) {
        RemoveRecursive(child);
      } else {
        g_unlink(child.c_str());
      }
    }
    g_dir_close(dir);
  }
  g_rmdir(path.c_str());
}

// Turns an arbitrary id into a valid D-Bus object-path element.
static std::string SanitizePathElement(const std::string& in) {
  std::string out;
  out.reserve(in.size());
  for (char c : in) {
    out.push_back((std::isalnum(static_cast<unsigned char>(c))) ? c : '_');
  }
  if (out.empty()) out = "app";
  return out;
}

// Extracts the file URL from one collected Item. content-hub marshals an Item
// as (streamType:s, stream:ay, name:s, url:s) — the URL is the LAST field, not
// the first. Prefer a string child that looks like a URL/path, else the last
// non-empty string child.
static std::string ItemUrl(GVariant* element) {
  GVariant* inner = g_variant_is_of_type(element, G_VARIANT_TYPE_VARIANT)
                        ? g_variant_get_variant(element)
                        : g_variant_ref(element);
  std::string url;
  if (inner && g_variant_is_of_type(inner, G_VARIANT_TYPE_TUPLE)) {
    gsize n = g_variant_n_children(inner);
    for (gsize i = 0; i < n; ++i) {
      GVariant* child = g_variant_get_child_value(inner, i);
      if (g_variant_is_of_type(child, G_VARIANT_TYPE_STRING)) {
        std::string s = g_variant_get_string(child, nullptr);
        if (s.find("://") != std::string::npos ||
            (!s.empty() && s.front() == '/')) {
          url = s;  // clearly a URL/path; prefer it
          g_variant_unref(child);
          break;
        }
        if (!s.empty()) url = s;  // fallback: keep last non-empty string
      }
      g_variant_unref(child);
    }
  }
  if (inner) g_variant_unref(inner);
  return url;
}

// Converts one Peer (a variant wrapping a struct) into a Flutter map with
// {id, name, iconPath, iconBytes}. The Peer struct field order isn't pinned
// across content-hub versions, so we walk children defensively: the string
// children are id, name, iconName in order; a byte-array child (iconData) is
// returned as raw bytes for direct rendering. Returns false if no id is found.
static bool PeerToMap(GVariant* element, flutter::EncodableMap* out) {
  GVariant* inner = g_variant_is_of_type(element, G_VARIANT_TYPE_VARIANT)
                        ? g_variant_get_variant(element)
                        : g_variant_ref(element);
  if (!inner) return false;

  bool ok = false;
  if (g_variant_is_of_type(inner, G_VARIANT_TYPE_TUPLE)) {
    std::vector<std::string> strings;
    std::vector<uint8_t> icon_bytes;
    gsize n = g_variant_n_children(inner);
    for (gsize i = 0; i < n; ++i) {
      GVariant* child = g_variant_get_child_value(inner, i);
      if (g_variant_is_of_type(child, G_VARIANT_TYPE_STRING)) {
        strings.emplace_back(g_variant_get_string(child, nullptr));
      } else if (g_variant_is_of_type(child, G_VARIANT_TYPE_BYTESTRING)
                 || g_variant_is_of_type(child, G_VARIANT_TYPE("ay"))) {
        gsize len = 0;
        const guchar* data = static_cast<const guchar*>(
            g_variant_get_fixed_array(child, &len, sizeof(guchar)));
        if (data && len > 0 && icon_bytes.empty()) {
          icon_bytes.assign(data, data + len);
        }
      }
      g_variant_unref(child);
    }

    if (!strings.empty() && !strings[0].empty()) {
      (*out)[flutter::EncodableValue("id")] =
          flutter::EncodableValue(strings[0]);
      (*out)[flutter::EncodableValue("name")] = flutter::EncodableValue(
          strings.size() > 1 && !strings[1].empty() ? strings[1] : strings[0]);
      (*out)[flutter::EncodableValue("iconPath")] = flutter::EncodableValue(
          strings.size() > 2 ? strings[2] : std::string());
      if (!icon_bytes.empty()) {
        (*out)[flutter::EncodableValue("iconBytes")] =
            flutter::EncodableValue(std::move(icon_bytes));
      }
      ok = true;
    }
  }
  g_variant_unref(inner);
  return ok;
}

// Called on the GLib thread when the source app finishes and content-hub
// delivers the import to our handler.
static gboolean on_handle_import(ContentHubHandler* /*handler*/,
                                  GDBusMethodInvocation* invocation,
                                  const gchar* transfer_path,
                                  gpointer user_data) {
  auto* state = static_cast<PickState*>(user_data);

  GError* err = nullptr;
  ContentHubTransfer* transfer = content_hub_transfer_proxy_new_sync(
      g_dbus_method_invocation_get_connection(invocation),
      G_DBUS_PROXY_FLAGS_NONE,
      kServiceBusName,
      transfer_path,
      /*cancellable=*/nullptr,
      &err);

  if (transfer && !err) {
    GVariant* items = nullptr;
    if (content_hub_transfer_call_collect_sync(transfer, &items,
                                               /*cancellable=*/nullptr, &err)
        && items) {
      // collect() returns 'av': an array of variants each wrapping an Item.
      // content-hub places the picked files in ~/.cache/<pkg>/HubIncoming/<id>,
      // but with the default transient store scope finalize() purges that dir.
      // So move each file into our own temp dir first, then finalize to let
      // content-hub tear down the transfer; clearTemporaryFiles() purges ours.
      g_mkdir_with_parents(state->temp_dir.c_str(), 0700);
      GVariantIter iter;
      g_variant_iter_init(&iter, items);
      GVariant* element = nullptr;
      int idx = 0;
      bool all_moved = true;
      while ((element = g_variant_iter_next_value(&iter))) {
        std::string url = ItemUrl(element);
        g_variant_unref(element);
        if (url.empty()) continue;

        GFile* src = (url.rfind("file://", 0) == 0)
                         ? g_file_new_for_uri(url.c_str())
                         : g_file_new_for_path(url.c_str());
        // Keep the original basename; isolate each file in its own subdir to
        // avoid name collisions within a multi-select.
        std::string sub = state->temp_dir + "/" + std::to_string(idx++);
        g_mkdir_with_parents(sub.c_str(), 0700);
        gchar* base = g_file_get_basename(src);
        std::string dest = sub + "/" + (base ? base : "file");
        g_free(base);

        GFile* dst = g_file_new_for_path(dest.c_str());
        GError* move_err = nullptr;
        if (g_file_move(src, dst, G_FILE_COPY_OVERWRITE, /*cancellable=*/nullptr,
                        /*progress=*/nullptr, /*progress_data=*/nullptr,
                        &move_err)) {
          state->uris.push_back(dest);
        } else {
          g_warning("content_hub_file_picker: move failed: %s",
                    move_err ? move_err->message : "unknown");
          all_moved = false;
          state->uris.push_back(url);  // fall back to the original location
        }
        if (move_err) g_error_free(move_err);
        g_object_unref(src);
        g_object_unref(dst);
      }
      g_variant_unref(items);

      // Only finalize if every file was moved out — finalize purges HubIncoming
      // for transient scope, which would delete any file we left behind.
      if (all_moved) {
        content_hub_transfer_call_finalize_sync(transfer, /*cancellable=*/nullptr,
                                                /*error=*/nullptr);
      }
    }
    g_object_unref(transfer);
  }
  if (err) {
    g_warning("content_hub_file_picker: collect error: %s", err->message);
    g_error_free(err);
  }

  content_hub_handler_complete_handle_import(
      /*handler=*/nullptr, invocation);
  g_main_loop_quit(state->loop);
  return TRUE;
}

// Called when a D-Bus property on the transfer changes; used to detect abort.
static void on_transfer_props_changed(GDBusProxy* proxy,
                                       GVariant* changed_props,
                                       GStrv /*invalidated*/,
                                       gpointer user_data) {
  auto* state = static_cast<PickState*>(user_data);

  GVariant* state_val =
      g_variant_lookup_value(changed_props, "State", G_VARIANT_TYPE_INT32);
  if (!state_val) return;

  gint transfer_state = g_variant_get_int32(state_val);
  g_variant_unref(state_val);

  if (transfer_state == kStateAborted) {
    state->aborted = true;
    g_main_loop_quit(state->loop);
  }
}

// Lists the apps (peers) that can supply the requested content type, so the
// Dart side can present a "Choose from" picker. Runs on a detached thread.
static void DoListSources(
    std::string content_type,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  GError* err = nullptr;

  GDBusConnection* conn =
      g_bus_get_sync(G_BUS_TYPE_SESSION, /*cancellable=*/nullptr, &err);
  if (!conn) {
    result->Error("DBUS_CONNECT",
                  err ? err->message : "Cannot connect to session bus");
    if (err) g_error_free(err);
    return;
  }

  ContentHubService* service = content_hub_service_proxy_new_sync(
      conn, G_DBUS_PROXY_FLAGS_NONE, kServiceBusName, kServiceObjectPath,
      /*cancellable=*/nullptr, &err);
  if (!service) {
    result->Error("SERVICE_PROXY",
                  err ? err->message : "Cannot create service proxy");
    if (err) g_error_free(err);
    g_object_unref(conn);
    return;
  }

  GVariant* peers = nullptr;
  if (!content_hub_service_call_known_sources_for_type_sync(
          service, content_type.c_str(), &peers,
          /*cancellable=*/nullptr, &err)
      || !peers) {
    result->Error("KNOWN_SOURCES",
                  err ? err->message : "Cannot list sources for content type");
    if (err) g_error_free(err);
    g_object_unref(service);
    g_object_unref(conn);
    return;
  }

  // known_sources_for_type returns 'av': an array of variants, each wrapping a
  // Peer struct.
  flutter::EncodableList sources;
  GVariantIter iter;
  g_variant_iter_init(&iter, peers);
  GVariant* element = nullptr;
  while ((element = g_variant_iter_next_value(&iter))) {
    flutter::EncodableMap peer;
    if (PeerToMap(element, &peer)) {
      sources.push_back(flutter::EncodableValue(std::move(peer)));
    }
    g_variant_unref(element);
  }
  g_variant_unref(peers);

  g_object_unref(service);
  g_object_unref(conn);
  result->Success(flutter::EncodableValue(std::move(sources)));
}

// Runs an import transfer from a specific peer on a detached background thread.
// Drives a private GMainContext so it doesn't interfere with other GLib users.
static void DoImportFromPeer(
    std::string peer_id,
    std::string content_type,
    gint selection_type,
    std::string /*app_id (ignored)*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  GError* err = nullptr;

  GDBusConnection* conn =
      g_bus_get_sync(G_BUS_TYPE_SESSION, /*cancellable=*/nullptr, &err);
  if (!conn) {
    result->Error("DBUS_CONNECT",
                  err ? err->message : "Cannot connect to session bus");
    if (err) g_error_free(err);
    return;
  }

  // content-hub identifies the destination app by its AppArmor profile and
  // rejects any mismatching app_id. Use our real profile for both the transfer
  // creation and the handler registration so the import callback routes back.
  const std::string app_id = GetAppArmorLabel(conn);

  ContentHubService* service = content_hub_service_proxy_new_sync(
      conn, G_DBUS_PROXY_FLAGS_NONE, kServiceBusName, kServiceObjectPath,
      /*cancellable=*/nullptr, &err);
  if (!service) {
    result->Error("SERVICE_PROXY",
                  err ? err->message : "Cannot create service proxy");
    if (err) g_error_free(err);
    g_object_unref(conn);
    return;
  }

  // Create an import transfer from that peer.
  gchar* transfer_path = nullptr;
  if (!content_hub_service_call_create_import_from_peer_sync(
          service, peer_id.c_str(), app_id.c_str(), content_type.c_str(),
          &transfer_path, /*cancellable=*/nullptr, &err)
      || !transfer_path) {
    std::string msg = std::string("Cannot create import transfer (app_id='") +
                      app_id + "'): " + (err ? err->message : "unknown");
    result->Error("CREATE_TRANSFER", msg);
    if (err) g_error_free(err);
    g_object_unref(service);
    g_object_unref(conn);
    return;
  }

  ContentHubTransfer* transfer = content_hub_transfer_proxy_new_sync(
      conn, G_DBUS_PROXY_FLAGS_NONE, kServiceBusName, transfer_path,
      /*cancellable=*/nullptr, &err);
  g_free(transfer_path);
  if (!transfer) {
    result->Error("TRANSFER_PROXY",
                  err ? err->message : "Cannot create transfer proxy");
    if (err) g_error_free(err);
    g_object_unref(service);
    g_object_unref(conn);
    return;
  }

  content_hub_transfer_call_set_selection_type_sync(
      transfer, selection_type, /*cancellable=*/nullptr, /*error=*/nullptr);

  // Set up a private GLib main context for this pick session.
  GMainContext* ctx = g_main_context_new();
  g_main_context_push_thread_default(ctx);
  GMainLoop* loop = g_main_loop_new(ctx, FALSE);

  PickState state{loop};
  state.temp_dir = TempDir();

  // Watch for transfer abort via property changes.
  g_signal_connect(transfer, "g-properties-changed",
                   G_CALLBACK(on_transfer_props_changed), &state);

  // Export our import handler skeleton on the session bus.
  ContentHubHandler* handler = content_hub_handler_skeleton_new();
  g_signal_connect(handler, "handle-handle-import",
                   G_CALLBACK(on_handle_import), &state);
  // handle-handle-export and handle-handle-share must return FALSE (not for us).
  g_signal_connect(
      handler, "handle-handle-export",
      G_CALLBACK(+[](ContentHubHandler*, GDBusMethodInvocation* inv,
                     const gchar*, gpointer) -> gboolean {
        content_hub_handler_complete_handle_export(nullptr, inv);
        return TRUE;
      }),
      nullptr);
  g_signal_connect(
      handler, "handle-handle-share",
      G_CALLBACK(+[](ContentHubHandler*, GDBusMethodInvocation* inv,
                     const gchar*, gpointer) -> gboolean {
        content_hub_handler_complete_handle_share(nullptr, inv);
        return TRUE;
      }),
      nullptr);

  std::string handler_path =
      "/com/lomiri/content/handler/" + SanitizePathElement(app_id);

  gboolean exported = g_dbus_interface_skeleton_export(
      G_DBUS_INTERFACE_SKELETON(handler), conn, handler_path.c_str(), &err);
  if (!exported) {
    result->Error("HANDLER_EXPORT",
                  err ? err->message : "Cannot export handler on session bus");
    if (err) g_error_free(err);
    g_object_unref(handler);
    g_object_unref(transfer);
    g_object_unref(service);
    g_object_unref(conn);
    g_main_loop_unref(loop);
    g_main_context_pop_thread_default(ctx);
    g_main_context_unref(ctx);
    return;
  }

  // Register our handler with the content-hub service so it knows where to
  // deliver the import callback.
  GError* reg_err = nullptr;
  if (!content_hub_service_call_register_import_export_handler_sync(
          service, app_id.c_str(), handler_path.c_str(),
          /*cancellable=*/nullptr, &reg_err)) {
    g_warning("content_hub_file_picker: register handler failed: %s",
              reg_err ? reg_err->message : "unknown");
  }
  if (reg_err) g_error_free(reg_err);

  // Start the transfer: this moves it to "initiated", which makes content-hub
  // launch the source app so the user can pick content there.
  if (!content_hub_transfer_call_start_sync(transfer, /*cancellable=*/nullptr,
                                            &err)) {
    result->Error("START", err ? err->message : "Cannot start transfer");
    if (err) g_error_free(err);
    g_dbus_interface_skeleton_unexport(G_DBUS_INTERFACE_SKELETON(handler));
    g_object_unref(handler);
    g_object_unref(transfer);
    g_object_unref(service);
    g_object_unref(conn);
    g_main_loop_unref(loop);
    g_main_context_pop_thread_default(ctx);
    g_main_context_unref(ctx);
    return;
  }

  // Block until the handler fires (user picks) or the transfer is aborted.
  g_main_loop_run(loop);

  // Cleanup.
  g_dbus_interface_skeleton_unexport(G_DBUS_INTERFACE_SKELETON(handler));
  g_object_unref(handler);
  g_object_unref(transfer);
  g_object_unref(service);
  g_object_unref(conn);
  g_main_loop_unref(loop);
  g_main_context_pop_thread_default(ctx);
  g_main_context_unref(ctx);

  if (state.aborted || state.uris.empty()) {
    // Null result signals cancellation to the Dart side.
    result->Success(flutter::EncodableValue());
    return;
  }

  flutter::EncodableList uris;
  uris.reserve(state.uris.size());
  for (const auto& uri : state.uris) {
    uris.push_back(flutter::EncodableValue(uri));
  }
  result->Success(flutter::EncodableValue(std::move(uris)));
}

}  // namespace

// static
void ContentHubFilePickerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrar* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ContentHubFilePickerPlugin>();
  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

void ContentHubFilePickerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  // Takes no arguments; handle before the args-map check below.
  if (method == kClearTempMethod) {
    RemoveRecursive(TempDir());
    result->Success(flutter::EncodableValue(true));
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) {
    result->Error("INVALID_ARGS", "Expected map argument");
    return;
  }

  auto get_string = [&](const char* key) -> const std::string* {
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return nullptr;
    return std::get_if<std::string>(&it->second);
  };
  auto get_int = [&](const char* key) -> const int* {
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return nullptr;
    return std::get_if<int>(&it->second);
  };

  if (method == kListSourcesMethod) {
    const auto* content_type = get_string("contentType");
    if (!content_type) {
      result->Error("INVALID_ARGS", "Missing contentType");
      return;
    }
    std::thread([ct = *content_type, res = std::move(result)]() mutable {
      DoListSources(std::move(ct), std::move(res));
    }).detach();
    return;
  }

  if (method == kImportFromPeerMethod) {
    const auto* peer_id = get_string("peerId");
    const auto* content_type = get_string("contentType");
    const auto* selection_type = get_int("selectionType");
    if (!peer_id || !content_type || !selection_type) {
      result->Error("INVALID_ARGS",
                    "Missing peerId, contentType, or selectionType");
      return;
    }
    // app_id is derived natively from the AppArmor profile (see DoImportFromPeer).
    std::thread([pid = *peer_id, ct = *content_type, st = *selection_type,
                 res = std::move(result)]() mutable {
      DoImportFromPeer(std::move(pid), std::move(ct), st, /*app_id=*/std::string(),
                       std::move(res));
    }).detach();
    return;
  }

  result->NotImplemented();
}

}  // namespace content_hub_file_picker

void ContentHubFilePickerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  static auto* plugin_registrar = new flutter::PluginRegistrar(registrar);
  content_hub_file_picker::ContentHubFilePickerPlugin::RegisterWithRegistrar(
      plugin_registrar);
}
