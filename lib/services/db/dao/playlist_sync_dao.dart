import 'package:Bloomee/core/models/playlist_sync_source.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:isar_community/isar.dart';

/// Stores where imported playlists came from, keyed by playlist id.
///
/// Records live in [AppSettingsStrDB] so no schema migration is needed.
class PlaylistSyncDAO {
  static const String keyPrefix = 'playlist_sync_source:';

  final Future<Isar> _db;

  const PlaylistSyncDAO(this._db);

  static String keyFor(int playlistId) => '$keyPrefix$playlistId';

  /// The record for [playlistId], or null when the playlist was not imported
  /// from a link or the record no longer matches the playlist.
  Future<PlaylistSyncSource?> getForPlaylist(int playlistId) async {
    final isar = await _db;
    final playlist = await isar.playlistDBs.get(playlistId);
    if (playlist == null) return null;
    final row = await isar.appSettingsStrDBs
        .filter()
        .settingNameEqualTo(keyFor(playlistId))
        .findFirst();
    final source = PlaylistSyncSource.tryParse(row?.settingValue);
    if (source == null) return null;
    if (!source.belongsTo(
        name: playlist.name, createdAt: playlist.createdAt)) {
      return null;
    }
    return source;
  }

  /// Saves [source] for [playlistId], stamping the playlist's current name
  /// and creation time.
  Future<void> put(int playlistId, PlaylistSyncSource source) async {
    final isar = await _db;
    final playlist = await isar.playlistDBs.get(playlistId);
    if (playlist == null) return;
    final stamped = PlaylistSyncSource(
      pluginId: source.pluginId,
      url: source.url,
      playlistName: playlist.name,
      playlistCreatedAtMs: playlist.createdAt.millisecondsSinceEpoch,
      items: source.items,
      lastSyncedAt: source.lastSyncedAt,
    );
    await isar.writeTxn(() async {
      await isar.appSettingsStrDBs.put(AppSettingsStrDB(
        settingName: keyFor(playlistId),
        settingValue: stamped.toJson(),
        lastUpdated: DateTime.now(),
      ));
    });
  }

  Future<void> delete(int playlistId) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      await isar.appSettingsStrDBs
          .filter()
          .settingNameEqualTo(keyFor(playlistId))
          .deleteAll();
    });
  }
}
