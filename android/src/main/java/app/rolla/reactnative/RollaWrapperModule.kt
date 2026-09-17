package app.rolla.reactnative

import android.app.Activity
import android.content.Intent
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.bridge.WritableArray
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
import com.rolla.sdk.wrapper.features.activity.RollaCompletedActivity
import com.rolla.sdk.wrapper.features.activity.RollaRemovedActivity
import com.rolla.sdk.wrapper.features.activity.RollaStartedActivity
import com.rolla.sdk.wrapper.features.band.RollaBandInfo
import com.rolla.sdk.wrapper.features.band.RollaBatteryResult
import com.rolla.sdk.wrapper.features.band.RollaPairedBandResult
import com.rolla.sdk.wrapper.features.goals.RollaGoalInfo
import com.rolla.sdk.wrapper.features.goals.RollaGoalsChanged
import com.rolla.sdk.wrapper.features.navigation.RollaScreen
import com.rolla.sdk.wrapper.features.notifications.RollaNotificationTarget
import com.rolla.sdk.wrapper.features.profile.RollaProfileUpdated
import com.rolla.sdk.wrapper.features.session.RollaCloseReason
import com.rolla.sdk.wrapper.features.session.RollaError
import com.rolla.sdk.wrapper.features.sync.RollaPrimarySourceChanged
import com.rolla.sdk.wrapper.features.sync.RollaSyncResult
import com.rolla.sdk.wrapper.features.sync.RollaSyncedHealthData
import com.rolla.sdk.wrapper.features.sync.RollaSyncedSamples
import com.rolla.sdk.wrapper.features.sync.RollaSyncedStreamSummary
import java.time.format.DateTimeFormatter
import java.util.Date

/**
 * React Native TurboModule over the Rolla Android SDK.
 *
 * Every entry point builds a `Rolla` instance from the configuration it is
 * given — the way a native host calls the SDK — and wires this module as its
 * listener. The SDK delivers events for the engine's lifetime to the last
 * listener wired, so events keep flowing after the SDK UI closes.
 */
