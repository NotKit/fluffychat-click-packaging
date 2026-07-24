import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

// Content-hub type IDs — bare lowercase ids from com::lomiri::content::Type
// (Type::Known::*), e.g. "pictures". NOT a dotted namespace.
const _kTypeAll = 'all';
const _kTypePictures = 'pictures';
const _kTypeVideos = 'videos';
const _kTypeMusic = 'music';

class ContentHubFilePickerPlugin {
  static const _channel = MethodChannel('content_hub_file_picker');

  // Called automatically by the Flutter plugin registrant. Plugins register
  // in alphabetical package order, so file_picker's FilePickerLinux would
  // overwrite a direct assignment here. Defer ours past all synchronous
  // registerWith() calls with a microtask so it wins.
  static void registerWith() {
    scheduleMicrotask(() {
      FilePickerPlatform.instance = ContentHubFilePicker._(_channel);
    });
  }
}

class ContentHubFilePicker extends FilePickerPlatform {
  ContentHubFilePicker._(this._channel);

  final MethodChannel _channel;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    final contentType = _fileTypeToContentHub(type);

    // Callers (via FluffyChat's selectFiles) no longer wrap this in a loading
    // dialog that would absorb errors, so treat any content-hub failure as a
    // cancellation (return null) rather than letting it propagate.
    try {
      // 1. Ask content-hub which apps can provide this content type.
      final List<dynamic>? raw = await _channel.invokeListMethod<dynamic>(
        'listSources',
        {'contentType': contentType},
      );
      final sources = (raw ?? [])
          .map((e) => _ContentPeer.fromMap((e as Map).cast<dynamic, dynamic>()))
          .toList();
      if (sources.isEmpty) return null;

      // 2. Let the user choose the source app (content-hub shows no UI itself).
      final navigator = _findNavigator();
      if (navigator == null) return null;
      final peer = await navigator.push<_ContentPeer>(
        MaterialPageRoute(builder: (_) => _ContentPeerPickerPage(sources)),
      );
      if (peer == null) return null;

      // 3. Run the import transfer from the chosen peer.
      onFileLoading?.call(FilePickerStatus.picking);
      try {
        final List<dynamic>? uris = await _channel.invokeListMethod<dynamic>(
          'importFromPeer',
          {
            'peerId': peer.id,
            'contentType': contentType,
            'selectionType': allowMultiple ? 1 : 0,
          },
        );
        if (uris == null || uris.isEmpty) return null;

        final files = uris.cast<String>().map((uri) {
          // Items arrive as file:// URIs; convert to plain paths.
          final path = Uri.parse(uri).isScheme('file')
              ? Uri.parse(uri).toFilePath()
              : uri;
          final file = File(path);
          final size = file.existsSync() ? file.lengthSync() : 0;
          return PlatformFile(path: path, name: p.basename(path), size: size);
        }).toList();

        return FilePickerResult(files);
      } finally {
        onFileLoading?.call(FilePickerStatus.done);
      }
    } on PlatformException catch (e) {
      debugPrint('content_hub_file_picker: pickFiles failed: ${e.message}');
      return null;
    }
  }

  // Locates the app's root NavigatorState by walking the element tree. Avoids a
  // dependency on the host app (which would be circular) and needs no app-side
  // wiring to install a navigator key.
  NavigatorState? _findNavigator() {
    NavigatorState? navigator;
    void visit(Element element) {
      if (navigator != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        navigator = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return navigator;
  }

  // Saving files via content-hub export is not implemented.
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    required Uint8List bytes,
    Function(FilePickerStatus)? onFileLoading,
    bool lockParentWindow = false,
  }) async =>
      null;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
    AndroidSAFOptions? androidSafOptions,
  }) async =>
      null;

  // The native side both chooses the temp dir (g_get_user_cache_dir) and purges
  // it, so the location is computed in exactly one place.
  @override
  Future<bool?> clearTemporaryFiles() async {
    try {
      return await _channel.invokeMethod<bool>('clearTemporaryFiles');
    } on PlatformException catch (e) {
      debugPrint('content_hub_file_picker: clearTemporaryFiles failed: ${e.message}');
      return false;
    }
  }

  String _fileTypeToContentHub(FileType type) {
    switch (type) {
      case FileType.image:
        return _kTypePictures;
      case FileType.video:
        return _kTypeVideos;
      case FileType.audio:
        return _kTypeMusic;
      case FileType.custom:
        // content-hub has no per-extension filtering; fall back to All.
        return _kTypeAll;
      case FileType.any:
      default:
        return _kTypeAll;
    }
  }
}

// A content-hub source app, as returned by the native listSources method.
class _ContentPeer {
  _ContentPeer({
    required this.id,
    required this.name,
    this.iconPath,
    this.iconBytes,
  });

  final String id;
  final String name;
  final String? iconPath;
  final Uint8List? iconBytes;

  factory _ContentPeer.fromMap(Map<dynamic, dynamic> map) {
    final bytes = map['iconBytes'];
    final path = map['iconPath'] as String?;
    return _ContentPeer(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? (map['id'] as String?) ?? '',
      iconPath: (path != null && path.isNotEmpty) ? path : null,
      iconBytes: bytes is Uint8List
          ? bytes
          : (bytes is List ? Uint8List.fromList(bytes.cast<int>()) : null),
    );
  }
}

// Full-screen "Choose from" app picker, mirroring the Lomiri content-hub
// ContentPeerPicker so the experience matches native UT apps.
class _ContentPeerPickerPage extends StatelessWidget {
  const _ContentPeerPickerPage(this.peers);

  final List<_ContentPeer> peers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Choose from'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Apps',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                mainAxisSpacing: 16,
                crossAxisSpacing: 8,
                childAspectRatio: 0.8,
              ),
              itemCount: peers.length,
              itemBuilder: (context, i) => _PeerTile(
                peer: peers[i],
                onTap: () => Navigator.of(context).pop(peers[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.onTap});

  final _ContentPeer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(width: 64, height: 64, child: _buildIcon(context)),
          ),
          const SizedBox(height: 6),
          Text(
            peer.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(BuildContext context) {
    final fallback = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.apps,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    final bytes = peer.iconBytes;
    if (bytes != null && bytes.isNotEmpty) {
      // content-hub app icons are usually SVG, which Image.memory can't decode.
      if (_looksLikeSvg(bytes)) {
        return SvgPicture.memory(
          bytes,
          fit: BoxFit.contain,
          placeholderBuilder: (_) => fallback,
        );
      }
      return Image.memory(bytes,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
    }
    if (peer.iconPath != null && peer.iconPath!.isNotEmpty) {
      final path = peer.iconPath!;
      if (path.toLowerCase().endsWith('.svg') && File(path).existsSync()) {
        return SvgPicture.file(File(path),
            fit: BoxFit.contain, placeholderBuilder: (_) => fallback);
      }
      if (File(path).existsSync()) {
        return Image.file(File(path),
            fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
      }
    }
    return fallback;
  }

  // Detects SVG by sniffing the first bytes for an XML/SVG marker.
  bool _looksLikeSvg(Uint8List bytes) {
    final n = bytes.length < 256 ? bytes.length : 256;
    final head = String.fromCharCodes(bytes.sublist(0, n)).toLowerCase();
    return head.contains('<svg') || head.contains('<?xml');
  }
}
