import java.util.Properties

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

// Релизная подпись для Google Play: android/key.properties (keyAlias/storeFile/storePassword/
// keyPassword) и сам keystore — секреты, в git не попадают (android/.gitignore). Файла нет —
// сборка не ломается, release подписывается debug-ключом с предупреждением: как и с
// google-services.json, править задачи можно без секретов, но в Play такой бандл не годится.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseKeystore = keystoreProperties.getProperty("storeFile") != null
if (!releaseKeystore) {
    logger.warn(
        "android/key.properties не найден — release подписывается DEBUG-ключом, для Google Play не годится"
    )
}

android {
    namespace = "by.luxsoft.esb.tasks"
    // Явно, а не flutter.compileSdkVersion/targetSdkVersion: Google Play с 31.08.2026 не
    // принимает новые приложения ниже API 36, а дефолт берётся из Flutter того, кто собирает.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "by.luxsoft.esb.tasks"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseKeystore) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig =
                if (releaseKeystore) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
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