class RollaWrapperModule(reactContext: ReactApplicationContext) :
    NativeRollaWrapperSpec(reactContext), LifecycleEventListener, ActivityEventListener {

    /**
     * The most recently created instance — the target of `dismiss`,
     * `updateToken` and `clearSession`, exactly like a native host that keeps
     * its latest `Rolla`. It outlives the SDK UI: the engine keeps running
     * after a close, so token pushes and session clears must keep working
     * until `destroyEngine()` tears the engine down (which nulls this).
     */
    private var rolla: Rolla? = null

    /**
     * JS subscriptions currently attached through `NativeEventEmitter`, which
     * calls [addListener] / [removeListeners] on this module. A notification
     * tap that arrives while nothing listens is queued for
     * `getInitialNotificationTarget()` instead of being dropped.
     */
    private var listenerCount = 0

    private var pendingNotificationTarget: WritableMap? = null

    init {
        reactContext.addLifecycleEventListener(this)
        reactContext.addActivityEventListener(this)
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

    // region Presentation

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

                val rollaTransition = RollaConfigurationParser.transition(transition)
                val instance = makeInstance(config)
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
                promise.reject("NO_ACTIVE_SESSION", noActiveSessionMessage("updateToken"))
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

    /**
     * Purges the SDK's persisted session. The native call needs a running
     * engine, so on a cold engine the SDK's documented recipe is "warm up,
     * then clear": with a `config` this does exactly that; without one a cold
     * engine is reported as `NO_ACTIVE_SESSION` instead of being mistaken for
     * a successful clear.
     */
    override fun clearSession(config: ReadableMap?, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val current = rolla
            if (current != null) {
                current.clearSession { result ->
                    result.onSuccess { promise.resolve(null) }
                        .onFailure { promise.reject("CLEAR_SESSION_FAILED", it.message, it) }
                }
                return@runOnUiThread
            }
            if (config == null) {
                promise.reject("NO_ACTIVE_SESSION", noActiveSessionMessage("clearSession"))
                return@runOnUiThread
            }
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.warmUpEngine(reactApplicationContext) { warmUp ->
                warmUp.onFailure { promise.rejectSdk(it) }
                    .onSuccess {
                        instance.clearSession { result ->
                            result.onSuccess { promise.resolve(null) }
                                .onFailure { promise.reject("CLEAR_SESSION_FAILED", it.message, it) }
                        }
                    }
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

    // endregion

    // region Headless

    override fun warmUpEngine(config: ReadableMap, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.warmUpEngine(reactApplicationContext) { result ->
                result.onSuccess { promise.resolve(null) }
                    .onFailure { promise.rejectSdk(it) }
            }
        }
    }

    override fun syncHealthData(config: ReadableMap, includeSamples: Boolean, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.syncHealthData(reactApplicationContext, includeSamples) { result ->
                result.onSuccess { promise.resolve(RollaPayloadEncoder.encode(it)) }
                    .onFailure { promise.rejectSdk(it) }
            }
        }
    }

    override fun getBandBatteryLevel(config: ReadableMap, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.getBandBatteryLevel(reactApplicationContext) { result ->
                result.onSuccess { promise.resolve(RollaPayloadEncoder.encode(it)) }
                    .onFailure { promise.rejectSdk(it) }
            }
        }
    }

    override fun getPairedBandInfo(config: ReadableMap, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.getPairedBandInfo(reactApplicationContext) { result ->
                result.onSuccess { promise.resolve(RollaPayloadEncoder.encode(it)) }
                    .onFailure { promise.rejectSdk(it) }
            }
        }
    }

    // endregion

    // region Navigation and notifications

    override fun openScreen(config: ReadableMap, screen: String, transition: String, promise: Promise) {
        val activity = reactApplicationContext.currentActivity
            ?: return promise.reject("NO_ACTIVITY", "RollaWrapper.openScreen requires a foreground activity.")

        UiThreadUtil.runOnUiThread {
            val rollaScreen = RollaScreen.entries.firstOrNull { it.rawValue == screen }
            if (rollaScreen == null) {
                promise.reject("INVALID_CONFIG", "Unknown screen '$screen'.")
                return@runOnUiThread
            }
            val rollaTransition = try {
                RollaConfigurationParser.transition(transition)
            } catch (e: IllegalArgumentException) {
                promise.reject("INVALID_CONFIG", e.message ?: "Invalid transition.", e)
                return@runOnUiThread
            }
            val instance = makeInstanceOrReject(config, promise) ?: return@runOnUiThread
            instance.openScreen(activity, rollaScreen, rollaTransition) { status ->
                promise.resolve(status.rawValue)
            }
        }
    }

    /**
     * The queued tap first, otherwise the tap that launched the current
     * activity; both are consumed on read so a later call (a re-login, a JS
     * reload) does not replay the same tap.
     */
    override fun getInitialNotificationTarget(promise: Promise) {
        val pending = pendingNotificationTarget
        if (pending != null) {
            pendingNotificationTarget = null
            promise.resolve(pending)
            return
        }
        val intent = reactApplicationContext.currentActivity?.intent
        val target = intent?.let { Rolla.notificationTarget(it) }
        if (target != null) {
            intent.removeExtra(NOTIFICATION_PAYLOAD_EXTRA)
        }
        promise.resolve(RollaPayloadEncoder.encode(target))
    }

    override fun notificationTarget(payload: ReadableMap, promise: Promise) {
        val intent = Intent()
        payload.getStringOrNull(NOTIFICATION_PAYLOAD_EXTRA)?.let { intent.putExtra(NOTIFICATION_PAYLOAD_EXTRA, it) }
        promise.resolve(RollaPayloadEncoder.encode(Rolla.notificationTarget(intent)))
    }

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {}

    /** A notification tap while the app is running re-delivers the launch intent here. */
    override fun onNewIntent(intent: Intent) {
        val target = Rolla.notificationTarget(intent) ?: return
        val payload = RollaPayloadEncoder.encode(target)
        if (listenerCount > 0) {
            emit("onNotificationTap", payload)
        } else {
            pendingNotificationTarget = payload
        }
    }

    // endregion

    override fun addListener(eventName: String) {
        listenerCount += 1
    }

    override fun removeListeners(count: Double) {
        listenerCount = maxOf(0, listenerCount - count.toInt())
    }

    /**
     * Builds a `Rolla` from the JS configuration, wires this module as its
     * listener and remembers it as the current instance.
     */
    private fun makeInstance(config: ReadableMap): Rolla {
        val instance = Rolla(RollaConfigurationParser.configuration(config))
        instance.listener = RollaListenerAdapter()
        rolla = instance
        return instance
    }

    private fun makeInstanceOrReject(config: ReadableMap, promise: Promise): Rolla? = try {
        makeInstance(config)
    } catch (e: IllegalArgumentException) {
        promise.reject("INVALID_CONFIG", e.message ?: "Invalid Rolla configuration.", e)
        null
    }

    private fun noActiveSessionMessage(method: String): String =
        "$method needs a running engine: call show(), openScreen(), warmUpEngine() or a headless method first."

    /** Rejects with the SDK's own error code; anything else is `UNKNOWN`. */
    private fun Promise.rejectSdk(error: Throwable) {
        val code = (error as? RollaError)?.code ?: "UNKNOWN"
        reject(code, error.message ?: "An unknown error occurred.", error)
    }

    private fun emit(event: String, payload: WritableMap?) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(event, payload)
    }

    private inner class RollaListenerAdapter : RollaListener {

        override fun onRollaClosed(rolla: Rolla, reason: RollaCloseReason) {
            // The instance is kept: the engine survives the close, and token
            // pushes, session clears and the observational events all continue
            // against it.
            emit("onClose", encodeReason(reason))
        }

        override fun onRollaError(rolla: Rolla, error: RollaError) {
            // A failed show() reaches here after the SDK has torn its
            // presentation down, so `isPresenting` is already false; an error
            // raised while the SDK UI is running leaves it true.
            // AlreadyPresenting is the one failure that leaves the flag true
            // for the *other* presentation, so it is special-cased.
            val presentationFailed = !rolla.isPresenting || error is RollaError.AlreadyPresenting
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

        override fun onSyncHealthDataCompleted(rolla: Rolla, result: RollaSyncResult) {
            emit("onSyncHealthDataCompleted", RollaPayloadEncoder.encode(result))
        }

        override fun onUiSyncCompleted(rolla: Rolla, result: RollaSyncResult) {
            emit("onUiSyncCompleted", RollaPayloadEncoder.encode(result))
        }

        override fun onActivityCompleted(rolla: Rolla, activity: RollaCompletedActivity) {
            emit("onActivityCompleted", RollaPayloadEncoder.encode(activity))
        }

        override fun onActivityStarted(rolla: Rolla, activity: RollaStartedActivity) {
            emit("onActivityStarted", RollaPayloadEncoder.encode(activity))
        }

        override fun onActivityRemoved(rolla: Rolla, activity: RollaRemovedActivity) {
            emit("onActivityRemoved", RollaPayloadEncoder.encode(activity))
        }

        override fun onBandPaired(rolla: Rolla, band: RollaBandInfo) {
            emit("onBandPaired", RollaPayloadEncoder.encode(band))
        }

        override fun onBandUnpaired(rolla: Rolla, band: RollaBandInfo) {
            emit("onBandUnpaired", RollaPayloadEncoder.encode(band))
        }

        override fun onBandConnected(rolla: Rolla, band: RollaBandInfo) {
            emit("onBandConnected", RollaPayloadEncoder.encode(band))
        }

        override fun onBandDisconnected(rolla: Rolla, band: RollaBandInfo) {
            emit("onBandDisconnected", RollaPayloadEncoder.encode(band))
        }

        override fun onPrimarySourceChanged(rolla: Rolla, change: RollaPrimarySourceChanged) {
            emit("onPrimarySourceChanged", RollaPayloadEncoder.encode(change))
        }

        override fun onGoalsChanged(rolla: Rolla, change: RollaGoalsChanged) {
            emit("onGoalsChanged", RollaPayloadEncoder.encode(change))
        }

        override fun onProfileUpdated(rolla: Rolla, update: RollaProfileUpdated) {
            emit("onProfileUpdated", RollaPayloadEncoder.encode(update))
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

        /** The intent extra the SDK's notification taps carry (`RollaNotificationTarget.PAYLOAD_EXTRA`). */
        private const val NOTIFICATION_PAYLOAD_EXTRA = "payload"
    }
}

/**
 * Encodes the SDK's typed payloads as JS-friendly maps. Dates become ISO-8601
 * strings; sample timestamps stay epoch milliseconds, as the SDK delivers
 * them; null fields are omitted.
 */
private object RollaPayloadEncoder {

    fun encode(result: RollaSyncResult): WritableMap = Arguments.createMap().apply {
        putString("outcome", result.outcome.rawValue)
        putBoolean("hasNewData", result.hasNewData)
        putString("source", result.source.rawValue)
        result.startedAt?.let { putString("startedAt", iso(it)) }
        result.lastSyncAt?.let { putString("lastSyncAt", iso(it)) }
        result.skipReason?.let { putString("skipReason", it.rawValue) }
        result.error?.let { putString("error", it) }
        result.syncedData?.let { putMap("syncedData", encode(it)) }
    }

    fun encode(data: RollaSyncedHealthData): WritableMap = Arguments.createMap().apply {
        putString("source", data.source.rawValue)
        putArray("syncedDates", Arguments.createArray().apply { data.syncedDates.forEach(::pushString) })
        data.batteryLevel?.let { putInt("batteryLevel", it) }
        data.heartRate?.let { putMap("heartRate", encode(it)) }
        data.hrv?.let { putMap("hrv", encode(it)) }
        data.steps?.let { putMap("steps", encode(it)) }
        data.sleep?.let { putMap("sleep", encode(it)) }
        data.weight?.let { putMap("weight", encode(it)) }
        data.bloodPressure?.let { putMap("bloodPressure", encode(it)) }
        data.workouts?.let { putMap("workouts", encode(it)) }
        data.samples?.let { putMap("samples", encode(it)) }
    }

    fun encode(summary: RollaSyncedStreamSummary): WritableMap = Arguments.createMap().apply {
        putInt("count", summary.count)
        summary.from?.let { putDouble("from", it.toDouble()) }
        summary.to?.let { putDouble("to", it.toDouble()) }
        summary.total?.let { putInt("total", it) }
        summary.blocks?.let { putInt("blocks", it) }
        summary.minutes?.let { putInt("minutes", it) }
    }

    fun encode(samples: RollaSyncedSamples): WritableMap = Arguments.createMap().apply {
        putArray("heartRate", samples.heartRate.toArray {
            putDouble("timestamp", it.timestamp.toDouble()); putInt("hr", it.hr)
        })
        putArray("hrv", samples.hrv.toArray {
            putDouble("timestamp", it.timestamp.toDouble()); putInt("hrv", it.hrv)
        })
        putArray("steps", samples.steps.toArray {
            putDouble("timestamp", it.timestamp.toDouble())
            putDouble("stepsDelta", it.stepsDelta)
            putDouble("caloriesDelta", it.caloriesDelta)
        })
        putArray("sleep", samples.sleep.toArray {
            putDouble("startTime", it.startTime.toDouble())
            putDouble("endTime", it.endTime.toDouble())
            putString("stage", it.stage)
        })
        putArray("weight", samples.weight.toArray {
            putDouble("timestamp", it.timestamp.toDouble()); putDouble("weight", it.weight)
        })
        putArray("bloodPressure", samples.bloodPressure.toArray {
            putDouble("timestamp", it.timestamp.toDouble())
            putInt("systolic", it.systolic)
            putInt("diastolic", it.diastolic)
        })
    }

    fun encode(activity: RollaCompletedActivity): WritableMap = Arguments.createMap().apply {
        putString("activityId", activity.activityId)
        putString("phase", activity.phase.rawValue)
        putString("source", activity.source.rawValue)
        activity.catalogId?.let { putString("catalogId", it) }
        activity.type?.let { putString("type", it) }
        activity.environment?.let { putString("environment", it) }
        activity.category?.let { putString("category", it) }
        activity.totalDurationS?.let { putInt("totalDurationS", it) }
        activity.totalDistanceM?.let { putDouble("totalDistanceM", it) }
        activity.totalCalories?.let { putDouble("totalCalories", it) }
        activity.startTime?.let { putString("startTime", iso(it)) }
        activity.endTime?.let { putString("endTime", iso(it)) }
    }

    fun encode(activity: RollaStartedActivity): WritableMap = Arguments.createMap().apply {
        putString("activityId", activity.activityId)
        putString("origin", activity.origin.rawValue)
        activity.type?.let { putString("type", it) }
        activity.startTime?.let { putString("startTime", iso(it)) }
        activity.catalogId?.let { putString("catalogId", it) }
    }

    fun encode(activity: RollaRemovedActivity): WritableMap = Arguments.createMap().apply {
        putString("activityId", activity.activityId)
        putString("reason", activity.reason.rawValue)
    }

    fun encode(band: RollaBandInfo): WritableMap = Arguments.createMap().apply {
        putString("macAddress", band.macAddress)
        band.name?.let { putString("name", it) }
        band.rssi?.let { putInt("rssi", it) }
        band.deviceType?.let { putString("deviceType", it) }
        band.batteryPercent?.let { putInt("batteryPercent", it) }
        band.firmwareVersion?.let { putString("firmwareVersion", it) }
        band.serialNumber?.let { putString("serialNumber", it) }
    }

    fun encode(battery: RollaBatteryResult): WritableMap = Arguments.createMap().apply {
        putString("status", battery.status.rawValue)
        battery.level?.let { putInt("level", it) }
    }

    fun encode(paired: RollaPairedBandResult): WritableMap = Arguments.createMap().apply {
        putString("status", paired.status.rawValue)
        paired.band?.let { putMap("band", encode(it)) }
    }

    fun encode(change: RollaPrimarySourceChanged): WritableMap = Arguments.createMap().apply {
        putString("previousSource", change.previousSource.rawValue)
        putString("currentSource", change.currentSource.rawValue)
    }

    fun encode(change: RollaGoalsChanged): WritableMap = Arguments.createMap().apply {
        putArray("changedGoals", change.changedGoals.toArray { encodeGoal(it) })
        putArray("enabledGoals", change.enabledGoals.toArray { encodeGoal(it) })
    }

    private fun WritableMap.encodeGoal(goal: RollaGoalInfo) {
        putInt("id", goal.id)
        putString("name", goal.name)
        putBoolean("enabled", goal.enabled)
    }

    fun encode(update: RollaProfileUpdated): WritableMap = Arguments.createMap().apply {
        // The SDK hands over Flutter-codec values (numbers, strings, lists,
        // maps, null); anything else is passed on as its string form.
        putMap("changedFields", Arguments.createMap().also { fields ->
            update.changedFields.forEach { (key, value) -> fields.putAny(key, value) }
        })
    }

    /** `{ kind: "none" }` when the notification is not one of Rolla's. */
    fun encode(target: RollaNotificationTarget?): WritableMap = Arguments.createMap().apply {
        when (target) {
            null -> putString("kind", "none")
            RollaNotificationTarget.AppSettings -> putString("kind", "appSettings")
            is RollaNotificationTarget.Screen -> {
                putString("kind", "screen")
                putString("screen", target.screen.rawValue)
            }
        }
    }

    private fun iso(date: Date): String = DateTimeFormatter.ISO_INSTANT.format(date.toInstant())

    private fun <T> List<T>.toArray(fill: WritableMap.(T) -> Unit): WritableArray =
        Arguments.createArray().also { array ->
            forEach { item -> array.pushMap(Arguments.createMap().apply { fill(item) }) }
        }

    private fun WritableMap.putAny(key: String, value: Any?) {
        when (value) {
            null -> putNull(key)
            is Boolean -> putBoolean(key, value)
            is Int -> putInt(key, value)
            is Number -> putDouble(key, value.toDouble())
            is String -> putString(key, value)
            is Map<*, *> -> putMap(key, Arguments.createMap().also { nested ->
                value.forEach { (k, v) -> nested.putAny(k.toString(), v) }
            })
            is Iterable<*> -> putArray(key, Arguments.createArray().also { array ->
                value.forEach { array.pushAny(it) }
            })
            else -> putString(key, value.toString())
        }
    }

    private fun WritableArray.pushAny(value: Any?) {
        when (value) {
            null -> pushNull()
            is Boolean -> pushBoolean(value)
            is Int -> pushInt(value)
            is Number -> pushDouble(value.toDouble())
            is String -> pushString(value)
            is Map<*, *> -> pushMap(Arguments.createMap().also { nested ->
                value.forEach { (k, v) -> nested.putAny(k.toString(), v) }
            })
            is Iterable<*> -> pushArray(Arguments.createArray().also { array ->
                value.forEach { array.pushAny(it) }
            })
            else -> pushString(value.toString())
        }
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
