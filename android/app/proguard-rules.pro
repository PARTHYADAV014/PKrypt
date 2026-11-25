# Flutter Wrapper & Plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.google.android.play.core.**

# Pkrypt Native Android Classes (MainActivity & Foreground Sync Service)
-keep class com.pkrypt.app.** { *; }

# Google ML Kit Face Detection & Vision
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.android.odml.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.mlkit_**

# Secure Storage, Biometrics & Media Plugins
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.biometric.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn javax.annotation.**
-dontwarn org.slf4j.**
-dontwarn com.google.errorprone.annotations.**
# Native Hardware Crypto Plugin
-keep class dev.dint.cryptography_flutter.** { *; }
-dontwarn dev.dint.cryptography_flutter.**

# TensorFlow Lite / LiteRT (MobileFaceNet)
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.ai.edge.litert.** { *; }
-dontwarn org.tensorflow.lite.**
-dontwarn com.google.ai.edge.litert.**
