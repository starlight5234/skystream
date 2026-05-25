import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/utils/layout_constants.dart';

/// A Slider widget that handles D-pad navigation properly on TV.
/// Left/Right D-pad adjusts the value, Up/Down D-pad navigates to other focusable elements.
class CustomSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final double step;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final Color? activeColor;
  final Color? inactiveColor;

  const CustomSlider({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.step = 1.0,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  State<CustomSlider> createState() => _CustomSliderState();
}

class _CustomSliderState extends State<CustomSlider> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  bool _isDragging = false;
  Timer? _seekCommitTimer;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _seekCommitTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleDpadSeek(double newValue) {
    if (!_isDragging) {
      _isDragging = true;
      widget.onChangeStart?.call(newValue);
    }
    widget.onChanged?.call(newValue);

    _seekCommitTimer?.cancel();
    _seekCommitTimer = Timer(const Duration(milliseconds: 500), () {
      widget.onChangeEnd?.call(newValue);
      _isDragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }

        final logicalKey = event.logicalKey;

        // Left arrow: decrease value
        if (logicalKey == LogicalKeyboardKey.arrowLeft) {
          final newValue = (widget.value - widget.step).clamp(
            widget.min,
            widget.max,
          );
          if (newValue != widget.value) {
            _handleDpadSeek(newValue);
          }
          return KeyEventResult.handled;
        }

        // Right arrow: increase value
        if (logicalKey == LogicalKeyboardKey.arrowRight) {
          final newValue = (widget.value + widget.step).clamp(
            widget.min,
            widget.max,
          );
          if (newValue != widget.value) {
            _handleDpadSeek(newValue);
          }
          return KeyEventResult.handled;
        }

        // Up arrow: move focus up — operate on our own node so traversal is
        // anchored to the slider and not to whatever happens to be the
        // enclosing FocusScope.
        if (logicalKey == LogicalKeyboardKey.arrowUp) {
          _focusNode.focusInDirection(TraversalDirection.up);
          return KeyEventResult.handled;
        }

        // Down arrow: move focus down
        if (logicalKey == LogicalKeyboardKey.arrowDown) {
          _focusNode.focusInDirection(TraversalDirection.down);
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: (_isFocused &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional)
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : Border.all(color: Colors.transparent, width: 2),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingXs,
          vertical: 4,
        ),
        child: ExcludeFocus(
          child: Slider(
            value: widget.value.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: widget.onChanged,
            onChangeStart: widget.onChangeStart,
            onChangeEnd: widget.onChangeEnd,
            activeColor: widget.activeColor ??
                ((_isFocused &&
                        FocusManager.instance.highlightMode ==
                            FocusHighlightMode.traditional)
                    ? Theme.of(context).colorScheme.primary
                    : null),
            inactiveColor: widget.inactiveColor,
          ),
        ),
      ),
    );
  }
}

/// A TextField widget that allows D-pad navigation out of the text field.
/// Up/Down D-pad navigates to other focusable elements instead of being trapped.
/// When keyboard OK is pressed, focus automatically moves to the next element.
class CustomTextField extends StatefulWidget {
  final TextEditingController? controller;
  final InputDecoration? decoration;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final String? hintText;
  final bool obscureText;
  final TextInputType? keyboardType;

