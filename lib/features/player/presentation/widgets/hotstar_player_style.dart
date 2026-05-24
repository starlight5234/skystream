import 'package:flutter/material.dart';

class HotstarPlayerStyle {
  static const Color background = Color(0xFF000000);
  static const Color panel = Color(0xFF05070B);
  static const Color panelElevated = Color(0xFF090D14);
  static const Color accent = Color(0xFF0A84FF);
  static const Color accentAlt = Color(0xFFDD3EFF);
  static const Color primaryText = Color(0xF2FFFFFF);
  static const Color secondaryText = Color(0xA6FFFFFF);
  static const Color mutedText = Color(0x73FFFFFF);
  static const Color divider = Color(0x1FFFFFFF);
  static const Color track = Color(0x55FFFFFF);
  static const Color trackInactive = Color(0x35FFFFFF);
  static const Color focus = Color(0x660A84FF);

  static const Duration controlFadeDuration = Duration(milliseconds: 220);
  static const Duration fastMotionDuration = Duration(milliseconds: 160);
  static const Duration panelMotionDuration = Duration(milliseconds: 240);

  static LinearGradient topGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.black.withValues(alpha: 0.78),
      Colors.black.withValues(alpha: 0.34),
      Colors.transparent,
    ],
  );

  static LinearGradient bottomGradient = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [
      Colors.black.withValues(alpha: 0.9),
      Colors.black.withValues(alpha: 0.45),
      Colors.transparent,
    ],
  );
}
