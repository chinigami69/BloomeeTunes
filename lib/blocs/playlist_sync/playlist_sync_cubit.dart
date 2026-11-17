import 'dart:async';
import 'dart:developer';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:Bloomee/blocs/playlist_sync/playlist_sync_state.dart';
import 'package:Bloomee/core/di/service_locator.dart';
import 'package:Bloomee/core/models/playlist_sync_source.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_sync_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/meta_resolver/cross_plugin_resolver.dart';
import 'package:Bloomee/services/plugin/plugin_service.dart';
import 'package:Bloomee/src/rust/api/plugin/commands.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';

export 'package:Bloomee/blocs/playlist_sync/playlist_sync_state.dart';

const int _kResolutionConcurrency = 5;
const double _kMinConfidence = 0.45;

/// Re-reads the link an imported playlist came from and brings the playlist
/// up to date: adds new songs, retries songs that were not found before and
/// removes songs that left the source (only ones the import added).
class PlaylistSyncCubit extends Cubit<PlaylistSyncState> {
  final PluginService _pluginService;
  final CrossPluginResolver _resolver;
  final PlaylistDAO? _playlistDaoOverride;
  final PlaylistSyncDAO? _syncDaoOverride;

  PlaylistSyncCubit({
    PluginService? pluginService,
    CrossPluginResolver? resolver,
    PlaylistDAO? playlistDao,
    PlaylistSyncDAO? syncDao,
  })  : _pluginService = pluginService ?? ServiceLocator.pluginService,
        _resolver = resolver ??
            CrossPluginResolver(
              pluginService: pluginService ?? ServiceLocator.pluginService,
            ),
        _playlistDaoOverride = playlistDao,
        _syncDaoOverride = syncDao,
        super(const PlaylistSyncState());

  late final PlaylistDAO _playlistDao = _playlistDaoOverride ??
      PlaylistDAO(DBProvider.db, TrackDAO(DBProvider.db));
  late final PlaylistSyncDAO _syncDao =
      _syncDaoOverride ?? PlaylistSyncDAO(DBProvider.db);

  /// Whether [playlistId] was imported from a link and can be synced.
  Future<bool> canSync(int playlistId) async {
    try {
      return await _syncDao.getForPlaylist(playlistId) != null;
    } catch (e) {
      log('canSync failed: $e', name: 'PlaylistSyncCubit');
      return false;
    }
  }

  Future<PlaylistSyncResult> sync(int playlistId) async {
    if (isClosed) return const PlaylistSyncResult.failed('Closed.');
    if (state.isSyncing(playlistId)) {
      return const PlaylistSyncResult.failed('Already syncing.');
    }
    emit(state.copyWith(syncing: {...state.syncing, playlistId}));
    try {
      return await _sync(playlistId);
    } on _SyncError catch (e) {
      return PlaylistSyncResult.failed(e.message);
    } on TimeoutException {
      return const PlaylistSyncResult.failed(
          'Timed out reading the source. Nothing changed.');
    } catch (e, st) {
      log('Sync failed: $e', name: 'PlaylistSyncCubit', error: e, stackTrace: st);
      return PlaylistSyncResult.failed('Sync failed: $e');
    } finally {
      if (!isClosed) {
        emit(state.copyWith(
            syncing: {...state.syncing}..remove(playlistId)));
      }
    }
  }

