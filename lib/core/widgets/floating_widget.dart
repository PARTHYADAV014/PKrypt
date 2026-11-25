import 'package:flutter/material.dart';

class FloatingWidget extends StatefulWidget {
  const FloatingWidget({
    super.key,
    required this.child,
    this.amplitude = 6,
    this.durationMs = 2500,
  });

  final Widget child;
  final double amplitude;
  final int durationMs;

  @override
  State<FloatingWidget> createState() => _FloatingWidgetState();
}

class _FloatingWidgetState extends State<FloatingWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.durationMs),
    )..repeat(reverse: true);

    _animation = Tween<double>(
      begin: -widget.amplitude / 2,
      end: widget.amplitude / 2,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _animation.value),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}