plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

apply(from = "python_runner.gradle.kts")

val releaseStoreFile = System.getenv("LAB_WORKSPACE_UPLOAD_STORE_FILE")
val releaseStorePassword = System.getenv("LAB_WORKSPACE_UPLOAD_STORE_PASSWORD")
val releaseKeyAlias = System.getenv("LAB_WORKSPACE_UPLOAD_KEY_ALIAS")
val releaseKeyPassword = System.getenv("LAB_WORKSPACE_UPLOAD_KEY_PASSWORD")
val releaseSigningAvailable = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "org.labworkspace.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.labworkspace.app"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Chaquopy's Python 3.15 runtime is available only for 64-bit ABIs.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            if (releaseSigningAvailable) {
                storeFile = file(requireNotNull(releaseStoreFile))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Missing credentials intentionally produce an unsigned release;
            // never silently sign a distributable artifact with the debug key.
            signingConfig = if (releaseSigningAvailable) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

dependencies {
    implementation("androidx.core:core:1.17.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
