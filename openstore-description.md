# OpenStore listing

Title: FluffyChat (Flutter-eLinux)

Tagline: Unofficial FluffyChat Matrix client build using Flutter-eLinux port

Description:

FluffyChat is an open source, cute and cross-platform chat app for Matrix — a
decentralised network for secure, federated messaging. Pick any homeserver, or
run your own, and talk to people everywhere else on the network.

This is an unofficial build of the upstream FluffyChat app for Ubuntu Touch. It
runs the real Flutter application natively through the Flutter-eLinux Wayland
embedder, so it is neither a web wrapper nor related to the older QML FluffyChat
port — it is the same codebase that ships on Android and desktop, compiled for
the device.

Features:

- End-to-end encryption with device verification and cross-signing
- Spaces, replies, reactions, read receipts and message editing
- Share photos, videos and files through the Ubuntu Touch Content Hub
- Multiple accounts side by side
- Material You theming with light and dark mode
- Sign in with a password or via SSO/OIDC
- Maliit on-screen keyboard support; links open in the browser

Known limitations:

- No push notifications. New messages only arrive while the app is running.
- Audio recording is not wired up on Ubuntu Touch, so voice messages cannot be
  recorded (received ones are still shown).
- The eLinux embedder is young; expect rough edges around window handling and
  text input.

Packaging and bug reports: https://github.com/NotKit/fluffychat-click-packaging
Upstream project: https://fluffychat.im (AGPL-3.0)
