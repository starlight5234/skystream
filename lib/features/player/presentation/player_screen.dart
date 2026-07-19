import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_view/video_view.dart' as vv;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import '../../watchparty/presentation/providers/active_watchparty_provider.dart';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../watchparty/data/watchparty_database.dart';
import '../../watchparty/data/supabase_watchparty_database.dart';
import '../../watchparty/service/watchparty_creator_service.dart';
import '../../watchparty/service/watchparty_joiner_service.dart';
import '../../watchparty/service/watchparty_chat_service.dart';
import '../../watchparty/presentation/widgets/watchparty_chat_body.dart';
import '../../watchparty/service/watchparty_crypto.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../watchparty/config/watchparty_config.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../features/settings/presentation/player_settings_provider.dart';
import 'widgets/skystream_player_controls.dart';
import 'widgets/hotstar_player_style.dart';
import 'player_controller.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final String videoUrl;
  final Episode? episode;

  const PlayerScreen({
    super.key,
    required this.item,
    required this.videoUrl,
    this.episode,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController; // media_kit renderer
  late final vv.VideoController
  _videoViewController; // video_view (ExoPlayer/AVPlayer)

  final ValueNotifier<BoxFit> _videoFit = ValueNotifier(BoxFit.contain);
  // Mirrors SkyStreamPlayerControlsState._isVisible, fed by its
  // onVisibilityChanged callback. Starts false to match the child's
  // initial state; the child will push true once it decides controls
  // should be visible (immediately on TV; on duration-load elsewhere).
  // Used here for subtitle Y-offset computation and the TV back-to-hide
  // intercept in PopScope.
  final ValueNotifier<bool> _controlsVisible = ValueNotifier(false);

  final GlobalKey<SkyStreamPlayerControlsState> _controlsKeyFinal = GlobalKey();

  // The persistent root key handler. It always stays focusable (it is the
  // parent of the ExcludeFocus'd chrome), so when the controls hide we route
  // focus back here and the next remote/keyboard press is guaranteed to be
  // seen — the single mechanism that keeps D-pad alive after auto-hide.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'player_root');

  // Some TVs deliver a single Back press through two channels (a goBack
  // KeyEvent *and* a route pop). This timestamp de-dupes them so one physical
  // press performs exactly one back action — see [_consumeBack].
  DateTime? _lastBackAt;

  bool _isTv = false;
  bool _isTablet = false;
  bool _wasPlayingBeforeBackground = false;
  bool _spaceHeldForSpeed = false;
  double? _speedBeforeSpaceHold;
  Timer? _spaceHoldTimer;

  Orientation? _lastOrientation;
  late final PlayerController _playerController;
  ProviderSubscription<AsyncValue<PlayerSettings>>? _settingsSub;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    WidgetsBinding.instance.addObserver(this);

    final deviceProfile = ref.read(deviceProfileProvider).asData?.value;
    _isTv = deviceProfile?.isTv ?? false;
    _isTablet = deviceProfile?.isTablet ?? false;

    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    WakelockPlus.enable();

    // Initialize player with larger buffer for torrent streaming
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 128 * 1024 * 1024, // 128MB
      ),
    );

    // Increase network timeout to allow TorrServer to pre-buffer
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      native.setProperty('network-timeout', '120');
      native.setProperty('force-seekable', 'yes');
      // Increase metadata probing depth to match VLC (resolves missing language tags)
      native.setProperty('demuxer-lavf-probesize', '33554432'); // 32MB
      // 30s covers the worst-case HLS segment duration; shorter values cause
      // mpv to miss video tracks in streams with 30s segments.
      native.setProperty('demuxer-lavf-analyzeduration', '30');
      // Enable verbose HLS/lavf logging in debug so variant selection and
      // segment fetch errors are visible in logcat.
      if (kDebugMode) {
        native.setProperty('msg-level', 'hls=v,lavf=v,ffmpeg/demuxer=v');
      }
      // Disable native MPV subtitle rendering on the video surface.
      // media_kit sets this at creation when libass=false, but MPV resets
      // it when a new file is opened. We re-assert it here and in
      // _applyPlaybackProperties / applySubtitleSettings as well.
      native.setProperty('sub-visibility', 'no');
    }
    _videoController = VideoController(_player);

    // Phase 8: Initialize video_view engine (ExoPlayer on Android, AVPlayer on iOS/macOS)
    _videoViewController = vv.VideoController(autoPlay: true);

    _settingsSub = ref.listenManual<AsyncValue<PlayerSettings>>(playerSettingsProvider, (
      _,
      next,
    ) {
      final settings = next.asData?.value;
      if (settings == null) return;
      if (settings.defaultResizeMode == "Zoom") {
        _videoFit.value = BoxFit.cover;
      } else if (settings.defaultResizeMode == "Stretch") {
        _videoFit.value = BoxFit.fill;
      }
    }, fireImmediately: true);

    _playerController = ref.read(playerControllerProvider.notifier);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playerController.init(
        player: _player,
        item: widget.item,
        videoUrl: widget.videoUrl,
        episode: widget.episode,
        videoViewController: _videoViewController,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final ctrl = ref.read(playerControllerProvider);
      _wasPlayingBeforeBackground = ctrl.useExoPlayer
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      _playerController.saveProgress();
      _playerController.pause();

      // Tear down any in-flight space-hold speed boost. If the user is
      // holding space (2× speed) and the OS backgrounds the app, the
      // KeyUp event is lost — leaving the state machine stuck with
      // _spaceHeldForSpeed=true forever. Subsequent space taps would
      // see the wrong branch. Reset speed back to whatever the user had
      // before the hold so we resume at the right rate.
      _spaceHoldTimer?.cancel();
      _spaceHoldTimer = null;
      if (_spaceHeldForSpeed) {
        final previousSpeed = _speedBeforeSpaceHold ?? 1.0;
        _spaceHeldForSpeed = false;
        _speedBeforeSpaceHold = null;
        unawaited(_playerController.setPlaybackSpeed(previousSpeed));
      }
    } else if (state == AppLifecycleState.resumed) {
      // Wakelock: re-acquire whenever the engine is currently playing on
      // resume — not just when WE auto-paused on background. External
      // play sources (media-session play from a notification, Bluetooth
      // headphones, Android Auto) can flip playing=true while the app
      // is backgrounded; the user then foregrounds the app to a playing
      // stream with NO wakelock, and the screen sleeps during playback.
      // (H-PLAYER-4)
      final ctrl = ref.read(playerControllerProvider);
      final isCurrentlyPlaying = ctrl.useExoPlayer
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      if (isCurrentlyPlaying) {
        WakelockPlus.enable();
      }

      // Only auto-play if we paused for backgrounding — don't override the
      // user's explicit pause-before-background intent.
      if (_wasPlayingBeforeBackground) {
        _wasPlayingBeforeBackground = false;
        WakelockPlus.enable();
        _playerController.play();
      }
    }
  }

  void _updateResizeMode(BoxFit mode) {
    if (mounted) _videoFit.value = mode;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Restore the system UI FIRST, before any disposal that could throw and
    // skip this. immersiveSticky is set for all mobile in initState, so it
    // must always be cleared on exit (on FireTV, leaving it active also makes
    // the system swallow hardware back-button events).
    //
    // Use manual + all overlays rather than edgeToEdge: leaving immersiveSticky
    // for edgeToEdge does NOT reliably re-show the status/navigation bars on
    // Android, so the user returns to a normal screen with the status bar
    // still hidden. manual + SystemUiOverlay.values forces both bars back —
    // the expected default behaviour off the player.
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      if (!_isTv) {
        if (_isTablet) {
          SystemChrome.setPreferredOrientations([]);
        } else {
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        }
      }
    }

    _settingsSub?.close();
    _playerController.disposeController();

    _player.dispose();
    _videoViewController.dispose();
    _controlsVisible.dispose();
    _videoFit.dispose();
    _rootFocusNode.dispose();

    WakelockPlus.disable();

    // Restore brightness if the user adjusted it via the gesture handler.
    // Without this, exiting the player leaves the device at whatever dim
    // value the user set, until they manually adjust again (audit H4).
    // Idempotent and safe on platforms without an override active.
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    _spaceHoldTimer?.cancel();
    if (_spaceHeldForSpeed) {
      final previousSpeed = _speedBeforeSpaceHold ?? 1.0;
      unawaited(_playerController.setPlaybackSpeed(previousSpeed));
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        windowManager.setFullScreen(false);
        if (Platform.isWindows || Platform.isLinux) {
          windowManager.setTitleBarStyle(TitleBarStyle.normal);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerScreen.dispose: $e');
      }
    }
    super.dispose();
  }

  bool _isPlayActivationKey(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.select ||
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.mediaPlayPause;

  /// Root key handler. Deliberately small: when a control is focused it stays
  /// out of the way so native directional traversal + the focused control's
  /// own activation run; it only acts when *no* control is focused (controls
  /// hidden / video-only) or for global media shortcuts on desktop.
  ///
  /// `primaryFocus == node` means the root node itself holds focus — i.e. no
  /// chrome control is focused. This is how we tell "hidden / video-only" from
  /// "a button is focused" without any manual focus bookkeeping.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final rootHasFocus = FocusManager.instance.primaryFocus == node;

    // Escape (desktop/keyboard) → dismiss via the single guarded handler.
    // Hardware/remote Back is intentionally NOT handled here: on Android/TV it
    // is delivered reliably to PopScope (the navigation channel), and the
    // redundant goBack KeyEvent must stay unhandled so the two deliveries can't
    // both act and walk past a dismissal into exiting the player. Desktop has
    // no PopScope-back, so Escape is its dismissal key.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      return _consumeBack()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    // Space-hold → 2× speed (non-TV). Only when no control is focused, so
    // Space still activates a focused button normally.
    if (!_isTv &&
        rootHasFocus &&
        event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _spaceHoldTimer ??= Timer(const Duration(milliseconds: 260), () {
          if (!mounted || _spaceHeldForSpeed) return;
          _spaceHeldForSpeed = true;
          _speedBeforeSpaceHold = ref
              .read(playerControllerProvider)
              .playbackSpeed;
          unawaited(
            ref.read(playerControllerProvider.notifier).setPlaybackSpeed(2.0),
          );
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        if (!_spaceHeldForSpeed) {
          _spaceHoldTimer?.cancel();
          _spaceHoldTimer = null;
          _spaceHeldForSpeed = true;
          _speedBeforeSpaceHold = ref
              .read(playerControllerProvider)
              .playbackSpeed;
          unawaited(
            ref.read(playerControllerProvider.notifier).setPlaybackSpeed(2.0),
          );
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _spaceHoldTimer?.cancel();
        _spaceHoldTimer = null;
        if (!_spaceHeldForSpeed) {
          _controlsKeyFinal.currentState?.togglePlayPause();
          _controlsKeyFinal.currentState?.onUserInteraction();
          return KeyEventResult.handled;
        }
        final previousSpeed = _speedBeforeSpaceHold ?? 1.0;
        _spaceHeldForSpeed = false;
        _speedBeforeSpaceHold = null;
        unawaited(
          ref
              .read(playerControllerProvider.notifier)
              .setPlaybackSpeed(previousSpeed),
        );
        return KeyEventResult.handled;
      }
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // A chrome control is focused: let it activate (select/enter/space via
    // Shortcuts + Material) and let arrows drive directional traversal. On
    // desktop we still honor the media convention of ←/→/↑/↓ seeking/volume.
    if (!rootHasFocus) {
      if (!_isTv) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _controlsKeyFinal.currentState?.triggerSeek(true);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _controlsKeyFinal.currentState?.triggerSeek(false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _controlsKeyFinal.currentState?.changeVolume(0.05);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _controlsKeyFinal.currentState?.changeVolume(-0.05);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // From here the root has focus — no control is focused (controls hidden
    // or video-only). On TV, if controls are visible, we recover focus.
    if (_isTv && _controlsVisible.value) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight ||
          _isPlayActivationKey(event)) {
        _controlsKeyFinal.currentState?.showControls();
        return KeyEventResult.handled;
      }
    }

    if (_isTv && !_controlsVisible.value) {
      if (event.logicalKey == LogicalKeyboardKey.goBack ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      // First press just wakes the chrome (focus lands on play/pause). It does
      // NOT toggle playback — pressing OK again, now that play/pause is focused,
      // is what pauses/plays. (Avoids the jarring "OK pauses then shows chrome".)
      _controlsKeyFinal.currentState?.showControls();
      return KeyEventResult.handled;
    }

    // Global media shortcuts (root-focused on any platform).
    if (_isPlayActivationKey(event)) {
      _controlsKeyFinal.currentState?.togglePlayPause();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      _controlsKeyFinal.currentState?.toggleMute();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _controlsKeyFinal.currentState?.cycleResize();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _controlsKeyFinal.currentState?.toggleFullscreen();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }

    // TV with controls already visible but focus on root (rare/transient) —
    // leave arrows for traversal.
    if (_isTv) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _controlsKeyFinal.currentState?.changeVolume(0.05);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _controlsKeyFinal.currentState?.changeVolume(-0.05);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _controlsKeyFinal.currentState?.triggerSeek(true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _controlsKeyFinal.currentState?.triggerSeek(false);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// The single Back-handling decision, shared by the root key handler and
  /// PopScope. Performs at most one dismissal — close the sources panel, else
  /// (on TV, while playing) hide the controls — and de-dupes the duplicate Back
  /// delivery within a short window. Returns true when the press was consumed
  /// (the caller must NOT exit); false when there's nothing left to dismiss.
  bool _consumeBack() {
    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(milliseconds: 200)) {
      // Near-instant duplicate delivery of the same physical press — swallow
      // it. Short enough not to eat an intentional fast double-press.
      return true;
    }
    final s = ref.read(playerControllerProvider);
    if (s.showSourcesPanel || s.showEpisodeList || s.showContentPanel) {
      _lastBackAt = now;
      _controlsKeyFinal.currentState?.closeActivePanel();
      return true;
    }
    if (_isTv && _controlsVisible.value) {
      final isPlaying =
          ref.read(playerControllerProvider.select((s) => s.useExoPlayer))
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      if (isPlaying) {
        _lastBackAt = now;
        _controlsKeyFinal.currentState?.hideControls();
        return true;
      }
    }
    return false;
  }

  Future<void> _handleBack() async {
    if (!context.mounted) return;

    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        await windowManager.setFullScreen(false);
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerScreen._handleBack: $e');
      }
    }

    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final errorMessage = ref.watch(
      playerControllerProvider.select((s) => s.errorMessage),
    );
    final isLoading = ref.watch(
      playerControllerProvider.select((s) => s.isLoading),
    );
    final subtitleSettings = ref.watch(playerSettingsProvider).asData?.value;

    if (errorMessage != null) {
      return Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 56,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context)!.playbackError,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        errorMessage,
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        autofocus: true,
                        onPressed: _handleBack,
                        icon: const Icon(Icons.arrow_back),
                        label: Text(AppLocalizations.of(context)!.goBack),
                      ),
                    ],
                  ),
                ),
              ),
              // Top-left back button — always visible for iOS/desktop
              // where there may be no system back gesture.
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: AppLocalizations.of(context)!.goBack,
                  onPressed: _handleBack,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: _controlsVisible,
      builder: (context, controlsVisible, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            // Single guarded path (shared with the root key handler): close the
            // sources panel, else hide TV controls. Only exit when nothing is
            // left to dismiss. The de-dupe inside prevents the dual Back
            // delivery (KeyEvent + route-pop) from skipping a step into exit.
            if (_consumeBack()) return;
            await _handleBack();
          },
          child: Scaffold(
            body: Focus(
              focusNode: _rootFocusNode,
              autofocus: true,
              onKeyEvent: _handleKey,
              child: Shortcuts(
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                },
                child: Consumer(
                  builder: (context, ref, _) {
                    final activeSession = ref.watch(activeWatchPartyProvider);
                    final showLandscapeChat = ref.watch(watchPartyLandscapeChatProvider);
                    final orientation = MediaQuery.of(context).orientation;
                    final isPortrait = orientation == Orientation.portrait;
                    final showChatPanel = activeSession != null ? (isPortrait || showLandscapeChat) : showLandscapeChat;

                    if (orientation != _lastOrientation) {
                      _lastOrientation = orientation;
                      if (Platform.isAndroid || Platform.isIOS) {
                        if (isPortrait) {
                          SystemChrome.setEnabledSystemUIMode(
                            SystemUiMode.manual,
                            overlays: SystemUiOverlay.values,
                          );
                        } else {
                          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                        }
                      }
                    }

                    final playerStack = Stack(
                      children: [
                        RepaintBoundary(
                          child: ValueListenableBuilder<BoxFit>(
                            valueListenable: _videoFit,
                            builder: (_, fit, child) => Center(
                              child: Consumer(
                                builder: (context, ref, _) {
                                  final useExoPlayer = ref.watch(
                                    playerControllerProvider.select(
                                      (s) => s.useExoPlayer,
                                    ),
                                  );
                                  if (useExoPlayer) {
                                    return vv.VideoView(
                                      controller: _videoViewController,
                                      videoFit: fit,
                                    );
                                  }
                                  return Video(
                                    controller: _videoController,
                                    fit: fit,
                                    subtitleViewConfiguration:
                                        const SubtitleViewConfiguration(
                                          visible: false,
                                          style: TextStyle(
                                            color: Colors.transparent,
                                          ),
                                        ),
                                    controls: (state) => const SizedBox.shrink(),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final useExoPlayer = ref.watch(
                              playerControllerProvider.select(
                                (s) => s.useExoPlayer,
                              ),
                            );
                            if (useExoPlayer) {
                              return const SizedBox.shrink();
                            }

                            return Positioned(
                              bottom:
                                  (controlsVisible
                                      ? HotstarPlayerStyle.bottomChromeHeight
                                      : 20.0) +
                                  ((100 -
                                          (subtitleSettings?.subtitlePosition ??
                                              100.0)) *
                                      (MediaQuery.sizeOf(context).height * 0.008)),
                              left: 20,
                              right: 20,
                              child: SubtitleView(
                                controller: _videoController,
                                configuration: SubtitleViewConfiguration(
                                  style: TextStyle(
                                    fontSize:
                                        subtitleSettings?.subtitleSize ?? 22.0,
                                    color: Color(
                                      subtitleSettings?.subtitleColor ?? 0xFFFFFFFF,
                                    ),
                                    backgroundColor:
                                        Color(
                                          subtitleSettings
                                                  ?.subtitleBackgroundColor ??
                                              0x00000000,
                                        ).withValues(
                                          alpha:
                                              subtitleSettings
                                                  ?.subtitleBackgroundOpacity ??
                                              0.0,
                                        ),
                                    shadows: const [
                                      Shadow(
                                        offset: Offset(0, 1),
                                        blurRadius: 2,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            );
                          },
                        ),
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: SkyStreamPlayerControls(
                              key: _controlsKeyFinal,
                              isLoading: isLoading,
                              player: _player,
                              videoViewController: _videoViewController,
                              title: widget.item.title,
                              subtitle: ref
                                  .read(playerControllerProvider)
                                  .streamSubtitle,
                              onResize: _updateResizeMode,
                              onBackPointer: _handleBack,
                              onRequestRootFocus: () =>
                                  _rootFocusNode.requestFocus(),
                              onVisibilityChanged: (v) {
                                if (mounted) {
                                  _controlsVisible.value = v;
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    );

                    if (showChatPanel) {
                      final orientation = MediaQuery.of(context).orientation;
                      if (orientation == Orientation.portrait) {
                        return SafeArea(
                          child: Column(
                            children: [
                              AspectRatio(
                                aspectRatio: 16 / 9,
                                child: playerStack,
                              ),
                              Expanded(
                                child: WatchPartyPlayerChatPanel(session: activeSession),
                              ),
                            ],
                          ),
                        );
                      } else {
                        return Row(
                          children: [
                            Expanded(child: playerStack),
                            SafeArea(
                              left: false,
                              top: false,
                              bottom: false,
                              child: WatchPartyPlayerChatPanel(session: activeSession),
                            ),
                          ],
                        );
                      }
                    }
                    return playerStack;
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class WatchPartyPlayerChatPanel extends ConsumerStatefulWidget {
  final ActiveWatchPartyState? session;
  const WatchPartyPlayerChatPanel({super.key, this.session});

  @override
  ConsumerState<WatchPartyPlayerChatPanel> createState() => _WatchPartyPlayerChatPanelState();
}

class _WatchPartyPlayerChatPanelState extends ConsumerState<WatchPartyPlayerChatPanel> {
  // Join/Host Setup State
  final _joinHostController = TextEditingController();
  final _joinPasscodeController = TextEditingController();
  WatchPartyCreatorService? _creatorService;
  WatchPartyJoinerService? _joinerService;
  bool _setupLoading = false;
  String _setupStatus = '';
  String? _setupError;
  String? _lobbyPasscode;

  ActiveWatchPartyState? _subscribedSession;

  @override
  void initState() {
    super.initState();
    _updateSessionSubscription();
  }

  @override
  void didUpdateWidget(WatchPartyPlayerChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSessionSubscription();
  }

  void _updateSessionSubscription() {
    if (_subscribedSession != widget.session) {
      _subscribedSession?.chatService.removeListener(_onChatServiceStateChanged);
      _subscribedSession = widget.session;
      _subscribedSession?.chatService.addListener(_onChatServiceStateChanged);
    }
  }

  void _onChatServiceStateChanged() {
    if (!mounted) return;
    final session = widget.session;
    if (session == null) return;

    if (session.chatService.connectionClosed) {
      session.chatService.removeListener(_onChatServiceStateChanged);
      _subscribedSession = null;

      final msg = session.chatService.kickMessage ?? 'The watch party connection was closed.';
      ref.read(notificationServiceProvider).showInfo(msg);
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    }
  }

  @override
  void dispose() {
    _subscribedSession?.chatService.removeListener(_onChatServiceStateChanged);
    _joinHostController.dispose();
    _joinPasscodeController.dispose();
    _creatorService?.removeListener(_onCreatorUpdate);
    _creatorService?.dispose();
    _joinerService?.removeListener(_onJoinerUpdate);
    _joinerService?.dispose();
    super.dispose();
  }

  void _onCreatorUpdate() {
    if (!mounted) return;
    final service = _creatorService;
    if (service == null) return;

    if (service.error != null) {
      final errorMsg = service.error!;
      _creatorService?.removeListener(_onCreatorUpdate);
      _creatorService = null;
      setState(() {
        _setupLoading = false;
        _setupError = errorMsg;
      });
      return;
    }

    if (service.lobbyReady) {
      _onP2PConnected(
        peerConnection: null,
        dataChannel: null,
        isHost: true,
        hostName: 'Host',
      );
      return;
    }

    setState(() {
      _setupLoading = service.isLoading;
      _setupStatus = service.statusMessage;
    });
  }

  void _onJoinerUpdate() {
    if (!mounted) return;
    final service = _joinerService;
    if (service == null) return;

    if (service.error != null) {
      final errorMsg = service.error!;
      _joinerService?.removeListener(_onJoinerUpdate);
      _joinerService = null;
      setState(() {
        _setupLoading = false;
        _setupError = errorMsg;
      });
      return;
    }

    if (service.connectionSuccess) {
      _onP2PConnected(
        peerConnection: service.peerConnection!,
        dataChannel: service.dataChannel!,
        isHost: false,
        hostName: _joinHostController.text.trim(),
      );
      return;
    }

    setState(() {
      _setupLoading = service.isLoading;
      _setupStatus = service.statusMessage;
    });
  }

  void _onP2PConnected({
    RTCPeerConnection? peerConnection,
    RTCDataChannel? dataChannel,
    required bool isHost,
    required String hostName,
  }) {
    setState(() {
      _setupLoading = false;
      _setupError = null;
    });

    _creatorService?.removeListener(_onCreatorUpdate);
    _joinerService?.removeListener(_onJoinerUpdate);

    final settings = ref.read(generalSettingsProvider);
    final passcode = isHost ? (_creatorService?.roomPasscode ?? '') : (_lobbyPasscode ?? '');
    final resolvedUserName = isHost
        ? hostName
        : (settings.watchPartyUsername.isNotEmpty
            ? settings.watchPartyUsername
            : 'Guest_${Random().nextInt(10000)}');

    final chatService = WatchPartyChatService(
      peerConnection: peerConnection,
      dataChannel: dataChannel,
      creatorService: isHost ? _creatorService : null,
      joinerService: isHost ? null : _joinerService,
      database: ref.read(watchPartyDatabaseProvider),
      isHost: isHost,
      hostName: hostName,
      userName: resolvedUserName,
      passcode: passcode,
    );

    ref.read(activeWatchPartyProvider.notifier).setActiveSession(
      ActiveWatchPartyState(
        peerConnection: peerConnection,
        dataChannel: dataChannel,
        creatorService: isHost ? _creatorService : null,
        database: ref.read(watchPartyDatabaseProvider),
        isHost: isHost,
        hostName: hostName,
        userName: resolvedUserName,
        passcode: passcode,
        chatService: chatService,
      ),
    );
  }

  void _executeStartHost() {
    final settings = ref.read(generalSettingsProvider);
    final database = ref.read(watchPartyDatabaseProvider);
    final name = settings.watchPartyUsername.isNotEmpty
        ? settings.watchPartyUsername
        : 'Host_${DateTime.now().millisecondsSinceEpoch % 1000}';

    setState(() {
      _setupLoading = true;
      _setupError = null;
      _setupStatus = 'Initializing WebRTC connection...';
    });

    _creatorService?.removeListener(_onCreatorUpdate);
    _creatorService?.dispose();

    _creatorService = WatchPartyCreatorService(settings, database);
    _creatorService!.addListener(_onCreatorUpdate);
    unawaited(_creatorService!.startHosting(name));
  }

  void _executeJoin() {
    final hostName = _joinHostController.text.trim();
    final passcode = _joinPasscodeController.text.trim();

    if (hostName.isEmpty || passcode.isEmpty) {
      setState(() {
        _setupError = 'Host name and Passcode are required.';
      });
      return;
    }

    final settings = ref.read(generalSettingsProvider);
    final database = ref.read(watchPartyDatabaseProvider);
    final guestName = settings.watchPartyUsername.isNotEmpty
        ? settings.watchPartyUsername
        : 'Guest_${Random().nextInt(10000)}';

    setState(() {
      _setupLoading = true;
      _setupError = null;
      _setupStatus = 'Checking for lobby...';
      _lobbyPasscode = passcode;
    });

    _joinerService?.removeListener(_onJoinerUpdate);
    _joinerService?.dispose();

    _joinerService = WatchPartyJoinerService(settings, database);
    _joinerService!.addListener(_onJoinerUpdate);
    unawaited(_joinerService!.startJoining(hostName, guestName, passcode));
  }

  void _cancelConnection() {
    _creatorService?.cancelHosting();
    _joinerService?.cancelJoining();
    setState(() {
      _setupLoading = false;
      _setupError = null;
      _setupStatus = '';
    });
  }

  // Active Session UI Helpers
  String _buildInviteUrl(GeneralSettings settings) {
    final session = widget.session!;
    final jsonStr = jsonEncode({
      'db': settings.watchPartyProjectId.trim(),
      'key': settings.watchPartyAnonKey.trim(),
      'turn_user': settings.watchPartyTurnUsername.trim(),
      'turn_pass': settings.watchPartyTurnPassword.trim(),
    });
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, session.passcode, session.hostName);
    return '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(session.hostName)}&code=${Uri.encodeComponent(encryptedCode)}';
  }

  void _copyInviteLink() {
    final settings = ref.read(generalSettingsProvider);
    final inviteUrl = _buildInviteUrl(settings);

    unawaited(Clipboard.setData(ClipboardData(text: inviteUrl)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard!')),
    );
  }

  void _showQRDialog() {
    final settings = ref.read(generalSettingsProvider);
    final inviteUrl = _buildInviteUrl(settings);

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Invite QR Code'),
        content: SizedBox(
          width: 250,
          height: 250,
          child: Center(
            child: QrImageView(
              data: inviteUrl,
              version: QrVersions.auto,
              size: 200.0,
              gapless: false,
              eyeStyle: QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              dataModuleStyle: QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPeopleDialog() {
    final session = widget.session!;
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final guests = session.creatorService?.activeDataChannels.keys.toList() ?? [];
            final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              title: const Text('Lobby Members'),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isDesktop ? 400.0 : double.infinity,
                ),
                child: SizedBox(
                  width: isDesktop ? 400.0 : double.maxFinite,
                  child: guests.isEmpty
                      ? const Text('No guests currently in the lobby.', style: TextStyle(color: Colors.grey))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: guests.length,
                          itemBuilder: (context, idx) {
                            final guest = guests[idx];
                            return ListTile(
                              title: Text(
                                guest,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: session.isHost
                                  ? IconButton(
                                      icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.primary),
                                      tooltip: 'Kick',
                                      onPressed: () {
                                        session.creatorService?.kickGuest(guest);
                                        setDialogState(() {});
                                      },
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDiagnosticsLogs() {
    final session = widget.session!;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final logs = session.isHost
            ? (session.creatorService?.diagnosticLogs ?? [])
            : (session.chatService.messages.where((m) => m['type'] == 'system').map((m) => m['text'] as String).toList());
        
        final logsToShow = logs.isEmpty ? ['No connection diagnostic logs available.'] : logs;

        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connection Diagnostic Logs',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: logsToShow.length,
                  itemBuilder: (context, idx) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      logsToShow[idx],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _leaveSessionConfirm() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Leave WatchParty?'),
        content: const Text('Are you sure you want to disconnect from this watch party?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (leave == true && mounted) {
      await widget.session!.chatService.leaveParty();
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final isPortrait = orientation == Orientation.portrait;
    final session = widget.session;

    return Container(
      width: isPortrait ? double.infinity : 320,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        border: Border(
          left: isPortrait
              ? BorderSide.none
              : BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)),
          top: isPortrait
              ? BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2))
              : BorderSide.none,
        ),
      ),
      child: session != null
          ? Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.people_alt, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Watch Party Chat',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.link_rounded, size: 20),
                        tooltip: 'Copy Invite Link',
                        onPressed: _copyInviteLink,
                      ),
                      IconButton(
                        icon: const Icon(Icons.qr_code_2_rounded, size: 20),
                        tooltip: 'Show QR Code',
                        onPressed: _showQRDialog,
                      ),
                      IconButton(
                        icon: const Icon(Icons.power_settings_new_rounded, size: 20),
                        color: Colors.redAccent,
                        tooltip: session.isHost ? 'End Lobby & Leave' : 'Leave Lobby',
                        onPressed: _leaveSessionConfirm,
                      ),
                      PopupMenuButton<String>(
                        surfaceTintColor: Colors.transparent,
                        onSelected: (val) {
                          if (val == 'people') {
                            _showPeopleDialog();
                          } else if (val == 'logs') {
                            _showDiagnosticsLogs();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'people',
                            child: Row(
                              children: [
                                Icon(Icons.people_outline, size: 20),
                                SizedBox(width: 8),
                                Text('People'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'logs',
                            child: Row(
                              children: [
                                Icon(Icons.receipt_long_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('Connection Logs'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          ref.read(watchPartyLandscapeChatProvider.notifier).toggle();
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: WatchPartyChatBody(
                    chatService: session.chatService,
                    isHost: session.isHost,
                    passcode: session.passcode,
                    creatorService: session.creatorService,
                    onCopyInviteLink: _copyInviteLink,
                    onShowQRDialog: _showQRDialog,
                  ),
                ),
              ],
            )
          : Stack(
              children: [
                Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.share_outlined, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Watch Party Setup',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () {
                              ref.read(watchPartyLandscapeChatProvider.notifier).toggle();
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_setupError != null) ...[
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  _setupError!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            Text(
                              'Host a Watch Party',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Start hosting a Watch Party so others can sync and watch this stream with you.',
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _setupLoading ? null : _executeStartHost,
                              icon: const Icon(Icons.add_to_queue_rounded, size: 18),
                              label: const Text('Host Lobby'),
                            ),
                            const Divider(height: 32),
                            Text(
                              'Join a Watch Party',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Enter a host\'s nickname and room passcode to join their synchronized session.',
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _joinHostController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'Host Nickname',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _joinPasscodeController,
                              style: const TextStyle(fontSize: 13),
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Passcode',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _setupLoading ? null : _executeJoin,
                              icon: const Icon(Icons.group_add_rounded, size: 18),
                              label: const Text('Join watch party'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_setupLoading)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 24),
                            Text(
                              _setupStatus,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: _cancelConnection,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
