# WebRTC's native library resolves these Java classes and members by name.
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.CommonApis { *; }
-keep class org.jni_zero.JniZero {
    static java.lang.Object[] init();
    static void crashIfMultiplexingMisaligned(long, long);
}
