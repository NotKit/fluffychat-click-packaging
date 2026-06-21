// This package intentionally contains no Dart API.
//
// It exists only to contribute a native elinux plugin that implements the
// `url_launcher_linux` pigeon channels
// (`dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.*`). The Dart side of
// url_launcher on elinux is provided, unchanged, by the upstream
// `url_launcher_linux` package, whose `UrlLauncherLinux.registerWith()` is
// already invoked under `Platform.isLinux`. See `elinux/` for the
// implementation.
library url_launcher_elinux;