  Future<PlaylistSyncResult> _sync(int playlistId) async {
    final source = await _syncDao.getForPlaylist(playlistId);
    if (source == null) {
      throw const _SyncError('This playlist was not imported from a link.');
    }
    if (!_pluginService.getLoadedPlugins().contains(source.pluginId)) {
      throw _SyncError(
          'The importer plugin (${source.pluginId}) is not enabled. '
          'Turn it on in Plugins and try again.');
    }

    final response = await _pluginService.executeImport(
      pluginId: source.pluginId,
      command: ContentImporterCommand.getTracks(url: source.url),
    );
    if (response is! PluginResponse_ImportTracks) {
      throw const _SyncError('Unexpected response from the importer plugin.');
    }
    final fetched = response.field0;
    if (fetched.isEmpty && source.items.isNotEmpty) {
      throw const _SyncError(
          'The source returned no songs, so nothing was changed.');
    }

    final byKey = <String, ImportTrackItem>{};
    for (final t in fetched) {
      byKey.putIfAbsent(_keyOf(t), () => t);
    }
    final plan = planPlaylistSync(
      recorded: source.items,
      fetchedKeys: byKey.keys.toList(growable: false),
    );

    // A read that silently came back short must not empty the playlist.
    if (plan.removedKeys.length > 100 &&
        plan.removedKeys.length > source.items.length / 2) {
      throw _SyncError('The source would remove ${plan.removedKeys.length} '
          'of ${source.items.length} songs, so nothing was changed.');
    }

    final items = Map<String, String?>.of(source.items);
    for (final k in plan.removedKeys) {
      items.remove(k);
    }

    final toAdd = <Track>[];
    var notFound = 0;
    if (plan.toResolve.isNotEmpty) {
      final resolverIds = await _contentResolverPluginIds();
      if (resolverIds.isEmpty) {
        throw const _SyncError(
            'No music source plugin is enabled to find the new songs.');
      }
      final results = List<Track?>.filled(plan.toResolve.length, null);
      final semaphore = Semaphore(_kResolutionConcurrency);
      await Future.wait([
        for (var i = 0; i < plan.toResolve.length; i++)
          semaphore.run(() async {
            results[i] = await _resolve(byKey[plan.toResolve[i]]!, resolverIds);
          }),
      ]);
      for (var i = 0; i < plan.toResolve.length; i++) {
        final track = results[i];
        items[plan.toResolve[i]] = track?.id;
        if (track == null) {
          notFound++;
        } else {
          toAdd.add(track);
        }
      }
    }

    for (final mediaId in plan.mediaIdsToRemove) {
      await _playlistDao.removeTrackFromPlaylist(playlistId, mediaId);
    }
    if (toAdd.isNotEmpty) {
      await _playlistDao.addTracksToPlaylist(playlistId, toAdd);
    }
    await _syncDao.put(
      playlistId,
      source.copyWith(items: items, lastSyncedAt: DateTime.now()),
    );

    log('Synced playlist $playlistId: +${toAdd.length} '
        '-${plan.mediaIdsToRemove.length}, $notFound not found',
        name: 'PlaylistSyncCubit');
    return PlaylistSyncResult(
      added: toAdd.length,
      removed: plan.mediaIdsToRemove.length,
      notFound: notFound,
    );
  }

  Future<Track?> _resolve(ImportTrackItem item, List<String> pluginIds) async {
    try {
      final candidates = await _resolver.resolveTrack(
        target: TrackMatchTarget.fromImport(
          title: item.title,
          artists: item.artists,
          durationMs: item.durationMs?.toInt(),
        ),
        pluginIds: pluginIds,
        sequential: false,
        minConfidence: _kMinConfidence,
        earlyAcceptThreshold: 0.93,
        limit: 1,
      );
      return candidates.isEmpty ? null : candidates.first.track;
    } catch (e) {
      log('Could not resolve "${item.title}": $e', name: 'PlaylistSyncCubit');
      return null;
    }
  }

  Future<List<String>> _contentResolverPluginIds() async {
    final available = await _pluginService.getAvailablePlugins();
    final loaded = _pluginService.getLoadedPlugins().toSet();
    return available
        .where((p) =>
            p.pluginType == PluginType.contentResolver &&
            loaded.contains(p.manifest.id))
        .map((p) => p.manifest.id)
        .toList(growable: false);
  }

  static String _keyOf(ImportTrackItem t) => playlistSyncSourceKey(
        sourceId: t.sourceId,
        url: t.url,
        title: t.title,
        artists: t.artists,
      );
}

class _SyncError implements Exception {
  final String message;
  const _SyncError(this.message);
}
