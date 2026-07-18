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
                    final showChatPanel = activeSession != null && (isPortrait || showLandscapeChat);

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
                        return Column(
                          children: [
                            AspectRatio(
                              aspectRatio: 16 / 9,
                              child: playerStack,
                            ),
                            Expanded(
                              child: WatchPartyPlayerChatPanel(session: activeSession!),
                            ),
                          ],
                        );
                      } else {
                        return Row(
                          children: [
                            Expanded(child: playerStack),
                            WatchPartyPlayerChatPanel(session: activeSession!),
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
  final ActiveWatchPartyState session;
  const WatchPartyPlayerChatPanel({super.key, required this.session});

  @override
  ConsumerState<WatchPartyPlayerChatPanel> createState() => _WatchPartyPlayerChatPanelState();
}

class _WatchPartyPlayerChatPanelState extends ConsumerState<WatchPartyPlayerChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isNotEmpty) {
      widget.session.chatService.sendMessage(text);
      _textController.clear();
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final isPortrait = orientation == Orientation.portrait;

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
      child: Column(
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
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    ref.read(watchPartyLandscapeChatProvider.notifier).toggle();
                  },
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: widget.session.chatService,
            builder: (context, _) {
              if (widget.session.chatService.isReconnecting) {
                return Container(
                  width: double.infinity,
                  color: Colors.amber,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Reconnecting (Attempt ${widget.session.chatService.reconnectAttempts}/3)...',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.session.chatService,
              builder: (context, _) {
                final messages = widget.session.chatService.messages;
                _scrollToBottom();
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, idx) {
                    final msg = messages[idx];
                    final isSystem = msg['type'] == 'system' || (msg['isSystem'] as bool? ?? false);
                    if (isSystem) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              msg['text'] as String,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      );
                    }

                    final isMe = msg['isMe'] as bool? ?? false;
                    final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');
                    final text = msg['text'] as String;

                    final reactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];
                    final isEmojiReaction = reactions.contains(text.trim());

                    if (isEmojiReaction) {
                      return Align(
                        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
                              child: Text(
                                isMe ? 'Me' : sender,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              child: Text(
                                text.trim(),
                                style: const TextStyle(fontSize: 32),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
                            child: Text(
                              isMe ? 'Me' : sender,
                              style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
                              ),
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12).copyWith(
                                topRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                                topLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
                              ),
                            ),
                            child: Text(
                              text,
                              style: TextStyle(
                                fontSize: 12,
                                color: isMe
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: ['👍', '❤️', '😂', '😮', '😢', '🎉'].map((emoji) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(15),
                      onTap: () {
                        widget.session.chatService.sendMessage(emoji);
                        _scrollToBottom();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                      ),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.send_rounded, size: 20),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
