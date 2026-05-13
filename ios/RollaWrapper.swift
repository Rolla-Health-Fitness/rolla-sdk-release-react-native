import Foundation
import UIKit
import RollaSDK

@objc(RollaSdk)
final class RollaSdk: RCTEventEmitter {

  private static let kEventClose            = "onClose"
  private static let kEventError            = "onError"
  private static let kEventTokenRefreshed   = "onTokenRefreshed"
  private static let kEventTokenExpired     = "onTokenExpired"

  private static let kNativeSdkVersion = "0.1.10"

  private var rolla: Rolla?
  private var hasListeners = false

  override static func requiresMainQueueSetup() -> Bool { true }

  override func supportedEvents() -> [String]! {
    return [
      Self.kEventClose,
      Self.kEventError,
      Self.kEventTokenRefreshed,
      Self.kEventTokenExpired,
    ]
  }

  override func startObserving() { hasListeners = true }
  override func stopObserving()  { hasListeners = false }

  override func invalidate() {
    DispatchQueue.main.async { [weak self] in
      self?.rolla?.dismiss()
      self?.rolla = nil
    }
    super.invalidate()
  }

  // MARK: - show

  @objc(show:resolver:rejecter:)
  func show(_ config: NSDictionary,
            resolver resolve: @escaping RCTPromiseResolveBlock,
            rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      if let existing = self.rolla, existing.isPresenting {
        reject("ALREADY_PRESENTING", "Rolla is already presenting. Dismiss it before calling show() again.", nil)
        return
      }

      guard let presenter = self.topPresentedViewController() else {
        reject("NO_PRESENTER", "Unable to find a view controller to present from.", nil)
        return
      }

      let configuration: RollaConfiguration
      do {
        configuration = try Self.buildConfiguration(from: config)
      } catch {
        reject("INVALID_CONFIG", error.localizedDescription, error)
        return
      }

      let instance = Rolla(configuration: configuration)
      instance.delegate = self
      self.rolla = instance
      instance.show(from: presenter)
      resolve(nil)
    }
  }

  // MARK: - dismiss

  @objc(dismiss:rejecter:)
  func dismiss(_ resolve: @escaping RCTPromiseResolveBlock,
               rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      self?.rolla?.dismiss()
      resolve(nil)
    }
  }

  // MARK: - updateToken

  @objc(updateToken:refreshToken:expiresIn:resolver:rejecter:)
  func updateToken(_ token: String,
                   refreshToken: NSString?,
                   expiresIn: NSNumber?,
                   resolver resolve: @escaping RCTPromiseResolveBlock,
                   rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let rolla = self.rolla else {
        reject("NO_ACTIVE_SESSION", "updateToken called with no active Rolla session.", nil)
        return
      }
      rolla.updateToken(
        token: token,
        refreshToken: refreshToken as String?,
        expiresIn: expiresIn?.doubleValue
      ) { result in
        switch result {
        case .success:           resolve(nil)
        case .failure(let err):  reject("UPDATE_TOKEN_FAILED", err.localizedDescription, err)
        }
      }
    }
  }

  // MARK: - clearSession

  @objc(clearSession:rejecter:)
  func clearSession(_ resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let rolla = self?.rolla else {
        resolve(nil)
        return
      }
      rolla.clearSession { result in
        switch result {
        case .success:           resolve(nil)
        case .failure(let err):  reject("CLEAR_SESSION_FAILED", err.localizedDescription, err)
        }
      }
    }
  }

  // MARK: - destroyEngine

  @objc(destroyEngine:rejecter:)
  func destroyEngine(_ resolve: @escaping RCTPromiseResolveBlock,
                     rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      Rolla.destroyEngine()
      self?.rolla = nil
      resolve(nil)
    }
  }

  // MARK: - isPresenting

  @objc(isPresenting:rejecter:)
  func isPresenting(_ resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      resolve(self?.rolla?.isPresenting ?? false)
    }
  }

  // MARK: - getNativeSdkVersion

  @objc(getNativeSdkVersion:rejecter:)
  func getNativeSdkVersion(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
    resolve(Self.kNativeSdkVersion)
  }

  // MARK: - Helpers

  private func emit(_ name: String, body: Any?) {
    guard hasListeners else { return }
    sendEvent(withName: name, body: body)
  }

  private func topPresentedViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let foreground = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let windowScene = foreground else { return nil }
    let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private static func buildConfiguration(from dict: NSDictionary) throws -> RollaConfiguration {
    guard let token = dict["token"] as? String, !token.isEmpty else {
      throw RollaSdkBridgeError.missingField("token")
    }
    guard let partnerId = dict["partnerId"] as? String, !partnerId.isEmpty else {
      throw RollaSdkBridgeError.missingField("partnerId")
    }
    let environment = (dict["environment"] as? String) ?? "rnd"

    let modules = (dict["disabledModules"] as? [String])
      ?? (dict["modules"] as? [String])

    return RollaConfiguration(
      token: token,
      refreshToken: dict["refreshToken"] as? String,
      tokenExpiresIn: (dict["tokenExpiresIn"] as? NSNumber)?.doubleValue,
      userId: dict["userId"] as? String,
      partnerId: partnerId,
      environment: environment,
      modules: modules,
      branding: buildBranding(from: dict["branding"] as? NSDictionary),
      showSettingsButton: (dict["showSettingsButton"] as? Bool) ?? true
    )
  }

  private static func buildBranding(from dict: NSDictionary?) -> RollaBranding? {
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

extension RollaSdk: RollaDelegate {

  func rollaDidClose(_ rolla: Rolla, reason: RollaCloseReason) {
    self.rolla = nil
    var payload: [String: Any] = ["reason": Self.encodeReason(reason)]
    if case .flutterRequested(let detail) = reason, let detail {
      payload["detail"] = detail
    }
    emit(Self.kEventClose, body: payload)
  }

  func rolla(_ rolla: Rolla, didFailWithError error: RollaError) {
    emit(Self.kEventError, body: [
      "code": error.code,
      "message": error.errorDescription ?? "",
    ])
  }

  func rollaDidRefreshToken(_ rolla: Rolla,
                            token: String,
                            refreshToken: String?,
                            expiresIn: TimeInterval?) {
    var payload: [String: Any] = ["token": token]
    if let refreshToken { payload["refreshToken"] = refreshToken }
    if let expiresIn    { payload["expiresIn"] = expiresIn }
    emit(Self.kEventTokenRefreshed, body: payload)
  }

  func rollaDidRequestTokenRefresh(_ rolla: Rolla) {
    emit(Self.kEventTokenExpired, body: [:])
  }

  private static func encodeReason(_ reason: RollaCloseReason) -> String {
    switch reason {
    case .flutterRequested:    return "flutterRequested"
    case .hostNavigationBack:  return "hostNavigationBack"
    case .hostModalDismiss:    return "hostModalDismiss"
    case .programmatic:        return "programmatic"
    case .hostStackReplaced:   return "hostStackReplaced"
    case .unknown:             return "unknown"
    }
  }
}

// MARK: - Bridge error

private enum RollaSdkBridgeError: LocalizedError {
  case missingField(String)
  var errorDescription: String? {
    switch self {
    case .missingField(let field): return "Missing required field '\(field)' in Rolla configuration."
    }
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
