plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "au.com.jd.bose"
    compileSdk = 35

    defaultConfig {
        applicationId = "au.com.jd.bose"
        minSdk = 31
        targetSdk = 35
        versionCode = 2
        versionName = "2.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.8"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // The BMAP wire layer + device map are GENERATED from protocol/spec/*.toml.
    // They live in a dedicated source root (committed, do-not-edit) so the app
    // and macOS share one source of truth. `copyGeneratedProtocol` refreshes them.
    sourceSets["main"].java.srcDir("src/generated/java")

    testOptions {
        unitTests.all { it.useJUnit() }
    }
}

// Copy the generated Kotlin protocol layer from protocol/generated/ into the app's
// generated source root. Mirrors macos/build.sh's copy of the generated Swift.
// Run manually (`./gradlew copyGeneratedProtocol`) after `cd protocol && make gen`;
// the committed copies are the build inputs so CI needs no Python.
tasks.register<Copy>("copyGeneratedProtocol") {
    val protocolGen = rootProject.file("../protocol/generated")
    from(protocolGen) {
        include("BMAP.generated.kt", "Devices.generated.kt")
    }
    into("src/generated/java/au/com/jd/bose")
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")

    // Compose
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.activity:activity-compose:1.8.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // JVM unit tests for the pure composite parsers (no hardware / Android stubs).
    testImplementation("junit:junit:4.13.2")
}
