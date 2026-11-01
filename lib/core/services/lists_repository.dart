import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';


/// Каталог списков правил `tachyon-lists`.
///
/// Файлы лежат в репозитории и разложены по форматам: приложению нужен `.trs`
/// — родной формат ядра. Каталог `catalog.json` содержит описание списков,
/// рекомендованное действие и контрольную сумму.
class ListsRepository {
  ListsRepository({required this.directory, HttpClient? client})
      : _client = client ?? HttpClient();

  static const repoRoot = 'https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main';
  static const catalogUrl = '$repoRoot/release/catalog.json';

  /// Приватный каталог приложения: сюда кладутся скачанные списки.
  final String directory;

  final HttpClient _client;

  /// Каталог списков, полученный с сервера.
  ListsCatalog? _catalog;

  /// Загруженный каталог.
  ListsCatalog? get catalog => _catalog;

  /// Каталог списков: описание, группа и рекомендованное действие.
  List<ListsEntry> get entries => _catalog?.entries ?? const [];

  /// Скачивает каталог. Ошибка не критична: приложение работает и без него.
  Future<ListsCatalog> refreshCatalog() async {
    final request = await _client
        .getUrl(Uri.parse(catalogUrl))
        .timeout(const Duration(seconds: 20));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('каталог недоступен: HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    _catalog = ListsCatalog.fromJson(jsonDecode(body) as Map<String, dynamic>);
    return _catalog!;
  }

  /// Путь, куда кладётся список с данным идентификатором.
  String pathFor(String id) => '$directory/lists/$id.trs';

  /// Скачивает список в формате `.trs`.
  ///
  /// Возвращает путь к файлу или текст ошибки.
  Future<String> download(String id) async {
    final listsDir = Directory('$directory/lists');
    if (!await listsDir.exists()) {
      await listsDir.create(recursive: true);
    }

    // Путь к файлу берём из каталога: он знает и формат, и контрольную
    // сумму. Без каталога предполагаем стандартное расположение.
    final entry = _catalog?.entryById(id);
    final relative = entry?.trsPath ?? 'release/tachyon/$id.trs';
    final url = '$repoRoot/$relative';
    final request =
        await _client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 60));
    final response = await request.close();
    if (response.statusCode != 200) {
      return 'список недоступен: HTTP ${response.statusCode}';
    }

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    if (bytes.length < 4) {
      return 'файл пустой';
    }
    // Формат `.trs` начинается с сигнатуры TSRS: это дешёвая проверка, что
    // скачалось именно то, а не HTML-страница с ошибкой.
    final signature = String.fromCharCodes(bytes.take(4));
    if (signature != 'TSRS') {
      return 'файл не похож на список правил';
    }

    // Контрольная сумма сверяется до записи: повреждённый или подменённый
    // список ядру не отдаём.
    final expected = entry?.sha256Trs ?? '';
    if (expected.isNotEmpty) {
      final actual = sha256.convert(bytes).toString();
      if (actual != expected.toLowerCase()) {
        return 'контрольная сумма не совпала: ожидали $expected, получили $actual';
      }
    }

    // Файл подменяется целиком: сначала рядом пишется временный, затем
    // он переименовывается. Прерванная загрузка не портит рабочую версию.
    final file = File(pathFor(id));
    final temporary = File('${file.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    return file.path;
  }

  /// Размер скачанного файла; 0, если его нет.
  Future<int> sizeOf(String id) async {
    final file = File(pathFor(id));
    if (!await file.exists()) return 0;
    return file.length();
  }

  /// Закрывает HTTP-клиент.
  void close() => _client.close(force: true);
}

/// Каталог списков с сервера.
class ListsCatalog {
  const ListsCatalog({
    required this.generatedAt,
    required this.repository,
    required this.entries,
  });

  final String generatedAt;
  final String repository;
  final List<ListsEntry> entries;

  /// Список по идентификатору.
  ListsEntry? entryById(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Списки, сгруппированные по назначению, в порядке каталога.
  Map<String, List<ListsEntry>> get grouped {
    final groups = <String, List<ListsEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.group, () => []).add(entry);
    }
    return groups;
  }

  static ListsCatalog fromJson(Map<String, dynamic> json) {
    final entries = ((json['lists'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ListsEntry.fromJson)
        .toList(growable: false);
    return ListsCatalog(
      generatedAt: (json['generated_at'] as String?) ?? '',
      repository: (json['repository'] as String?) ?? '',
      entries: entries,
    );
  }
}

/// Описание одного списка правил.
class ListsEntry {
  const ListsEntry({
    required this.id,
    required this.group,
    required this.kind,
    required this.title,
    required this.description,
    required this.recommendedAction,
    required this.domainCount,
    required this.subnetCount,
    this.trsPath = '',
    this.sha256Trs = '',
  });

  final String id;
  final String group;

  /// `domains`, `subnets` или `mixed`.
  final String kind;
  final String title;
  final String description;

  /// `proxy`, `direct` или `block`.
  final String recommendedAction;

  final int domainCount;
  final int subnetCount;

  /// Путь к файлу `.trs` относительно корня репозитория.
  final String trsPath;

  /// Ожидаемая SHA-256 файла `.trs`.
  final String sha256Trs;

  /// Человеческое название группы.
  String get groupLabel => switch (group) {
        'ai' => 'ИИ-сервисы',
        'block' => 'Блокировки',
        'direct' => 'Напрямую',
        'gaming' => 'Игры',
        'infra' => 'Инфраструктура',
        'internal' => 'Внутренние',
        'media' => 'Медиа',
        'other' => 'Прочее',
        'regional' => 'Регион',
        'social' => 'Соцсети',
        'tech' => 'Технологии',
        _ => group,
      };

  /// Рекомендованное действие переводится в действие конфигурации.
  String get routeAction => switch (recommendedAction) {
        'direct' => 'direct',
        'block' => 'block',
        _ => 'proxy',
      };

  static ListsEntry fromJson(Map<String, dynamic> json) {
    final counts = (json['counts'] as Map<String, dynamic>?) ?? const {};
    return ListsEntry(
      id: (json['id'] as String?) ?? '',
      group: (json['group'] as String?) ?? 'other',
      kind: (json['kind'] as String?) ?? 'domains',
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      recommendedAction: (json['recommended_action'] as String?) ?? 'proxy',
      domainCount: (counts['domain_suffix'] as num?)?.toInt() ?? 0,
      subnetCount: (counts['ipv4_cidr'] as num?)?.toInt() ?? 0,
      trsPath: ((json['files'] as Map<String, dynamic>?)?['trs'] as String?) ?? '',
      sha256Trs: (json['sha256_trs'] as String?) ?? '',
    );
  }
}
