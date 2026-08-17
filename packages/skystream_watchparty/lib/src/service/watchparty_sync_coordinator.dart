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
  void setPlaybackActionListener(void Function(String action, int positionMs)? listener);
}

class WatchPartySyncCoordinator {
  final Ref ref;
  final WatchPartyPlayerAdapter adapter;

  bool _isHandlingRemoteCommand = false;
  bool _disposed = false;

  WatchPartySyncCoordinator({
    required this.ref,
    required this.adapter,
  });

  void attach() {
    adapter.setPlaybackActionListener((action, positionMs) {
      if (_isHandlingRemoteCommand || _disposed) return;
      if (action == 'play') {
        onUserPlay(positionMs);
      } else if (action == 'pause') {
        onUserPause(positionMs);
      } else if (action == 'seek') {
        onUserSeek(Duration(milliseconds: positionMs));
      }
    });

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
        });
      }
    };

    chatService.onSyncStateRequested = (requester) {
      if (_disposed) return;
      final currentMs = adapter.positionMs;
      final isPlaying = adapter.isPlaying;
      chatService.sendSyncStateResponse(currentMs, isPlaying);

      if (ref.read(activeWatchPartyProvider)?.isPausedForMembers == true) {
        ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
        scheduleMicrotask(() {
          adapter.play();
        });
      }
    };

    chatService.onSyncStateReceived = (positionMs, isPlaying) {
      if (_disposed) return;
      _isHandlingRemoteCommand = true;
      adapter.seekTo(Duration(milliseconds: positionMs));
      if (isPlaying) {
        adapter.play();
      } else {
        adapter.pause();
      }
      _isHandlingRemoteCommand = false;
    };

    chatService.onPlayerCommandReceived = (cmd, positionMs) {
      if (_disposed) return;
      _isHandlingRemoteCommand = true;
      if (cmd == 'play') {
        adapter.play();
      } else if (cmd == 'pause') {
        adapter.pause();
      } else if (cmd == 'seek') {
        adapter.seekTo(Duration(milliseconds: positionMs));
      }
      _isHandlingRemoteCommand = false;
    };

    if (!session.isPausedForMembers) {
      chatService.requestSyncState();
    }
  }

  /// Called when the local user initiates a play action.
  /// Returns false if the action is restricted.
  bool onUserPlay(int positionMs) {
    if (_isHandlingRemoteCommand || _disposed) return true;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return true;

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    session.chatService.sendPlayerCommand('play', positionMs);
    return true;
  }

  /// Called when the local user initiates a pause action.
  /// Returns false if the action is restricted.
  bool onUserPause(int positionMs) {
    if (_isHandlingRemoteCommand || _disposed) return true;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return true;

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    session.chatService.sendPlayerCommand('pause', positionMs);
    return true;
  }

  /// Called when the local user initiates a seek action.
  /// Returns false if the action is restricted.
  bool onUserSeek(Duration targetPosition) {
    if (_isHandlingRemoteCommand || _disposed) return true;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return true;

    if (!session.canControlPlayback) {
      adapter.showNotification(
        'Only the stream host (${session.mediaSharer ?? "sharer"}) can control playback.',
      );
      return false;
    }

    session.chatService.sendPlayerCommand('seek', targetPosition.inMilliseconds);
    return true;
  }

  void dispose() {
    _disposed = true;
    adapter.setPlaybackActionListener(null);
    try {
      final session = ref.read(activeWatchPartyProvider);
      if (session != null) {
        session.chatService.onGuestConnected = null;
        session.chatService.onSyncStateRequested = null;
        session.chatService.onSyncStateReceived = null;
        session.chatService.onPlayerCommandReceived = null;
      }
    } catch (_) {}
  }
}
