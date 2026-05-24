import 'package:flutter/material.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'resume_prompt_overlay.dart';

class NextEpisodeOverlay extends StatelessWidget {
  final String nextEpisodeTitle;
  final VoidCallback onPlayNext;
  final VoidCallback onDismiss;

  const NextEpisodeOverlay({
    super.key,
    required this.nextEpisodeTitle,
    required this.onPlayNext,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _NextEpisodePlacement(
      child: CountdownFillButton(
        label: l10n.playNow,
        subtitle: nextEpisodeTitle,
        duration: const Duration(seconds: 15),
        onPressed: onPlayNext,
        onTimeout: onDismiss,
      ),
    );
  }
}

class _NextEpisodePlacement extends StatelessWidget {
  final Widget child;

  const _NextEpisodePlacement({required this.child});

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
