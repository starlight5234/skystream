import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/providers/active_watchparty_provider.dart';

abstract class WatchPartyPlayerAdapter {
  int get positionMs;
  bool get isPlaying;
  void play();
  void pause();
  void seekTo(Duration position);
  void showNotification(String message);
}

class WatchPartySyncCoordinator {
  final WidgetRef ref;
  final WatchPartyPlayerAdapter adapter;

  bool _disposed = false;

  WatchPartySyncCoordinator({
    required this.ref,
    required this.adapter,
  });

  void attach() {
    final session = ref.read(activeWatchPartyProvider);
    if (session != null) {
      _bindSession(session);
    }
  }

  void onSessionChanged(ActiveWatchPartyState? previous, ActiveWatchPartyState? next) {
    if (next != null) {
      _bindSession(next);
    }
  }

  void _bindSession(ActiveWatchPartyState session) {
    final chatService = session.chatService;

    chatService.onGuestConnected = (guestName) {
      if (_disposed) return;
      if (ref.read(activeWatchPartyProvider)?.isPausedForMembers == true) {
        ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
        scheduleMicrotask(() {
          adapter.play();
          chatService.sendPlayerCommand('play', adapter.positionMs);
        });
      }
    };

    chatService.onSyncStateRequested = (requester) {
      if (_disposed) return;
      final currentMs = adapter.positionMs;
      final isWaiting = ref.read(activeWatchPartyProvider)?.isPausedForMembers == true;
      final isPlaying = isWaiting ? true : adapter.isPlaying;
      chatService.sendSyncStateResponse(currentMs, isPlaying);

      if (isWaiting) {
        ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
        scheduleMicrotask(() {
          adapter.play();
          chatService.sendPlayerCommand('play', currentMs);
        });
      }
    };

    chatService.onSyncStateReceived = (positionMs, isPlaying) {
      if (_disposed) return;
      adapter.seekTo(Duration(milliseconds: positionMs));
      if (isPlaying) {
        adapter.play();
      } else {
        adapter.pause();
      }
    };

    chatService.onPlayerCommandReceived = (cmd, positionMs) {
      if (_disposed) return;
      if (cmd == 'play') {
        adapter.play();
      } else if (cmd == 'pause') {
        adapter.pause();
      } else if (cmd == 'seek') {
        adapter.seekTo(Duration(milliseconds: positionMs));
      }
    };

    chatService.onSharerLeftStream = (sharerName) {
      if (_disposed) return;
      ref.read(activeWatchPartyProvider.notifier).unlockPlaybackControl();
      adapter.showNotification(
        'Stream sharer ($sharerName) left the player. Playback controls unlocked.',
      );
    };

    if (!session.isPausedForMembers) {
      chatService.requestSyncState();
    }
  }

  /// Handles user pressing play/pause in the UI.
  /// Returns true if the action was executed.
  bool handleUserTogglePlay() {
    if (_disposed) return false;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) {
      if (adapter.isPlaying) {
        adapter.pause();
      } else {
        adapter.play();
      }
      return true;
    }

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    if (adapter.isPlaying) {
      session.chatService.sendPlayerCommand('pause', adapter.positionMs);
      adapter.pause();
    } else {
      session.chatService.sendPlayerCommand('play', adapter.positionMs);
      adapter.play();
    }
    return true;
  }

  /// Handles user seeking in the UI (scrubber release or chapter jump).
  /// Returns true if the action was executed.
  bool handleUserSeek(Duration targetPosition) {
    if (_disposed) return false;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) {
      adapter.seekTo(targetPosition);
      return true;
    }

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    session.chatService.sendPlayerCommand('seek', targetPosition.inMilliseconds);
    adapter.seekTo(targetPosition);
    return true;
  }

  /// Handles user relative seeking (+/- 10s skip).
  /// Returns true if the action was executed.
  bool handleUserSeekRelative(Duration offset, Duration maxDuration) {
    if (_disposed) return false;
    final session = ref.read(activeWatchPartyProvider);
    final targetMs = (adapter.positionMs + offset.inMilliseconds)
        .clamp(0, maxDuration.inMilliseconds);
    final target = Duration(milliseconds: targetMs);

    if (session == null) {
      adapter.seekTo(target);
      return true;
    }

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    session.chatService.sendPlayerCommand('seek', targetMs);
    adapter.seekTo(target);
    return true;
  }

  void dispose() {
    _disposed = true;
    try {
      final session = ref.read(activeWatchPartyProvider);
      if (session != null) {
        session.chatService.onGuestConnected = null;
        session.chatService.onSyncStateRequested = null;
        session.chatService.onSyncStateReceived = null;
        session.chatService.onPlayerCommandReceived = null;
        session.chatService.onSharerLeftStream = null;
      }
    } catch (_) {}
  }
}
