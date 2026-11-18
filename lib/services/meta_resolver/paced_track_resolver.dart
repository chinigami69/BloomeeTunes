import 'dart:async';
import 'dart:developer';

import 'package:Bloomee/services/meta_resolver/cross_plugin_resolver.dart';

/// Resolves many tracks without flooding the source plugins.
///
/// Sources throttle bursts of searches, which made large imports miss most
/// of their songs at random. This runs a small number of lookups at a time,
/// tries plugins one after another, and gives songs whose lookup went
/// unanswered (errors, timeouts, empty answers) more attempts after a pause.
/// Songs the source answered for but did not match are not retried.
class PacedTrackResolver {
  final CrossPluginResolver resolver;

  /// Lookups running at once in the first round. Retries run one at a time.
  final int concurrency;

  /// Pause after each lookup.
  final Duration gap;

  /// Pause before each retry round; its length is the number of retries.
  final List<Duration> retryPauses;

  const PacedTrackResolver({
    required this.resolver,
    this.concurrency = 2,
    this.gap = const Duration(milliseconds: 250),
    this.retryPauses = const [Duration(seconds: 6), Duration(seconds: 20)],
  });

  /// Resolves [count] tracks. [onStart] is called when a lookup begins and
  /// [onResult] with its candidates (best first, empty on a miss); both can
  /// be called again for the same index when it is retried.
  Future<void> resolveAll({
    required int count,
    required TrackMatchTarget Function(int index) targetOf,
    required List<String> pluginIds,
    required void Function(int index, List<ScoredTrackCandidate> candidates)
        onResult,
    void Function(int index)? onStart,
    bool Function()? isCancelled,
    double minConfidence = 0.45,
    double earlyAcceptThreshold = 0.93,
    int limit = 5,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    var pending = List<int>.generate(count, (i) => i);
    for (var round = 0; pending.isNotEmpty; round++) {
      if (cancelled()) return;
      final isLastRound = round >= retryPauses.length;
      final retry = <int>[];
      final semaphore = Semaphore(round == 0 ? concurrency : 1);

      await Future.wait([
        for (final index in pending)
          semaphore.run(() async {
            if (cancelled()) return;
            onStart?.call(index);
            final stats = ResolveStats();
            var candidates = const <ScoredTrackCandidate>[];
            try {
              candidates = await resolver.resolveTrack(
                target: targetOf(index),
                pluginIds: pluginIds,
                sequential: true,
                minConfidence: minConfidence,
                earlyAcceptThreshold: earlyAcceptThreshold,
                limit: limit,
                stats: stats,
              );
            } catch (e) {
              stats.errors++;
              log('Lookup $index failed: $e', name: 'PacedTrackResolver');
            }
            if (cancelled()) return;
            onResult(index, candidates);
            if (candidates.isEmpty && stats.looksUnanswered && !isLastRound) {
              retry.add(index);
            }
            await Future<void>.delayed(gap);
          }),
      ]);

      if (retry.isEmpty || isLastRound || cancelled()) return;
      retry.sort();
      log('Retrying ${retry.length} unanswered lookups '
          '(round ${round + 2} of ${retryPauses.length + 1})',
          name: 'PacedTrackResolver');
      await Future<void>.delayed(retryPauses[round]);
      pending = retry;
    }
  }
}
