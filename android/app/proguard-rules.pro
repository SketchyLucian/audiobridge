# Keep JNI native bridge classes and methods used by libaudiobridge_opus.so
-keep class com.audiobridge.app.OpusNative { *; }
-keep class com.audiobridge.app.AAudioOutputNative { *; }

# Keep Android entrypoints & services
-keep class com.audiobridge.app.MainActivity { *; }
-keep class com.audiobridge.app.AudioRelayService { *; }

# Keep Flutter embedding classes referenced via JNI
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**
