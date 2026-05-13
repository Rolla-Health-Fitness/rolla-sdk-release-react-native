package app.rolla.reactnative

import android.graphics.Color
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.rolla.sdk.wrapper.Rolla
import com.rolla.sdk.wrapper.RollaBranding
import com.rolla.sdk.wrapper.RollaCloseReason
import com.rolla.sdk.wrapper.RollaConfiguration
import com.rolla.sdk.wrapper.RollaError
import com.rolla.sdk.wrapper.RollaListener

class RollaSdkModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), LifecycleEventListener {

    private var rolla: Rolla? = null

    init {
        reactContext.addLifecycleEventListener(this)
    }

    override fun getName(): String = NAME

    override fun onHostResume() {}
    override fun onHostPause() {}

    override fun onHostDestroy() {
        UiThreadUtil.runOnUiThread {
            rolla?.dismiss()
            rolla = null
        }
    }

    override fun invalidate() {
        UiThreadUtil.runOnUiThread {
            rolla?.dismiss()
            rolla = null
        }
        super.invalidate()
    }

    @ReactMethod
    fun show(config: ReadableMap, promise: Promise) {
        val activity = currentActivity
            ?: return promise.reject("NO_ACTIVITY", "RollaSdk.show requires a foreground activity.")

        UiThreadUtil.runOnUiThread {
            try {
                val existing = rolla
                if (existing != null && existing.isPresenting) {
                    promise.reject(
                        "ALREADY_PRESENTING",
                        "Rolla is already presenting. Dismiss it before calling show() again."
                    )
                    return@runOnUiThread
                }

                val configuration = buildConfiguration(config)
                val instance = Rolla(configuration)
                instance.listener = RollaListenerAdapter()
                rolla = instance
                instance.show(activity)
                promise.resolve(null)
            } catch (t: Throwable) {
                promise.reject("SHOW_FAILED", t.message ?: "Failed to launch Rolla.", t)
            }
        }
    }

    @ReactMethod
    fun dismiss(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            rolla?.dismiss()
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun updateToken(
        token: String,
        refreshToken: String?,
        expiresIn: Double?,
        promise: Promise
    ) {
        UiThreadUtil.runOnUiThread {
            val current = rolla
            if (current == null) {
                promise.reject("NO_ACTIVE_SESSION", "updateToken called with no active Rolla session.")
                return@runOnUiThread
            }
            current.updateToken(
                token = token,
                refreshToken = refreshToken,
                expiresIn = expiresIn?.toInt()
            ) { result ->
                result.onSuccess { promise.resolve(null) }
                    .onFailure { promise.reject("UPDATE_TOKEN_FAILED", it.message, it) }
            }
        }
    }

    @ReactMethod
    fun clearSession(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val current = rolla
            if (current == null) {
                promise.resolve(null)
                return@runOnUiThread
            }
            current.clearSession { result ->
                result.onSuccess { promise.resolve(null) }
                    .onFailure { promise.reject("CLEAR_SESSION_FAILED", it.message, it) }
            }
        }
    }

    @ReactMethod
    fun destroyEngine(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            Rolla.destroyEngine()
            rolla = null
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun isPresenting(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            promise.resolve(rolla?.isPresenting == true)
        }
    }

    @ReactMethod
    fun getNativeSdkVersion(promise: Promise) {
        promise.resolve(NATIVE_SDK_VERSION)
    }

    @ReactMethod fun addListener(eventName: String) { /* no-op, required by RN 0.65+ */ }
    @ReactMethod fun removeListeners(count: Int)   { /* no-op, required by RN 0.65+ */ }

