import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Khoá ký APK CỐ ĐỊNH: 2 file `signing.properties` + `signing-key.jks`
// nằm ở THƯ MỤC GỐC của repo (ngoài source.zip, nên cập nhật code không
// bao giờ ghi đè/xoá mất). Có khoá -> mọi bản build cùng 1 chữ ký ->
// cài đè được, không mất đăng nhập/cài đặt. Không có -> ký tạm (debug)
// như trước để build vẫn chạy.
val signingPropsFile = rootProject.file("../signing.properties")
val signingProps = Properties()
if (signingPropsFile.exists()) {
    FileInputStream(signingPropsFile).use { signingProps.load(it) }
}
val hasFixedKey = signingPropsFile.exists() &&
    rootProject.file("../" + signingProps.getProperty("storeFile", "signing-key.jks")).exists()

android {
    namespace = "com.binh.fb_video_downloader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.binh.fb_video_downloader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("fixed") {
            if (hasFixedKey) {
                storeFile = rootProject.file("../" + signingProps.getProperty("storeFile", "signing-key.jks"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasFixedKey) {
                println("Ký APK bằng khoá CỐ ĐỊNH (signing-key.jks)")
                signingConfigs.getByName("fixed")
            } else {
                println("CẢNH BÁO: chưa có signing.properties ở gốc repo -> ký tạm (debug)")
                signingConfigs.getByName("debug")
            }
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
