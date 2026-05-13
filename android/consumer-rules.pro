# Keep public symbols of the native SDK and our wrapper module so R8/ProGuard
# in the consumer app does not strip them. Without these, the React-Native
# autolinker still wires the module but reflection-based lookups can fail
# silently at runtime.
-keep class com.rolla.sdk.wrapper.** { *; }
-keep class app.rolla.reactnative.** { *; }
