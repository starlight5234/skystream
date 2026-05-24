import 'dart:async';
import 'package:flutter/material.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'hotstar_player_style.dart';

class ResumePromptOverlay extends StatelessWidget {
  final int positionMs;
  final VoidCallback onResume;
  final VoidCallback onStartOver;

  const ResumePromptOverlay({
    super.key,
    required this.positionMs,
    required this.onResume,
    required this.onStartOver,
  });

  String _formatDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _CountdownButtonPlacement(
      child: CountdownFillButton(
        label: l10n.resumeNow,
        subtitle: l10n.pausedAt(_formatDuration(positionMs)),
        duration: const Duration(seconds: 8),
        onPressed: onResume,
        onTimeout: onStartOver,
      ),
    );
  }
}

class CountdownFillButton extends StatefulWidget {
  final String label;
  final String? subtitle;
  final Duration duration;
  final VoidCallback onPressed;
  final VoidCallback onTimeout;
  final bool showDismiss;
  final VoidCallback? onDismiss;

  const CountdownFillButton({
    super.key,
    required this.label,
    this.subtitle,
    required this.duration,
    required this.onPressed,
    required this.onTimeout,
    this.showDismiss = false,
    this.onDismiss,
  });

  @override
  State<CountdownFillButton> createState() => _CountdownFillButtonState();
}

class _CountdownFillButtonState extends State<CountdownFillButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
    _timer = Timer(widget.duration, _handleTimeout);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handlePressed() {
    if (_completed) return;
    _completed = true;
    _timer?.cancel();
    widget.onPressed();
  }

  void _handleTimeout() {
    if (_completed) return;
    _completed = true;
    widget.onTimeout();
  }

  void _handleDismiss() {
    if (_completed) return;
    _completed = true;
    _timer?.cancel();
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isCompact = size.shortestSide < 600;
    final buttonWidth = isCompact ? 190.0 : 260.0;
    final buttonHeight = widget.subtitle == null
        ? (isCompact ? 46.0 : 52.0)
        : (isCompact ? 58.0 : 64.0);
    final borderRadius = BorderRadius.circular(isCompact ? 8 : 10);

    return SizedBox(
      width: buttonWidth,
      height: buttonHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.52),
                borderRadius: borderRadius,
                border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
              ),
            ),
          ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: borderRadius,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: _controller.value,
                      heightFactor: 1,
                      child: child,
                    ),
                  );
                },
                child: ColoredBox(
                  color: HotstarPlayerStyle.accent.withValues(alpha: 0.92),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: borderRadius,
                onTap: _handlePressed,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 12 : 16,
                    vertical: isCompact ? 7 : 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      SizedBox(width: isCompact ? 6 : 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: isCompact ? 13 : 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (widget.subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.78),
                                  fontSize: isCompact ? 10 : 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (widget.showDismiss && widget.onDismiss != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: _handleDismiss,
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownButtonPlacement extends StatelessWidget {
  final Widget child;

  const _CountdownButtonPlacement({required this.child});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final isCompact = size.shortestSide < 600;
    final bottomOffset = isCompact ? 108.0 : 116.0;
    final sideOffset = isCompact ? 18.0 : 24.0;

    return Positioned(
      right: sideOffset + padding.right,
      bottom: bottomOffset + padding.bottom,
      child: child,
    );
  }
}
