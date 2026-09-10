package com.mycompany.pulse_tasks

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Канал для пуша (#36720). Одного совпадения id с манифестом и с channel_id, который
        // шлёт сервер (PushFcm.lsf), мало: канал должен существовать, а FCM сам его не
        // создаёт — не найдя, кладёт уведомление в свой запасной «Разное» обычной важности:
        // звук есть, всплытия поверх экрана нет. Всплытие даёт только HIGH.
        //
        // Здесь, а не в Application: до первого входа пушей не бывает (токена на сервере
        // ещё нет), а созданный канал живёт в системе и через рестарты, и через обновления.
        // Звать на каждом запуске безопасно — готовый канал система не пересоздаёт и
        // настроек, изменённых человеком, не сбрасывает. Обратная сторона: поднять важность
        // или сменить звук уже созданного канала отсюда нельзя, только новым id.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("pulse_tasks", "Задачи", NotificationManager.IMPORTANCE_HIGH)
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Запуск внешнего приложения по имени пакета (#36840). Свой канал, а не
        // android_intent_plus: тот гейтит и canResolveActivity, и launch через
        // resolveActivity(MATCH_DEFAULT_ONLY), которому лаунчер-активити без
        // CATEGORY_DEFAULT не видна, — установленное приложение выглядит отсутствующим,
        // а launch при этом МОЛЧА снимает package и открывает системный лаунчер.
        // getLaunchIntentForPackage — платформенный путь ровно для этой задачи: сам
        // находит лаунчер-активити пакета; null — пакет не установлен либо невидим
        // (с Android 11 видимость даёт только <queries> манифеста).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pulse_tasks/external_apps")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchPackage" -> {
                        val pkg = call.argument<String>("package")
                        val intent = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                        if (intent == null) {
                            result.success(false)
                        } else {
                            try {
                                startActivity(intent)
                                result.success(true)
                            } catch (e: ActivityNotFoundException) {
                                // гонка «удалили между резолвом и тапом» — тот же итог
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
