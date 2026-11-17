import 'package:Bloomee/core/models/playlist_sync_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('planPlaylistSync', () {
    test('new source songs are resolved in source order', () {
      final plan = planPlaylistSync(
        recorded: {'id:a': 'yt1', 'id:b': 'yt2'},
        fetchedKeys: ['id:a', 'id:b', 'id:c', 'id:d'],
      );
      expect(plan.toResolve, ['id:c', 'id:d']);
      expect(plan.removedKeys, isEmpty);
      expect(plan.mediaIdsToRemove, isEmpty);
    });

    test('songs not found last time are retried, skipped ones are not', () {
      final plan = planPlaylistSync(
        recorded: {'id:a': 'yt1', 'id:b': null, 'id:c': ''},
        fetchedKeys: ['id:a', 'id:b', 'id:c'],
      );
      expect(plan.toResolve, ['id:b']);
      expect(plan.isEmpty, isFalse);
    });

    test('songs that left the source are removed', () {
      final plan = planPlaylistSync(
        recorded: {'id:a': 'yt1', 'id:b': 'yt2', 'id:c': null, 'id:d': ''},
        fetchedKeys: ['id:a'],
      );
      expect(plan.removedKeys, unorderedEquals(['id:b', 'id:c', 'id:d']));
      expect(plan.mediaIdsToRemove, ['yt2']);
    });

    test('a track still used by another source song is kept', () {
      final plan = planPlaylistSync(
        recorded: {'id:a': 'yt1', 'id:b': 'yt1'},
        fetchedKeys: ['id:a'],
      );
      expect(plan.removedKeys, ['id:b']);
      expect(plan.mediaIdsToRemove, isEmpty);
    });

    test('duplicates in the source are handled once', () {
      final plan = planPlaylistSync(
        recorded: const {},
        fetchedKeys: ['id:a', 'id:a', 'id:b'],
      );
      expect(plan.toResolve, ['id:a', 'id:b']);
    });

    test('no changes gives an empty plan', () {
      final plan = planPlaylistSync(
        recorded: {'id:a': 'yt1'},
        fetchedKeys: ['id:a'],
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('playlistSyncSourceKey', () {
    test('prefers id, then url, then title and artists', () {
      expect(
        playlistSyncSourceKey(
            sourceId: '42', url: 'u', title: 'T', artists: ['A']),
        'id:42',
      );
      expect(
        playlistSyncSourceKey(url: 'u', title: 'T', artists: ['A']),
        'url:u',
      );
      expect(
        playlistSyncSourceKey(
            sourceId: ' ', title: ' Song ', artists: ['Ab', 'Cd ']),
        'meta:song|ab,cd',
      );
    });
  });

  group('PlaylistSyncSource', () {
    test('survives a JSON round trip', () {
      final source = PlaylistSyncSource(
        pluginId: 'spotify',
        url: 'https://open.spotify.com/playlist/x',
        playlistName: 'Liked Songs · Part 7',
        playlistCreatedAtMs: 1000,
        items: const {'id:a': 'yt1', 'id:b': null, 'id:c': ''},
        lastSyncedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      final back = PlaylistSyncSource.tryParse(source.toJson())!;
      expect(back.pluginId, source.pluginId);
      expect(back.url, source.url);
      expect(back.playlistName, source.playlistName);
      expect(back.playlistCreatedAtMs, 1000);
      expect(back.items, source.items);
      expect(back.lastSyncedAt, source.lastSyncedAt);
    });

    test('rejects broken records', () {
      expect(PlaylistSyncSource.tryParse(null), isNull);
      expect(PlaylistSyncSource.tryParse('not json'), isNull);
      expect(PlaylistSyncSource.tryParse('{"url": "x"}'), isNull);
    });

    test('only belongs to the playlist it was made for', () {
      const source = PlaylistSyncSource(
        pluginId: 'p',
        url: 'u',
        playlistName: 'Part 1',
        playlistCreatedAtMs: 5,
        items: {},
      );
      final other = DateTime.fromMillisecondsSinceEpoch(9);
      expect(source.belongsTo(name: 'part 1', createdAt: other), isTrue);
      expect(
          source.belongsTo(
              name: 'Renamed', createdAt: DateTime.fromMillisecondsSinceEpoch(5)),
          isTrue);
      expect(source.belongsTo(name: 'Other', createdAt: other), isFalse);
    });
  });
}
