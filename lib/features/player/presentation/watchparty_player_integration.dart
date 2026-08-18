import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_view/video_view.dart' as vv;
import 'package:skystream_watchparty/skystream_watchparty.dart';

import '../../../../core/services/notification_service.dart';
import 'player_controller.dart';

class PlayerScreenWatchPartyAdapter implements WatchPartyPlayerAdapter {
  final WidgetRef ref;
  final Player player;
  final vv.VideoController videoViewController;

  PlayerScreenWatchPartyAdapter({
    required this.ref,
    required this.player,
    required this.videoViewController,
  });

  @override
  int get positionMs {
    if (ref.read(playerControllerProvider).useExoPlayer) {
      return videoViewController.position.value;
    }
    return player.state.position.inMilliseconds;
  }

  @override
  bool get isPlaying {
    if (ref.read(playerControllerProvider).useExoPlayer) {
      return videoViewController.playbackState.value ==
          vv.VideoControllerPlaybackState.playing;
    }
    return player.state.playing;
  }

  @override
  VoidCallback registerPlayingListener(VoidCallback onPlayingChanged) {
    final useExo = ref.read(playerControllerProvider).useExoPlayer;
    if (useExo) {
      videoViewController.playbackState.addListener(onPlayingChanged);
      return () => videoViewController.playbackState
          .removeListener(onPlayingChanged);
    } else {
      final sub = player.stream.playing.listen((_) => onPlayingChanged());
      return () => sub.cancel();
    }
  }

  @override
  void play() {
    if (ref.read(playerControllerProvider).useExoPlayer) {
      videoViewController.play();
    } else {
      player.play();
    }
  }

  @override
  void pause() {
    if (ref.read(playerControllerProvider).useExoPlayer) {
      videoViewController.pause();
    } else {
      player.pause();
    }
  }

  @override
  void seekTo(Duration position) {
    if (ref.read(playerControllerProvider).useExoPlayer) {
      videoViewController.seekTo(position.inMilliseconds);
    } else {
      player.seek(position);
    }
  }

  @override
  void showNotification(String message) {
    ref.read(notificationServiceProvider).showInfo(message);
  }
}

class WatchPartyPlayerIntegration {
  final WidgetRef ref;
  final WatchPartyPlayerAdapter adapter;
  late final WatchPartySyncCoordinator coordinator;
  ProviderSubscription<ActiveWatchPartyState?>? _sessionSub;

  WatchPartyPlayerIntegration({
    required this.ref,
    required this.adapter,
  }) {
    coordinator = WatchPartySyncCoordinator(
      ref: ref,
      adapter: adapter,
    );
  }

  void attach() {
    coordinator.attach();
    _sessionSub?.close();
    _sessionSub = ref.listenManual<ActiveWatchPartyState?>(
      activeWatchPartyProvider,
      (previous, next) {
        coordinator.onSessionChanged(previous, next);
      },
    );
  }

  /// Handles "Play Now" from WatchPartyWaitOverlay (BUG-5)
  void handlePlayNow() {
    ref.read(activeWatchPartyProvider.notifier).unpauseForMembers();
    final session = ref.read(activeWatchPartyProvider);
    if (session != null) {
      session.chatService.sendPlayerCommand('play', adapter.positionMs);
    }
    adapter.play();
  }

  bool handleUserTogglePlay() => coordinator.handleUserTogglePlay();

  bool handleUserSeek(Duration target) => coordinator.handleUserSeek(target);

  bool handleUserSeekRelative(Duration offset, Duration maxDuration) =>
      coordinator.handleUserSeekRelative(offset, maxDuration);

  void dispose() {
    _sessionSub?.close();
    _sessionSub = null;
    coordinator.dispose();
  }
}
