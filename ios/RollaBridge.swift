import Foundation
import UIKit
import UserNotifications
import RollaSDK

/// ObjC-callable protocol the TurboModule (`RollaWrapper.mm`) implements to
/// receive lifecycle events from the Swift Rolla SDK. Mirrors `RollaDelegate`
/// but with primitive ObjC-compatible types only.
@objc public protocol RollaBridgeListener: AnyObject {
  func rollaBridgeDidClose(reason: String, detail: String?)
  /// `presentationFailed` is true when the error ended a pending `show()`: no
  /// SDK UI is on screen and no close event will follow. It is false for
  /// errors raised while the SDK UI is running.
  func rollaBridgeDidFail(code: String, message: String, presentationFailed: Bool)
  func rollaBridgeDidRefreshToken(token: String, refreshToken: String?, expiresIn: NSNumber?)
  func rollaBridgeDidRequestTokenRefresh()
  /// An observational SDK event, already encoded as a JSON-friendly dictionary.
  /// `name` is the JS event name (`onActivityCompleted`, `onBandPaired`, …).
  func rollaBridgeDidReceiveEvent(name: String, payload: [String: Any])
  /// A tap on one of the SDK's notifications. Returns whether JS received it;
  /// when it did not, the target is kept for `getInitialNotificationTarget()`.
  func rollaBridgeDidReceiveNotificationTap(payload: [String: Any]) -> Bool
}

/// Raised while translating the JS configuration or when the SDK UI is already
/// on screen. Bridges to ObjC as an `NSError` whose `userInfo["code"]` carries
/// the React Native rejection code.
struct RollaBridgeError: CustomNSError, LocalizedError {
  static let errorDomain = "RollaWrapper"
  static let codeUserInfoKey = "code"

  let code: String
  let message: String

  var errorCode: Int { 0 }
  var errorDescription: String? { message }
  var errorUserInfo: [String: Any] {
    [Self.codeUserInfoKey: code, NSLocalizedDescriptionKey: message]
  }

  static func invalidConfig(_ message: String) -> RollaBridgeError {
    RollaBridgeError(code: "INVALID_CONFIG", message: message)
  }

  /// A call that needs a running engine was made while no engine has been
  /// started in this process (or after `destroyEngine()`).
  static func noActiveSession(_ method: String) -> RollaBridgeError {
    RollaBridgeError(
      code: "NO_ACTIVE_SESSION",
      message: "\(method) needs a running engine: call show(), openScreen(), warmUpEngine() or a headless method first."
    )
  }

  /// The SDK's own error, carrying its `RollaError.code` as the JS rejection code.
  static func sdk(_ error: RollaError) -> RollaBridgeError {
    RollaBridgeError(code: error.code, message: error.errorDescription ?? "An unknown error occurred.")
  }
}

/// Thin ObjC-callable shim over the Swift-only RollaSDK API. The actual
/// React Native TurboModule lives in `RollaWrapper.mm`; this class only
/// exists because the SDK's surface is Swift-only and Swift cannot import
/// the codegen ObjC++ header `<RollaWrapperSpec/RollaWrapperSpec.h>`.
///
/// All public methods take/return primitive ObjC-compatible types so the
/// `.mm` can call them without bridging headers.
///
/// Every entry point builds a `Rolla` instance from the configuration it is
/// given — the way a native host calls the SDK — and wires this bridge as its
/// delegate. The SDK delivers events for the engine's lifetime to the last
/// delegate wired, so events keep flowing after the SDK UI closes.
@objc(RollaBridge)
public class RollaBridge: NSObject {

  @objc public weak var listener: RollaBridgeListener?

  /// The most recently created instance — the target of `dismiss`,
  /// `updateToken` and `clearSession`, exactly like a native host that keeps
  /// its latest `Rolla`. It outlives the SDK UI: the engine keeps running after
  /// a close, so token pushes and session clears must keep working until
  /// `destroyEngine()` tears the engine down (which is when this becomes nil).
  private var rolla: Rolla?

  // MARK: - Presentation

