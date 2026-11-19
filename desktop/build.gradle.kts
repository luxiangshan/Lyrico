import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.4.21"
    kotlin("plugin.compose") version "2.4.21"
    kotlin("plugin.serialization") version "2.4.21"
    id("org.jetbrains.compose") version "1.12.2"
}

group = "com.lonx.lyrico.desktop"
version = "1.7.0"

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation("org.jetbrains.compose.material:material-icons-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
    implementation("net.jthink:jaudiotagger:3.0.1")
    // remote storage (shared with the Android mod)
    implementation("com.squareup.okhttp3:okhttp:5.5.1")
    implementation("com.hierynomus:smbj:0.14.0")
    implementation("com.rapid7.client:dcerpc:0.12.13")
    implementation("org.slf4j:slf4j-nop:2.0.9")
    implementation("org.json:json:20240303")
    implementation("com.google.zxing:core:3.5.3")
    implementation("net.java.dev.jna:jna-platform:5.17.0")
    // plugins: GraalJS (pure Java, interpreter mode on a stock JDK) + kXML for the XML host API
    implementation("org.graalvm.polyglot:polyglot:24.2.2")
    implementation("org.graalvm.polyglot:js-community:24.2.2")
    implementation("net.sf.kxml:kxml2:2.3.0")

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.5.1")
}

tasks.test {
    useJUnit()
    systemProperty("file.encoding", "UTF-8")
}

compose.desktop {
    application {
        mainClass = "com.lonx.lyrico.desktop.MainKt"
        jvmArgs += listOf("-Dfile.encoding=UTF-8", "-Dsun.stdout.encoding=UTF-8", "-Xmx1g")
        nativeDistributions {
            targetFormats(TargetFormat.Msi)
            packageName = "Lyrico Mod"
            packageVersion = "1.7.0"
            description = "Lyrico Mod - music tag and lyrics editor"
            vendor = "luxiangshan"
            copyright = "GPL-3.0"
            modules(
                "java.base", "java.desktop", "java.logging", "java.management", "java.naming",
                "java.net.http", "java.prefs", "java.security.jgss", "java.sql", "java.xml",
                "jdk.charsets", "jdk.crypto.ec", "jdk.localedata", "jdk.unsupported", "jdk.zipfs",
                "jdk.management", "jdk.net", "jdk.security.auth",
            )
            windows {
                menuGroup = "Lyrico Mod"
                shortcut = true
                dirChooser = true
                perUserInstall = true
                upgradeUuid = "6f3c2a8e-4b1d-4e7a-9c55-1a2b3c4d5e6f"
                iconFile.set(project.file("packaging/icon.ico"))
            }
        }
    }
}
