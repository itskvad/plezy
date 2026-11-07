import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/services/discover_home_cache.dart';

void main() {
  test('hub JSON round-trips every field the home cache renders', () {
    const hub = MediaHub(
      id: 'home.recent',
      identifier: 'home.recent',
      title: 'Recently Added',
      type: 'movie',
      items: [],
      size: 4,
      more: true,
      libraryId: '1',
      serverId: 'server-1',
      serverName: 'Plex',
    );

    final restored = MediaHub.fromJson(hub.toJson());

    expect(restored.id, hub.id);
    expect(restored.identifier, hub.identifier);
    expect(restored.title, hub.title);
    expect(restored.type, hub.type);
    expect(restored.size, hub.size);
    expect(restored.more, hub.more);
    expect(restored.libraryId, hub.libraryId);
    expect(restored.serverId, hub.serverId);
    expect(restored.serverName, hub.serverName);
    expect(restored.items, isEmpty);
  });

  test('snapshot writes and reads per profile, ignoring other profiles', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-discover-cache');
    addTearDown(() => directory.delete(recursive: true));
    final cache = DiscoverHomeCache(directoryProvider: () async => directory);
    final snapshot = DiscoverHomeSnapshot(
      onDeck: const [],
      copies: const {},
      hubs: const [MediaHub(id: 'home.recent', title: 'Recently Added', type: 'movie', items: [])],
      hasMoreContinueWatching: false,
      savedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    // A slash and a space exercise the filename-safe key encoding.
    await cache.write('local user/1', snapshot);

    final restored = await cache.read('local user/1');
    expect(restored, isNotNull);
    expect(restored!.hubs.single.title, 'Recently Added');
    expect(restored.savedAt, snapshot.savedAt);
    expect(restored.hasMoreContinueWatching, isFalse);
    expect(await cache.read('local user/2'), isNull);
  });

  test('clearAll invalidates writes queued by pre-logout cache instances', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-discover-cache-clear');
    addTearDown(() => directory.delete(recursive: true));
    final snapshot = DiscoverHomeSnapshot(
      onDeck: const [],
      copies: const {},
      hubs: const [MediaHub(id: 'home.recent', title: 'Stale', type: 'movie', items: [])],
      hasMoreContinueWatching: false,
      savedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    final beforeLogout = DiscoverHomeCache(directoryProvider: () async => directory);
    await DiscoverHomeCache(directoryProvider: () async => directory).clearAll();

    // A session that outlives the logout must not recreate the deleted file.
    await beforeLogout.write('profile-a', snapshot);
    expect(await beforeLogout.read('profile-a'), isNull);

    final afterLogout = DiscoverHomeCache(directoryProvider: () async => directory);
    await afterLogout.write('profile-a', snapshot);
    expect(await afterLogout.read('profile-a'), isNotNull);
  });
}