  @objc public var isPresenting: Bool {
    rolla?.isPresenting ?? false
  }

  /// Presents the SDK UI. Throws a `RollaBridgeError` when the configuration is
  /// invalid or the SDK UI is already on screen. A failure after this returns
  /// (engine start-up, SDK initialization) is reported asynchronously through
  /// `rollaBridgeDidFail(presentationFailed: true)`.
  @objc public func show(
    config: [String: Any],
    transition transitionName: String,
    presenter: UIViewController
  ) throws {
    if let existing = rolla, existing.isPresenting {
      throw RollaBridgeError(
        code: "ALREADY_PRESENTING",
        message: "Rolla is already presenting. Dismiss it before calling show() again."
      )
    }

    let transition = try RollaConfigurationParser.transition(named: transitionName)
    let instance = try makeInstance(config: config)
    instance.show(from: presenter, transition: transition)
  }

  @objc public func dismiss() {
    rolla?.dismiss()
  }

  /// Pushes fresh credentials to the running engine. Like the native SDK, this
  /// needs an engine that some earlier call started; on a cold engine the
  /// caller should pass the newest pair in its next configuration instead.
  /// - Parameter completion: `nil` on success, otherwise an `NSError` carrying
  ///   the JS rejection code in `userInfo["code"]` (`NO_ACTIVE_SESSION` when
  ///   the engine is cold, the SDK's `RollaError.code` otherwise).
  @objc public func updateToken(
    _ token: String,
    refreshToken: String?,
    expiresIn: NSNumber?,
    completion: @escaping (NSError?) -> Void
  ) {
    guard let rolla else {
      completion(RollaBridgeError.noActiveSession("updateToken") as NSError)
      return
    }
    rolla.updateToken(
      token: token,
      refreshToken: refreshToken,
      expiresIn: expiresIn?.doubleValue
    ) { result in
      switch result {
      case .success:            completion(nil)
      case .failure(let error): completion(RollaBridgeError.sdk(error) as NSError)
      }
    }
  }

  /// Purges the SDK's persisted session. The native call needs a running
  /// engine, so on a cold engine the SDK's documented recipe is "warm up,
  /// then clear": when `config` is given the bridge does exactly that; without
  /// it a cold engine is reported as `NO_ACTIVE_SESSION` instead of being
  /// mistaken for a successful clear.
  /// - Parameter completion: `nil` on success, otherwise an `NSError` carrying
  ///   the JS rejection code in `userInfo["code"]`.
  @objc public func clearSession(
    config: [String: Any]?,
    completion: @escaping (NSError?) -> Void
  ) {
    if let rolla {
      rolla.clearSession { result in
        switch result {
        case .success:            completion(nil)
        case .failure(let error): completion(RollaBridgeError.sdk(error) as NSError)
        }
      }
      return
    }
    guard let config else {
      completion(RollaBridgeError.noActiveSession("clearSession") as NSError)
      return
    }
    warmUpEngine(config: config) { [weak self] error in
      if let error {
        completion(error)
        return
      }
      guard let self, let rolla = self.rolla else {
        completion(RollaBridgeError.noActiveSession("clearSession") as NSError)
        return
      }
      rolla.clearSession { result in
        switch result {
        case .success:            completion(nil)
        case .failure(let error): completion(RollaBridgeError.sdk(error) as NSError)
        }
      }
    }
  }

  @objc public func destroyEngine() {
    Rolla.destroyEngine()
    rolla = nil
  }

  @objc public func invalidate() {
    rolla?.dismiss()
    rolla = nil
  }

  // MARK: - Headless

  /// - Parameter completion: `nil` on success, otherwise an `NSError` carrying
  ///   the JS rejection code in `userInfo["code"]`.
  @objc public func warmUpEngine(
    config: [String: Any],
    completion: @escaping (NSError?) -> Void
  ) {
    let instance: Rolla
    do {
      instance = try makeInstance(config: config)
    } catch {
      completion(error as NSError)
      return
    }
    instance.warmUpEngine { result in
      switch result {
      case .success:            completion(nil)
      case .failure(let error): completion(RollaBridgeError.sdk(error) as NSError)
      }
    }
  }

