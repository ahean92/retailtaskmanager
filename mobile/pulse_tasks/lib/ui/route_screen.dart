import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/route_controller.dart';
import '../data/task_repository.dart';
import '../models/route.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String _day(DateTime d) => '${d.day} ${_months[d.month - 1]}';

bool _isToday(DateTime? d) {
  if (d == null) return true;
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

Future<void> openRouteTask(BuildContext context, String taskId) async {
  final repo = context.read<TaskRepository>();
  final route = context.read<RouteController>();
  if (repo.viewOf(taskId) == null) {
    final view = await repo.loadTaskById(taskId);
    if (!context.mounted) return;
    if (view == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Задача не открывается: нет связи или она уже недоступна'),
        duration: Duration(seconds: 3),
      ));
      return;
    }
  }
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => TaskDetailScreen(taskId: taskId),
  ));
  await route.refresh();
}

class RouteScreen extends StatelessWidget {
  const RouteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final route = context.watch<RouteController>();
    final online = context.watch<TaskRepository>().online;
    final plan = route.plan;
    final canChange = online && !route.busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Мой маршрут')),
      body: Column(
        children: [
          if (!online)
            const DsBanner(
              Icons.cloud_off,
              '${RouteController.needsNetwork}: показан последний маршрут, '
              'собрать его и поменять порядок сейчас нельзя',
              key: Key('route-offline'),
            ),
          if (route.error != null)
            DsBanner(
              Icons.error_outline,
              route.error!,
              key: const Key('route-error'),
              tone: DsTone.danger,
              actionLabel: 'Скрыть',
              onAction: route.clearError,
            ),
          if (route.busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: RefreshIndicator(
              onRefresh: route.refresh,
              child: plan == null
                  ? const _Empty()
                  : _Stops(plan: plan, canChange: canChange),
            ),
          ),
        ],
      ),
      bottomNavigationBar: DsBottomActionBar(
        key: const Key('route-build'),
        primaryLabel: plan == null ? 'Собрать маршрут' : 'Дополнить',
        primaryIcon: Icons.alt_route,
        onPrimary: canChange ? route.build : null,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
        children: [
          Icon(Icons.alt_route, size: 48, color: Wms.muted),
          const SizedBox(height: 12),
          const Text(
            'Маршрута на сегодня нет',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Соберите его: в маршрут попадут объекты ваших открытых задач, '
            'ближайший к вам — первым',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Wms.muted),
          ),
        ],
      );
}

class _Stops extends StatelessWidget {
  final RoutePlan plan;
  final bool canChange;

  const _Stops({required this.plan, required this.canChange});

  @override
  Widget build(BuildContext context) {
    final route = context.read<RouteController>();
    final movable = canChange && !plan.closed && plan.stops.length > 1;
    return ReorderableListView.builder(
      key: const Key('route-stops'),
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 24),
      header: _Header(plan: plan),
      itemCount: plan.stops.length,
      onReorderItem: (from, to) {
        if (movable) route.reorder(from, to);
      },
      itemBuilder: (context, i) {
        final s = plan.stops[i];
        return _StopTile(
          key: ValueKey('route-stop-${s.objectId}'),
          stop: s,
          number: i + 1,
          index: i,
          movable: movable,
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final RoutePlan plan;

  const _Header({required this.plan});

  @override
  Widget build(BuildContext context) {
    final tone = switch (plan.status) {
      'closed' => DsTone.done,
      'active' => DsTone.brandSoft,
      _ => DsTone.neutral,
    };
    final date = plan.date;
    return DsCard(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Пройдено ${plan.passed} из ${plan.total}',
                key: const Key('route-progress'),
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            if (plan.statusName.isNotEmpty)
              DsChip(plan.statusName, tone: tone, compact: true),
          ],
        ),
        if (plan.total > 0) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: plan.passed / plan.total,
              minHeight: 6,
              backgroundColor: Wms.chipBg,
              color: plan.closed ? Wms.done : Wms.primary,
            ),
          ),
        ],
        if (date != null && !_isToday(date)) ...[
          const SizedBox(height: 8),
          Text('Маршрут на ${_day(date)}',
              style: TextStyle(fontSize: 13, color: Wms.muted)),
        ],
      ],
    );
  }
}

class _StopTile extends StatelessWidget {
  final RouteStop stop;
  final int number;
  final int index;
  final bool movable;

  const _StopTile({
    super.key,
    required this.stop,
    required this.number,
    required this.index,
    required this.movable,
  });

  @override
  Widget build(BuildContext context) {
    final left = stop.tasks.where((t) => !t.done).length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RouteStopScreen(objectId: stop.objectId))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: stop.passed ? Wms.doneTint : Wms.chipBg,
                foregroundColor: stop.passed ? Wms.done : Wms.text2,
                child: stop.passed
                    ? const Icon(Icons.check, size: 18)
                    : Text('$number',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(stop.name,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: stop.passed ? Wms.muted : Wms.text)),
                    if (stop.address != null)
                      Text(stop.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: Wms.muted)),
                    const SizedBox(height: 4),
                    Text(
                      stop.passed
                          ? 'Пройдено'
                          : 'Осталось задач: $left из ${stop.tasks.length}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: stop.passed ? Wms.done : Wms.text2),
                    ),
                  ],
                ),
              ),
              if (movable)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle,
                        key: Key('route-drag-${stop.objectId}'),
                        color: Wms.muted),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.chevron_right, color: Wms.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class RouteStopScreen extends StatelessWidget {
  final String objectId;

  const RouteStopScreen({super.key, required this.objectId});

  @override
  Widget build(BuildContext context) {
    final route = context.watch<RouteController>();
    RouteStop? stop;
    for (final s in route.plan?.stops ?? const <RouteStop>[]) {
      if (s.objectId == objectId) stop = s;
    }
    return Scaffold(
      appBar: AppBar(title: Text(stop?.name ?? 'Остановка')),
      body: stop == null
          ? const Center(child: Text('Остановки больше нет в маршруте'))
          : RefreshIndicator(
              onRefresh: route.refresh,
              child: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 24),
                children: [
                  if (stop.address != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(stop.address!,
                          style: TextStyle(fontSize: 14, color: Wms.muted)),
                    ),
                  if (stop.passed)
                    const DsBanner(Icons.check_circle_outline,
                        'Остановка пройдена: все задачи выполнены',
                        tone: DsTone.done),
                  for (final t in stop.tasks)
                    ListTile(
                      key: Key('route-task-${t.id}'),
                      leading: Icon(
                        t.done
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: t.done ? Wms.done : Wms.muted,
                      ),
                      title: Text(t.name),
                      subtitle: Text([
                        t.id,
                        if (t.deadline != null) 'срок ${_day(t.deadline!)}',
                        if (t.done) 'выполнена',
                      ].join(' · ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openRouteTask(context, t.id),
                    ),
                ],
              ),
            ),
    );
  }
}
