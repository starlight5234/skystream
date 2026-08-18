import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/providers/active_watchparty_provider.dart';

abstract class WatchPartyPlayerAdapter {
  int get positionMs;
  int get durationMs;
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
  String? _syncedMediaKey;

  WatchPartySyncCoordinator({
    required this.ref,
    required this.adapter,
  });

  String? _getMediaKey(Map<String, dynamic>? media) {
    if (media == null) return null;
    final ep = media['episodeUrl'] as String?;
    if (ep != null && ep.isNotEmpty) return ep;
    final mUrl = media['mediaUrl'] as String?;
    if (mUrl != null && mUrl.isNotEmpty) return mUrl;
    return '${media['title']}_${media['season']}_${media['episodeNumber']}';
  }

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
      final currentSession = ref.read(activeWatchPartyProvider);
      if (currentSession?.isPausedForMembers == true && adapter.isPlaying) {
        adapter.pause();
      }
      final mediaKey = _getMediaKey(currentSession?.activeMediaPayload);
      final hasValidPlayback = adapter.positionMs > 0 || adapter.durationMs > 0;
      if (_syncedMediaKey != mediaKey &&
          adapter.isPlaying &&
          hasValidPlayback &&
          currentSession != null &&
          !currentSession.isHost &&
          currentSession.isRoomStreamActive) {
        _syncedMediaKey = mediaKey;
        chatService.requestSyncState();
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

    if (session.isHost) {
      chatService.onSyncStateRequested = (requester) {
        if (_disposed) return;
        final currentSession = ref.read(activeWatchPartyProvider);
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
    } else {
      chatService.onSyncStateRequested = null;
    }

    chatService.onSyncStateReceived = (positionMs, isPlaying) {
      if (_disposed) return;
      final currentSession = ref.read(activeWatchPartyProvider);
      if (currentSession?.isLocalControlUnlocked == true && !currentSession!.isHost) return;

      _syncedMediaKey = _getMediaKey(currentSession?.activeMediaPayload);
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
      if (currentSession?.isLocalControlUnlocked == true && !currentSession!.isHost) return;

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
        'Host ($sharerName) left the player. Switched to local playback control.',
      );
    };

    chatService.onHostRejoined = (sharerName) {
      if (_disposed) return;
      final currentSession = ref.read(activeWatchPartyProvider);
      if (currentSession != null && !currentSession.isHost) {
        ref.read(activeWatchPartyProvider.notifier).resetLocalControl();
        adapter.showNotification('Host ($sharerName) rejoined the stream.');
        if (currentSession.forceSyncOnRejoin) {
          chatService.requestSyncState();
        }
      }
    };

    if (session.isHost && session.activeMediaPayload != null) {
      chatService.notifyHostRejoinedStream();
    }

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
      if (session.isHost) {
        if (!session.allowMemberControl) {
          session.chatService.notifySharerLeftStream();
        }
      }

      session.chatService.onGuestConnected = null;
      session.chatService.onSyncStateRequested = null;
      session.chatService.onSyncStateReceived = null;
      session.chatService.onPlayerCommandReceived = null;
      session.chatService.onSharerLeftStream = null;
      session.chatService.onHostRejoined = null;
    }
  }
}
