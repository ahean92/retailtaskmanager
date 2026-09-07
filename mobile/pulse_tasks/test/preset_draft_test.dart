import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/quick_create.dart';

/// Правила черновика задачи по пресету — без экрана: кому уйдёт задача при каждой
/// политике назначения и какой первой недостающей вещью объясняется выключенная
/// кнопка «Создать».

const _shop = (id: 'o1', name: 'Магазин №1', address: null);
const _ivanov = Performer(id: 'p1', name: 'Иванов', roles: [
  PerformerRole(objectId: 'o1', roleId: 'cleaner'),
]);
const _petrov = Performer(id: 'p2', name: 'Петров', roles: [
  PerformerRole(objectId: 'o1', roleId: 'cleaner'),
  PerformerRole(objectId: 'o2', roleId: 'cleaner'),
]);
const _data = QuickCreateData(performers: [_ivanov, _petrov]);

QuickPreset _preset({String assign = 'self', String? role, bool requireComment = false}) =>
    QuickPreset(
        code: 'errand',
        title: 'Поручение',
        typeId: 'issue',
        assign: assign,
        roleId: role,
        requireComment: requireComment);

void main() {
  test('чего не хватает — по порядку: объект, название, описание', () {
    expect(const PresetDraft(preset: QuickPreset(code: 'x', title: 'x')).missing(_data),
        contains('без типа задачи'));
    expect(PresetDraft(preset: _preset()).missing(_data), 'Не выбран объект');
    expect(PresetDraft(preset: _preset(), object: _shop).missing(_data),
        'Укажите название');
    expect(
        PresetDraft(preset: _preset(requireComment: true), object: _shop, name: 'Убрать')
            .missing(_data),
        'Опишите, что нужно сделать');
    expect(PresetDraft(preset: _preset(), object: _shop, name: 'Убрать').missing(_data),
        isNull);
  });

  test('self — исполнителя не шлём: сервер назначит на создателя', () {
    final d = PresetDraft(preset: _preset(), object: _shop, name: 'Убрать');
    expect(d.assignee(_data), isNull);
    expect(d.missing(_data), isNull);
  });

  test('pick — только выбранный из списка, без выбора создавать нельзя', () {
    final empty = PresetDraft(preset: _preset(assign: 'pick'), object: _shop, name: 'Убрать');
    expect(empty.assignee(_data), isNull);
    expect(empty.missing(_data), 'Выберите исполнителя');
    final picked = PresetDraft(
        preset: _preset(assign: 'pick'), object: _shop, name: 'Убрать', picked: _petrov);
    expect(picked.assignee(_data)?.id, 'p2');
    expect(picked.missing(_data), isNull);
  });

  test('byRole — единственный с ролью на объекте назначается сам, из нескольких выбирают', () {
    final one = PresetDraft(
        preset: _preset(assign: 'byRole', role: 'cleaner'),
        object: (id: 'o2', name: 'Магазин №2', address: null),
        name: 'Убрать');
    expect(one.assignee(_data)?.id, 'p2', reason: 'на o2 роль только у Петрова');
    final two = PresetDraft(
        preset: _preset(assign: 'byRole', role: 'cleaner'), object: _shop, name: 'Убрать');
    expect(two.assignee(_data), isNull, reason: 'на o1 двое — нужен выбор');
    expect(two.missing(_data), 'На этом объекте нет исполнителя с нужной ролью');
    final chosen = PresetDraft(
        preset: _preset(assign: 'byRole', role: 'cleaner'),
        object: _shop,
        name: 'Убрать',
        picked: _ivanov);
    expect(chosen.assignee(_data)?.id, 'p1');
    // выбранный не с этой ролью на этом объекте не считается
    final stale = PresetDraft(
        preset: _preset(assign: 'byRole', role: 'cleaner'),
        object: (id: 'o2', name: 'Магазин №2', address: null),
        name: 'Убрать',
        picked: _ivanov);
    expect(stale.assignee(_data)?.id, 'p2', reason: 'единственный кандидат важнее чужого выбора');
  });

  test('неизвестная политика назначения — создавать нельзя', () {
    final d = PresetDraft(preset: _preset(assign: 'lottery'), object: _shop, name: 'Убрать');
    expect(d.missing(_data), contains('Неизвестный способ назначения'));
  });
}
