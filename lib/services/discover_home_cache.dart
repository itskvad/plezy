import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../utils/app_logger.dart';
import '../utils/isolate_helper.dart';

/// The last committed Discover home state, persisted per profile.
///
/// This is a latency optimization, not a source of truth: the provider paints
/// it before the first network pass and replaces it as soon as fresh content
/// commits. It also keeps the home usable when the app starts offline.
class DiscoverHomeSnapshot {
  const DiscoverHomeSnapshot({
    required this.onDeck,
    required this.copies,
    required this.hubs,
    required this.hasMoreContinueWatching,
    required this.savedAt,
  });

  final List<MediaItem> onDeck;
  final Map<String, List<MediaItem>> copies;
  final List<MediaHub> hubs;
  final bool hasMoreContinueWatching;
  final DateTime savedAt;
}

/// Reads and writes [DiscoverHomeSnapshot]s under the application support
/// directory. Writes are best-effort: a cache failure must never disturb the
/// load it is trying to accelerate.
class DiscoverHomeCache {
  DiscoverHomeCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static int _generation = 0;
  static Future<void> _operationChain = Future<void>.value();

  static const int _version = 1;
  static const String _directoryName = 'discover_home';

  /// Below this size the JSON decode runs inline; spawning an isolate for a
  /// small snapshot costs more than it saves. Larger rows stay off the UI
  /// isolate, matching the HTTP layer's offload policy.
  static const int _isolateThreshold = 32 * 1024;

  final Future<Directory> Function() _directoryProvider;
  final int _generationAtCreation = _generation;

  Future<DiscoverHomeSnapshot?> read(String profileId) async {
    try {
      final file = File(await _path(profileId));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.length < _isolateThreshold) return _decode(raw);
      return await tryIsolateRun(() => _decode(raw));
    } catch (e, st) {
      appLogger.d('Discover home cache read failed', error: e, stackTrace: st);
      return null;
    }
  }

  Future<void> write(String profileId, DiscoverHomeSnapshot snapshot) {
    if (_generationAtCreation != _generation) return Future<void>.value();

    // Serialize writes from every cache instance: separate providers can
    // otherwise collide on the same temp file, and logout must be able to
    // drain writes that were started by an instance it does not own.
    final next = _operationChain.then((_) {
      if (_generationAtCreation != _generation) return;
      return _writeOnce(profileId, snapshot);
    });
    _operationChain = next;
    return next;
  }

  Future<void> _writeOnce(String profileId, DiscoverHomeSnapshot snapshot) async {
    try {
      // Build the JSON-ready map on this isolate (MediaItem.toJson is cheap
      // compared with the file write) and encode it off-isolate: a home pass
      // can carry several hundred items.
      final encoded = _encode(snapshot);
      final json = await tryIsolateRun(() => jsonEncode(encoded));
      final path = await _path(profileId);
      final file = File(path);
      await file.parent.create(recursive: true);
      final temp = File('$path.tmp');
      await temp.writeAsString(json, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(path);
    } catch (e, st) {
      appLogger.d('Discover home cache write failed', error: e, stackTrace: st);
    }
  }

  Future<void> clear(String profileId) {
    // Ordered behind any write already queued, so a profile deletion cannot
    // race a snapshot that was being persisted as the profile went away.
    final next = _operationChain.then((_) => _clearOnce(profileId));
    _operationChain = next;
    return next;
  }

  Future<void> _clearOnce(String profileId) async {
    try {
      final file = File(await _path(profileId));
      if (await file.exists()) await file.delete();
    } catch (e, st) {
      appLogger.d('Discover home cache clear failed', error: e, stackTrace: st);
    }
  }

  /// Drops every profile's snapshot. Called on full logout so the next sign-in
  /// cannot paint the previous account's home for even one frame.
  Future<void> clearAll() {
    // Invalidate writes queued by cache instances that existed before logout.
    // The clear itself is ordered after any write already in progress, so no
    // old snapshot can recreate the directory after it has been removed.
    _generation++;
    final next = _operationChain.then((_) => _clearAllOnce());
    _operationChain = next;
    return next;
  }

  Future<void> _clearAllOnce() async {
    try {
      final directory = Directory(p.join((await _directoryProvider()).path, _directoryName));
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (e, st) {
      appLogger.d('Discover home cache clearAll failed', error: e, stackTrace: st);
    }
  }

  Future<String> _path(String profileId) async {
    final directory = await _directoryProvider();
    // Profile ids can contain path separators on some backends; base64url is
    // deterministic and filename-safe without pulling in a hash dependency.
    final safeId = base64Url.encode(utf8.encode(profileId)).replaceAll('=', '');
    return p.join(directory.path, _directoryName, '$safeId.json');
  }

  static Map<String, dynamic> _encode(DiscoverHomeSnapshot snapshot) {
    return {
      'version': _version,
      'savedAt': snapshot.savedAt.toIso8601String(),
      'hasMoreContinueWatching': snapshot.hasMoreContinueWatching,
      'onDeck': [for (final item in snapshot.onDeck) item.toJson()],
      'copies': {
        for (final MapEntry(:key, :value) in snapshot.copies.entries)
          key: [for (final item in value) item.toJson()],
      },
      'hubs': [for (final hub in snapshot.hubs) hub.toJson()],
    };
  }

  static DiscoverHomeSnapshot? _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    if ((decoded['version'] as num?)?.toInt() != _version) return null;
    final savedAt = DateTime.tryParse(decoded['savedAt'] as String? ?? '');
    if (savedAt == null) return null;

    final rawCopies = decoded['copies'];
    return DiscoverHomeSnapshot(
      onDeck: _decodeItems(decoded['onDeck']),
      copies: rawCopies is Map
          ? {
              for (final MapEntry(:key, :value) in rawCopies.entries)
                if (key is String) key: _decodeItems(value),
            }
          : const {},
      hubs: [
        for (final rawHub in (decoded['hubs'] as List? ?? const []))
          if (rawHub is Map<String, dynamic>) MediaHub.fromJson(rawHub),
      ],
      hasMoreContinueWatching: decoded['hasMoreContinueWatching'] as bool? ?? false,
      savedAt: savedAt,
    );
  }

  static List<MediaItem> _decodeItems(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map<String, dynamic>) MediaItem.fromJson(entry),
    ];
  }
}
