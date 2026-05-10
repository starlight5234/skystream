import 'package:flutter/material.dart';

class FocusableItem extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double focusedScale;
  final double hoverScale;
  final Color? focusColor;
  final BorderRadius? borderRadius;

  const FocusableItem({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.focusedScale = 1.05,
    this.hoverScale = 1.02,
    this.focusColor,
    this.borderRadius,
  });

  @override
  State<FocusableItem> createState() => _FocusableItemState();
}

class _FocusableItemState extends State<FocusableItem>
    with SingleTickerProviderStateMixin {
  bool _isFocused = false;
  bool _isHovered = false;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  late final Animation<double> _scaleAnim = Tween<double>(
    begin: 1.0,
    end: widget.focusedScale,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _updateState() {
    // In D-pad/keyboard mode the border+glow is the focus indicator; skip scale
    // to prevent edge items from overflowing the viewport.
    final isDpad = FocusManager.instance.highlightMode ==
        FocusHighlightMode.traditional;
    final shouldScale = _isHovered || (_isFocused && !isDpad);
    if (shouldScale) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (focused) {
        setState(() {
          _isFocused = focused;
        });
        _updateState();
      },
      onShowHoverHighlight: (hovered) {
        setState(() {
          _isHovered = hovered;
        });
        _updateState();
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => widget.onTap(),
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: ScaleTransition(
          scale: _scaleAnim,
          child: Container(
            decoration: _isFocused
                ? BoxDecoration(
                    border: Border.all(
                      color:
                          widget.focusColor ??
                          Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius:
                        widget.borderRadius ?? BorderRadius.circular(12),
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
