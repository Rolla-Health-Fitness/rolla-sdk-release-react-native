/**
 * Public type contracts for `@rolla-health/react-native-sdk`.
 *
 * Mirrors the native iOS/Android demo apps' usage of the Rolla SDK:
 *  - iOS:     `rolla-sdk-demo-ios/RollaSDKDemoApp/HomeViewController.swift`
 *  - Android: `rolla-sdk-demo-android/.../MainActivity.kt`
 *
 * Modal-only — no Pigeon parity in JS.
 */

export type RollaEnvironment =
  | 'production'
  | 'staging'
  | 'development'
  | 'rnd'
  | string;

/**
 * Reasons the native SDK reports when the modal is dismissed.
 *
 * Values originate from `com.rolla.sdk.wrapper.RollaCloseReason` (Android) and
 * `RollaCloseReason` (iOS) — see those types for the source of truth.
 */
export type RollaCloseReasonKind =
  | 'flutterRequested'
  | 'hostNavigationBack'
  | 'hostModalDismiss'
  | 'programmatic'
  | 'hostStackReplaced'
  | 'unknown';

export interface RollaBranding {
  appName?: string;
  /** Hex color, `#RRGGBB` or `#RRGGBBAA`. Parsed natively — do not use `processColor`. */
  primaryColor?: string;
  secondaryColor?: string;
  accentColor?: string;
  brightness?: 'light' | 'dark';
  defaultThemeMode?: 'light' | 'dark' | 'system';
  /** BCP-47 locale tag, e.g. `'en-US'`. */
  defaultLocale?: string;
  headerLogoAsset?: string;
  termsUrl?: string;
  privacyUrl?: string;
}

export interface RollaConfiguration {
  token: string;
  refreshToken?: string;
  /** Seconds until the access token expires. */
  tokenExpiresIn?: number;
  userId?: string;
  partnerId: string;
  environment: RollaEnvironment;
  /**
   * Optional list of module identifiers to disable in the SDK UI.
   * Native expects raw strings (e.g. `'WEIGHT'`, `'BLOOD_PRESSURE'`).
   */
  disabledModules?: string[];
  branding?: RollaBranding;
  showSettingsButton?: boolean;
}

export interface RollaCloseEvent {
  reason: RollaCloseReasonKind;
  /** Present when reason is `'flutterRequested'`. */
  detail?: string;
}

export interface RollaErrorEvent {
  code: string;
  message: string;
}

export interface RollaTokenRefreshedEvent {
  token: string;
  refreshToken?: string;
  /** Seconds until the new token expires. */
  expiresIn?: number;
}

/** No payload — JS must call `Rolla.updateToken(...)` with fresh credentials. */
export type RollaTokenExpiredEvent = Record<string, never>;

export interface RollaEventMap {
  onClose: RollaCloseEvent;
  onError: RollaErrorEvent;
  onTokenRefreshed: RollaTokenRefreshedEvent;
  onTokenExpired: RollaTokenExpiredEvent;
}

export type RollaEventName = keyof RollaEventMap;

export interface RollaSubscription {
  remove(): void;
}
