import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api_client.dart';
import 'session.dart';

/// Фоновый обработчик — отдельная точка входа в изолят, поднимаемый системой, когда
/// сообщение пришло на свёрнутое или убитое приложение. Аннотация обязательна: без неё
/// release-сборка выкинет функцию как недостижимую, и обработчик молча не позовётся.
///
/// Делать здесь почти нечего, и это правильно: шторку по блоку `notification` рисует сама
/// система, а базы, экранов и сессии у этого изолята нет — он поднят в пустом приложении.
/// Работа начинается, когда человек нажмёт на уведомление и приложение откроется целиком
/// ([PushService.onOpenTask]). Обработчик всё равно нужен: без него FCM не доставит
/// сообщение в фоне вообще, и `data` до открытия не доживёт.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  if (kDebugMode) {
    debugPrint('push (фон): ${message.data}');
  }
}

/// Пуш-уведомления через FCM (#36720): регистрация телефона на сервере, разрешения и
/// переход на задачу по нажатию.
///
/// Настоящий пуш — единственный способ достучаться до закрытого приложения, и весь смысл
/// этого класса в нём. Всё остальное из подсистемы уведомлений (лента, счётчик
/// непрочитанного, опрос раз в минуту) работает и без него — здесь покупается только
/// немедленность.
///
/// Firebase может быть не настроен вовсе: `google-services.json` заказчика в репозитории
/// не лежит (docs/mvp/push-fcm-setup.md), и сборка без него — штатный случай. Тогда
/// [available] остаётся false, а приложение работает ровно как раньше: ни одного экрана,
/// который сломался бы от отсутствия пуша, здесь нет.
class PushService {
  PushService({required this.api, required this.session});

  final ApiClient api;
  final Session session;

  /// Нажали на уведомление про задачу — приложению пора её открыть. Вешается снаружи
  /// (main.dart): навигация — дело того, у кого есть Navigator, а не этого класса.
  void Function(String taskId)? onOpenTask;

  /// Что-то приехало, пока приложение открыто. Показывать шторку поверх собственного
  /// экрана незачем — человек и так смотрит в телефон, — но ленту и бейдж обновить надо.
  void Function()? onForegroundMessage;

  /// Удалось ли вообще поднять Firebase. False — конфигурации заказчика в сборке нет.
  bool get available => _available;
  bool _available = false;

  /// Токен, зарегистрированный на сервере. Хранится, чтобы было что снимать при выходе:
  /// после [FirebaseMessaging.deleteToken] спросить его уже не у кого.
  String? _registeredToken;

  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  /// Поднять Firebase и развесить обработчики. Зовётся один раз при запуске, до первого
  /// кадра, — иначе уведомление, которым приложение и открыли, обработать будет некому.
  Future<void> init() async {
    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (e) {
      // сборка без конфигурации Firebase — это не поломка, а установка, где пуш не
      // заводили; приложение обязано открыться и работать
      if (kDebugMode) {
        debugPrint('push: Firebase не настроен ($e) — пуш выключен');
      }
      return;
    }

    FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
    _messageSub = FirebaseMessaging.onMessage.listen((_) {
      onForegroundMessage?.call();
    });
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_handleOpen);

    // Приложение было убито, и его подняли нажатием на уведомление: этого сообщения нет
    // ни в одном потоке, его отдают ровно один раз и только так.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleOpen(initial);
  }

  void _handleOpen(RemoteMessage message) {
    final taskId = message.data['taskId'];
    if (taskId is String && taskId.isNotEmpty) {
      onOpenTask?.call(taskId);
    }
  }

  /// Зарегистрировать этот телефон за вошедшим человеком. Идемпотентна: зовётся и после
  /// входа, и на каждом запуске с живой сессией — токен FCM ротируется сам по себе
  /// (переустановка, очистка данных, восстановление из бэкапа), и реестр на сервере
  /// должен догонять его, а не хранить позавчерашний.
  Future<void> register() async {
    if (!_available || !session.isActive) return;

    // На iOS без запроса токена не будет вовсе; на Android с 13-й версии без него
    // система молча не покажет ни одного уведомления, хотя токен выдаст.
    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (_) {
      // отказ в разрешении — это ответ, а не сбой: регистрацию он не отменяет, человек
      // может разрешить показ позже в настройках системы, и токен к тому моменту нужен
    }

    await _sendToken(await _currentToken());

    // Токен может смениться в любой момент работы приложения — тогда прежний мёртв, и
    // сервер должен узнать новый прежде, чем по старому уйдёт первое уведомление.
    _tokenSub?.cancel();
    _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen(_sendToken);
  }

  Future<String?> _currentToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      // на iOS без APNs-ключа в проекте Firebase токен не выдаётся — это настройка
      // заказчика, а не состояние, которое приложение может исправить
      if (kDebugMode) {
        debugPrint('push: токен не получен ($e)');
      }
      return null;
    }
  }

  Future<void> _sendToken(String? token) async {
    if (token == null || token.isEmpty || !session.isActive) return;
    try {
      final info = await PackageInfo.fromPlatform();
      await api.registerDevice(
        token,
        Platform.isIOS ? 'ios' : 'android',
        '${info.version}+${info.buildNumber}',
      );
      _registeredToken = token;
    } catch (_) {
      // магазин без связи — обычное дело; следующий запуск приложения зарегистрирует
      // телефон снова, а до тех пор пуша просто нет
    }
  }

  /// Снять регистрацию при выходе из аккаунта.
  ///
  /// Это та самая мина безопасности из дизайна, и потому здесь два действия, а не одно.
  /// Токен привязан к паре «устройство плюс пользователь»: не сняв его, уведомления
  /// следующего сотрудника уедут на телефон предыдущего вместе с названиями объектов и
  /// содержанием задач — причём в системную шторку, где их прочтёт кто угодно, не
  /// открывая приложение.
  ///
  /// Сначала сервер убирает строку реестра. Затем токен уничтожается у самого FCM: это
  /// подстраховка ровно на случай, когда первое не удалось — выход из аккаунта в подсобке
  /// без связи. Мёртвый токен FCM отдаёт сервером как 404, и тот снимает устройство сам
  /// (PushFcm.sendToDevice), так что дыра закрывается с обеих сторон.
  ///
  /// Остаётся один непокрытый случай: выход без сети, когда и до сервера, и до FCM не
  /// достучаться. Его закрывает вход следующего сотрудника — реестр уникален по токену, и
  /// регистрация перенаправляет строку на нового владельца (PushDevice.device).
  Future<void> unregister() async {
    if (!_available) return;
    _tokenSub?.cancel();
    _tokenSub = null;

    final token = _registeredToken ?? await _currentToken();
    _registeredToken = null;
    if (token == null || token.isEmpty) return;

    try {
      await api.unregisterDevice(token);
    } catch (_) {
      // до сервера не достучались — остаётся вторая половина, ради которой она и есть
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // и её не вышло: телефон офлайн целиком, случай описан в комментарии выше
    }
  }

  void dispose() {
    _tokenSub?.cancel();
    _messageSub?.cancel();
    _openedSub?.cancel();
  }
}
