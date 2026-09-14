import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/ui/brand.dart';

void main() {
  // Цвет оформления приезжает текстом из настройки на сервере (#37184).
  group('цвет из настройки', () {
    test('неразбираемый текст оставляет цвет приложения', () {
      expect(Brand.parseColor('зелёный'), isNull);
      expect(Brand.fromJson(const {'primary': 'зелёный'}).primary,
          Brand.pulse.primary);
    });

    test('восьмизначный цвет не делает шапку прозрачной', () {
      final b = Brand.fromJson(const {'primary': '#0F6E5C00'});
      expect(b.primary.toARGB32() >> 24, 0xFF);
      expect(Brand.parseColor('#0F6E5C00')!.toARGB32() >> 24, 0xFF);
    });

    test('шестизначный — как есть, с решёткой и без', () {
      expect(Brand.parseColor('#0F6E5C')!.toARGB32(), 0xFF0F6E5C);
      expect(Brand.parseColor('0f6e5c')!.toARGB32(), 0xFF0F6E5C);
    });
  });
}
