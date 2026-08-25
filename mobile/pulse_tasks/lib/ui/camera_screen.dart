import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../data/task_file_controller.dart';
import 'theme.dart';

/// Серийная съёмка (#36914): камера не закрывается после кадра.
///
/// Системный выбиратель (image_picker) на каждый снимок открывается и закрывается
/// заново — а в поле кадров нужно три подряд: витрина целиком, ценник крупно, срок
/// годности. Поэтому здесь своё превью: затвор снимает и остаётся на месте, снятое
/// копится лентой внизу, лишний кадр убирается крестиком тут же — и файл удаляется
/// сразу, не дожидаясь возврата на предыдущий экран.
///
/// Возвращает пути снятых кадров (пустой список — не снято ничего). Кадры лежат во
/// временном каталоге приложения: тот, кто их принял, копирует их себе
/// (TaskFilesController.storePhoto), а брошенное подчистит система.
///
/// Разрешение — [ResolutionPreset.veryHigh] (1080p): ценник должен читаться, а
/// снимок при этом остаётся в пределах мегабайта, поэтому отдельного сжатия после
/// съёмки нет. Если камера такого не умеет, ниже есть откат на [ResolutionPreset.high].
class CameraScreen extends StatefulWidget {
  /// Сколько кадров ещё можно снять: предел «десять на задачу» считается вместе с уже
  /// снятыми и уже уехавшими, поэтому его знает вызывающий, а не этот экран.
  final int limit;

  const CameraScreen({super.key, required this.limit});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;

  /// Снятое в этом заходе — пути во временном каталоге, в порядке съёмки.
  final List<String> _shots = [];

  /// Затвор занят: без этого двойной тап по кнопке роняет плагин
  /// («Previous capture has not returned yet»).
  bool _busy = false;

  /// Камеры нет, разрешение не дали, инициализация упала — текст вместо превью.
  String? _error;

  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Приложение ушло в фон — камеру надо отпустить (иначе система отберёт её сама и
  /// вернувшийся экран покажет чёрный прямоугольник), а по возвращении поднять заново.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _start();
    }
  }

  Future<void> _start() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('noCamera', 'На устройстве нет камеры');
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      CameraController controller =
          CameraController(back, ResolutionPreset.veryHigh, enableAudio: false);
      try {
        await controller.initialize();
      } on CameraException {
        // 1080p умеют не все — на таком аппарате лучше снимать хуже, чем не снимать
        await controller.dispose();
        controller =
            CameraController(back, ResolutionPreset.high, enableAudio: false);
        await controller.initialize();
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = e.code == 'CameraAccessDenied'
            ? 'Нет доступа к камере — разрешите его в настройках телефона'
            : 'Камера недоступна: ${e.description ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Камера недоступна: $e';
      });
    }
  }

  int get _left => widget.limit - _shots.length;

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _busy) return;
    if (_left <= 0) return;
    setState(() => _busy = true);
    try {
      // Затвор с таймаутом: takePicture может не вернуться вовсе — на эмуляторе это
      // видно постоянно (виртуальная камера роняет поток кадров: «returnBuffer:
      // timestamp is not increasing»), на живом аппарате так выглядит камера,
      // которую отобрала система. Без предела кнопка осталась бы с крутилкой
      // навсегда, и человек в зале решил бы, что приложение зависло.
      final file = await c.takePicture().timeout(const Duration(seconds: 20));
      final size = await File(file.path).length();
      if (size > TaskFilesController.maxPhotoBytes) {
        await _delete(file.path);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(TaskFilesController.tooLargeMessage(size))));
        return;
      }
      if (!mounted) return;
      setState(() => _shots.add(file.path));
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Снимок не получился: ${e.description ?? e.code}')));
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Камера не ответила — попробуйте снять ещё раз')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// Убрать кадр прямо здесь: файл удаляется сразу — снимок, от которого отказались,
  /// не должен ни уехать, ни занимать место.
  Future<void> _remove(String path) async {
    setState(() => _shots.remove(path));
    await _delete(path);
  }

  @override
  Widget build(BuildContext context) {
    // «назад» — это «готово с тем, что снято»: кадры уже сделаны сознательно, и
    // терять их из-за системного жеста нельзя. Отказаться от кадра можно крестиком.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_shots);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(_shots.isEmpty
              ? 'Съёмка'
              : 'Снято ${_shots.length} — осталось $_left'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(_shots),
              child: const Text('Готово',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _preview()),
            _strip(),
            _shutter(),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined,
                  color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _start,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }
    final c = _controller;
    if (_initializing || c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return Center(child: CameraPreview(c));
  }

  /// Лента снятого — чтобы было видно, что уже в руках, и можно было отказаться от
  /// неудачного кадра, не выходя из съёмки.
  Widget _strip() {
    if (_shots.isEmpty) return const SizedBox(height: 8);
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _shots.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final path = _shots[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(path),
                    width: 60, height: 60, fit: BoxFit.cover),
              ),
              Positioned(
                right: 0,
                top: 0,
                child: InkWell(
                  onTap: () => _remove(path),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _shutter() {
    final full = _left <= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          if (full)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                TaskFilesController.limitMessage(0),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          GestureDetector(
            onTap: full || _error != null ? null : _shoot,
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: full ? Colors.white24 : Colors.white,
                border: Border.all(color: Wms.primary, width: 3),
              ),
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.photo_camera,
                      color: full ? Colors.white54 : Wms.primary),
            ),
          ),
        ],
      ),
    );
  }
}
