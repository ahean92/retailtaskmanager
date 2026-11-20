import 'package:flutter/material.dart';

import '../ds.dart';

/// A card with the standard chrome every metric view sits in — [DsCardBox] with the
/// home screen's side margins.
class HomePanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const HomePanel({super.key, required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    return DsCardBox(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: padding,
      child: child,
    );
  }
}

// ---------- tiles ----------
