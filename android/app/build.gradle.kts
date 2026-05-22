plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}

fun requiredReleaseSigningValue(name: String): String {
    val value = System.getenv(name)
    if (value.isNullOrBlank()) {
        throw GradleException("Android release signing requires the $name environment variable.")
    }
    return value
}

android {
    namespace = "com.audiobridge.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.audiobridge.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DOPUS_BUILD_SHARED_LIBRARY=OFF",
                    "-DOPUS_BUILD_TESTING=OFF",
                    "-DOPUS_BUILD_PROGRAMS=OFF",
                    "-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF",
                    "-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF",
                    "-DOPUS_FIXED_POINT=OFF"
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    signingConfigs {
        create("release") {
            if (releaseTaskRequested) {
                storeFile = file(requiredReleaseSigningValue("ANDROID_KEYSTORE_PATH"))
                storePassword = requiredReleaseSigningValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = requiredReleaseSigningValue("ANDROID_KEY_ALIAS")
                keyPassword = requiredReleaseSigningValue("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
