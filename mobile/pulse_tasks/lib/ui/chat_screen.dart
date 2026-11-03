import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/chat_controller.dart';
import '../data/task_repository.dart';
import '../models/chat.dart';
import 'theme.dart';
import 'widgets/task_photo.dart';

/// Переписка одного чата (#37369): пузыри как в ленте задачи — свои справа, чужие
/// слева, в группе — с именем автора; между днями разделители. ✓ — отправлено,
/// ✓✓ — доставлено, ✓✓ цветом — прочитано. Ответить — долгим нажатием; фото —
/// миниатюрой и во весь экран; в чате «только чтение» вместо поля ввода — строка
/// «Только чтение»; в меню — «Выключить звук»/«Включить звук». Открытая переписка опрашивает сервер
/// каждые 10 секунд и гасит непрочитанное при показе; сообщение пишется и без
/// связи — пузырём «не отправлено» (ChatConversationController).
class ChatScreen extends StatefulWidget {
  final int? chatId;
  final int? userId;

  const ChatScreen({super.key, this.chatId, this.userId})
      : assert(chatId != null || userId != null);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  /// null — базы нет (сессия умерла под открытой перепиской): экран рисует пустое
  /// место, а не роняет то, чему осталось жить один кадр.
  ChatConversationController? _controller;
  ChatConversationController get _c => _controller!;
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Снимок, выбранный к следующему сообщению, и сообщение, на которое отвечают,
  /// — показаны над полем ввода, пока не отправлены или не убраны.
  String? _photo;
  int? _replyTo;
  String? _replyAuthor;
  String? _replyText;
  bool _sending = false;

