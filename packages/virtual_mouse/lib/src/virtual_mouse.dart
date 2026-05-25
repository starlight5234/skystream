import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:virtual_mouse/virtual_mouse.dart';

class VirtualMouse extends StatefulWidget {
  /// The focus node to be used in the virtual mouse cursor
  final FocusScopeNode? node;

  /// If the virtual mouse cursor should be focused when the widget is rendered
  final bool autoFocus;

  /// The velocity of the virtual mouse cursor movement in milliseconds
  final double velocity;

  /// The angle of the pointer in degrees
  final double angle;

  /// The duration of the virtual mouse cursor movement
  final Duration duration;

  /// The color of the pointer
  final Color pointerColor;

  /// The child widget to be rendered inside the virtual mouse cursor
  final Widget child;

  /// Custom pointer to be used in the virtual mouse cursor
  final CustomPainter? pointer;

  /// Callback to be called when a key is pressed
  /// The key pressed is passed as argument
  /// The key is an instance of [KeyHandler]
  /// The key pressed can be accessed by the properties:
  /// - keyMap.up
  /// - keyMap.down
  /// - keyMap.left
  /// - keyMap.right
  /// - keyMap.enter
  final Function(KeyHandler key)? onKeyPressed;

  /// Callback to be called when the mouse is moved to a new position
  final Function(Offset offset, Size constrants)? onMove;

  /// Whether the virtual mouse cursor is visible
  /// When false, the cursor is hidden and key events pass through
  final bool visible;

  const VirtualMouse({
    super.key,
    this.node,
    this.onMove,
    this.pointer,
    this.onKeyPressed,
    this.velocity = 1.0,
    this.angle = -40.0,
    this.autoFocus = true,
    this.pointerColor = Colors.red,
    this.duration = const Duration(milliseconds: 10),
    this.visible = true,
    required this.child,
  });

  @override
  State<VirtualMouse> createState() => _VirtualMouseState();
}

class _VirtualMouseState extends State<VirtualMouse> {
  final _keyMap = KeyHandler();
  final _pointerKey = GlobalKey();

  double _dx = 0;
  double _dy = 0;
  Timer? _moveTimer;

  double _maxWidth = 0;
  double _maxHeigth = 0;

  Size get size => Size(_maxWidth, _maxHeigth);

  Offset get offset {
    if (_pointerKey.currentContext != null) {
      final renderbox =
          _pointerKey.currentContext?.findRenderObject() as RenderBox;
      return renderbox.localToGlobal(Offset.zero);
    }

    return Offset(_dx, _dy);
  }

  void _setup() {
    if (!mounted) return;

    final sizeOf = MediaQuery.sizeOf(context);
    setState(() {
      _dx = sizeOf.width / 2;
      _dy = sizeOf.height / 2;
    });
  }

  void _move() {
    if (_moveTimer?.isActive ?? false) return; // Single-flight guard
    _moveTimer = Timer.periodic(widget.duration, (t) {
      bool shouldContinue = false;

      if (_keyMap.left && _dx > 0) {
        _dx -= widget.velocity;
        shouldContinue = true;
      } else if (_keyMap.right && _dx < _maxWidth - 10) {
        _dx += widget.velocity;
        shouldContinue = true;
      } else if (_keyMap.up) {
        if (_dy > 0) {
          // Allow cursor to move all the way to top (for app bar access)
          _dy -= widget.velocity;
          shouldContinue = true;
        } else {
          // Already at top edge (dy <= 0) - trigger scroll up
          _scroll(-widget.velocity * 5);
          shouldContinue = true;
        }
      } else if (_keyMap.down) {
        if (_dy < _maxHeigth - 30) {
          _dy += widget.velocity;
          shouldContinue = true;
        } else {
          // At bottom edge - trigger scroll down
          _scroll(widget.velocity * 5);
          shouldContinue = true;
        }
      }

      if (!shouldContinue) {
        t.cancel();
        _moveTimer = null;
      }

      widget.onMove?.call(offset, size);
      setState(() {});
    });
  }

  void _scroll(double delta) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    // Use center of screen for scroll events (edge positions may miss scrollable area)
    final scrollPosition = Offset(_maxWidth / 2, _maxHeigth / 2);

    // Simulate scroll gesture at center position
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        position: scrollPosition,
        scrollDelta: Offset(0, delta),
      ),
    );
  }

  void _tap() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(position: offset),
    );
    await Future.delayed(const Duration(milliseconds: 100));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(position: offset),
    );
  }

  void _keyListener() {
    if (_keyMap.arrows) {
      _move();
    }

    if (_keyMap.enter) {
      _tap();
    }

    if (widget.onKeyPressed != null) {
      widget.onKeyPressed?.call(_keyMap);
    }
  }

  @override
  void initState() {
    super.initState();
    _keyMap.addListener(_keyListener);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setup();
    });
  }

  @override
  void dispose() {
    _moveTimer?.cancel();
    _keyMap.removeListener(_keyListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pointer =
        widget.pointer ??
        CursorPainter(color: widget.pointerColor, angle: widget.angle);

    return FocusScope(
      node: widget.node,
      onKeyEvent: _keyEvent,
      autofocus: widget.autoFocus,
      onFocusChange: (value) {
        if (!value) _keyMap.reset();
      },
      child: LayoutBuilder(
        builder: (context, constrants) {
          _maxWidth = constrants.maxWidth;
          _maxHeigth = constrants.maxHeight;
          // If not visible, just return child without cursor overlay
          if (!widget.visible) {
            return widget.child;
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              Positioned(
                top: _dy,
                left: _dx,
                key: _pointerKey,
                child: CustomPaint(painter: pointer, child: Container()),
              ),
            ],
          );
        },
      ),
    );
  }

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    // If not visible, don't handle key events - pass through to Flutter
    if (!widget.visible) {
      return KeyEventResult.ignored;
    }

    final pressed = HardwareKeyboard.instance.isLogicalKeyPressed(
      event.logicalKey,
    );

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _keyMap.keyUp(pressed);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _keyMap.keyDown(pressed);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _keyMap.keyLeft(pressed);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _keyMap.keyRight(pressed);
    } else if (event.logicalKey == LogicalKeyboardKey.select) {
      _keyMap.keyEnter(pressed);
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      _keyMap.keyEnter(pressed);
    }

    return KeyEventResult.handled;
  }
}