  @objc public func syncHealthData(
    config: [String: Any],
    includeSamples: Bool,
    completion: @escaping ([String: Any]?, NSError?) -> Void
  ) {
    let instance: Rolla
    do {
      instance = try makeInstance(config: config)
    } catch {
      completion(nil, error as NSError)
      return
    }
    instance.syncHealthData(includeSamples: includeSamples) { result in
      switch result {
      case .success(let sync):  completion(RollaPayloadEncoder.encode(sync), nil)
      case .failure(let error): completion(nil, RollaBridgeError.sdk(error) as NSError)
      }
    }
  }

  @objc public func getBandBatteryLevel(
    config: [String: Any],
    completion: @escaping ([String: Any]?, NSError?) -> Void
  ) {
    let instance: Rolla
    do {
      instance = try makeInstance(config: config)
    } catch {
      completion(nil, error as NSError)
      return
    }
    instance.getBandBatteryLevel { result in
      switch result {
      case .success(let battery): completion(RollaPayloadEncoder.encode(battery), nil)
      case .failure(let error):   completion(nil, RollaBridgeError.sdk(error) as NSError)
      }
    }
  }

  @objc public func getPairedBandInfo(
    config: [String: Any],
    completion: @escaping ([String: Any]?, NSError?) -> Void
  ) {
    let instance: Rolla
    do {
      instance = try makeInstance(config: config)
    } catch {
      completion(nil, error as NSError)
      return
    }
    instance.getPairedBandInfo { result in
      switch result {
      case .success(let paired): completion(RollaPayloadEncoder.encode(paired), nil)
      case .failure(let error):  completion(nil, RollaBridgeError.sdk(error) as NSError)
      }
    }
  }

  // MARK: - Navigation

  /// - Parameter completion: the `RollaOpenScreenStatus` raw value, or an
  ///   `NSError` when the configuration or screen name is invalid.
  @objc public func openScreen(
    config: [String: Any],
    screen screenName: String,
    transition transitionName: String,
    presenter: UIViewController,
    completion: @escaping (String?, NSError?) -> Void
  ) {
    let instance: Rolla
    let screen: RollaScreen
    let transition: RollaTransition
    do {
      guard let parsedScreen = RollaScreen(rawValue: screenName) else {
        throw RollaBridgeError.invalidConfig("Unknown screen '\(screenName)'.")
      }
      screen = parsedScreen
      transition = try RollaConfigurationParser.transition(named: transitionName)
      instance = try makeInstance(config: config)
    } catch {
      completion(nil, error as NSError)
      return
    }
    instance.openScreen(screen, from: presenter, transition: transition) { status in
      completion(status.rawValue, nil)
    }
  }

  // MARK: - Helpers

  /// Builds a `Rolla` from the JS configuration, wires this bridge as its
  /// delegate and remembers it as the current instance.
  private func makeInstance(config: [String: Any]) throws -> Rolla {
    let configuration = try RollaConfigurationParser.configuration(from: config)
    let instance = Rolla(configuration: configuration)
    instance.delegate = self
    rolla = instance
    return instance
  }

  private func emit(_ name: String, _ payload: [String: Any]) {
    listener?.rollaBridgeDidReceiveEvent(name: name, payload: payload)
  }
}

// MARK: - RollaDelegate

extension RollaBridge: RollaDelegate {

  public func rollaDidClose(_ rolla: Rolla, reason: RollaCloseReason) {
    // The instance is kept: the engine survives the close, and token pushes,
    // session clears and the observational events all continue against it.
    let key: String
    var detail: String?
    switch reason {
    case .flutterRequested(let r):
      key = "flutterRequested"
      detail = r
    case .hostNavigationBack:  key = "hostNavigationBack"
    case .hostModalDismiss:    key = "hostModalDismiss"
    case .programmatic:        key = "programmatic"
    case .hostStackReplaced:   key = "hostStackReplaced"
    case .unknown:             key = "unknown"
    // RollaCloseReason is a non-frozen library enum: a reason added by a
    // newer SDK must not crash the bridge.
    @unknown default:          key = "unknown"
    }
    listener?.rollaBridgeDidClose(reason: key, detail: detail)
  }

