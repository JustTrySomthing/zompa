# WebRTC's native library resolves these Java classes and members by name.
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
