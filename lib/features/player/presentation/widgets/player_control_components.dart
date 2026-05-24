import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_view/video_view.dart' as vv;
import '../../../../shared/widgets/custom_widgets.dart';
import 'hotstar_player_style.dart';
import 'player_stream_widgets.dart';

/// Top bar with back button and title for the player.
/// Extracted from SkyStreamPlayerControls to reduce widget size.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final bool isTv;
  final FocusNode? backFocusNode;
  final List<Widget> trailingActions;

  const PlayerTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.isTv = false,
    this.backFocusNode,
    this.trailingActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: () {},
        onDoubleTap: () {},
        onHorizontalDragStart: (_) {},
        onVerticalDragStart: (_) {},
        child: Container(
          padding: EdgeInsets.only(
            top: MediaQuery.viewPaddingOf(context).top + 16,
            left: 20,
            right: 20,
            bottom: 8,
          ),
          child: Row(
            children: [
              CustomButton(
                showFocusHighlight: isTv,
                focusNode: backFocusNode,
                onPressed: onBack ?? () => context.pop(),
                child: const Icon(
                  Icons.arrow_back,
                  color: Colors.white,
                  size: 34,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: HotstarPlayerStyle.secondaryText,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      style: const TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ...trailingActions,
            ],
          ),
        ),
      ),
    );
  }
}

/// Center playback controls (seek back, play/pause, seek forward).
/// Uses StreamBuilder-based PlayerPlayPauseButton for efficient updates.
class PlayerCenterControls extends StatelessWidget {
  final Player player;
  final vv.VideoController? videoViewController;
  final bool isLoading;
  final bool isTv;
  final FocusNode? playFocusNode;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;
  final VoidCallback onPlayPause;

  const PlayerCenterControls({
    super.key,
    required this.player,
    required this.onSeekBackward,
    required this.onSeekForward,
    required this.onPlayPause,
    this.videoViewController,
    this.isLoading = false,
    this.isTv = false,
    this.playFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundedPlaybackButton(
            icon: Icons.keyboard_double_arrow_left_rounded,
            size: 46,
            isTv: isTv,
            onPressed: onSeekBackward,
          ),
          const SizedBox(width: 64),
          PlayerPlayPauseButton(
            player: player,
            videoViewController: videoViewController,
            isLoading: isLoading,
            isTv: isTv,
            focusNode: playFocusNode,
            onPressed: onPlayPause,
          ),
          const SizedBox(width: 64),
          _RoundedPlaybackButton(
            icon: Icons.keyboard_double_arrow_right_rounded,
            size: 46,
            isTv: isTv,
            onPressed: onSeekForward,
          ),
        ],
      ),
    );
  }
}

class _RoundedPlaybackButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool isTv;
  final VoidCallback onPressed;

  const _RoundedPlaybackButton({
    required this.icon,
    required this.size,
    required this.isTv,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CustomButton(
      showFocusHighlight: isTv,
      onPressed: onPressed,
      shape: const CircleBorder(),
      child: Container(
        width: size + 16,
        height: size + 16,
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}

/// A reusable action button for the player controls bottom bar.
class PlayerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool rotate;
  final bool highlight;
  final bool isTv;
  final int focusOrder;

  const PlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.rotate = false,
    this.highlight = false,
    this.isTv = false,
    this.focusOrder = 0,
  });

  @override
  State<PlayerActionButton> createState() => _PlayerActionButtonState();
}

class _PlayerActionButtonState extends State<PlayerActionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.highlight || _hovered || _focused || _pressed;

    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.focusOrder.toDouble()),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: _setPressed,
            borderRadius: BorderRadius.circular(6),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: isActive
                    ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: widget.rotate ? 0.5 : 0.0),
                    duration: const Duration(milliseconds: 180),
                    builder: (context, value, child) {
                      return Transform.rotate(
                        angle: value * 3.14159,
                        child: Icon(
                          widget.icon,
                          color: isActive
                              ? HotstarPlayerStyle.accent
                              : Colors.white,
                          size: 20,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: isActive
                          ? HotstarPlayerStyle.accent
                          : HotstarPlayerStyle.primaryText,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
