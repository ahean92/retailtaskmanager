import 'package:flutter/material.dart';

import '../../models/place.dart';
import '../../models/task_view.dart';
import '../theme.dart';

/// Почему список пуст — решение отдельно от экрана: «Задач нет» — только один из
/// ответов, и схлопывать в него остальные нельзя: человек, который стоит в двенадцати
/// километрах от ближайшего объекта, и человек, у которого на объекте всё сделано,
/// должны сделать разное.
/// Почему список пуст. «Задач нет» — только один из ответов, и схлопывать в него
/// остальные нельзя: человек, который стоит в двенадцати километрах от ближайшего
/// объекта, и человек, у которого на объекте всё сделано, должны сделать разное.
EmptyListState emptyListState({
required bool loading,
required bool locating,
required bool filtered,
required bool geoRequired,
required Place place,
required TaskFilter filter,
String? objectName,
}) {
if (loading || locating) {
    return const EmptyListState(Icons.hourglass_empty, 'Загрузка…', '');
  }
  // пусто из-за разбора — говорить про разбор (#36915): совет «нажмите „Обновить
  // местоположение"» человеку, который опечатался в поиске, — ложный след
if (filtered) {
    return const EmptyListState(
      Icons.search_off,
      'Ничего не нашлось',
      'Измените запрос или нажмите «Показать все».',
    );
  }
  // Список больше не режется по месту (#36837), поэтому его пустота для
  // гео-аккаунта значит «задач нет вообще» — а не «не там стою». Состояние места
  // всё же различается: оно говорит, что делать дальше, — и объясняет, почему
  // строки, которые появятся, будут только для просмотра.
if (geoRequired) {
    switch (place.state) {
      case PlaceState.unknown:
        return const EmptyListState(
          Icons.location_searching,
          'Задач нет',
          'Потяните вниз, чтобы обновить. И нажмите «Обновить местоположение» — '
              'без него приложение не знает, какие задачи можно выполнять на '
              'месте.',
          relocate: true,
        );
      case PlaceState.noObjects:
        return const EmptyListState(
          Icons.wrong_location_outlined,
          'Задач нет',
          'Определить, где вы, не по чему: ни одному объекту проверки не '
              'проставлены координаты. Это чинится не на телефоне — сообщите '
              'администратору.',
          relocate: true,
        );
      case PlaceState.far:
        final nearest = place.nearest;
        return EmptyListState(
          Icons.near_me_disabled_outlined,
          'Задач нет',
          'Потяните вниз, чтобы обновить. Вы не на объекте: ближайший — '
              '«${nearest?.name ?? 'объект'}», до него '
              '${nearest?.distanceText ?? 'далеко'}.',
          relocate: true,
        );
      case PlaceState.located:
        // the shop the list is narrowed to, when it was opened from a tile — the
        // person asked about that one, and an answer about the full list would
        // name the wrong scope
        final narrowed = objectName;
        return EmptyListState(
          Icons.task_alt,
          filter == TaskFilter.all
              ? (narrowed == null
                  ? 'Задач нет'
                  : 'На объекте «$narrowed» задач нет')
              : 'Под фильтр «${filter.title}» ничего не попало',
          'Потяните вниз, чтобы обновить.',
        );
    }
  }
  // Список, суженный до магазина, пустеет по-магазинному: «задач нет» человеку, у
  // которого плитка только что показала «6 всего», обязано говорить, ГДЕ их нет.
  return EmptyListState(
    Icons.task_alt,
    filter == TaskFilter.all
        ? (objectName == null
            ? 'Задач нет'
            : 'На объекте «$objectName» задач нет')
        : 'Под фильтр «${filter.title}» ничего не попало',
    filter == TaskFilter.all ? 'Потяните вниз, чтобы обновить.' : '',
  );
}

/// Почему список пуст, одним экраном: значок, строка и что с этим делать.
class EmptyListState {
  final IconData icon;
  final String title;
  final String explanation;

  /// Показывать ли кнопку «Обновить местоположение» — она помогает не всегда, и там,
  /// где не помогает, её нет.
  final bool relocate;

  const EmptyListState(this.icon, this.title, this.explanation,
      {this.relocate = false});
}

class EmptyListView extends StatelessWidget {
  final EmptyListState state;
  final Future<void> Function() onRelocate;
  const EmptyListView(
      {super.key, required this.state, required this.onRelocate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Icon(state.icon, size: 48, color: Wms.muted),
          const SizedBox(height: 16),
          Text(
            state.title,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: Wms.text),
          ),
          if (state.explanation.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              state.explanation,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.4, color: Wms.muted),
            ),
          ],
          if (state.relocate) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRelocate,
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('Обновить местоположение'),
            ),
          ],
        ],
      ),
    );
  }
}