  public func rollaDidFailWithError(_ rolla: Rolla, error: RollaError) {
    // A failed show() reaches here after the SDK has torn its presentation
    // down, so `isPresenting` is already false; an error raised while the SDK
    // UI is running leaves it true. `.alreadyPresenting` is the one failure
    // that leaves the flag true for the *other* presentation, so it is
    // special-cased.
    var presentationFailed = !rolla.isPresenting
    if case .alreadyPresenting = error {
      presentationFailed = true
    }
    listener?.rollaBridgeDidFail(
      code: error.code,
      message: error.errorDescription ?? "",
      presentationFailed: presentationFailed
    )
  }

  public func rollaDidRefreshToken(
    _ rolla: Rolla,
    token: String,
    refreshToken: String?,
    expiresIn: TimeInterval?
  ) {
    let n: NSNumber? = expiresIn.map { NSNumber(value: $0) }
    listener?.rollaBridgeDidRefreshToken(token: token, refreshToken: refreshToken, expiresIn: n)
  }

  public func rollaDidRequestTokenRefresh(_ rolla: Rolla) {
    listener?.rollaBridgeDidRequestTokenRefresh()
  }

  public func rollaDidCompleteHealthDataSync(_ rolla: Rolla, result: RollaSyncResult) {
    emit("onSyncHealthDataCompleted", RollaPayloadEncoder.encode(result))
  }

  public func rollaDidCompleteUISync(_ rolla: Rolla, result: RollaSyncResult) {
    emit("onUiSyncCompleted", RollaPayloadEncoder.encode(result))
  }

  public func rollaDidCompleteActivity(_ rolla: Rolla, activity: RollaCompletedActivity) {
    emit("onActivityCompleted", RollaPayloadEncoder.encode(activity))
  }

  public func rollaDidStartActivity(_ rolla: Rolla, activity: RollaStartedActivity) {
    emit("onActivityStarted", RollaPayloadEncoder.encode(activity))
  }

  public func rollaDidRemoveActivity(_ rolla: Rolla, activity: RollaRemovedActivity) {
    emit("onActivityRemoved", RollaPayloadEncoder.encode(activity))
  }

  public func rollaDidPairBand(_ rolla: Rolla, band: RollaBandInfo) {
    emit("onBandPaired", RollaPayloadEncoder.encode(band))
  }

  public func rollaDidUnpairBand(_ rolla: Rolla, band: RollaBandInfo) {
    emit("onBandUnpaired", RollaPayloadEncoder.encode(band))
  }

  public func rollaDidConnectBand(_ rolla: Rolla, band: RollaBandInfo) {
    emit("onBandConnected", RollaPayloadEncoder.encode(band))
  }

  public func rollaDidDisconnectBand(_ rolla: Rolla, band: RollaBandInfo) {
    emit("onBandDisconnected", RollaPayloadEncoder.encode(band))
  }

  public func rollaDidChangePrimarySource(_ rolla: Rolla, change: RollaPrimarySourceChanged) {
    emit("onPrimarySourceChanged", RollaPayloadEncoder.encode(change))
  }

  public func rollaDidChangeGoals(_ rolla: Rolla, change: RollaGoalsChanged) {
    emit("onGoalsChanged", RollaPayloadEncoder.encode(change))
  }

  public func rollaDidUpdateProfile(_ rolla: Rolla, update: RollaProfileUpdated) {
    emit("onProfileUpdated", RollaPayloadEncoder.encode(update))
  }
}

