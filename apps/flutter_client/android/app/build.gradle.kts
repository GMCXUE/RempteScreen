plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.remotescreen.remotescreen"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    testOptions { unitTests { isIncludeAndroidResources = true; all {
        it.jvmArgs("--add-opens=java.base/java.lang=ALL-UNNAMED", "--add-opens=java.base/java.util=ALL-UNNAMED", "--add-opens=java.base/java.io=ALL-UNNAMED", "--add-opens=java.base/java.net=ALL-UNNAMED", "--add-opens=java.base/java.security=ALL-UNNAMED", "--add-opens=java.base/java.text=ALL-UNNAMED", "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED", "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED", "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED")
    } } }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.remotescreen.remotescreen"
        minSdk = flutter.minSdkVersion

        // 投屏前台服务已在 third_party/flutter_webrtc 补丁版中实现
        // （ScreenProjectionService），targetSdk 恢复跟随 Flutter 默认值（34+）。
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

dependencies {
    // 原生视频悬浮窗与补丁版 flutter_webrtc 使用完全相同的 WebRTC 构建。
    implementation("io.github.webrtc-sdk:android:150.7871.01")
}

// Native notification policy regression checks.
dependencies { testImplementation("junit:junit:4.13.2"); testImplementation("org.robolectric:robolectric:4.17") }

// Flutter produces host-test assets through a separate copy task; Gradle 9 requires the edge.
tasks.matching { it.name.startsWith("package") && it.name.endsWith("UnitTestForUnitTest") }.configureEach {
    val buildVariant = name.removePrefix("package").removeSuffix("UnitTestForUnitTest")
    dependsOn(tasks.matching { it.name == "copyFlutterAssets$buildVariant" })
}
