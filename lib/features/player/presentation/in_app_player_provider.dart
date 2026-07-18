import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:video_view/video_view.dart' as vv;
import '../../../../core/domain/entity/multimedia_item.dart';
import 'player_controller.dart';

enum PlayerWindowMode {
  fullscreen,
  none,
}

class InAppPlayerState {
  final PlayerWindowMode mode;
  final MultimediaItem? item;
  final String? videoUrl;
  final Episode? episode;
  
  // Draggable / Resizable Window Bounds
  final double width;
  final double height;
  final double? left;
  final double? top;

  // Active Player controller instances
  final Player? player;
  final vv.VideoController? videoViewController;

  const InAppPlayerState({
    required this.mode,
    this.item,
    this.videoUrl,
    this.episode,
    this.width = 240.0,
    this.height = 135.0, // 16:9 aspect ratio
    this.left,
    this.top,
    this.player,
    this.videoViewController,
  });

  InAppPlayerState copyWith({
    PlayerWindowMode? mode,
    MultimediaItem? item,
    String? videoUrl,
    Episode? episode,
    double? width,
    double? height,
    double? left,
    double? top,
    Player? player,
    vv.VideoController? videoViewController,
    bool clearPosition = false,
  }) {
    return InAppPlayerState(
      mode: mode ?? this.mode,
      item: item ?? this.item,
      videoUrl: videoUrl ?? this.videoUrl,
      episode: episode ?? this.episode,
      width: width ?? this.width,
      height: height ?? this.height,
      left: clearPosition ? null : (left ?? this.left),
      top: clearPosition ? null : (top ?? this.top),
      player: player ?? this.player,
      videoViewController: videoViewController ?? this.videoViewController,
    );
  }
}

class InAppPlayer extends Notifier<InAppPlayerState> {
  @override
  InAppPlayerState build() {
    return const InAppPlayerState(mode: PlayerWindowMode.none);
  }

  void play({
    required MultimediaItem item,
    required String videoUrl,
    Episode? episode,
  }) {
    // Clean up any existing player first
    _cleanupActiveControllers();

    // 1. Initialize native player instances
    MediaKit.ensureInitialized();
    final newPlayer = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 128 * 1024 * 1024, // 128MB
      ),
    );

    if (newPlayer.platform is NativePlayer) {
      final native = newPlayer.platform as NativePlayer;
      native.setProperty('hwdec', 'auto');
      native.setProperty('network-timeout', '120');
      native.setProperty('force-seekable', 'yes');
      native.setProperty('demuxer-lavf-probesize', '33554432');
      native.setProperty('demuxer-lavf-analyzeduration', '30');
      native.setProperty('sub-visibility', 'no');

      // Thermal & Performance optimization settings
      native.setProperty('framedrop', 'decoder');
      native.setProperty('hr-seek-framedrop', 'yes');
      native.setProperty('vd-lavc-fast', 'yes');
      native.setProperty('vd-lavc-threads', '4');
      native.setProperty('vd-lavc-skiploopfilter', 'nonkey');
      native.setProperty('scale', 'bilinear');
      native.setProperty('cscale', 'bilinear');
      native.setProperty('dscale', 'bilinear');
      native.setProperty('sws-scaler', 'fast-bilinear');
    }

    final newVideoViewController = vv.VideoController(autoPlay: true);

    state = InAppPlayerState(
      mode: PlayerWindowMode.fullscreen,
      item: item,
      videoUrl: videoUrl,
      episode: episode,
      player: newPlayer,
      videoViewController: newVideoViewController,
    );

    // 2. Initialize the global PlayerController
    ref.read(playerControllerProvider.notifier).init(
      player: newPlayer,
      item: item,
      videoUrl: videoUrl,
      episode: episode,
      videoViewController: newVideoViewController,
    );
  }



  void maximize() {
    if (state.mode == PlayerWindowMode.none) return;
    state = state.copyWith(mode: PlayerWindowMode.fullscreen);
  }


  void updatePosition(double left, double top) {
    state = state.copyWith(left: left, top: top);
  }

  void updateSize(double width, double height) {
    state = state.copyWith(width: width, height: height);
  }

  void close([Player? player]) {
    if (player != null && state.player != player) {
      return;
    }
    _cleanupActiveControllers();
    state = const InAppPlayerState(mode: PlayerWindowMode.none);
  }

  void _cleanupActiveControllers() {
    final oldPlayer = state.player;
    // Don't dispose active videoViewController synchronously if it is being shut down
    if (oldPlayer != null) {
      unawaited(oldPlayer.dispose());
    }
    if (state.mode != PlayerWindowMode.none) {
      ref.read(playerControllerProvider.notifier).disposeController(oldPlayer);
    }
  }
}

final inAppPlayerProvider = NotifierProvider<InAppPlayer, InAppPlayerState>(() {
  return InAppPlayer();
});

/// A provider that holds a builder for any secondary side/bottom panel to show alongside the video.
/// Used for WatchParty chat, comment feeds, etc., without coupling the player to those features.
class PlayerAuxiliaryPanelBuilderNotifier extends Notifier<WidgetBuilder?> {
  @override
  WidgetBuilder? build() => null;

  set state(WidgetBuilder? value) => super.state = value;
}

final playerAuxiliaryPanelBuilderProvider = NotifierProvider<PlayerAuxiliaryPanelBuilderNotifier, WidgetBuilder?>(() {
  return PlayerAuxiliaryPanelBuilderNotifier();
});

/// Tracks if the auxiliary panel is visible in landscape mode.
class PlayerAuxiliaryPanelVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  set state(bool value) => super.state = value;
}

final playerAuxiliaryPanelVisibleProvider = NotifierProvider<PlayerAuxiliaryPanelVisibleNotifier, bool>(() {
  return PlayerAuxiliaryPanelVisibleNotifier();
});

/// Manages temporary notifications displayed inside the player.
class PlayerNotificationNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  set state(String? value) => super.state = value;
}

final playerNotificationProvider = NotifierProvider<PlayerNotificationNotifier, String?>(() {
  return PlayerNotificationNotifier();
});