  /// Сколько серверных сообщений было на экране при последней отметке прочтения —
  /// отметка ставится, только когда их стало больше, а не на каждую перерисовку.
  int _markedCount = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db == null) return;
    final c = ChatConversationController(
        db: db, api: repo.api, chatId: widget.chatId, userId: widget.userId);
    _controller = c;
    // список и бейдж перечитываются очередями: отправка, дожим, отметка
    c.onQueueChanged = () {
      if (mounted) context.read<ChatListController>().loadLocal();
    };
    c.addListener(_onChanged);
    _scroll.addListener(_onScroll);
    c.load();
    // приложение на экране (resumed) — опрос идёт; о чьём-то жизненном цикле
    // платформа не сказала (тесты) — опрос не заводится вовсе
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      c.startPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onChanged);
    _scroll.removeListener(_onScroll);
    _controller?.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Опрос живёт, пока переписка на экране: сворачивать приложение — не значит
  /// читать переписку, и опрос в фоне только жёг бы сеть. Приложение, о жизненном
  /// цикле которого платформа ещё не сказала (тесты), тоже не опрашивает.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller?.startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller?.stopPolling();
    }
  }

  void _onChanged() {
    if (!mounted) return;
    final shown = _c.items.where((m) => !m.pending).length;
    setState(() {});
    if (_c.loading || shown == _markedCount) return;
    _markedCount = shown;
    _c.markRead();
    _jumpToBottom();
  }

  /// Доскроллил до верха — подвезти историю; внизу ничего не ждём.
  void _onScroll() {
    if (_scroll.position.pixels <= 200 &&
        !_scroll.position.outOfRange) {
      unawaited(_controller?.loadOlder() ?? Future.value());
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return const SizedBox.shrink();
    final chat = _c.chat;
    return Scaffold(
      appBar: AppBar(
        // заголовок — имя переписки; меняется, когда локальный диалог стал серверным
        title: Text(
          _c.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (_c.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          // звук чата — у серверного чата; локальный диалог заглушить нельзя,
          // пока сервер его не создал. Действие всегда глаголом: что произойдёт
          // по тапу — «Выключить звук» у звучащего, «Включить звук» у тихого
          if (_c.chatId != null)
            PopupMenuButton<String>(
              onSelected: (_) => _toggleMute(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'mute',
                  child: Row(
                    children: [
                      Icon(
                        (chat?.muted ?? false)
                            ? Icons.notifications_outlined
                            : Icons.notifications_off_outlined,
                        size: 20,
                        color: Wms.primary,
                      ),
                      const SizedBox(width: 12),
                      Text((chat?.muted ?? false)
                          ? 'Включить звук'
                          : 'Выключить звук'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_c.online)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 14, color: Wms.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Офлайн — показана сохранённая переписка; новое уйдёт при '
                      'связи',
                      style: TextStyle(fontSize: 12, color: Wms.muted),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _feed(context)),
          if (_c.error != null && _c.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_c.error!,
                  style: TextStyle(fontSize: 13, color: Wms.muted)),
            ),
          _composerArea(context),
        ],
      ),
    );
  }

  Widget _feed(BuildContext context) {
    if (_c.loading && _c.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // «Какое сегодня» — серверное today строки чата (#37125); нет строки — дата
    // устройства, разделители без неё честнее, чем никакие
    final today = _c.chat?.serverToday ?? DateTime.now();
    if (_c.items.isEmpty) {
      return Center(
        child: Text(_c.error ?? 'Сообщений пока нет — напишите первым',
            style: TextStyle(fontSize: 13, color: Wms.muted)),
      );
    }
    // Цитата ответа для своего неотправленного: автор и текст берутся из
    // исходного сообщения на экране — очередь хранит только id ответа
    final byId = {
      for (final m in _c.items)
        if (!m.pending && m.id > 0) m.id: m,
    };
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        for (var i = 0; i < _c.items.length; i++) ...[
          if (i == 0 || _dayOf(_c.items[i - 1]) != _dayOf(_c.items[i]))
            _DaySeparator(
                label: _dayLabel(_c.items[i].when, today)),
          Builder(builder: (context) {
            final m = _c.items[i];
            final quoteSource = m.pending ? byId[m.replyId] : null;
            return _Bubble(
              message: m,
              controller: _c,
              // имя автора — в группе и ролевом чате; диалог и так знает обоих
              showAuthor:
                  !m.mine && (_c.chat?.kind ?? ChatKind.dialog) != ChatKind.dialog,
              replyQuoteAuthor: m.pending
                  ? (quoteSource == null
                      ? null
                      : (quoteSource.mine ? 'Вы' : quoteSource.author))
                  : m.replyAuthor,
              replyQuoteText:
                  m.pending ? quoteSource?.text : m.replyText,
              onReply: _canReplyTo(m) ? () => _startReply(m) : null,
              onDiscard: m.pending && m.sendError != null && m.clientId != null
                  ? () => _discard(m.clientId!)
                  : null,
            );
          }),
        ],
        if (_c.loadingOlder)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          ),
      ],
    );
  }

  /// Ответить можно на серверное сообщение (его id уезжает в replyTo); свой ответ
  /// на неотправленное, которого на сервере нет, сервер отверг бы.
  bool _canReplyTo(ChatMessage m) =>
      _canInput && !m.pending && m.id > 0;

  bool get _canInput => !_readonly;

  bool get _readonly => _c.chat?.readonly ?? false;

  DateTime? _dayOf(ChatMessage m) {
    final w = m.when;
    return w == null ? null : DateTime(w.year, w.month, w.day);
  }

  static String _dayLabel(DateTime? t, DateTime today) {
    if (t == null) return '';
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
    ];
    final d = DateTime.utc(t.year, t.month, t.day);
    final now = DateTime.utc(today.year, today.month, today.day);
    final diff = now.difference(d).inDays;
    if (diff <= 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    return '${t.day} ${months[t.month - 1]}'
        '${today.year != t.year ? ' ${t.year}' : ''}';
  }

  // --- поле ввода или «только чтение» ---

  Widget _composerArea(BuildContext context) {
    if (_controller == null) return const SizedBox.shrink();
    if (_readonly) {
      // что решает сервер, то и показано: ролевой чат и «только чтение» (#37369)
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Wms.card,
          border: Border(top: BorderSide(color: Wms.line)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 16, color: Wms.muted),
            const SizedBox(width: 8),
            Text('Только чтение',
                style: TextStyle(fontSize: 14, color: Wms.muted)),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Wms.card,
        border: Border(top: BorderSide(color: Wms.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_replyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(Icons.reply, size: 16, color: Wms.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${_replyAuthor ?? ''}: ${_replyText ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 12, color: Wms.muted),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Отменить ответ',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _sending
                            ? null
                            : () => setState(() {
                                  _replyTo = null;
                                  _replyAuthor = null;
                                  _replyText = null;
                                }),
                      ),
                    ],
                  ),
                ),
              if (_photo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(_photo!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => brokenPhoto(56)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Фото уйдёт вместе с сообщением',
                            style:
                                TextStyle(fontSize: 12, color: Wms.muted)),
                      ),
                      IconButton(
                        tooltip: 'Убрать фото',
                        icon: const Icon(Icons.close),
                        onPressed: _sending
                            ? null
                            : () => setState(() => _photo = null),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Фото',
                    icon:
                        Icon(Icons.add_a_photo_outlined, color: Wms.primary),
                    onPressed: _sending ? null : _pickPhoto,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Написать…',
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: 'Отправить',
                    icon: const Icon(Icons.send, size: 20),
                    onPressed: _canSend ? _send : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _canSend =>
      !_sending && (_text.text.trim().isNotEmpty || _photo != null);

  /// Камера или галерея — тот же выбор, что у ленты задачи: снимок «с места»
  /// делают камерой, а «вот что было утром» берут из галереи.
  Future<void> _pickPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Камера'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Галерея'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      final file = await ImagePicker().pickImage(
          source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (file == null || !mounted) return;
      setState(() => _photo = file.path);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Не удалось получить фото: $e')));
    }
  }

  void _startReply(ChatMessage m) {
    HapticFeedback.mediumImpact();
    setState(() {
      _replyTo = m.id;
      _replyAuthor = m.mine ? 'Вы' : (m.author ?? '');
      _replyText = (m.text ?? '').trim().isEmpty ? 'Фотография' : m.text;
    });
  }

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await _c.send(_text.text,
          photoPath: _photo, replyTo: _replyTo);
      _text.clear();
      _photo = null;
      _replyTo = null;
      _replyAuthor = null;
      _replyText = null;
      _jumpToBottom();
      if (!_c.online) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Сохранено офлайн — отправится при связи'),
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Не удалось сохранить сообщение: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _discard(String clientId) async {
    await _c.discard(clientId);
  }

  /// Переключить звук без очереди: вызов ждём и при отказе говорим почему — кэш списка
  /// всё равно вернёт серверное значение следующей синхронизацией.
  Future<void> _toggleMute() async {
    final messenger = ScaffoldMessenger.of(context);
    final muted = _c.chat?.muted ?? false;
    try {
      await _c.setMuted(!muted);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Разделитель дней — от серверного today, как заголовки ленты (#37125).
class _DaySeparator extends StatelessWidget {
  final String label;

  const _DaySeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Wms.chipBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: Wms.text2)),
        ),
      ),
    );
  }
}

