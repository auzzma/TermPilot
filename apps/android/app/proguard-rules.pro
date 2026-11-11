# JNI symbols are looked up by class and method name in the shared Rust library.
-keep class com.termpilot.app.NativeBridge { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
