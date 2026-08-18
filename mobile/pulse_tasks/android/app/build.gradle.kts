plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Пуш через FCM (#36720). Плагин применяется только когда google-services.json заказчика
// действительно лежит рядом: сам по себе он валит сборку целиком с «File
// google-services.json is missing», а собирать приложение должно быть можно и тому, кто
// правит список задач и к уведомлениям отношения не имеет. Как завести файл —
// docs/mvp/push-fcm-setup.md.
//
// Молчать про его отсутствие при этом нельзя: без файла приложение собирается, ставится
// и работает, и «пуши почему-то не приходят» выяснилось бы уже на объекте.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.warn(
        "google-services.json не найден — сборка БЕЗ пуш-уведомлений. " +
            "См. docs/mvp/push-fcm-setup.md"
    )
}

android {
    namespace = "com.mycompany.pulse_tasks"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mycompany.pulse_tasks"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
