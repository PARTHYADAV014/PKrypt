import 'dart:math' as math;
import 'package:flutter/material.dart';

/// MagneticWrapper — when the pointer hovers within [activationRadius] dp
/// of the widget, it subtly tilts toward the cursor using a 3-D perspective
/// transform, then smoothly returns to flat when the pointer moves away.
class MagneticWrapper extends StatefulWidget {
  const MagneticWrapper({
    super.key,
    required this.child,
    this.maxTilt = 5,
    this.activationRadius = 150,
  });

  final Widget child;

  /// Maximum tilt in degrees (converted to radians internally).
  final double maxTilt;

  /// Distance (in logical pixels) from the widget centre at which
  /// the magnetic effect activates.
  final double activationRadius;

  @override
  State<MagneticWrapper> createState() => _MagneticWrapperState();
}

class _MagneticWrapperState extends State<MagneticWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _tiltXAnim;
  late Animation<double> _tiltYAnim;

  double _targetTiltX = 0;
  double _targetTiltY = 0;
  double _currentTiltX = 0;
  double _currentTiltY = 0;

  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    _tiltXAnim = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _tiltYAnim = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateTilt(double newX, double newY) {
    if (newX == _targetTiltX && newY == _targetTiltY) return;

    _tiltXAnim = Tween<double>(
      begin: _currentTiltX,
      end: newX,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _tiltYAnim = Tween<double>(
      begin: _currentTiltY,
      end: newY,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _targetTiltX = newX;
    _targetTiltY = newY;
    _controller.forward(from: 0);
  }

  void _processPointerPosition(Offset pointerGlobal) {
    final renderBox = _key.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final globalPos = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final center = Offset(
      globalPos.dx + size.width / 2,
      globalPos.dy + size.height / 2,
    );

    final dist = (pointerGlobal - center).distance;

    if (dist > widget.activationRadius) {
      _currentTiltX = _tiltXAnim.value;
      _currentTiltY = _tiltYAnim.value;
      _updateTilt(0, 0);
      return;
    }

    final dx = pointerGlobal.dx - center.dx;
    final dy = pointerGlobal.dy - center.dy;
    final maxRad = widget.maxTilt * math.pi / 180;

    final tiltY = (dx / widget.activationRadius) * maxRad;
    final tiltX = -(dy / widget.activationRadius) * maxRad;

    _currentTiltX = _tiltXAnim.value;
    _currentTiltY = _tiltYAnim.value;
    _updateTilt(tiltX, tiltY);
  }

  void _resetTilt() {
    _currentTiltX = _tiltXAnim.value;
    _currentTiltY = _tiltYAnim.value;
    _updateTilt(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (event) => _processPointerPosition(event.position),
      onPointerMove: (event) => _processPointerPosition(event.position),
      onPointerUp: (_) => _resetTilt(),
      child: MouseRegion(
        onExit: (_) => _resetTilt(),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final tx = _tiltXAnim.value;
            final ty = _tiltYAnim.value;
            final matrix = Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateX(tx)
              ..rotateY(ty);
            return Transform(
              transform: matrix,
              alignment: FractionalOffset.center,
              child: child,
            );
          },
          child: SizedBox(key: _key, child: widget.child),
        ),
      ),
    );
  }
}
