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
        // Нативное ядро libtachyon.so собрано с поддержкой API 24 (Android 7.0+).
        minSdk = 24
        // targetSdk = 28 переводит процесс в SELinux-домен untrusted_app_27 на Android 10–16,
        // что разрешает горячую загрузку обновлённого ядра libtachyon.so из code_cache/engine через dlopen.
        targetSdk = 28
        // Единый versionCode для всех APK (--split-per-abi, universal и локальных сборок),
        // смещённый на +5000 выше старых ABI-множителей (1000/2000/4000), чтобы обновление поверх любой старой сборки проходило без конфликта версий.
        versionCode = 5000 + flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // Сжимаем .so внутри APK и распаковываем при установке (extractNativeLibs=true):
            // уменьшает размер APK в 2–2.5 раза и исключает ошибку «Файл повреждён» (INSTALL_FAILED_INVALID_APK)
            // на устройствах с 4 КБ страницами и кастомных системных установщиках при прямом mmap из ZIP.
            useLegacyPackaging = true
        }
        resources {
            excludes += setOf(
                "META-INF/*.version",
                "META-INF/com/**",
                "META-INF/version-control-info.textproto",
                "DebugProbesKt.bin",
            )
        }
    }

    signingConfigs {
        create("tachyon") {
            val ciKeystore = file("tachyon.keystore")
            val homeKeystore = file("${System.getProperty("user.home")}/.android/debug.keystore")
            storeFile = if (ciKeystore.exists()) ciKeystore else homeKeystore
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("tachyon")
        }
        release {
            // Подпись постоянным ключом: сборка ставится и обновляется поверх без конфликтов.
            signingConfig = signingConfigs.getByName("tachyon")
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
