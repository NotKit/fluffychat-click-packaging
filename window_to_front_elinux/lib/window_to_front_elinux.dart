// This package intentionally contains no Dart API.
//
// It exists only to contribute a native elinux plugin that handles the
// `window_to_front` MethodChannel. The Dart side is provided, unchanged, by the
// upstream `window_to_front` package (the `WindowToFront` class). On elinux the
// native handler is otherwise missing, so `WindowToFront.activate()` throws
// MissingPluginException; this plugin answers `activate` as a no-op. See
// `elinux/` for the implementation.
library window_to_front_elinux;
