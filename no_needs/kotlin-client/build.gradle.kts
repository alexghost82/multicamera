import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.1.20"
    kotlin("plugin.compose") version "2.1.20"
    id("org.jetbrains.compose") version "1.8.2"
}

kotlin { jvmToolchain(21) }

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material)
    implementation(compose.materialIconsExtended)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
    implementation("org.json:json:20250107")
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:1.11.4")
}

val configureNative by tasks.registering(Exec::class) {
    commandLine("cmake", "-S", "native", "-B", "build/native")
    environment("JAVA_HOME", System.getProperty("java.home"))
    environment("PKG_CONFIG_PATH", "/opt/homebrew/opt/gstreamer/lib/pkgconfig")
}
val buildNative by tasks.registering(Exec::class) {
    dependsOn(configureNative)
    commandLine("cmake", "--build", "build/native", "-j", "4")
}
val prepareNativeResources by tasks.registering(Copy::class) {
    dependsOn(buildNative)
    from(layout.buildDirectory.file("native/libcamerawallgst.dylib"))
    from(layout.projectDirectory.file(".tools/go2rtc"))
    into(layout.buildDirectory.dir("app-resources/common"))
}
tasks.matching { it.name in setOf("createDistributable", "packageDmg", "prepareAppResources") }.configureEach {
    dependsOn(prepareNativeResources)
}
tasks.matching { it.name == "createDistributable" }.configureEach {
    doLast {
        val helper = layout.buildDirectory.file("compose/binaries/main/app/CameraWallKotlin.app/Contents/app/resources/go2rtc").get().asFile
        check(helper.setExecutable(true, false)) { "Cannot make packaged go2rtc executable" }
    }
}

tasks.test {
    dependsOn(buildNative)
    inputs.file(layout.buildDirectory.file("native/libcamerawallgst.dylib"))
    useJUnitPlatform()
    jvmArgs("-Djava.library.path=${layout.buildDirectory.dir("native").get().asFile}", "-Djava.awt.headless=false")
    testLogging { events("passed", "skipped", "failed"); showStandardStreams = true }
}

tasks.withType<JavaExec>().configureEach {
    dependsOn(buildNative)
    jvmArgs("-Djava.library.path=${layout.buildDirectory.dir("native").get().asFile}", "-Dapple.awt.application.name=CameraWall Kotlin")
}

compose.desktop {
    application {
        mainClass = "camerawall.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg)
            packageName = "CameraWallKotlin"
            packageVersion = "1.0.0"
            modules("java.net.http", "jdk.unsupported", "jdk.crypto.ec")
            appResourcesRootDir.set(layout.buildDirectory.dir("app-resources"))
        }
    }
}