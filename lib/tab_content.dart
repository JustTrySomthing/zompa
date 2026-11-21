import 'package:flutter/material.dart';

/// A short fade that keeps the tab content and its layout in place.
class TabContent extends StatefulWidget {
  const TabContent({super.key, required this.selection, required this.child});

  final Object selection;
  final Widget child;

  @override
  State<TabContent> createState() => _TabContentState();
}

class _TabContentState extends State<TabContent>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    lowerBound: .84,
    value: 1,
    duration: const Duration(milliseconds: 140),
  );

  @override
  void didUpdateWidget(TabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selection != oldWidget.selection) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _fade.value = 1;
      } else {
        _fade.forward(from: _fade.lowerBound);
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _fade, child: widget.child);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }
}
