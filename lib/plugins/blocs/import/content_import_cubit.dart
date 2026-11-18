import 'dart:async';
import 'dart:developer';

import 'package:Bloomee/services/meta_resolver/cross_plugin_resolver.dart';
import 'package:Bloomee/services/meta_resolver/paced_track_resolver.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:Bloomee/core/di/service_locator.dart';
import 'package:Bloomee/core/models/playlist_sync_source.dart';
import 'package:Bloomee/plugins/blocs/import/content_import_state.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_sync_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/plugin/plugin_service.dart';
import 'package:Bloomee/src/rust/api/plugin/commands.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';

const double _kMinConfidence = 0.45;
const int _kMaxCandidatesPerTrack = 5;

class ContentImportCubit extends Cubit<ContentImportState> {
  final PluginService _pluginService;
  final CrossPluginResolver _resolver;
  final PlaylistDAO _playlistDao;
  final PlaylistSyncDAO? _syncDaoOverride;
  late final PlaylistSyncDAO _syncDao =
      _syncDaoOverride ?? PlaylistSyncDAO(DBProvider.db);

  bool _cancelRequested = false;
  int _operationId = 0;
  ContentImporterCommand? _retryCommand;

  bool _isCurrent(int operationId) => !isClosed && operationId == _operationId;

  ContentImportCubit({
    PluginService? pluginService,
    CrossPluginResolver? resolver,
    PlaylistDAO? playlistDao,
    PlaylistSyncDAO? playlistSyncDao,
  })  : _pluginService = pluginService ?? ServiceLocator.pluginService,
        _resolver = resolver ??
            CrossPluginResolver(
              pluginService: pluginService ?? ServiceLocator.pluginService,
            ),
        _playlistDao = playlistDao ?? _defaultPlaylistDao(),
        _syncDaoOverride = playlistSyncDao,
        super(const ContentImportState());

  static PlaylistDAO _defaultPlaylistDao() {
    final trackDao = TrackDAO(DBProvider.db);
    return PlaylistDAO(DBProvider.db, trackDao);
  }

  // ── URL import pipeline ─────────────────────────────────────────────────

  Future<void> checkUrl(String pluginId, String url) async {
    if (isClosed) return;
    final operationId = ++_operationId;
    _cancelRequested = false;
    emit(ContentImportState(pluginId: pluginId, url: url));
    await _runImportStep(
      pluginId,
      ContentImporterCommand.canHandleUrl(url: url),
      operationId,
    );
  }

  /// Resume the failed command, sharing any native request still in progress.
  Future<void> retry() async {
    if (isClosed || state.phase != ImportPhase.error) return;
    final command = _retryCommand;
    final pluginId = state.pluginId;
    if (command == null || pluginId == null) {
      reset();
      return;
    }
    await _runImportStep(pluginId, command, ++_operationId);
  }

  Future<void> _runImportStep(
    String pluginId,
    ContentImporterCommand command,
    int operationId,
  ) async {
    if (!_isCurrent(operationId)) return;
    final (phase, timeoutError, failurePrefix) = switch (command) {
      ContentImporterCommand_CanHandleUrl() => (
          ImportPhase.checkingUrl,
          'Plugin timed out while checking URL.',
          'Failed to check URL',
        ),
      ContentImporterCommand_GetCollectionInfo() => (
          ImportPhase.fetchingInfo,
          'Timed out fetching collection info.',
          'Failed to fetch collection info',
        ),
      ContentImporterCommand_GetTracks() => (
          ImportPhase.fetchingTracks,
          'Timed out fetching tracks.',
          'Failed to fetch tracks',
        ),
    };
    _retryCommand = command;
    emit(state.copyWith(phase: phase, clearError: true));

    final PluginResponse response;
    try {
      response = await _pluginService.executeImport(
        pluginId: pluginId,
        command: command,
      );
    } catch (e, stackTrace) {
      if (!_isCurrent(operationId)) return;
      log('$failurePrefix ($pluginId): $e',
          name: 'ContentImportCubit', error: e, stackTrace: stackTrace);
      emit(state.copyWith(
        phase: ImportPhase.error,
        error: e is TimeoutException ? timeoutError : '$failurePrefix: $e',
      ));
      return;
    }
    if (!_isCurrent(operationId)) return;

    switch (command) {
      case ContentImporterCommand_CanHandleUrl(:final url):
        if (response is PluginResponse_CanHandle && response.field0) {
          await _runImportStep(pluginId,
              ContentImporterCommand.getCollectionInfo(url: url), operationId);
          return;
        }
        _retryCommand = null;
        emit(state.copyWith(
          phase: ImportPhase.error,
          error: 'This plugin cannot handle the provided URL.',
        ));
      case ContentImporterCommand_GetCollectionInfo(:final url):
        if (response is PluginResponse_CollectionInfo) {
          emit(state.copyWith(collectionInfo: response.field0));
          await _runImportStep(pluginId,
              ContentImporterCommand.getTracks(url: url), operationId);
          return;
        }
        emit(state.copyWith(
          phase: ImportPhase.error,
          error: 'Unexpected response when fetching collection info.',
        ));
      case ContentImporterCommand_GetTracks():
        if (response is PluginResponse_ImportTracks) {
          emit(state.copyWith(
            tracks: List.unmodifiable(
              response.field0.map((t) => ImportTrackEntry(sourceTrack: t)),
            ),
            phase: ImportPhase.resolving,
          ));
          await _resolveTracks(operationId);
          if (_isCurrent(operationId) && state.phase != ImportPhase.error) {
            _retryCommand = null;
          }
          return;
        }
        emit(state.copyWith(
          phase: ImportPhase.error,
          error: 'Unexpected response when fetching tracks.',
        ));
    }
  }

