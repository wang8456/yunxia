import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名口令不进仓库：key.properties 在 app/android/ 下，keystore 在项目根的 keystore/
val keyProps = Properties()
val keyPropsFile = rootProject.file("key.properties")
if (keyPropsFile.exists()) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}

android {
    namespace = "com.yunxia.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // ABI 交给 `flutter build apk --split-per-abi` 分；这里再写 abiFilters 会冲突
        applicationId = "com.yunxia.app"
        // 24 = Android 7.0，家里最老的平板也能装
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyPropsFile.exists()) {
            create("release") {
                keyAlias = keyProps["keyAlias"] as String
                keyPassword = keyProps["keyPassword"] as String
                storeFile = file(keyProps["storeFile"] as String)
                storePassword = keyProps["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有正式签名就用它：换了签名就没法覆盖升级旧版本
            signingConfig = if (keyPropsFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // media_kit 自带的 libmpv 是 -Dlibplacebo=disabled 编的，放不了杜比视界 P5（整屏发绿）。
    // app/src/main/jniLibs/<abi>/libmpv.so 是 mpv-android 官方构建（带 libplacebo/gpu-next），
    // 两边同名，用 pickFirst 让 src/main/jniLibs 那份胜出。装完必须验证 APK 里
    // libmpv.so 能搜到 "gpu-next"，搜不到就是没换成。
    packaging {
        jniLibs {
            pickFirsts += setOf("**/libmpv.so")
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
