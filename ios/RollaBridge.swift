import Foundation
import UIKit
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
}

/// Thin ObjC-callable shim over the Swift-only RollaSDK API. The actual
/// React Native TurboModule lives in `RollaWrapper.mm`; this class only
/// exists because the SDK's surface is Swift-only and Swift cannot import
/// the codegen ObjC++ header `<RollaWrapperSpec/RollaWrapperSpec.h>`.
///
/// All public methods take/return primitive ObjC-compatible types so the
/// `.mm` can call them without bridging headers.
@objc(RollaBridge)
public class RollaBridge: NSObject {

  @objc public weak var listener: RollaBridgeListener?

  private var rolla: Rolla?

  // MARK: - Public API

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

    let configuration = try RollaConfigurationParser.configuration(from: config)
    let transition = try RollaConfigurationParser.transition(named: transitionName)

    let instance = Rolla(configuration: configuration)
    instance.delegate = self
    rolla = instance
    instance.show(from: presenter, transition: transition)
  }

  @objc public func dismiss() {
    rolla?.dismiss()
  }

  /// - Parameter completion: called with `nil` on success, error message on failure.
  @objc public func updateToken(
    _ token: String,
    refreshToken: String?,
    expiresIn: NSNumber?,
    completion: @escaping (String?) -> Void
  ) {
    guard let rolla else {
      completion("No active Rolla session.")
      return
    }
    rolla.updateToken(
      token: token,
      refreshToken: refreshToken,
      expiresIn: expiresIn?.doubleValue
    ) { result in
      switch result {
      case .success:           completion(nil)
      case .failure(let err):  completion(err.localizedDescription)
      }
    }
  }

  /// - Parameter completion: called with `nil` on success, error message on failure.
  @objc public func clearSession(completion: @escaping (String?) -> Void) {
    guard let rolla else {
      completion(nil)
      return
    }
    rolla.clearSession { result in
      switch result {
      case .success:           completion(nil)
      case .failure(let err):  completion(err.localizedDescription)
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
}

// MARK: - RollaDelegate

extension RollaBridge: RollaDelegate {

  public func rollaDidClose(_ rolla: Rolla, reason: RollaCloseReason) {
    self.rolla = nil
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
    if presentationFailed, self.rolla === rolla {
      self.rolla = nil
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
