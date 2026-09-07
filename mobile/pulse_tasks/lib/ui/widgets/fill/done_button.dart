import 'package:flutter/material.dart';

/// Confirm button for a text box, shown only while it has focus. On a multi-line field
/// the keyboard offers a newline rather than a done key, so this is the only place the
/// user can say "finished" — and the hand does reach for something.
class DoneButton extends StatelessWidget {
  final FocusNode node;
  const DoneButton(this.node, {super.key});

  @override
  Widget build(BuildContext context) {
    if (!node.hasFocus) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: FilledButton.tonalIcon(
        onPressed: () => node.unfocus(), // the listener commits the value
        icon: const Icon(Icons.check, size: 18),
        label: const Text('Готово'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
      ),
    );
  }
}
