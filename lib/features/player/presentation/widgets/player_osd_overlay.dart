import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../player_gesture_handler.dart';
import 'hotstar_player_style.dart';

/// Rebuilds only when [PlayerGestureHandler] notifies (OSD/volume state).
/// Use this instead of listening to the handler in the full controls to avoid
/// rebuilding the entire player UI on every OSD change.
class PlayerOSDVolumeOverlay extends ConsumerWidget {
  const PlayerOSDVolumeOverlay({
    super.key,
    required this.getDuration,
    required this.formatDuration,
  });

  final Duration Function() getDuration;
  final String Function(Duration) formatDuration;

  String _formatSignedDelta(Duration delta) {
    final sign = delta.isNegative ? '-' : '+';
    return '$sign${formatDuration(delta.abs())}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerGestureHandlerProvider);
    final handler = ref.read(playerGestureHandlerProvider.notifier);
    final seekDelta = state.swipeSeekValue != null
        ? state.swipeSeekValue! -
              (state.swipeSeekStartValue ?? state.swipeSeekValue!)
        : Duration.zero;
    final size = MediaQuery.sizeOf(context);
    final seekFontSize = size.shortestSide < 600 ? 24.0 : 32.0;

    if (state.swipeSeekValue != null) {
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),
                child: Center(
                  key: const ValueKey('swipe-seek-target'),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      child: Text(
                        '${formatDuration(state.swipeSeekValue!)} [${_formatSignedDelta(seekDelta)}]',
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: seekFontSize,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.68),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        PlayerOsdOverlay(
          showOSD: state.showOSD,
          osdValue: state.osdValue,
          osdLabel: state.osdLabel,
          osdIcon: state.osdIcon,
          osdAlignment: state.osdAlignment,
          supportsVolumeBoost: handler.supportsVolumeBoost,
        ),
      ],
    );
  }
}

class PlayerOsdOverlay extends StatelessWidget {
  final bool showOSD;
  final double? osdValue;
  final String osdLabel;
  final IconData osdIcon;
  final Alignment osdAlignment;
  final bool supportsVolumeBoost;

  const PlayerOsdOverlay({
    super.key,
    required this.showOSD,
    required this.osdValue,
    required this.osdLabel,
    required this.osdIcon,
    required this.osdAlignment,
    required this.supportsVolumeBoost,
  });

  @override
  Widget build(BuildContext context) {
    if (!showOSD) return const SizedBox.shrink();
    final bool showBoostState =
        supportsVolumeBoost &&
        (osdValue ?? 0) > 1.0 &&
        !(osdLabel == "Brightness" || osdLabel == "Auto");

    final isBrightness = osdLabel == "Brightness" || osdLabel == "Auto";
    if (osdValue != null) {
      return Align(
        alignment: isBrightness ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 42),
          child: _HotstarEdgeRail(
            icon: osdIcon,
            value: osdValue!,
            label: osdLabel,
            isBoosted: showBoostState,
            supportsVolumeBoost: supportsVolumeBoost,
          ),
        ),
      );
    }

    return Align(
      alignment: osdAlignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(osdIcon, color: Colors.white, size: 24),
              const SizedBox(width: 12),
              Text(
                osdLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HotstarEdgeRail extends StatelessWidget {
  final IconData icon;
  final double value;
  final String label;
  final bool isBoosted;
  final bool supportsVolumeBoost;

  const _HotstarEdgeRail({
    required this.icon,
    required this.value,
    required this.label,
    required this.isBoosted,
    required this.supportsVolumeBoost,
  });

  @override
  Widget build(BuildContext context) {
    final isBrightness = label == "Brightness" || label == "Auto";
    final baseValue = value.clamp(0.0, 1.0);
    final railValue = isBrightness || !supportsVolumeBoost
        ? baseValue
        : value.clamp(0.0, 1.0);
    final size = MediaQuery.sizeOf(context);
    final isCompact = size.shortestSide < 600;
    final railWidth = isCompact ? 34.0 : 48.0;
    final railHeight = isCompact ? 176.0 : 248.0;
    final iconSize = isCompact ? 22.0 : 28.0;
    final gap = isCompact ? 8.0 : 12.0;
    final fillWidth = isCompact ? 3.5 : 4.5;
    final fillRadius = isCompact ? 4.0 : 6.0;

    return SizedBox(
      width: railWidth,
      height: railHeight,
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: iconSize),
          SizedBox(height: gap),
          Expanded(
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(fillRadius),
                child: SizedBox(
                  width: fillWidth,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Container(
                        color: HotstarPlayerStyle.track.withValues(alpha: 0.36),
                      ),
                      FractionallySizedBox(
                        heightFactor: railValue,
                        child: Container(color: Colors.white),
                      ),
                      if (isBoosted)
                        Align(
                          alignment: Alignment.topCenter,
                          child: FractionallySizedBox(
                            heightFactor: (value - 1.0).clamp(0.0, 1.0),
                            child: Container(color: Colors.orange),
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
