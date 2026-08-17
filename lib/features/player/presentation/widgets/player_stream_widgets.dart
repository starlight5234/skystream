import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_view/video_view.dart' as vv;
import '../player_controller.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import 'hotstar_player_style.dart';
import '../../../skip/data/skip_service.dart';

/// A self-contained progress bar widget that uses StreamBuilder to avoid
/// rebuilding the parent widget on every position update.
class PlayerProgressBar extends ConsumerStatefulWidget {
  final Player player;
  final vv.VideoController? videoViewController;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  /// On TV the scrubber becomes a focusable element: D-pad Left/Right seek by
  /// the configured step and the thumb enlarges while focused. Off TV the
  /// slider stays pointer-only (it is reached by touch/mouse, not focus).
  final bool isTv;
  final FocusNode? focusNode;
  final VoidCallback? onArrowUp;
  final VoidCallback? onArrowDown;

  const PlayerProgressBar({
    super.key,
    required this.player,
    this.videoViewController,
    this.onSeekStart,
    this.onSeekEnd,
    this.isTv = false,
    this.focusNode,
    this.onArrowUp,
    this.onArrowDown,
  });

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  double? _dragValue;
  bool _scrubFocused = false;
  late final FocusNode _scrubFocusNode;
  static const double _sliderTrackInset = 24;
  ProviderSubscription<int>? _streamIndexSub;

