import 'dart:convert';

/// Where an imported playlist came from, so it can be synced again later.
///
/// [items] maps the source key of every track the source returned (see
/// [playlistSyncSourceKey]) to the media id Bloomee resolved it to:
/// - a non-empty id: the track was added to the playlist;
/// - an empty string: the user skipped it during review (never retried);
/// - `null`: no match was found (retried on the next sync).
class PlaylistSyncSource {
  static const int currentVersion = 1;

  final String pluginId;
  final String url;

  /// Name and creation time of the playlist when the source was recorded.
  /// Used to make sure a record still belongs to the same playlist (for
  /// example after a backup restore assigned new ids).
  final String playlistName;
  final int? playlistCreatedAtMs;

  final Map<String, String?> items;
  final DateTime? lastSyncedAt;

  const PlaylistSyncSource({
    required this.pluginId,
    required this.url,
    required this.playlistName,
    this.playlistCreatedAtMs,
    required this.items,
    this.lastSyncedAt,
  });

  bool belongsTo({required String name, required DateTime createdAt}) =>
      playlistName.toLowerCase() == name.toLowerCase() ||
      playlistCreatedAtMs == createdAt.millisecondsSinceEpoch;

  PlaylistSyncSource copyWith({
    Map<String, String?>? items,
    String? playlistName,
    DateTime? lastSyncedAt,
  }) =>
      PlaylistSyncSource(
        pluginId: pluginId,
        url: url,
        playlistName: playlistName ?? this.playlistName,
        playlistCreatedAtMs: playlistCreatedAtMs,
        items: items ?? this.items,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  Map<String, dynamic> toMap() => {
        'v': currentVersion,
        'pluginId': pluginId,
        'url': url,
        'playlistName': playlistName,
        'playlistCreatedAtMs': playlistCreatedAtMs,
        'items': items,
        'lastSyncedAt': lastSyncedAt?.millisecondsSinceEpoch,
      };

  String toJson() => json.encode(toMap());

  /// Returns null for anything that is not a valid record.
  static PlaylistSyncSource? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = json.decode(source);
      if (map is! Map<String, dynamic>) return null;
      final pluginId = map['pluginId'];
      final url = map['url'];
      final rawItems = map['items'];
      if (pluginId is! String || url is! String || rawItems is! Map) {
        return null;
      }
      final lastSynced = map['lastSyncedAt'];
      return PlaylistSyncSource(
        pluginId: pluginId,
        url: url,
        playlistName: (map['playlistName'] as String?) ?? '',
        playlistCreatedAtMs: map['playlistCreatedAtMs'] as int?,
        items: {
          for (final e in rawItems.entries)
            if (e.key is String) e.key as String: e.value as String?,
        },
        lastSyncedAt: lastSynced is int
            ? DateTime.fromMillisecondsSinceEpoch(lastSynced)
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Stable identity of a track inside an imported collection.
///
/// Prefers the source's own id, then its url, then title + artists.
String playlistSyncSourceKey({
  String? sourceId,
  String? url,
  required String title,
  required List<String> artists,
}) {
  final id = sourceId?.trim();
  if (id != null && id.isNotEmpty) return 'id:$id';
  final link = url?.trim();
  if (link != null && link.isNotEmpty) return 'url:$link';
  final who = artists.map((a) => a.trim().toLowerCase()).join(',');
  return 'meta:${title.trim().toLowerCase()}|$who';
}

/// What a sync has to do, computed without touching the database.
class PlaylistSyncPlan {
  /// Source keys to look up and add, in source order. Includes keys that
  /// failed to resolve last time.
  final List<String> toResolve;

  /// Source keys that are no longer in the source.
  final List<String> removedKeys;

  /// Media ids to take out of the playlist: tracks that came from a removed
  /// key and are not also used by a key that is still in the source.
  final List<String> mediaIdsToRemove;

  const PlaylistSyncPlan({
    required this.toResolve,
    required this.removedKeys,
    required this.mediaIdsToRemove,
  });

  bool get isEmpty => toResolve.isEmpty && removedKeys.isEmpty;
}

PlaylistSyncPlan planPlaylistSync({
  required Map<String, String?> recorded,
  required List<String> fetchedKeys,
}) {
  final fetched = <String>{};
  final toResolve = <String>[];
  for (final key in fetchedKeys) {
    if (!fetched.add(key)) continue;
    if (!recorded.containsKey(key) || recorded[key] == null) {
      toResolve.add(key);
    }
  }

  final removedKeys = recorded.keys.where((k) => !fetched.contains(k)).toList();

  final keptIds = <String>{
    for (final k in fetched)
      if (recorded[k] case final id? when id.isNotEmpty) id,
  };
  final mediaIdsToRemove = <String>[];
  final seen = <String>{};
  for (final k in removedKeys) {
    final id = recorded[k];
    if (id == null || id.isEmpty || keptIds.contains(id)) continue;
    if (seen.add(id)) mediaIdsToRemove.add(id);
  }

  return PlaylistSyncPlan(
    toResolve: toResolve,
    removedKeys: removedKeys,
    mediaIdsToRemove: mediaIdsToRemove,
  );
}