/// Одно сообщение: свои справа на подложке выделения, чужие слева на карточке;
/// имя автора в группе, цитата ответа, фото миниатюрой (и во весь экран по тапу),
/// галки статуса у своих, у неотправленного — пометка и причина.
class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final ChatConversationController controller;
  final bool showAuthor;

  /// Цитата ответа: у серверного сообщения — как его прислал сервер, у своего
  /// неотправленного — из исходного сообщения на экране (null — исходного нет,
  /// цитата не рисуется).
  final String? replyQuoteAuthor;
  final String? replyQuoteText;
  final VoidCallback? onReply;
  final VoidCallback? onDiscard;

  const _Bubble({
    required this.message,
    required this.controller,
    required this.showAuthor,
    this.replyQuoteAuthor,
    this.replyQuoteText,
    this.onReply,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.mine;
    final failed = m.sendError != null;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // Ответить — долгим нажатием (#37369); контекстное меню не нужно: у
        // сообщения ровно одно действие
        onLongPress: onReply,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine ? Wms.active : Wms.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: failed ? Wms.warn : Wms.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showAuthor || m.edited) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showAuthor)
                      Flexible(
                        child: Text(
                          m.author ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: mine ? Wms.primaryDark : Wms.primary),
                        ),
                      ),
                    if (m.edited) ...[
                      if (showAuthor) const SizedBox(width: 6),
                      Text('изменено',
                          style:
                              TextStyle(fontSize: 11, color: Wms.muted)),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
              ],
              if (m.replyId != null &&
                  (replyQuoteAuthor != null || replyQuoteText != null)) ...[
                _Quote(
                    author: replyQuoteAuthor ?? '',
                    text: replyQuoteText ?? ''),
                const SizedBox(height: 4),
              ],
              if ((m.text ?? '').trim().isNotEmpty)
                Text(m.text!.trim(), style: const TextStyle(fontSize: 14)),
              if (m.photoPath != null) ...[
                const SizedBox(height: 6),
                TaskPhotoThumb(loader: localPhoto(File(m.photoPath!))),
              ],
              if (m.fileImage) ...[
                const SizedBox(height: 6),
                TaskPhotoThumb(
                  size: 180,
                  loader: ({required bool thumb}) =>
                      controller.photoFile(m.id, thumb: thumb),
                  onBroken: () => unawaited(controller.evictPhoto(m.id)),
                ),
              ],
              if (m.fileName != null && !m.fileImage) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.attach_file, size: 14, color: Wms.muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(m.fileName ?? 'файл',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Wms.muted)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_when(m.when),
                      style: TextStyle(fontSize: 11, color: Wms.muted)),
                  if (m.pending) ...[
                    const SizedBox(width: 4),
                    Icon(failed ? Icons.error_outline : Icons.schedule,
                        size: 13, color: failed ? Wms.warn : Wms.muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        failed
                            ? 'не принято: ${m.sendError}'
                            : 'не отправлено — уйдёт при связи',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: failed ? Wms.warn : Wms.muted),
                      ),
                    ),
                    if (onDiscard != null)
                      TextButton(
                        onPressed: onDiscard,
                        style: TextButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            visualDensity: VisualDensity.compact),
                        child: const Text('Убрать'),
                      ),
                  ],
                  if (!m.pending && mine && m.status != null) ...[
                    const SizedBox(width: 4),
                    _Ticks(status: m.status!),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// «10:42» — день уже назван разделителем, часы и минуты внутри дня.
  static String _when(DateTime? t) {
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

/// Цитата исходного сообщения внутри пузыря ответа.
class _Quote extends StatelessWidget {
  final String author;
  final String text;

  const _Quote({required this.author, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: Wms.chipBg,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: Wms.primary, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Wms.primary)),
          if (text.trim().isNotEmpty)
            Text(
              text.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Wms.text2),
            ),
        ],
      ),
    );
  }
}

/// ✓ — отправлено, ✓✓ — доставлено, ✓✓ цветом — прочитано (#37369).
class _Ticks extends StatelessWidget {
  final String status;

  const _Ticks({required this.status});

  @override
  Widget build(BuildContext context) {
    final seen = status == ChatMessageStatus.seen;
    final delivered =
        status == ChatMessageStatus.delivered || seen;
    final color = seen ? Wms.primary : Wms.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(delivered ? Icons.done_all : Icons.done,
            size: 14, color: color),
      ],
    );
  }
}
