import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyFile = rootProject.file("key.properties")
val releaseKeys = Properties().apply {
    if (releaseKeyFile.isFile) releaseKeyFile.inputStream().use { load(it) }
}
val readerPreview = providers.gradleProperty("wenkuReaderPreview").orNull == "true"
val catalogProbe = providers.gradleProperty("wenkuCatalogProbe").orNull == "true"
check(!catalogProbe || readerPreview) { "Account read probes are restricted to the reader preview" }

android {
    namespace = "org.mewx.wenku8_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    // The separately authorized API runtime must remain byte-for-byte intact.
    // AGP otherwise strips its symbols even when jniLibs contains original files.
    packaging.jniLibs.keepDebugSymbols.add("**/libcpp.so")

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.mewx.wenku8_flutter"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["wenkuAppLabel"] = "轻小说文库"
        testInstrumentationRunner = "org.mewx.wenku8_flutter.SessionFixtureInstrumentation"
        if (catalogProbe) testInstrumentationRunner = "org.mewx.wenku8_flutter.CatalogReadInstrumentation"
        // AGP otherwise builds upstream desktop utilities too, including the
        // DRM tool whose encryption code is intentionally disabled in this app.
        externalNativeBuild.cmake.targets.addAll(listOf("mobi", "wenku_mobi"))
    }
    if (catalogProbe) testBuildType = "release"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    if (releaseKeyFile.isFile) {
        signingConfigs.create("distribution") {
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
            storeFile = rootProject.file(requireNotNull(releaseKeys.getProperty("storeFile")))
            storePassword = releaseKeys.getProperty("storePassword")
        }
    }

    buildTypes {
        getByName("debug") {
            // The integration runner uninstalls its package on completion.
            // Keep rendering probes separate from the user's release data.
            applicationIdSuffix = ".render_probe"
        }
        getByName("profile") {
            applicationIdSuffix = ".profile_probe"
        }
        release {
            proguardFile(file("document-import.pro"))
            if (catalogProbe) proguardFile(file("catalog-probe.pro"))
            if (readerPreview) {
                applicationIdSuffix = ".reader_preview"
                manifestPlaceholders["wenkuAppLabel"] = "文库 · 阅读预览"
            }
            // Local previews remain install-compatible. Public distributions
            // use an owner's untracked key.properties, never an embedded key.
            signingConfig = signingConfigs.getByName(
                if (releaseKeyFile.isFile && !readerPreview) "distribution" else "debug"
            )
        }
    }

    // Match the embedded API library to the Flutter code actually compiled for
    // this APK. Otherwise a one-ABI build advertises extra, unusable ABIs solely
    // because libcpp.so exists for them. Let Flutter own split-APK filtering.
    val targets = project.findProperty("target-platform")?.toString()
    if (targets != null && project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
        val targetAbis = targets.split(",").map { platform ->
            when (platform) {
                "android-arm" -> "armeabi-v7a"
                "android-arm64" -> "arm64-v8a"
                "android-x64" -> "x86_64"
                else -> error("Unsupported Flutter target platform: $platform")
            }
        }
        buildTypes.configureEach {
            ndk.abiFilters.clear()
            ndk.abiFilters.addAll(targetAbis)
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
    implementation("org.jsoup:jsoup:1.23.2")
    implementation("org.commonmark:commonmark:0.30.1")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // Keep the media host classes available to the app's shared-engine wiring.
    implementation("androidx.media:media:1.7.0")
    testImplementation("junit:junit:4.13.2")
}
