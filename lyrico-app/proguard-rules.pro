# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Kotlin metadata (reflection libraries may need it)
-keepattributes Signature,InnerClasses,EnclosingMethod,KotlinMetadata

############################################
# Parcelable
############################################
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

############################################
# Compose Destinations (generated navigation)
############################################
-keep class com.ramcosta.composedestinations.generated.** { *; }

############################################
# Coil
############################################
-keep class com.lonx.lyrico.utils.coil.AudioCoverFetcher* { *; }

############################################
# opencc4j
############################################
-dontwarn com.huaban.analysis.jieba.JiebaSegmenter
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.PropertyDescriptor
-dontwarn java.lang.management.ManagementFactory
-dontwarn java.lang.management.RuntimeMXBean
-keep class com.github.houbb.** { *; }

############################################
# miuix blur
############################################
-keep class top.yukonga.miuix.kmp.blur.** { *; }


############################################
# Lyrico Mod：远程存储（smbj / bouncycastle / mbassador / zxing）
############################################
-keep class com.hierynomus.** { *; }
-keep class net.engio.mbassy.** { *; }
-keep class org.bouncycastle.** { *; }
-keep class com.google.zxing.** { *; }
-keep class com.lonx.lyrico.remote.** { *; }
-dontwarn com.hierynomus.**
-dontwarn net.engio.mbassy.**
-dontwarn org.bouncycastle.**
-dontwarn org.slf4j.**
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.**
-dontwarn javax.naming.**
-dontwarn javax.el.**
-dontwarn sun.security.**
-dontwarn java.awt.**
-keep class com.rapid7.client.dcerpc.** { *; }
-dontwarn com.rapid7.client.dcerpc.**
-dontwarn com.sun.**
-dontwarn org.slf4j.impl.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.j2objc.annotations.**
-dontwarn org.checkerframework.**
-dontwarn javax.annotation.**
-dontwarn java.lang.invoke.**
