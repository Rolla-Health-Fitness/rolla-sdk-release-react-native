import Foundation
import UIKit
import RollaSDK

/// ObjC-callable protocol the TurboModule (`RollaWrapper.mm`) implements to
/// receive lifecycle events from the Swift Rolla SDK. Mirrors `RollaDelegate`
/// but with primitive ObjC-compatible types only.
@objc public protocol RollaBridgeListener: AnyObject {
  func rollaBridgeDidClose(reason: String, detail: String?)
  func rollaBridgeDidFail(code: String, message: String)
  func rollaBridgeDidRefreshToken(token: String, refreshToken: String?, expiresIn: NSNumber?)
  func rollaBridgeDidRequestTokenRefresh()
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

  @objc public static let nativeSdkVersion = "0.1.10"

  @objc public weak var listener: RollaBridgeListener?

  private var rolla: Rolla?

  // MARK: - Public API

  @objc public var isPresenting: Bool {
    rolla?.isPresenting ?? false
  }

  /// - Returns: `nil` on success; otherwise an error description string.
  @objc public func show(
    token: String,
    refreshToken: String?,
    tokenExpiresIn: NSNumber?,
    userId: String?,
    partnerId: String,
    environment: String,
    modules: [String]?,
    branding: [String: Any]?,
    showSettingsButton: Bool,
    presenter: UIViewController
  ) -> String? {
    if let existing = rolla, existing.isPresenting {
      return "Rolla is already presenting."
    }

    let configuration = RollaConfiguration(
      token: token,
      refreshToken: refreshToken,
      tokenExpiresIn: tokenExpiresIn?.doubleValue,
      userId: userId,
      partnerId: partnerId,
      environment: environment,
      modules: modules,
      branding: Self.buildBranding(from: branding),
      showSettingsButton: showSettingsButton
    )

    let instance = Rolla(configuration: configuration)
    instance.delegate = self
    rolla = instance
    instance.show(from: presenter)
    return nil
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

  // MARK: - Helpers

  private static func buildBranding(from dict: [String: Any]?) -> RollaBranding? {
    guard let dict else { return nil }
    let appName       = (dict["appName"] as? String) ?? "Rolla"
    let primary       = UIColor(hexString: dict["primaryColor"]  as? String) ?? .systemBlue
    let secondary     = UIColor(hexString: dict["secondaryColor"] as? String) ?? .systemGray
    let accent        = UIColor(hexString: dict["accentColor"]   as? String) ?? .systemPurple
    let brightness    = (dict["brightness"] as? String) ?? "light"
    let themeMode     = (dict["defaultThemeMode"] as? String) ?? "system"
    return RollaBranding(
      appName: appName,
      primaryColor: primary,
      secondaryColor: secondary,
      accentColor: accent,
      brightness: brightness,
      defaultThemeMode: themeMode,
      defaultLocale: dict["defaultLocale"] as? String,
      headerLogoAsset: dict["headerLogoAsset"] as? String,
      termsUrl: dict["termsUrl"] as? String,
      privacyUrl: dict["privacyUrl"] as? String
    )
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
    }
    listener?.rollaBridgeDidClose(reason: key, detail: detail)
  }

  public func rolla(_ rolla: Rolla, didFailWithError error: RollaError) {
    listener?.rollaBridgeDidFail(code: error.code, message: error.errorDescription ?? "")
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

// MARK: - Hex color parsing

private extension UIColor {
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
