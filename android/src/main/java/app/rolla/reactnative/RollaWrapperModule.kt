package app.rolla.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.rolla.sdk.wrapper.Rolla
import com.rolla.sdk.wrapper.RollaListener
import com.rolla.sdk.wrapper.config.RollaBranding
import com.rolla.sdk.wrapper.config.RollaConfiguration
import com.rolla.sdk.wrapper.config.RollaDataSource
import com.rolla.sdk.wrapper.config.RollaDisabledModule
import com.rolla.sdk.wrapper.config.RollaLanguage
import com.rolla.sdk.wrapper.config.RollaThemeMode
import com.rolla.sdk.wrapper.config.RollaTransition
import com.rolla.sdk.wrapper.features.session.RollaCloseReason
import com.rolla.sdk.wrapper.features.session.RollaError

class RollaWrapperModule(reactContext: ReactApplicationContext) :
    NativeRollaWrapperSpec(reactContext), LifecycleEventListener {

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

    override fun show(config: ReadableMap, transition: String, promise: Promise) {
        val activity = reactApplicationContext.currentActivity
            ?: return promise.reject("NO_ACTIVITY", "RollaWrapper.show requires a foreground activity.")

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

                val configuration = RollaConfigurationParser.configuration(config)
                val rollaTransition = RollaConfigurationParser.transition(transition)
                val instance = Rolla(configuration)
                instance.listener = RollaListenerAdapter()
                rolla = instance
                instance.show(activity, rollaTransition)
                promise.resolve(null)
            } catch (e: IllegalArgumentException) {
                promise.reject("INVALID_CONFIG", e.message ?: "Invalid Rolla configuration.", e)
            } catch (t: Throwable) {
                promise.reject("SHOW_FAILED", t.message ?: "Failed to launch Rolla.", t)
            }
        }
    }

    override fun dismiss(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            rolla?.dismiss()
            promise.resolve(null)
        }
    }

    override fun updateToken(
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

    override fun clearSession(promise: Promise) {
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

    override fun destroyEngine(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            Rolla.destroyEngine()
            rolla = null
            promise.resolve(null)
        }
    }

    override fun isPresenting(promise: Promise) {
        UiThreadUtil.runOnUiThread {
            promise.resolve(rolla?.isPresenting == true)
        }
    }

    override fun getNativeSdkVersion(promise: Promise) {
        // Injected by android/build.gradle from package.json `nativeSdkVersion` —
        // the same field the Gradle dependency is pinned from.
        promise.resolve(BuildConfig.NATIVE_SDK_VERSION)
    }

    override fun addListener(eventName: String) {
        // no-op, required by RN 0.65+ NativeEventEmitter
    }

    override fun removeListeners(count: Double) {
        // no-op, required by RN 0.65+ NativeEventEmitter
    }

    private fun emit(event: String, payload: WritableMap?) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(event, payload)
    }

    private inner class RollaListenerAdapter : RollaListener {

        override fun onRollaClosed(rolla: Rolla, reason: RollaCloseReason) {
            this@RollaWrapperModule.rolla = null
            emit("onClose", encodeReason(reason))
        }

        override fun onRollaError(rolla: Rolla, error: RollaError) {
            // A failed show() reaches here after the SDK has torn its
            // presentation down, so `isPresenting` is already false; an error
            // raised while the SDK UI is running leaves it true.
            // AlreadyPresenting is the one failure that leaves the flag true
            // for the *other* presentation, so it is special-cased.
            val presentationFailed = !rolla.isPresenting || error is RollaError.AlreadyPresenting
            if (presentationFailed && this@RollaWrapperModule.rolla === rolla) {
                this@RollaWrapperModule.rolla = null
            }
            val payload = Arguments.createMap().apply {
                putString("code", error.code)
                putString("message", error.message)
                putBoolean("presentationFailed", presentationFailed)
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
        const val NAME = "RollaWrapper"
    }
}

/**
 * Translates the JS `RollaConfiguration` map into the SDK's typed configuration.
 * Absent keys and JS `null` both mean "unset" and leave the SDK default in
 * place; a present key with a value the SDK does not know throws
 * [IllegalArgumentException], surfaced to JS as `INVALID_CONFIG` rather than a
 * silent drop.
 */
private object RollaConfigurationParser {

    fun configuration(map: ReadableMap): RollaConfiguration {
        val token = map.getStringOrNull("token")?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("Missing required field 'token'.")
        val partnerId = map.getStringOrNull("partnerId")?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("Missing required field 'partnerId'.")

        return RollaConfiguration(
            token = token,
            partnerId = partnerId,
            refreshToken = map.getStringOrNull("refreshToken"),
            tokenExpiresIn = map.getIntOrNull("tokenExpiresIn"),
            userId = map.getStringOrNull("userId"),
            environment = map.getStringOrNull("environment") ?: "rnd",
            disabledModules = enumSet(map, "disabledModules", RollaDisabledModule.entries) { it.rawValue },
            disabledDataSources = enumSet(map, "disabledDataSources", RollaDataSource.entries) { it.rawValue },
            language = optionalEnum(map, "language", RollaLanguage.entries) { it.rawValue },
            branding = map.getMapOrNull("branding")?.let(::branding),
            // Defaults mirror RollaConfiguration's own so an unset key behaves
            // exactly like a native host that omitted the argument.
            showOptionsButton = map.getBooleanOrNull("showOptionsButton") ?: true,
            showGoalsSection = map.getBooleanOrNull("showGoalsSection") ?: false,
        )
    }

    fun branding(map: ReadableMap): RollaBranding {
        // Every field is optional and null keeps the SDK default — never
        // substitute fallback values here, they would override the SDK's own
        // palette/copy.
        return RollaBranding(
            hostAppName = map.getStringOrNull("hostAppName"),
            primaryColor = optionalColor(map, "primaryColor"),
            themeMode = optionalEnum(map, "themeMode", RollaThemeMode.entries) { it.rawValue },
            headerLogoAsset = map.getStringOrNull("headerLogoAsset"),
            privacyUrl = map.getStringOrNull("privacyUrl"),
            removeRollaBandReferences = map.getBooleanOrNull("removeRollaBandReferences"),
        )
    }

    fun transition(name: String): RollaTransition = when (name) {
        "default" -> RollaTransition.DEFAULT
        "fade" -> RollaTransition.FADE
        else -> throw IllegalArgumentException("Unknown transition '$name'. Expected 'default' or 'fade'.")
    }

    private fun <T> optionalEnum(
        map: ReadableMap,
        key: String,
        entries: List<T>,
        rawValue: (T) -> String
    ): T? {
        val name = map.getStringOrNull(key) ?: return null
        return entries.firstOrNull { rawValue(it) == name }
            ?: throw IllegalArgumentException("Unknown value '$name' for '$key'.")
    }

    private fun <T> enumSet(
        map: ReadableMap,
        key: String,
        entries: List<T>,
        rawValue: (T) -> String
    ): Set<T> {
        if (!map.hasKey(key) || map.isNull(key)) return emptySet()
        val names = map.getArray(key)?.toStringList()
            ?: throw IllegalArgumentException("'$key' must be an array of strings.")
        return names.mapTo(LinkedHashSet()) { name ->
            entries.firstOrNull { rawValue(it) == name }
                ?: throw IllegalArgumentException("Unknown value '$name' in '$key'.")
        }
    }

    private fun optionalColor(map: ReadableMap, key: String): Int? {
        val hex = map.getStringOrNull(key) ?: return null
        return parseHexColor(hex)
            ?: throw IllegalArgumentException("'$key' must be a hex color string ('#RRGGBB' or '#RRGGBBAA').")
    }

    /**
     * Parses `#RRGGBB` / `#RRGGBBAA` (CSS channel order, the same contract as
     * iOS; the `#` is optional) into the ARGB Int the SDK expects. Not
     * `Color.parseColor`, which reads 8-digit values as `#AARRGGBB`.
     */
    private fun parseHexColor(hex: String): Int? {
        val digits = hex.trim().removePrefix("#")
        if (digits.length != 6 && digits.length != 8) return null
        val value = digits.toLongOrNull(16) ?: return null
        return if (digits.length == 6) {
            (0xFF000000L or value).toInt()
        } else {
            val rgb = (value shr 8) and 0xFFFFFFL
            val alpha = value and 0xFFL
            ((alpha shl 24) or rgb).toInt()
        }
    }
}

private fun ReadableMap.getStringOrNull(key: String): String? =
    if (hasKey(key) && !isNull(key)) getString(key) else null

private fun ReadableMap.getIntOrNull(key: String): Int? =
    if (hasKey(key) && !isNull(key)) getInt(key) else null

private fun ReadableMap.getBooleanOrNull(key: String): Boolean? =
    if (hasKey(key) && !isNull(key)) getBoolean(key) else null

private fun ReadableMap.getMapOrNull(key: String): ReadableMap? =
    if (hasKey(key) && !isNull(key)) getMap(key) else null

private fun ReadableArray.toStringList(): List<String> {
    val out = ArrayList<String>(size())
    for (i in 0 until size()) {
        out.add(getString(i) ?: throw IllegalArgumentException("Expected a string at index $i."))
    }
    return out
}