  // ── Resolve imported tracks ──────────────────────────────────────────────

  Future<void> _resolveTracks(int operationId) async {
    final List<String> resolverPluginIds;
    try {
      resolverPluginIds = await _getContentResolverPluginIds();
    } catch (e, stackTrace) {
      if (!_isCurrent(operationId) || _cancelRequested) return;
      log('Resolver discovery failed: $e',
          name: 'ContentImportCubit', error: e, stackTrace: stackTrace);
      emit(state.copyWith(
        phase: ImportPhase.error,
        error: 'Failed to fetch tracks: resolver discovery failed: $e',
      ));
      return;
    }
    if (!_isCurrent(operationId) || _cancelRequested) return;
    if (resolverPluginIds.isEmpty) {
      log('No content-resolver plugins loaded; skipping resolution.',
          name: 'ContentImportCubit');
      emit(state.copyWith(phase: ImportPhase.review));
      return;
    }

    final tracks = List<ImportTrackEntry>.from(state.tracks);

    void emitProgress() {
      if (!_isCurrent(operationId) || _cancelRequested) return;
      final counts = _recount(tracks);
      emit(state.copyWith(
        tracks: List.unmodifiable(tracks),
        resolvedCount: counts.resolved,
        failedCount: counts.failed,
      ));
    }

    // Paced, with retries for lookups the source did not answer, so a large
    // import does not get throttled into missing most of its songs.
    await PacedTrackResolver(resolver: _resolver).resolveAll(
      count: tracks.length,
      pluginIds: resolverPluginIds,
      minConfidence: _kMinConfidence,
      limit: _kMaxCandidatesPerTrack,
      isCancelled: () => !_isCurrent(operationId) || _cancelRequested,
      targetOf: (index) {
        final source = tracks[index].sourceTrack;
        return TrackMatchTarget.fromImport(
          title: source.title,
          artists: source.artists,
          durationMs: source.durationMs?.toInt(),
        );
      },
      onStart: (index) {
        tracks[index] =
            tracks[index].copyWith(status: TrackResolutionStatus.resolving);
        emitProgress();
      },
      onResult: (index, candidates) {
        final entry = tracks[index];
        tracks[index] = candidates.isNotEmpty
            ? entry.copyWith(
                status: TrackResolutionStatus.resolved,
                resolvedTrack: candidates.first.track,
                candidates:
                    candidates.map((c) => c.track).toList(growable: false),
              )
            : entry.copyWith(
                status: TrackResolutionStatus.failed,
                candidates: const [],
              );
        emitProgress();
      },
    );

    if (_isCurrent(operationId) && !_cancelRequested) {
      final counts = _recount(tracks);
      log(
        'Resolution complete: ${counts.resolved} resolved, '
        '${counts.failed} failed out of ${tracks.length}',
        name: 'ContentImportCubit',
      );
      emit(state.copyWith(
        tracks: List.unmodifiable(tracks),
        resolvedCount: counts.resolved,
        failedCount: counts.failed,
        phase: ImportPhase.review,
      ));
    }
  }

  // ── Cancellation ─────────────────────────────────────────────────────────

  void cancelResolution() {
    if (state.phase != ImportPhase.resolving) return;
    _cancelRequested = true;
    log('Resolution cancelled by user.', name: 'ContentImportCubit');

    final counts = _recount(state.tracks);
    emit(state.copyWith(
      phase: ImportPhase.review,
      resolvedCount: counts.resolved,
      failedCount: counts.failed,
    ));
  }

  // ── User candidate selection ─────────────────────────────────────────────

  void pickCandidate(int trackIndex, int? candidateIdx) {
    final tracks = List<ImportTrackEntry>.from(state.tracks);
    if (trackIndex < 0 || trackIndex >= tracks.length) return;

    tracks[trackIndex] = tracks[trackIndex].copyWith(
      selectedCandidateIndex: candidateIdx,
    );

    final counts = _recount(tracks);
    emit(state.copyWith(
      tracks: List.unmodifiable(tracks),
      resolvedCount: counts.resolved,
      failedCount: counts.failed,
    ));
  }