/// `RollaDelegate` ships a no-op default for every requirement, so if the SDK
/// renames one, a conformance written against the old name still compiles and
/// the callback silently goes nowhere. Referencing each requirement we rely on
/// by name turns that rename into a compile error here instead.
private let rollaDelegateRequirementsCheck: (RollaDelegate) -> Void = { delegate in
  _ = delegate.rollaDidClose(_:reason:)
  _ = delegate.rollaDidFailWithError(_:error:)
  _ = delegate.rollaDidRefreshToken(_:token:refreshToken:expiresIn:)
  _ = delegate.rollaDidRequestTokenRefresh(_:)
  _ = delegate.rollaDidCompleteHealthDataSync(_:result:)
  _ = delegate.rollaDidCompleteUISync(_:result:)
  _ = delegate.rollaDidCompleteActivity(_:activity:)
  _ = delegate.rollaDidStartActivity(_:activity:)
  _ = delegate.rollaDidRemoveActivity(_:activity:)
  _ = delegate.rollaDidPairBand(_:band:)
  _ = delegate.rollaDidUnpairBand(_:band:)
  _ = delegate.rollaDidConnectBand(_:band:)
  _ = delegate.rollaDidDisconnectBand(_:band:)
  _ = delegate.rollaDidChangePrimarySource(_:change:)
  _ = delegate.rollaDidChangeGoals(_:change:)
  _ = delegate.rollaDidUpdateProfile(_:update:)
}

// MARK: - Notification taps

/// Entry point for the host's `UNUserNotificationCenterDelegate`. The Rolla SDK
/// never claims the notification-center delegate, so the host forwards taps:
///
///     func userNotificationCenter(_ center: UNUserNotificationCenter,
///                                 didReceive response: UNNotificationResponse,
///                                 withCompletionHandler completionHandler: @escaping () -> Void) {
///       _ = RollaBridgeNotifications.handle(response: response)
///       completionHandler()
///     }
///
/// A tap while JS is listening arrives as the `onNotificationTap` event; one
/// that JS is not ready for (cold start) is kept for
/// `Rolla.getInitialNotificationTarget()`.
@objc(RollaBridgeNotifications)
public final class RollaBridgeNotifications: NSObject {

  /// The module currently alive, set by `RollaWrapper.mm`.
  @objc public static weak var listener: RollaBridgeListener?

  private static var pendingTarget: [String: Any]?

  /// - Returns: whether the notification was one of Rolla's.
  @objc(handleResponse:)
  @discardableResult
  public static func handle(response: UNNotificationResponse) -> Bool {
    handle(userInfo: response.notification.request.content.userInfo)
  }

  /// - Returns: whether the notification was one of Rolla's.
  @objc(handleUserInfo:)
  @discardableResult
  public static func handle(userInfo: [AnyHashable: Any]) -> Bool {
    guard let target = Rolla.notificationTarget(userInfo: userInfo) else { return false }
    let payload = RollaPayloadEncoder.encode(target)
    let delivered = listener?.rollaBridgeDidReceiveNotificationTap(payload: payload) ?? false
    if !delivered {
      pendingTarget = payload
    }
    return true
  }

  /// The queued tap, cleared on read; `{ kind: "none" }` when there is none.
  @objc public static func consumePendingTarget() -> [String: Any] {
    defer { pendingTarget = nil }
    return pendingTarget ?? RollaPayloadEncoder.noNotificationTarget
  }

  /// Whether a notification is one of Rolla's — for the host's `willPresent`
  /// decision (the SDK's notifications should show as banners in the foreground).
  @objc(isRollaNotification:)
  public static func isRollaNotification(_ notification: UNNotification) -> Bool {
    Rolla.notificationTarget(userInfo: notification.request.content.userInfo) != nil
  }

  /// Resolves a notification's user-info dictionary without touching the queue.
  @objc(resolveUserInfo:)
  public static func resolve(userInfo: [AnyHashable: Any]) -> [String: Any] {
    guard let target = Rolla.notificationTarget(userInfo: userInfo) else {
      return RollaPayloadEncoder.noNotificationTarget
    }
    return RollaPayloadEncoder.encode(target)
  }
}

// MARK: - Payload encoding

