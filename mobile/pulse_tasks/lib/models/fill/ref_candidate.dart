// Кандидат справочника для поля-ссылки и строки таблицы (apiRowSubjects) и порядок их
// выдачи без связи. Отдельно от поля: кандидатов держат свой кэш бланка и шторки
// выбора, а полю они нужны только как будущий ответ.

/// Кандидат справочника для поля-ссылки (#36841, из apiRowSubjects). [available] —
/// предмет доступен на объекте задачи (сотрудник этого магазина); сервер отдаёт и
/// недоступных только по явному запросу «весь справочник».
///
/// [id] — это и есть код предмета; [barcodes] — его штрихкоды (#37192, у товара их
/// несколько: штука, упаковка). Оба едут в кэш кандидатов бланка, поэтому скан и ввод
/// кода работают и без связи. [exact] — сервер сказал, что кандидат точно совпал с
/// запросом по коду или штрихкоду; офлайн то же решает [matchesCode].
///
/// [available] == null — сервер не посчитал доступность: предзагрузка бандла ходит
/// без неё (#37637), бейдж «нет в остатках» показываем только при явном false
/// (кандидат из поиска apiRowSubjects).
class RefCandidate {
  final String id;
  final String name;
  final bool? available;
  final List<String> barcodes;
  final bool exact;

  const RefCandidate(
      {required this.id,
      required this.name,
      this.available,
      this.barcodes = const [],
      this.exact = false});

  factory RefCandidate.fromJson(Map<String, dynamic> j) => RefCandidate(
        id: j['subjectId']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        available: j['available'] == null ? null : j['available'] == true,
        barcodes: _splitBarcodes(j['barcodes']),
        exact: j['exact'] == true,
      );

  Map<String, dynamic> toJson() => {
        'subjectId': id,
        'name': name,
        'available': available,
        if (barcodes.isNotEmpty) 'barcodes': barcodes.join(','),
      };

  /// Точное совпадение с набранным или отсканированным [code] — по коду предмета или
  /// по любому его штрихкоду, без учёта регистра и краевых пробелов. Та же проверка,
  /// что exactSubject на сервере (RowSubjectsApi.lsf); [exact] сервера — сверх неё.
  bool matchesCode(String code) {
    final q = code.trim().toLowerCase();
    if (q.isEmpty) return false;
    if (exact) return true;
    if (id.toLowerCase() == q) return true;
    return barcodes.any((b) => b.toLowerCase() == q);
  }

  /// Подстрочное совпадение с текстом поиска — по названию и по коду, как
  /// matchSubject на сервере; по нему фильтруется кэш без связи.
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        id.toLowerCase().contains(q) ||
        matchesCode(q);
  }

  /// Штрихкоды приходят строкой через запятую (barcodes(RefValue) на сервере);
  /// в кэше лежат так же.
  static List<String> _splitBarcodes(Object? raw) {
    if (raw is List) {
      return [
        for (final b in raw)
          if (b.toString().trim().isNotEmpty) b.toString().trim()
      ];
    }
    final s = raw?.toString() ?? '';
    return [
      for (final b in s.split(','))
        if (b.trim().isNotEmpty) b.trim()
    ];
  }
}

/// Порядок выдачи кандидатов без связи — тот же, что у сервера (subjectRank в
/// RowSubjectsApi.lsf): точные совпадения с [query] по коду или штрихкоду первыми,
/// остальные в прежнем порядке.
List<RefCandidate> rankSubjects(List<RefCandidate> items, String query) {
  if (query.trim().isEmpty) return items;
  return [
    for (final c in items)
      if (c.matchesCode(query)) c,
    for (final c in items)
      if (!c.matchesCode(query)) c,
  ];
}
