import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Client for the Lomiri push service (`lomiri-push-service`) on Ubuntu Touch.
///
/// Registration returns a token identifying this user+device for our click
/// package. The token is used as the Matrix pushkey; UBports runs a Matrix
/// push gateway that relays `/_matrix/push/v1/notify` into the device's push
/// connection, keyed by the pusher's `app_id` and pushkey.
class LomiriPushClient {
  LomiriPushClient._();

  static const _channel = MethodChannel('lomiri_push_client');

  /// UBports' Matrix push gateway. The homeserver posts notifications here.
  static const gatewayUrl =
      'https://push.ubports.com:5003/_matrix/push/v1/notify';

  /// The click app id ("<package>_<app>") this plugin registers under, derived
  /// natively from the AppArmor profile. Must equal the `app_id` of the
  /// push-helper hook in the manifest, and the Matrix pusher's `app_id`.
  static Future<String?> get appId => _invoke<String>('appId');

  /// Registers for push and returns the token, or null on failure.
  ///
  /// The push service performs an HTTP registration against the push server,
  /// so this fails while the device is offline. Ubuntu's own QML client waits
  /// for connectivity before registering; we retry with a backoff instead,
  /// which keeps the plugin free of a libconnectivity dependency.
  static Future<String?> register({
    int attempts = 4,
    Duration initialDelay = const Duration(seconds: 2),
  }) async {
    var delay = initialDelay;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final token = await _channel.invokeMethod<String>('register');
        if (token != null && token.isNotEmpty) return token;
      } on MissingPluginException {
        // Not an Ubuntu Touch build — no point retrying.
        return null;
      } on PlatformException catch (e) {
        debugPrint(
          'lomiri_push_client: register attempt $attempt/$attempts '
          'failed: ${e.message}',
        );
      }
      if (attempt < attempts) {
        await Future.delayed(delay);
        delay *= 2;
      }
    }
    return null;
  }

  /// Drops this device's registration. The Matrix pusher should be deleted
  /// separately — the two are independent.
  static Future<void> unregister() => _invoke<void>('unregister');

  /// Sets the launcher emblem counter (hidden when [count] is 0).
  static Future<void> setCounter(int count) =>
      _invoke<void>('setCounter', {'count': count});

  /// Tags of notifications still listed in the messaging menu.
  static Future<List<String>> listPersistent() async {
    try {
      final tags = await _channel.invokeListMethod<String>('listPersistent');
      return tags ?? const [];
    } on PlatformException catch (e) {
      debugPrint('lomiri_push_client: listPersistent failed: ${e.message}');
      return const [];
    }
  }

  /// Raises a notification through the postal service.
  ///
  /// AppArmor does not let a confined app talk to
  /// org.freedesktop.Notifications, so flutter_local_notifications cannot work
  /// here; postal is the sanctioned route and is already allowed by the
  /// push-notification-client policy group.
  ///
  /// [actions] are URLs; the first is opened when the notification is tapped.
  /// [tag] groups a room's notifications so [clearPersistent] can drop them.
  static Future<void> post({
    required String summary,
    required String body,
    String? tag,
    String? icon,
    List<String> actions = const [],
    bool sound = false,
    bool vibrate = false,
    int? counter,
  }) async {
    final notification = <String, Object?>{
      'card': <String, Object?>{
        'summary': summary,
        'body': body,
        'popup': true,
        'persist': true,
        if (icon != null) 'icon': icon,
        if (actions.isNotEmpty) 'actions': actions,
      },
      'sound': sound,
      'vibrate': vibrate,
      if (tag != null) 'tag': tag,
      if (counter != null)
        'emblem-counter': <String, Object?>{
          'count': counter,
          'visible': counter > 0,
        },
    };
    await _invoke<void>('post', {
      'notification': jsonEncode({'notification': notification}),
    });
  }

  /// Dismisses notifications by tag; an empty [tags] clears all of them.
  /// Returns the number cleared.
  static Future<int> clearPersistent([List<String> tags = const []]) async {
    final cleared = await _invoke<int>('clearPersistent', {'tags': tags});
    return cleared ?? 0;
  }

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('lomiri_push_client: $method failed: ${e.message}');
      return null;
    }
  }
}