/// Encodes the SDK's typed payloads as JSON-friendly dictionaries for JS. Dates
/// become ISO-8601 strings; sample timestamps stay epoch milliseconds, as the
/// SDK delivers them; nil fields are omitted.
private enum RollaPayloadEncoder {

  static let noNotificationTarget: [String: Any] = ["kind": "none"]

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func put(_ dict: inout [String: Any], _ key: String, _ value: Any?) {
    if let value { dict[key] = value }
  }

  private static func iso(_ date: Date?) -> String? {
    date.map { iso8601.string(from: $0) }
  }

  static func encode(_ result: RollaSyncResult) -> [String: Any] {
    var dict: [String: Any] = [
      "outcome": result.outcome.rawValue,
      "hasNewData": result.hasNewData,
      "source": result.source.rawValue,
    ]
    put(&dict, "startedAt", iso(result.startedAt))
    put(&dict, "lastSyncAt", iso(result.lastSyncAt))
    put(&dict, "skipReason", result.skipReason?.rawValue)
    put(&dict, "error", result.error)
    put(&dict, "syncedData", result.syncedData.map(encode))
    return dict
  }

  static func encode(_ data: RollaSyncedHealthData) -> [String: Any] {
    var dict: [String: Any] = [
      "source": data.source.rawValue,
      "syncedDates": data.syncedDates,
    ]
    put(&dict, "batteryLevel", data.batteryLevel)
    put(&dict, "heartRate", data.heartRate.map(encode))
    put(&dict, "hrv", data.hrv.map(encode))
    put(&dict, "steps", data.steps.map(encode))
    put(&dict, "sleep", data.sleep.map(encode))
    put(&dict, "weight", data.weight.map(encode))
    put(&dict, "bloodPressure", data.bloodPressure.map(encode))
    put(&dict, "workouts", data.workouts.map(encode))
    put(&dict, "samples", data.samples.map(encode))
    return dict
  }

  static func encode(_ summary: RollaSyncedStreamSummary) -> [String: Any] {
    var dict: [String: Any] = ["count": summary.count]
    put(&dict, "from", summary.from)
    put(&dict, "to", summary.to)
    put(&dict, "total", summary.total)
    put(&dict, "blocks", summary.blocks)
    put(&dict, "minutes", summary.minutes)
    return dict
  }

  static func encode(_ samples: RollaSyncedSamples) -> [String: Any] {
    [
      "heartRate": samples.heartRate.map { ["timestamp": $0.timestamp, "hr": $0.hr] },
      "hrv": samples.hrv.map { ["timestamp": $0.timestamp, "hrv": $0.hrv] },
      "steps": samples.steps.map {
        ["timestamp": $0.timestamp, "stepsDelta": $0.stepsDelta, "caloriesDelta": $0.caloriesDelta]
      },
      "sleep": samples.sleep.map {
        ["startTime": $0.startTime, "endTime": $0.endTime, "stage": $0.stage]
      },
      "weight": samples.weight.map { ["timestamp": $0.timestamp, "weight": $0.weight] },
      "bloodPressure": samples.bloodPressure.map {
        ["timestamp": $0.timestamp, "systolic": $0.systolic, "diastolic": $0.diastolic]
      },
    ]
  }

  static func encode(_ activity: RollaCompletedActivity) -> [String: Any] {
    var dict: [String: Any] = [
      "activityId": activity.activityId,
      "phase": activity.phase.rawValue,
      "source": activity.source.rawValue,
    ]
    put(&dict, "catalogId", activity.catalogId)
    put(&dict, "type", activity.type)
    put(&dict, "environment", activity.environment)
    put(&dict, "category", activity.category)
    put(&dict, "totalDurationS", activity.totalDurationS)
    put(&dict, "totalDistanceM", activity.totalDistanceM)
    put(&dict, "totalCalories", activity.totalCalories)
    put(&dict, "startTime", iso(activity.startTime))
    put(&dict, "endTime", iso(activity.endTime))
    return dict
  }

