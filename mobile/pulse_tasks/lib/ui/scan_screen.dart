import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen barcode/QR scanner for «Скан кода» fields. Pops with the decoded
/// value; pops with null when the user backs out or the camera cannot be used —
/// the caller keeps the plain text field as the manual fallback.
///
/// The camera permission is requested by the scanner on start, i.e. at the
/// first actual scan — not on app entry.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController();

  /// onDetect keeps firing while the route is popping — return the code once
  bool _returned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// With an explicit controller the widget does not pause/resume itself
  /// (useAppLifecycleState works only without one), so mirror the app
  /// lifecycle here: camera off in background, back on when we return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_controller.start());
      case AppLifecycleState.inactive:
        unawaited(_controller.stop());
      default:
        break;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_returned) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code == null || code.isEmpty) continue;
      _returned = true;
      // in gloves the eyes are on the shelf, not the screen — confirm by feel
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop(code);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Сканирование'),
        actions: [
          // the dim stockroom of the ticket is this screen's normal habitat
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }
              final on = state.torchState == TorchState.on;
              return IconButton(
                tooltip: 'Фонарик',
                icon: Icon(on ? Icons.flash_on : Icons.flash_off,
                    color: on ? Colors.amber : Colors.white),
                onPressed: () => unawaited(_controller.toggleTorch()),
              );
            },
          ),
        ],
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: _error,
        overlayBuilder: (context, constraints) => _overlay(),
      ),
    );
  }

  /// A guidance frame only — the whole preview is scanned, which is more
  /// forgiving than a scan window when the hands are gloved and the light poor.
  Widget _overlay() {
    return Stack(children: [
      Center(
        child: Container(
          width: 260,
          height: 180,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white70, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      Positioned(
        left: 16,
        right: 16,
        bottom: 24,
        child: Text('Наведите камеру на штрихкод или QR-код',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9), fontSize: 14)),
      ),
    ]);
  }

  /// The camera failed to start. The case that matters is a denied permission:
  /// say what happened and hand the user back to manual input instead of
  /// leaving a black screen.
  Widget _error(BuildContext context, MobileScannerException error) {
    final String message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Нет доступа к камере. Разрешите камеру в настройках телефона — '
            'или введите код вручную.',
      MobileScannerErrorCode.unsupported =>
        'Камера на этом устройстве недоступна.',
      _ => 'Не удалось запустить камеру.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                size: 48, color: Colors.white54),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.keyboard, size: 18),
              label: const Text('Ввести вручную'),
            ),
          ],
        ),
      ),
    );
  }
}
