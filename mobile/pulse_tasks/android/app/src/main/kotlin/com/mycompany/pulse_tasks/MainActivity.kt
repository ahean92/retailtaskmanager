package com.mycompany.pulse_tasks

import android.content.ActivityNotFoundException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