  static func encode(_ activity: RollaStartedActivity) -> [String: Any] {
    var dict: [String: Any] = [
      "activityId": activity.activityId,
      "origin": activity.origin.rawValue,
    ]
    put(&dict, "type", activity.type)
    put(&dict, "startTime", iso(activity.startTime))
    put(&dict, "catalogId", activity.catalogId)
    return dict
  }

  static func encode(_ activity: RollaRemovedActivity) -> [String: Any] {
    ["activityId": activity.activityId, "reason": activity.reason.rawValue]
  }

  static func encode(_ band: RollaBandInfo) -> [String: Any] {
    var dict: [String: Any] = ["macAddress": band.macAddress]
    put(&dict, "name", band.name)
    put(&dict, "rssi", band.rssi)
    put(&dict, "deviceType", band.deviceType)
    put(&dict, "batteryPercent", band.batteryPercent)
    put(&dict, "firmwareVersion", band.firmwareVersion)
    put(&dict, "serialNumber", band.serialNumber)
    return dict
  }

  static func encode(_ battery: RollaBatteryResult) -> [String: Any] {
    var dict: [String: Any] = ["status": battery.status.rawValue]
    put(&dict, "level", battery.level)
    return dict
  }

  static func encode(_ paired: RollaPairedBandResult) -> [String: Any] {
    var dict: [String: Any] = ["status": paired.status.rawValue]
    put(&dict, "band", paired.band.map(encode))
    return dict
  }

  static func encode(_ change: RollaPrimarySourceChanged) -> [String: Any] {
    [
      "previousSource": change.previousSource.rawValue,
      "currentSource": change.currentSource.rawValue,
    ]
  }

  static func encode(_ change: RollaGoalsChanged) -> [String: Any] {
    [
      "changedGoals": change.changedGoals.map(encode),
      "enabledGoals": change.enabledGoals.map(encode),
    ]
  }

  static func encode(_ goal: RollaGoalInfo) -> [String: Any] {
    ["id": goal.id, "name": goal.name, "enabled": goal.enabled]
  }

  static func encode(_ update: RollaProfileUpdated) -> [String: Any] {
    // The SDK hands over Flutter-codec values (numbers, strings, arrays,
    // dictionaries, NSNull), which React Native serializes as they are.
    ["changedFields": update.changedFields]
  }

  static func encode(_ target: RollaNotificationTarget) -> [String: Any] {
    switch target {
    case .appSettings:
      return ["kind": "appSettings"]
    case .screen(let screen):
      return ["kind": "screen", "screen": screen.rawValue]
    @unknown default:
      // A destination newer than this wrapper — Home is the SDK's own fallback.
      return ["kind": "screen", "screen": RollaScreen.home.rawValue]
    }
  }
}

// MARK: - Configuration parsing

/// Translates the JS `RollaConfiguration` dictionary into the SDK's typed
/// configuration. Absent keys and JS `null` (bridged as `NSNull`) both mean
/// "unset" and leave the SDK default in place; a present key with a value the
/// SDK does not know is an `INVALID_CONFIG` error rather than a silent drop.
private enum RollaConfigurationParser {

  static func configuration(from dict: [String: Any]) throws -> RollaConfiguration {
    let token = try requiredString("token", in: dict)
    let partnerId = try requiredString("partnerId", in: dict)
    let branding = try optionalDictionary("branding", in: dict).map(branding(from:))

    return RollaConfiguration(
      token: token,
      refreshToken: dict["refreshToken"] as? String,
      tokenExpiresIn: (dict["tokenExpiresIn"] as? NSNumber)?.doubleValue,
      userId: dict["userId"] as? String,
      partnerId: partnerId,
      environment: dict["environment"] as? String ?? "rnd",
      disabledModules: try enumSet("disabledModules", in: dict, RollaDisabledModule.init(rawValue:)),
      disabledDataSources: try enumSet("disabledDataSources", in: dict, RollaDataSource.init(rawValue:)),
      language: try optionalEnum("language", in: dict, RollaLanguage.init(rawValue:)),
      branding: branding,
      // Defaults mirror RollaConfiguration's own so an unset key behaves
      // exactly like a native host that omitted the argument.
      showOptionsButton: dict["showOptionsButton"] as? Bool ?? true,
      showGoalsSection: dict["showGoalsSection"] as? Bool ?? false
    )
  }

