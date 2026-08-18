import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/providers/active_watchparty_provider.dart';

abstract class WatchPartyPlayerAdapter {
  int get positionMs;
  bool get isPlaying;
  void play();
  void pause();
  void seekTo(Duration position);
  void showNotification(String message);
  VoidCallback registerPlayingListener(VoidCallback onPlayingChanged);
}

class WatchPartySyncCoordinator {
  final WidgetRef ref;
  final WatchPartyPlayerAdapter adapter;

  bool _disposed = false;
  ActiveWatchPartyState? _lastKnownSession;
  // Cache the notifier so dispose() can clear activeMedia without calling
  // ref.read() after the widget is unmounted (WidgetRef throws post-unmount).
  ActiveWatchPartyNotifier? _notifier;
  VoidCallback? _playingListenerDispose;
  Timer? _syncRequestTimer;
  bool _isUnpausing = false;

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
    _lastKnownSession = session;
    _notifier = ref.read(activeWatchPartyProvider.notifier);
    final chatService = session.chatService;

    if (session.isPausedForMembers) {
      scheduleMicrotask(() => adapter.pause());
    }

    _playingListenerDispose?.call();
    _playingListenerDispose = adapter.registerPlayingListener(() {
      if (_disposed) return;
      if (ref.read(activeWatchPartyProvider)?.isPausedForMembers == true && adapter.isPlaying) {
        adapter.pause();
      }
    });

    chatService.onGuestConnected = (guestName) {
      if (_disposed) return;
      if (!_isUnpausing && ref.read(activeWatchPartyProvider)?.isPausedForMembers == true) {
        _isUnpausing = true;
        ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
        scheduleMicrotask(() {
          adapter.play();
          chatService.sendPlayerCommand('play', adapter.positionMs);
          _isUnpausing = false;
        });
      }
    };

    chatService.onSyncStateRequested = (requester) {
      if (_disposed) return;
      final currentSession = ref.read(activeWatchPartyProvider);
      if (currentSession?.isLocalControlUnlocked == true && !currentSession!.isMediaSharer) return;

      final currentMs = adapter.positionMs;
      final isWaiting = currentSession?.isPausedForMembers == true;
      final isPlaying = isWaiting ? true : adapter.isPlaying;
      chatService.sendSyncStateResponse(currentMs, isPlaying);

      if (isWaiting && !_isUnpausing) {
        _isUnpausing = true;
        ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
        scheduleMicrotask(() {
          adapter.play();
          chatService.sendPlayerCommand('play', currentMs);
          _isUnpausing = false;
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
      final currentSession = ref.read(activeWatchPartyProvider);
      if (currentSession?.isLocalControlUnlocked == true && !currentSession!.isMediaSharer) return;

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
        'Stream sharer ($sharerName) left the player. Switched to local playback control.',
      );
    };

    if (!session.isPausedForMembers) {
      _syncRequestTimer?.cancel();
      _syncRequestTimer = Timer(const Duration(milliseconds: 500), () {
        _syncRequestTimer = null;
        if (!_disposed && ref.read(activeWatchPartyProvider)?.isPausedForMembers != true) {
          chatService.requestSyncState();
        }
      });
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

    final shouldBroadcast = session.shouldBroadcastPlayerCommands;
    if (adapter.isPlaying) {
      if (shouldBroadcast) {
        session.chatService.sendPlayerCommand('pause', adapter.positionMs);
      }
      adapter.pause();
    } else {
      if (shouldBroadcast) {
        session.chatService.sendPlayerCommand('play', adapter.positionMs);
      }
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

    if (session.shouldBroadcastPlayerCommands) {
      session.chatService.sendPlayerCommand('seek', targetPosition.inMilliseconds);
    }
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

    if (session.shouldBroadcastPlayerCommands) {
      session.chatService.sendPlayerCommand('seek', targetMs);
    }
    adapter.seekTo(target);
    return true;
  }

  void dispose() {
    _disposed = true;
    _syncRequestTimer?.cancel();
    _syncRequestTimer = null;
    _isUnpausing = false;
    _playingListenerDispose?.call();
    _playingListenerDispose = null;

    final session = _lastKnownSession;
    final notifier = _notifier;
    _lastKnownSession = null;
    _notifier = null;

    if (session != null) {
      if (session.isMediaSharer && !session.allowMemberControl) {
        session.chatService.notifySharerLeftStream();
      }
      // Use the cached notifier — avoids calling ref.read() after the
      // WidgetRef is invalidated post-unmount (which throws StateError,
      // silently caught, leaving activeMediaPayload stuck non-null).
      notifier?.setActiveMedia(null);

      session.chatService.onGuestConnected = null;
      session.chatService.onSyncStateRequested = null;
      session.chatService.onSyncStateReceived = null;
      session.chatService.onPlayerCommandReceived = null;
      session.chatService.onSharerLeftStream = null;
    }
  }
}