  // ValueNotifiers so position/duration updates don't setState the whole widget.
  final _vvPositionNotifier = ValueNotifier<int>(0);
  final _vvDurationNotifier = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _scrubFocusNode = widget.focusNode ?? FocusNode(debugLabel: 'scrubber');
    widget.videoViewController?.position.addListener(_onVvPosition);
    widget.videoViewController?.mediaInfo.addListener(_onVvMediaInfo);
    _syncVideoViewProgress();
    _watchStreamChanges();
    _scrubFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) {
      setState(() => _scrubFocused = _scrubFocusNode.hasFocus);
    }
  }

  void _watchStreamChanges() {
    // `currentStreamIndex` ticks every time the active source changes
    // (source picker, quality switch, episode autoplay). Cheap int
    // comparison; no allocations.
    _streamIndexSub = ref.listenManual<int>(
      playerControllerProvider.select((s) => s.currentStreamIndex),
      (prev, next) {
        if (prev != null && prev != next && _dragValue != null && mounted) {
          setState(() => _dragValue = null);
        }
      },
    );
  }

  @override
  void didUpdateWidget(PlayerProgressBar old) {
    super.didUpdateWidget(old);
    if (old.videoViewController != widget.videoViewController) {
      old.videoViewController?.position.removeListener(_onVvPosition);
      old.videoViewController?.mediaInfo.removeListener(_onVvMediaInfo);
      widget.videoViewController?.position.addListener(_onVvPosition);
      widget.videoViewController?.mediaInfo.addListener(_onVvMediaInfo);
      _syncVideoViewProgress();
    }
  }

  void _syncVideoViewProgress() {
    _onVvPosition();
    _onVvMediaInfo();
  }

  void _onVvPosition() {
    _vvPositionNotifier.value = widget.videoViewController?.position.value ?? 0;
  }

  void _onVvMediaInfo() {
    _vvDurationNotifier.value =
        widget.videoViewController?.mediaInfo.value?.duration ?? 0;
  }

  @override
  void dispose() {
    widget.videoViewController?.position.removeListener(_onVvPosition);
    widget.videoViewController?.mediaInfo.removeListener(_onVvMediaInfo);
    _scrubFocusNode.removeListener(_onFocusChange);
    _streamIndexSub?.close();
    _vvPositionNotifier.dispose();
    _vvDurationNotifier.dispose();
    if (widget.focusNode == null) {
      _scrubFocusNode.dispose();
    }
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final absDuration = duration.abs();
    final hours = absDuration.inHours;
    final minutes = absDuration.inMinutes.remainder(60);
    final seconds = absDuration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatRemaining(Duration duration, Duration position) {
    final remaining = duration - position;
    final clamped = remaining.isNegative ? Duration.zero : remaining;
    return '-${_formatDuration(clamped)}';
  }

  Widget _buildTimeHeader({
    required bool isLive,
    required Duration duration,
    required Duration displayDuration,
  }) {
    if (isLive) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: _sliderTrackInset),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.45),
                width: 1,
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: Colors.red, size: 7),
                SizedBox(width: 5),
                Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentText = _formatDuration(displayDuration);
    final remainingText = _formatRemaining(duration, displayDuration);
    final durationText = _formatDuration(duration);
    // Persisted across sessions — once a user toggles to remaining-time
    // they almost always want it always. Stored in PlayerSettings so it
    // survives episode change, source change, and app restart.
    final showRemaining =
        ref.watch(
          playerSettingsProvider.select(
            (s) => s.asData?.value.showRemainingTime,
          ),
        ) ??
        false;
    final label = showRemaining
        ? '$remainingText / $durationText'
        : '$currentText / $durationText';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sliderTrackInset),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              ref
                  .read(playerSettingsProvider.notifier)
                  .setShowRemainingTime(!showRemaining);
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: const TextStyle(
                  color: HotstarPlayerStyle.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final useExoPlayer = ref.watch(
      playerControllerProvider.select((s) => s.useExoPlayer),
    );
    final canSeek = ref.watch(
      playerControllerProvider.select((s) => s.canSeek),
    );

    final skipSegments = ref.watch(
      playerControllerProvider.select((s) => s.skipSegments),
    );

    _scrubFocusNode.canRequestFocus = widget.isTv && canSeek;
    _scrubFocusNode.skipTraversal = !(widget.isTv && canSeek);

    if (useExoPlayer && widget.videoViewController != null) {
      return _buildVideoViewBar(canSeek: canSeek, skipSegments: skipSegments);
    }
    return _buildMediaKitBar(canSeek: canSeek, skipSegments: skipSegments);
  }

  Widget _buildVideoViewBar({
    required bool canSeek,
    required List<SkipSegment> skipSegments,
  }) {
    final isLive = ref.watch(playerControllerProvider.select((s) => s.isLive));

    return ValueListenableBuilder<int>(
      valueListenable: _vvDurationNotifier,
      builder: (context, durationMs, _) {
        return ValueListenableBuilder<int>(
          valueListenable: _vvPositionNotifier,
          builder: (context, positionMs, _) {
            final durationMsD = durationMs.toDouble();
            final positionMsD = positionMs.toDouble();
            final displayValue = _dragValue ?? positionMsD;
            final displayDuration = Duration(
              milliseconds: (_dragValue ?? positionMsD).toInt(),
            );
            final duration = Duration(milliseconds: durationMs);

            return _buildRow(
              duration: duration,
              durationMs: durationMsD,
              displayValue: displayValue,
              displayDuration: displayDuration,
              bufferWidget: null,
              canSeek: canSeek,
              onSeekEnd: (val) => ref
                  .read(playerControllerProvider.notifier)
                  .seekTo(Duration(milliseconds: val.toInt())),
              isLive: isLive,
              skipSegments: skipSegments,
            );
          },
        );
      },
    );
  }

  Widget _buildMediaKitBar({
    required bool canSeek,
    required List<SkipSegment> skipSegments,
  }) {
    final isLive = ref.watch(playerControllerProvider.select((s) => s.isLive));

    return StreamBuilder<Duration>(
      stream: widget.player.stream.duration,
      initialData: widget.player.state.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final durationMs = duration.inMilliseconds.toDouble();

        return StreamBuilder<Duration>(
          stream: widget.player.stream.position,
          initialData: widget.player.state.position,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final positionMs = position.inMilliseconds.toDouble();
            final displayValue = _dragValue ?? positionMs;
            final displayDuration = _dragValue != null
                ? Duration(milliseconds: _dragValue!.toInt())
                : position;

            final bufferWidget = durationMs > 0
                ? StreamBuilder<Duration>(
                    stream: widget.player.stream.buffer,
                    initialData: widget.player.state.buffer,
                    builder: (context, bufferSnapshot) {
                      final bufferMs = (bufferSnapshot.data ?? Duration.zero)
                          .inMilliseconds
                          .toDouble();
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: LinearProgressIndicator(
                          value: (bufferMs / durationMs).clamp(0, 1),
                          backgroundColor: Colors.transparent,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white.withValues(alpha: 0.25),
                          ),
                          minHeight: 2,
                        ),
                      );
                    },
                  )
                : null;

            return _buildRow(
              duration: duration,
              durationMs: durationMs,
              displayValue: displayValue,
              displayDuration: displayDuration,
              bufferWidget: bufferWidget,
              canSeek: canSeek,
              onSeekEnd: (val) => ref
                  .read(playerControllerProvider.notifier)
                  .seekTo(Duration(milliseconds: val.toInt())),
              isLive: isLive,
              skipSegments: skipSegments,
            );
          },
        );
      },
    );
  }

  Widget _buildRow({
    required Duration duration,
    required double durationMs,
    required double displayValue,
    required Duration displayDuration,
    required Widget? bufferWidget,
    required bool canSeek,
    required void Function(double val) onSeekEnd,
    required List<SkipSegment> skipSegments,
    bool isLive = false,
  }) {
    // Sizes to content (time row + the fixed-height track band) so it never
    // overflows its slot — no magic outer height.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTimeHeader(
          isLive: isLive,
          duration: duration,
          displayDuration: displayDuration,
        ),
        SizedBox(
          height: 32,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  ?bufferWidget,
                  ..._buildSkipMarkers(width, durationMs, skipSegments, canSeek),
                  _buildSlider(
                    durationMs: durationMs,
                    displayValue: displayValue,
                    canSeek: canSeek,
                    onSeekEnd: onSeekEnd,
                  ),
                  if (_dragValue != null)
                    _buildScrubTooltip(width, displayValue, durationMs,
                        displayDuration),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Overlay-radius inset the slider track reserves on each side, so markers and
  /// the tooltip line up with the actual track rather than the full width.
  double _trackInset(bool canSeek) => canSeek
      ? (_dragValue != null || _scrubFocused ? 16.0 : 10.0)
      : 0.0;

  List<Widget> _buildSkipMarkers(
    double width,
    double durationMs,
    List<SkipSegment> skipSegments,
    bool canSeek,
  ) {
    if (durationMs <= 0 || skipSegments.isEmpty) return const [];
    final inset = _trackInset(canSeek);
    final trackWidth = (width - inset * 2).clamp(0.0, width).toDouble();
    return [
      for (final seg in skipSegments)
        if ((seg.startTime * 1000 / durationMs).clamp(0.0, 1.0) <
            (seg.endTime * 1000 / durationMs).clamp(0.0, 1.0))
          Positioned(
            left:
                inset +
                trackWidth * (seg.startTime * 1000 / durationMs).clamp(0.0, 1.0),
            width:
                trackWidth *
                ((seg.endTime * 1000 / durationMs).clamp(0.0, 1.0) -
                    (seg.startTime * 1000 / durationMs).clamp(0.0, 1.0)),
            height: 3,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: HotstarPlayerStyle.skipSegment,
                borderRadius: BorderRadius.all(Radius.circular(1.5)),
              ),
            ),
          ),
    ];
  }

  Widget _buildSlider({
    required double durationMs,
    required double displayValue,
    required bool canSeek,
    required void Function(double val) onSeekEnd,
  }) {
    final isDragging = _dragValue != null;
    final maxValue = durationMs > 0 ? durationMs : 1.0;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: _scrubFocused ? 4 : 2.5,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: canSeek
              ? (isDragging ? 8 : (_scrubFocused ? 9 : 6))
              : 0,
        ),
        overlayShape: RoundSliderOverlayShape(
          overlayRadius: canSeek ? (isDragging || _scrubFocused ? 16 : 10) : 0,
        ),
        activeTrackColor: canSeek
            ? HotstarPlayerStyle.accent
            : HotstarPlayerStyle.accent.withValues(alpha: 0.5),
        inactiveTrackColor: HotstarPlayerStyle.trackInactive,
        disabledActiveTrackColor: HotstarPlayerStyle.accent.withValues(
          alpha: 0.5,
        ),
        disabledInactiveTrackColor: HotstarPlayerStyle.trackInactive,
        disabledThumbColor: Colors.transparent,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbColor: Colors.white,
        overlayColor: HotstarPlayerStyle.accent.withValues(alpha: 0.18),
      ),
      child: CustomSlider(
        value: displayValue.clamp(0, maxValue),
        min: 0.0,
        max: maxValue,
        step: 5 * 60 * 1000.0, // D-pad Left/Right jumps 5 minutes on the remote
        focusNode: _scrubFocusNode,
        onArrowUp: widget.onArrowUp,
        onArrowDown: widget.onArrowDown,
        onChanged: canSeek
            ? (val) => setState(() => _dragValue = val)
            : null,
        onChangeStart: canSeek
            ? (val) {
                widget.onSeekStart?.call();
                setState(() => _dragValue = val);
              }
            : null,
        onChangeEnd: canSeek
            ? (val) {
                onSeekEnd(val);
                widget.onSeekEnd?.call();
                setState(() => _dragValue = null);
              }
            : null,
      ),
    );
  }

  Widget _buildScrubTooltip(
    double width,
    double displayValue,
    double durationMs,
    Duration displayDuration,
  ) {
    const tooltipWidth = 76.0;
    final scrubPercent = durationMs > 0
        ? (displayValue / durationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final maxLeft = width > tooltipWidth ? width - tooltipWidth : 0.0;
    final left = (width * scrubPercent - tooltipWidth / 2)
        .clamp(0.0, maxLeft)
        .toDouble();
    return Align(
      alignment: Alignment(
        width > 0 ? (left / width * 2 - 1).clamp(-1.0, 1.0) : 0.0,
        -3.5, // above the centered track
      ),
      child: IgnorePointer(
        child: SizedBox(
          width: tooltipWidth,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _formatDuration(displayDuration),
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerPlayPauseButton extends StatelessWidget {
  final Player player;
  final vv.VideoController? videoViewController;
  final bool isLoading;
  final bool isTv;
  final double size;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  /// When false the button shows the play/pause icon even while buffering — the
  /// buffering state is surfaced by the centered [PlayerBufferingIndicator]
  /// instead. Used for the corner button on desktop/TV so the spinner isn't
  /// hidden away where it's easy to miss.
  final bool showBufferingSpinner;

  /// Optional circular fill behind the glyph (used for the big touch-center
  /// button so it reads as a tappable target over bright video).
  final Color? backgroundColor;

  const PlayerPlayPauseButton({
    super.key,
    required this.player,
    this.videoViewController,
    this.isLoading = false,
    this.isTv = false,
    this.size = 82,
    this.focusNode,
    this.onPressed,
    this.showBufferingSpinner = true,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering =
            ref.watch(playerControllerProvider.select((s) => s.isBuffering)) &&
            showBufferingSpinner;
        final useExoPlayer = ref.watch(
          playerControllerProvider.select((s) => s.useExoPlayer),
        );

        if (useExoPlayer && videoViewController != null) {
          return ListenableBuilder(
            listenable: videoViewController!.playbackState,
            builder: (context, _) {
              final isPlaying =
                  videoViewController!.playbackState.value ==
                  vv.VideoControllerPlaybackState.playing;
              return _buildButton(
                isPlaying: isPlaying,
                isSpinning: isBuffering,
              );
            },
          );
        }

        return StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            return _buildButton(
              isPlaying: snapshot.data ?? false,
              isSpinning: isBuffering,
            );
          },
        );
      },
    );
  }

  Widget _buildButton({required bool isPlaying, required bool isSpinning}) {
    return CustomButton(
      focusNode: focusNode,
      onPressed: onPressed ?? () => player.playOrPause(),
      showFocusHighlight: isTv,
      shape: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: backgroundColor != null
            ? BoxDecoration(shape: BoxShape.circle, color: backgroundColor)
            : null,
        child: isSpinning
            ? const _PlayerSpinner()
            : Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: size * 0.88,
              ),
      ),
    );
  }
}