    private fun emit(event: String, payload: WritableMap?) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(event, payload)
    }

    private fun buildConfiguration(map: ReadableMap): RollaConfiguration {
        val token = map.getString("token")
            ?: throw IllegalArgumentException("Missing required field 'token'.")
        val partnerId = map.getString("partnerId")
            ?: throw IllegalArgumentException("Missing required field 'partnerId'.")

        val environment = map.getStringOrNull("environment") ?: "rnd"
        val modules: List<String>? = when {
            map.hasKey("disabledModules") && !map.isNull("disabledModules") ->
                map.getArray("disabledModules")?.toStringList()
            map.hasKey("modules") && !map.isNull("modules") ->
                map.getArray("modules")?.toStringList()
            else -> null
        }

        return RollaConfiguration(
            token = token,
            partnerId = partnerId,
            refreshToken = map.getStringOrNull("refreshToken"),
            tokenExpiresIn = map.getIntOrNull("tokenExpiresIn"),
            userId = map.getStringOrNull("userId"),
            environment = environment,
            modules = modules,
            branding = if (map.hasKey("branding") && !map.isNull("branding"))
                buildBranding(map.getMap("branding")!!) else null,
            showSettingsButton = if (map.hasKey("showSettingsButton"))
                map.getBoolean("showSettingsButton") else true
        )
    }

    private fun buildBranding(map: ReadableMap): RollaBranding {
        return RollaBranding(
            appName = map.getStringOrNull("appName") ?: "Rolla",
            primaryColor = parseColorOrDefault(map.getStringOrNull("primaryColor"), 0xFF6750A4.toInt()),
            secondaryColor = parseColorOrDefault(map.getStringOrNull("secondaryColor"), 0xFF625B71.toInt()),
            accentColor = parseColorOrDefault(map.getStringOrNull("accentColor"), 0xFF7D5260.toInt()),
            brightness = map.getStringOrNull("brightness") ?: "light",
            defaultThemeMode = map.getStringOrNull("defaultThemeMode") ?: "system",
            defaultLocale = map.getStringOrNull("defaultLocale"),
            headerLogoAsset = map.getStringOrNull("headerLogoAsset"),
            termsUrl = map.getStringOrNull("termsUrl"),
            privacyUrl = map.getStringOrNull("privacyUrl")
        )
    }

    private fun parseColorOrDefault(hex: String?, fallback: Int): Int {
        if (hex.isNullOrBlank()) return fallback
        return try {
            Color.parseColor(if (hex.startsWith("#")) hex else "#$hex")
        } catch (_: IllegalArgumentException) {
            fallback
        }
    }

    private inner class RollaListenerAdapter : RollaListener {

        override fun onRollaClosed(rolla: Rolla, reason: RollaCloseReason) {
            this@RollaSdkModule.rolla = null
            emit("onClose", encodeReason(reason))
        }

        override fun onRollaError(rolla: Rolla, error: RollaError) {
            val payload = Arguments.createMap().apply {
                putString("code", error.code)
                putString("message", error.message)
            }
            emit("onError", payload)
        }

        override fun onTokenRefreshed(
            rolla: Rolla,
            token: String,
            refreshToken: String?,
            expiresIn: Int?
        ) {
            val payload = Arguments.createMap().apply {
                putString("token", token)
                refreshToken?.let { putString("refreshToken", it) }
                expiresIn?.let { putInt("expiresIn", it) }
            }
            emit("onTokenRefreshed", payload)
        }

        override fun onTokenExpired(rolla: Rolla) {
            emit("onTokenExpired", Arguments.createMap())
        }
    }

    private fun encodeReason(reason: RollaCloseReason): WritableMap {
        val map = Arguments.createMap()
        val key = when (reason) {
            is RollaCloseReason.FlutterRequested -> {
                reason.reason?.let { map.putString("detail", it) }
                "flutterRequested"
            }
            RollaCloseReason.HostNavigationBack -> "hostNavigationBack"
            RollaCloseReason.HostModalDismiss   -> "hostModalDismiss"
            RollaCloseReason.Programmatic       -> "programmatic"
            RollaCloseReason.HostStackReplaced  -> "hostStackReplaced"
            RollaCloseReason.Unknown            -> "unknown"
        }
        map.putString("reason", key)
        return map
    }

    companion object {
        const val NAME = "RollaSdk"
        private const val NATIVE_SDK_VERSION = "0.1.10"
    }
}

private fun ReadableMap.getStringOrNull(key: String): String? =
    if (hasKey(key) && !isNull(key)) getString(key) else null

private fun ReadableMap.getIntOrNull(key: String): Int? =
    if (hasKey(key) && !isNull(key)) getInt(key) else null

private fun ReadableArray.toStringList(): List<String> {
    val out = ArrayList<String>(size())
    for (i in 0 until size()) {
        getString(i)?.let { out.add(it) }
    }
    return out
}
