import 'package:equatable/equatable.dart';

class PlaylistSyncState extends Equatable {
  /// Playlists currently being synced.
  final Set<int> syncing;

  const PlaylistSyncState({this.syncing = const {}});

  bool isSyncing(int playlistId) => syncing.contains(playlistId);

  PlaylistSyncState copyWith({Set<int>? syncing}) =>
      PlaylistSyncState(syncing: syncing ?? this.syncing);

  @override
  List<Object?> get props => [syncing];
}

/// Outcome of one sync. [error] is set when nothing was changed.
class PlaylistSyncResult {
  final int added;
  final int removed;
  final int notFound;
  final String? error;

  const PlaylistSyncResult({
    this.added = 0,
    this.removed = 0,
    this.notFound = 0,
    this.error,
  });

  const PlaylistSyncResult.failed(String message)
      : added = 0,
        removed = 0,
        notFound = 0,
        error = message;

  bool get ok => error == null;
  bool get changed => added > 0 || removed > 0;
}