  // ── Step 5: Save to Library ──────────────────────────────────────────────

  Future<void> saveToLibrary({String? customName}) async {
    final info = state.collectionInfo;
    if (info == null) return;

    emit(state.copyWith(phase: ImportPhase.saving));

    try {
      final rawName = customName?.trim().isNotEmpty == true
          ? customName!.trim()
          : info.title.trim();
      final playlistName = rawName.isNotEmpty ? rawName : 'Imported Playlist';

      final playlistId = await _playlistDao.ensurePlaylist(playlistName);

      final thumbUrl = info.thumbnailUrl;
      if (thumbUrl != null && thumbUrl.isNotEmpty) {
        await _playlistDao.updatePlaylistThumbnail(playlistId, thumbUrl);
      }

      var savedCount = 0;
      for (final entry in state.tracks) {
        final track = entry.effectiveTrack;
        if (track != null) {
          await _playlistDao.addTrackToPlaylist(playlistId, track);
          savedCount++;
        }
      }

      log('Saved $savedCount tracks to "$playlistName".',
          name: 'ContentImportCubit');

      await _rememberSource(playlistId);

      emit(state.copyWith(
        phase: ImportPhase.done,
        resolvedCount: savedCount,
      ));
    } catch (e) {
      log('saveToLibrary failed: $e', name: 'ContentImportCubit');
      emit(state.copyWith(
        phase: ImportPhase.error,
        error: 'Failed to save playlist: $e',
      ));
    }
  }

  /// Records the link this playlist came from so it can be synced later.
  /// Never fails the import.
  Future<void> _rememberSource(int playlistId) async {
    final pluginId = state.pluginId;
    final url = state.url;
    if (pluginId == null || url == null || url.trim().isEmpty) return;
    try {
      final previous = await _syncDao.getForPlaylist(playlistId);
      final items = <String, String?>{
        // Importing a different link into the same playlist starts over.
        if (previous != null && previous.url == url) ...previous.items,
      };
      for (final entry in state.tracks) {
        final t = entry.sourceTrack;
        final key = playlistSyncSourceKey(
          sourceId: t.sourceId,
          url: t.url,
          title: t.title,
          artists: t.artists,
        );
        final id = entry.effectiveTrack?.id;
        items[key] = id ?? (entry.isSkipped ? '' : null);
      }
      await _syncDao.put(
        playlistId,
        PlaylistSyncSource(
          pluginId: pluginId,
          url: url,
          playlistName: '',
          items: items,
          lastSyncedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      log('Could not record import source: $e', name: 'ContentImportCubit');
    }
  }

  // ── Reset ────────────────────────────────────────────────────────────────

  void reset() {
    if (isClosed) return;
    ++_operationId;
    _retryCommand = null;
    _cancelRequested = false;
    emit(const ContentImportState());
  }

  // ── M3U Import ────────────────────────────────────────────────────────────

  /// Directly loads tracks parsed from an M3U file and starts resolution.
  ///
  /// Bypasses the URL-check / collection-info / fetch-tracks plugin steps.
  /// The [summary] provides playlist metadata (title, kind, trackCount).
  Future<void> loadFromM3U(
    List<ImportTrackItem> tracks,
    ImportCollectionSummary summary,
  ) async {
    if (isClosed) return;
    final operationId = ++_operationId;
    _retryCommand = null;
    _cancelRequested = false;
    emit(ContentImportState(
      phase: ImportPhase.resolving,
      collectionInfo: summary,
      tracks: List.unmodifiable(
        tracks.map((t) => ImportTrackEntry(sourceTrack: t)).toList(),
      ),
    ));
    await _resolveTracks(operationId);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Returns only loaded content-resolver plugin IDs.
  Future<List<String>> _getContentResolverPluginIds() async {
    final available = await _pluginService.getAvailablePlugins();
    final loadedIds = _pluginService.getLoadedPlugins().toSet();
    return available
        .where((p) =>
            p.pluginType == PluginType.contentResolver &&
            loadedIds.contains(p.manifest.id))
        .map((p) => p.manifest.id)
        .toList(growable: false);
  }

  /// Single source of truth for resolved/failed counts.
  ({int resolved, int failed}) _recount(List<ImportTrackEntry> tracks) {
    var resolved = 0;
    var failed = 0;
    for (final t in tracks) {
      if (t.isSkipped) {
        failed++;
      } else if (t.effectiveTrack != null) {
        resolved++;
      } else if (t.status != TrackResolutionStatus.pending &&
          t.status != TrackResolutionStatus.resolving) {
        failed++;
      }
    }
    return (resolved: resolved, failed: failed);
  }
}