  static func branding(from dict: [String: Any]) throws -> RollaBranding {
    // Every field is optional and nil keeps the SDK default — never substitute
    // fallback values here, they would override the SDK's own palette/copy.
    RollaBranding(
      hostAppName: dict["hostAppName"] as? String,
      primaryColor: try optionalColor("primaryColor", in: dict),
      themeMode: try optionalEnum("themeMode", in: dict, RollaThemeMode.init(rawValue:)),
      headerLogoAsset: dict["headerLogoAsset"] as? String,
      privacyUrl: dict["privacyUrl"] as? String,
      removeRollaBandReferences: dict["removeRollaBandReferences"] as? Bool
    )
  }

  static func transition(named name: String) throws -> RollaTransition {
    switch name {
    case "default": return .default
    case "fade":    return .fade
    default:
      throw RollaBridgeError.invalidConfig("Unknown transition '\(name)'. Expected 'default' or 'fade'.")
    }
  }

  // MARK: Helpers

  private static func isUnset(_ value: Any?) -> Bool {
    value == nil || value is NSNull
  }

  private static func requiredString(_ key: String, in dict: [String: Any]) throws -> String {
    guard let value = dict[key] as? String, !value.isEmpty else {
      throw RollaBridgeError.invalidConfig("Missing required field '\(key)'.")
    }
    return value
  }

  private static func optionalDictionary(_ key: String, in dict: [String: Any]) throws -> [String: Any]? {
    let raw = dict[key]
    if isUnset(raw) { return nil }
    guard let value = raw as? [String: Any] else {
      throw RollaBridgeError.invalidConfig("'\(key)' must be an object.")
    }
    return value
  }

  private static func optionalEnum<T>(
    _ key: String,
    in dict: [String: Any],
    _ make: (String) -> T?
  ) throws -> T? {
    let raw = dict[key]
    if isUnset(raw) { return nil }
    guard let name = raw as? String, let value = make(name) else {
      throw RollaBridgeError.invalidConfig("Unknown value '\(raw ?? "")' for '\(key)'.")
    }
    return value
  }

  private static func enumSet<T: Hashable>(
    _ key: String,
    in dict: [String: Any],
    _ make: (String) -> T?
  ) throws -> Set<T> {
    let raw = dict[key]
    if isUnset(raw) { return [] }
    guard let names = raw as? [String] else {
      throw RollaBridgeError.invalidConfig("'\(key)' must be an array of strings.")
    }
    var result = Set<T>()
    for name in names {
      guard let value = make(name) else {
        throw RollaBridgeError.invalidConfig("Unknown value '\(name)' in '\(key)'.")
      }
      result.insert(value)
    }
    return result
  }

  private static func optionalColor(_ key: String, in dict: [String: Any]) throws -> UIColor? {
    let raw = dict[key]
    if isUnset(raw) { return nil }
    guard let hex = raw as? String, let color = UIColor(hexString: hex) else {
      throw RollaBridgeError.invalidConfig("'\(key)' must be a hex color string ('#RRGGBB' or '#RRGGBBAA').")
    }
    return color
  }
}

// MARK: - Hex color parsing

private extension UIColor {
  /// Parses `#RRGGBB` / `#RRGGBBAA` (CSS channel order; the `#` is optional).
  convenience init?(hexString: String?) {
    guard var s = hexString?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    let hasAlpha = s.count == 8
    let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0
    let g = CGFloat((v >> (hasAlpha ? 16 : 8))  & 0xFF) / 255.0
    let b = CGFloat((v >> (hasAlpha ? 8  : 0))  & 0xFF) / 255.0
    let a = hasAlpha ? CGFloat(v & 0xFF) / 255.0 : 1.0
    self.init(red: r, green: g, blue: b, alpha: a)
  }
}
