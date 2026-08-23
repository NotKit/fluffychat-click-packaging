#ifndef APP_URL_SERVICE_H_
#define APP_URL_SERVICE_H_

#include <gio/gio.h>

#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Receives URLs dispatched to an already running app.
//
// lomiri-app-launch's second-exec looks up every session bus connection owned
// by our PID and calls org.freedesktop.Application.Open on each, at the object
// path built from the APP_ID. It ignores the connections that do not answer,
// so exporting the interface on our own connection is enough.
//
// GDBus runs on a private main context in its own thread; TakeUrls() hands the
// results to the platform thread.
class AppUrlService {
 public:
  AppUrlService();
  ~AppUrlService();

  // Starts the service. Returns false if there is no APP_ID (not launched by
  // lomiri-app-launch) or the session bus is unavailable.
  bool Start();

  // Returns the URLs received since the last call, oldest first.
  std::vector<std::string> TakeUrls();

 private:
  static void HandleMethodCall(GDBusConnection* connection,
                               const gchar* sender,
                               const gchar* object_path,
                               const gchar* interface_name,
                               const gchar* method_name,
                               GVariant* parameters,
                               GDBusMethodInvocation* invocation,
                               gpointer user_data);

  void Run();
  void PushUrl(const std::string& url);

  std::thread thread_;
  GMainContext* context_ = nullptr;
  GMainLoop* loop_ = nullptr;
  GDBusConnection* connection_ = nullptr;
  guint registration_id_ = 0;
  std::mutex mutex_;
  std::vector<std::string> urls_;
};

#endif  // APP_URL_SERVICE_H_
