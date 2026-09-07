import 'package:flutter/material.dart';

import '../../theme.dart';

/// A card with the standard chrome every metric view sits in.
class HomePanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const HomePanel({super.key, required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: padding,
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: child,
    );
  }
}

// ---------- tiles ----------
