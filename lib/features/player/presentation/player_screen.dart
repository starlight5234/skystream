import 'dart:async';
import 'dart:io';
import 'dart:ui';

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

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../features/settings/presentation/player_settings_provider.dart';
import 'widgets/skystream_player_controls.dart';
import 'widgets/hotstar_player_style.dart';
import 'player_controller.dart';
import 'player_platform_service.dart';
import 'in_app_player_provider.dart';

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

  late final PlayerController _playerController;
  ProviderSubscription<AsyncValue<PlayerSettings>>? _settingsSub;

  String? _toastMessage;
  Timer? _toastTimer;

  void _showToastMessage(String message) {
    if (!mounted) return;
    setState(() {
      _toastMessage = message;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) {
        setState(() {
          _toastMessage = null;
        });
      }
    });
  }

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

    // Check if player is already active globally (from in-app PiP)
    final inAppPlayerState = ref.read(inAppPlayerProvider);
    final isAlreadyActive = inAppPlayerState.player != null &&
        inAppPlayerState.videoUrl == widget.videoUrl;

    if (!isAlreadyActive) {
      // Initialize new playback session globally
      ref.read(inAppPlayerProvider.notifier).play(
        item: widget.item,
        videoUrl: widget.videoUrl,
        episode: widget.episode,
      );
    } else {
      // Maximize the player state
      ref.read(inAppPlayerProvider.notifier).maximize();
    }

    final updatedState = ref.read(inAppPlayerProvider);
    _player = updatedState.player!;
    _videoViewController = updatedState.videoViewController!;
    _videoController = VideoController(_player);

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
        SystemChrome.setPreferredOrientations([]);
      }
    }

    _settingsSub?.close();
    
    _playerController.disposeController(_player);
    _player.dispose();
    _videoViewController.dispose();
    ref.read(inAppPlayerProvider.notifier).close(_player);

    _controlsVisible.dispose();
    _videoFit.dispose();
    _rootFocusNode.dispose();

    WakelockPlus.disable();

    // Restore brightness if the user adjusted it via the gesture handler.
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    _spaceHoldTimer?.cancel();
    _toastTimer?.cancel();
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
    ref.read(inAppPlayerProvider.notifier).close(_player);
    if (!context.mounted) return;
    if (mounted) context.pop();
  }



  @override
  Widget build(BuildContext context) {
    ref.listen<WidgetBuilder?>(playerAuxiliaryPanelBuilderProvider, (previous, next) {
      if (next == null && previous != null) {
        // If watchparty ends while viewing player, force maximize to landscape
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    });

    ref.listen<String?>(playerNotificationProvider, (previous, next) {
      if (next != null) {
        _showToastMessage(next);
        ref.read(playerNotificationProvider.notifier).state = null; // Reset
      }
    });

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

    final auxiliaryPanelBuilder = ref.watch(playerAuxiliaryPanelBuilderProvider);
    final orientation = MediaQuery.of(context).orientation;
    final isPortrait = orientation == Orientation.portrait;
    final showLandscapeChat = ref.watch(playerAuxiliaryPanelVisibleProvider);

    return ValueListenableBuilder<bool>(
      valueListenable: _controlsVisible,
      builder: (context, controlsVisible, _) {
        final playerStack = Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            },
            child: Stack(
              children: [
                RepaintBoundary(
                  child: ValueListenableBuilder<BoxFit>(
                    valueListenable: _videoFit,
                    builder: (_, fit, child) => Center(
                      // Phase 8: Switch engine based on stream type
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
                      child: RepaintBoundary(
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
            ),
          ),
        );

        Widget mainLayout;

        if (auxiliaryPanelBuilder != null && !isLoading) {
          final panelWidget = auxiliaryPanelBuilder(context);

          if (isPortrait) {
            mainLayout = Column(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: playerStack,
                ),
                Expanded(child: panelWidget),
              ],
            );
          } else if (showLandscapeChat) {
            mainLayout = Row(
              children: [
                Expanded(child: playerStack),
                Container(
                  width: 320,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: panelWidget,
                ),
              ],
            );
          } else {
            mainLayout = playerStack;
          }
        } else {
          mainLayout = playerStack;
        }

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (_consumeBack()) return;
            await _handleBack();
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              top: !isPortrait || auxiliaryPanelBuilder == null || isLoading,
              bottom: !isPortrait || auxiliaryPanelBuilder == null || isLoading,
              child: Stack(
                children: [
                  mainLayout,
                  if (_toastMessage != null)
                    Positioned(
                      bottom: 40,
                      left: 20,
                      right: 20,
                      child: Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.75),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white24,
                                  width: 0.5,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 12,
                                    offset: Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.wifi_off_rounded,
                                    color: Colors.amberAccent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: Text(
                                      _toastMessage!,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: 0.2,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
