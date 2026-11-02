plugins {
    id("com.android.application")
    // Kotlin нужен для VPN-сервиса и обвязки JNI.
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.tachyon.tachyon_proxy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.tachyon.tachyon_proxy"
        // Ядро собрано под API 26: более старые версии Android не
        // поддерживаются.
        minSdk = 26
        // targetSdk = 28 переводит процесс в SELinux-домен untrusted_app_27 на Android 10–16,
        // что разрешает горячую загрузку обновлённого ядра libtachyon.so из code_cache/engine через dlopen.
        targetSdk = 28
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Подпись debug-ключом: сборка ставится на устройство без
            // подготовки релизного ключа.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    lint {
        disable += "ExpiredTargetSdkVersion"
        checkReleaseBuilds = false
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