/// The single shared player spinner — used by the centered buffering indicator
/// and by the play/pause button so they look identical (they both appear in the
/// screen centre on touch).
class _PlayerSpinner extends StatelessWidget {
  const _PlayerSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 42,
      height: 42,
      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3.5),
    );
  }
}

class PlayerBufferingIndicator extends StatelessWidget {
  final bool isVisible;

  /// On touch the play/pause button lives in the screen centre and shows its
  /// own spinner, so this indicator is suppressed while the controls are
  /// visible. On desktop/TV the play/pause button is in the corner, so the
  /// centered indicator stays shown even with controls visible — otherwise a
  /// stall is easy to miss.
  final bool isTouch;

  const PlayerBufferingIndicator({
    super.key,
    this.isVisible = false,
    this.isTouch = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering = ref.watch(
          playerControllerProvider.select((s) => s.isBuffering),
        );
        final isLoading = ref.watch(
          playerControllerProvider.select((s) => s.isLoading),
        );
        final userSkippedOverlay = ref.watch(
          playerControllerProvider.select((s) => s.userSkippedOverlay),
        );

        if (!isBuffering && !isLoading) return const SizedBox.shrink();
        // Touch + controls visible → the centered play/pause spinner covers it.
        if (isVisible && isTouch) return const SizedBox.shrink();
        // While the primary (blocking) loading overlay is up, defer to it.
        if (isLoading && !userSkippedOverlay) return const SizedBox.shrink();

        return const IgnorePointer(child: Center(child: _PlayerSpinner()));
      },
    );
  }
}
