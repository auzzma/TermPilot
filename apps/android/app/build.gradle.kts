plugins { id("com.android.application"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "com.termpilot.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.termpilot.app"
        minSdk = 30
        targetSdk = 36
        providers.gradleProperty("termpilotAbi").orNull?.let { ndk.abiFilters += it }
        versionCode = 21
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    packaging { jniLibs.useLegacyPackaging = false; resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        create("internalRelease") {
            initWith(getByName("release"))
            matchingFallbacks += "release"
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    // CI signing is opt-in. No private keystore or password belongs in Git.
    if (providers.environmentVariable("TERMPILOT_ANDROID_SIGN").orNull == "1") {
        val ciSigning = signingConfigs.create("ciRelease") {
            storeFile = file(requireNotNull(System.getenv("ANDROID_KEYSTORE_PATH")))
            storePassword = requireNotNull(System.getenv("ANDROID_KEYSTORE_PASSWORD"))
            keyAlias = requireNotNull(System.getenv("ANDROID_KEY_ALIAS"))
            keyPassword = requireNotNull(System.getenv("ANDROID_KEY_PASSWORD"))
        }
        buildTypes.getByName("internalRelease").signingConfig = ciSigning
    }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.10.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// Export exact Maven runtime coordinates without copying developer-machine paths.
tasks.register("exportMobileDependencyInventory") {
    doLast {
        val entries = configurations.getByName("releaseRuntimeClasspath").resolvedConfiguration.resolvedArtifacts
            .map { it.moduleVersion.id }.distinct().sortedBy { it.toString() }
        val destination = layout.buildDirectory.file("mobile-licenses/maven-dependencies.txt").get().asFile
        destination.parentFile.mkdirs()
        destination.writeText(entries.joinToString("\n", postfix = "\n") { "${it.group}:${it.name}:${it.version}" })
    }
}
