import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CardsWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double scaleFactor;
  final bool autoFocus;
  final BorderRadius? borderRadius;
  final FocusNode? focusNode;

  const CardsWrapper({
    super.key,
    required this.child,
    required this.onTap,
    this.scaleFactor = 1.03,
    this.autoFocus = false,
    this.borderRadius,
    this.focusNode,
  });

  @override
  State<CardsWrapper> createState() => _CardsWrapperState();
}

class _CardsWrapperState extends State<CardsWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isFocused = false;
  late FocusNode _node;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.scaleFactor,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _node.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant CardsWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) _node.dispose();
      _node = widget.focusNode ?? FocusNode();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  bool _isHovered = false;

  void _updateAnimation() {
    // In D-pad/keyboard mode the border+glow is the focus indicator; skip scale
    // to prevent edge items from overflowing the viewport.
    final isDpad = FocusManager.instance.highlightMode ==
        FocusHighlightMode.traditional;
    final shouldScale = _isHovered || (_isFocused && !isDpad);
    if (shouldScale) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _onFocusChange(bool hasFocus) {
    setState(() {
      _isFocused = hasFocus;
    });
    _updateAnimation();
    if (hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ro = context.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return;
        const duration = Duration(milliseconds: 380);
        const curve = Curves.fastOutSlowIn;

        // Horizontal: always center the focused card inside its row so the
        // active card stays in the middle of the screen as the user walks
        // along the row.
        Scrollable.maybeOf(context, axis: Axis.horizontal)
            ?.position
            .ensureVisible(ro, alignment: 0.5, duration: duration, curve: curve);

        // Vertical: only scroll if the card is actually clipped. Moving
        // Left/Right within a row would otherwise re-center the row
        // vertically on every keystroke and the whole screen would jump.
        final vScroll = Scrollable.maybeOf(context, axis: Axis.vertical);
        if (vScroll != null) {
          final scrollBox = vScroll.context.findRenderObject();
          if (scrollBox is RenderBox && scrollBox.hasSize) {
            final top = ro.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
            final bottom = top + ro.size.height;
            final viewportH = scrollBox.size.height;
            if (top < 0 || bottom > viewportH) {
              vScroll.position.ensureVisible(
                ro,
                alignment: 0.5,
                duration: duration,
                curve: curve,
              );
            }
          }
        }
      });
    }
  }

  void _onHover(bool isHovered) {
    setState(() {
      _isHovered = isHovered;
    });
    _updateAnimation();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onFocusChange: _onFocusChange,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => _onHover(true),
        onExit: (_) => _onHover(false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
                border: (_isFocused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional)
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      )
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