  const CustomTextField({
    super.key,
    this.controller,
    this.decoration,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.hintText,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        final key = event.logicalKey;

        // Use directional traversal anchored to our own node so D-pad Up/Down
        // lands on the spatial neighbour. The previous unfocus/disable/
        // re-enable dance relied on a 100ms timer that could race on slow
        // devices and re-focus the field instead of moving on.
        if (key == LogicalKeyboardKey.arrowUp) {
          _focusNode.focusInDirection(TraversalDirection.up);
          return KeyEventResult.handled;
        }

        if (key == LogicalKeyboardKey.arrowDown) {
          _focusNode.focusInDirection(TraversalDirection.down);
          return KeyEventResult.handled;
        }

        // Let left/right pass through for text cursor navigation
        return KeyEventResult.ignored;
      },
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Define consistent premium borders for the project
    final enabledBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: colorScheme.outline.withValues(alpha: 0.5),
        width: 1,
      ),
    );

    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: colorScheme.primary, width: 2),
    );

    // Merge the provided decoration with our consistent styling
    final effectiveDecoration = (widget.decoration ?? const InputDecoration())
        .copyWith(
          hintText: widget.hintText ?? widget.decoration?.hintText,
          enabledBorder: widget.decoration?.enabledBorder ?? enabledBorder,
          focusedBorder: widget.decoration?.focusedBorder ?? focusedBorder,
          border: widget.decoration?.border ?? enabledBorder,
        );

    return TextField(
      focusNode: _focusNode,
      controller: widget.controller,
      decoration: effectiveDecoration,
      autofocus: widget.autofocus,
      textInputAction: widget.textInputAction ?? TextInputAction.done,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      onSubmitted: (value) {
        // Call user callback first — it may navigate away or close a host
        // dialog, so bail out if we got unmounted before moving focus.
        widget.onSubmitted?.call(value);
        if (mounted) {
          _focusNode.focusInDirection(TraversalDirection.down);
        }
      },
    );
  }
}

/// A styled button for TV that shows focus state clearly with proper Material Design styling.
class CustomButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final bool isPrimary;
  final bool isOutlined;
  final FocusNode? focusNode;
  final Color? backgroundColor;
  final OutlinedBorder? shape;
  final bool showFocusHighlight;

  const CustomButton({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.isPrimary = false,
    this.isOutlined = false,
    this.focusNode,
    this.backgroundColor,
    this.shape,
    this.showFocusHighlight = false,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton> {
  late FocusNode _focusNode;
  bool _isFocused = false;
  late final VoidCallback _focusListener;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusListener = () {
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
    };
    _focusNode.addListener(_focusListener);
  }

  @override
  void dispose() {
    // Always remove the listener; the node may be owned by the parent, in
    // which case it outlives this state and would otherwise hold a reference
    // to a disposed closure target.
    _focusNode.removeListener(_focusListener);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final isTraditional = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final showHighlight =
        widget.showFocusHighlight && _isFocused && isTraditional;

    // Wrap in an AnimatedScale + Container so focused buttons get a clear
    // "elevation" cue regardless of their fill color. Useful on TV where blue
    // and grey buttons can otherwise look identical to non-focused.
    final scale = showHighlight ? 1.04 : 1.0;
    final glowColor = primaryColor;

    Widget core;
    if (widget.isPrimary) {
      core = FilledButton(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onPressed: widget.onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: showHighlight
              // On focus, brighten the primary fill so it pops against the dark
              // background and the white outline contrasts clearly.
              ? Color.lerp(primaryColor, Colors.white, 0.18)
              : (widget.backgroundColor ?? primaryColor),
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          disabledBackgroundColor: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.38),
          side: showHighlight
              ? const BorderSide(color: Colors.white, width: 3)
              : BorderSide.none,
          shadowColor: Colors.transparent,
          shape: widget.shape,
        ),
        child: widget.child,
      );
    } else {
      core = TextButton(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onPressed: widget.onPressed,
        style: TextButton.styleFrom(
          backgroundColor: showHighlight
              // Fill the button on focus so a "grey" outlined button no longer
              // looks identical to its non-focused state.
              ? primaryColor.withValues(alpha: 0.28)
              : null,
          foregroundColor: _isFocused
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.onSurfaceVariant,
          disabledForegroundColor: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.38),
          side: showHighlight
              ? const BorderSide(color: Colors.white, width: 3)
              : (widget.isOutlined
                    ? BorderSide(color: Theme.of(context).colorScheme.outline)
                    : BorderSide.none),
          shape: widget.shape,
        ),
        child: widget.child,
      );
    }

    return AnimatedScale(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      scale: scale,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: showHighlight
              ? [
                  BoxShadow(
                    color: glowColor.withValues(alpha: 0.55),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: core,
      ),
    );
  }
}
