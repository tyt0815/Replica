-keep class io.ymusic.quickjs.QuickJsNative { *; }
-keep class io.ymusic.quickjs.QuickJsException { <init>(java.lang.String); }
-keep class io.ymusic.mse.MseJsEventBridge { *; }
-keep class io.ymusic.mse.MseLogBridge { *; }

-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

-keepattributes RuntimeVisibleAnnotations,AnnotationDefault
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static **$Companion Companion;
}
-keep,allowshrinking,allowobfuscation class <2>$Companion {
    kotlinx.serialization.KSerializer serializer(...);
}
