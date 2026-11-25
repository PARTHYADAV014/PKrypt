import 'package:flutter/material.dart';

/// RippleTap — wraps any child and shows a custom expanding ripple
/// from the exact tap position when tapped.
class RippleTap extends StatefulWidget {
  const RippleTap({
    super.key,
    required this.child,
    this.onTap,
    this.rippleColor = Colors.white,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color rippleColor;

  @override
  State<RippleTap> createState() => _RippleTapState();
}

class _RippleTapState extends State<RippleTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _sizeAnimation;
  late Animation<double> _opacityAnimation;

  Offset _tapPosition = Offset.zero;
  Size _childSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _sizeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _opacityAnimation = Tween<double>(begin: 0.2, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _tapPosition = details.localPosition;
    _childSize = context.size ?? Size.zero;
    _controller.forward(from: 0);
  }

  void _onTap() {
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _onTapDown,
      onTap: _onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  if (!_controller.isAnimating && _controller.value == 0) {
                    return const SizedBox.shrink();
                  }
                  final maxRadius = _childSize.longestSide * 1.5;
                  final radius = _sizeAnimation.value * maxRadius;
                  return CustomPaint(
                    painter: _RipplePainter(
                      position: _tapPosition,
                      radius: radius,
                      color: widget.rippleColor
                          .withValues(alpha: _opacityAnimation.value),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.position,
    required this.radius,
    required this.color,
  });

  final Offset position;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius, paint);
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}
