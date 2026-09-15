/**
 * Public type contracts for `@rolla-health/react-native-sdk`.
 *
 * Every union below mirrors a native SDK enum by its raw value — the strings
 * are passed to the native side verbatim:
 *  - iOS:     `RollaSDK` (`RollaConfiguration.swift`, `RollaDisabledModule.swift`, …)
 *  - Android: `com.rolla.sdk.wrapper.config.*`
 *
 * The native demo apps (`rolla-sdk-demo-ios`, `rolla-sdk-demo-android`) show
 * the same configuration being built natively.
 */

export type RollaEnvironment = 'production' | 'rnd';

/**
 * SDK modules that can be disabled everywhere in the SDK UI
 * (`RollaConfiguration.disabledModules`).
 */
export type RollaDisabledModule =
  | 'bloodPressure'
  | 'insights'
  | 'leaderboards'
  | 'weight';

/**
 * Data sources the host app can hide from the SDK UI
 * (`RollaConfiguration.disabledDataSources`). A deny-list: an empty list offers
 * every source. A source the user has already connected still renders so it
 * can be viewed or disconnected; only new connections are suppressed.
 */
export type RollaDataSource =
  | 'band'
  | 'garmin'
  | 'oura'
  | 'appleHealth'
  | 'healthConnect';

/**
 * SDK UI languages a host app can configure (`RollaConfiguration.language`).
 * When set, it is authoritative for the Flutter engine's lifetime and replaces
 * persisted picks and the user's backend profile language.
 */
export type RollaLanguage =
  | 'english'
  | 'german'
  | 'spanish'
  | 'croatian'
  | 'bosnian'
  | 'serbianLatin'
  | 'serbianCyrillic'
  | 'arabic';

/** Theme the SDK UI runs in: light, dark, or following the device (system). */
export type RollaThemeMode = 'system' | 'light' | 'dark';

/**
 * How the SDK UI is animated on and off screen by `Rolla.show()`. The dismissal
 * always mirrors the presentation, whichever way the SDK UI is closed.
 *  - `'default'` — the platform's standard presentation (iOS: slide-in from the
 *    trailing edge with a subtle parallax on the host screen; Android: the
 *    standard activity animation).
 *  - `'fade'` — a cross-fade between the host screen and the SDK UI.
 */
export type RollaTransition = 'default' | 'fade';

/**
 * Reasons the native SDK reports when the SDK UI is dismissed.
 *
 * Values originate from `com.rolla.sdk.wrapper.features.session.RollaCloseReason`
 * (Android) and `RollaCloseReason` (iOS) — see those types for the source of truth.
 */
export type RollaCloseReasonKind =
  | 'flutterRequested'
  | 'hostNavigationBack'
  | 'hostModalDismiss'
  | 'programmatic'
  | 'hostStackReplaced'
  | 'unknown';

/**
 * Visual identity of the SDK UI. Every field is optional: a set field overrides
 * the SDK's built-in default individually — unset fields keep it. The wrapper
 * never substitutes fallback values.
 */
export interface RollaBranding {
  /**
   * Display name of the host app, shown wherever SDK copy refers to the app
   * (consent and permission texts). Unset keeps the generic wording.
   */
  hostAppName?: string;
  /**
   * Seeds the SDK's entire color scheme (buttons, navigation, inputs, charts,
   * share cards) in both light and dark themes. Hex string, `#RRGGBB` or
   * `#RRGGBBAA`. Parsed natively — do not use `processColor`.
   */
  primaryColor?: string;
  /** Theme the SDK UI runs in. Unset follows the device. */
  themeMode?: RollaThemeMode;
  /**
   * Path of a logo asset pre-bundled into the SDK by Rolla, shown in the top
   * app bar and on activity share cards.
   */
  headerLogoAsset?: string;
  /** Privacy policy URL linked from the consent screen. */
  privacyUrl?: string;
  /**
   * Whether the SDK UI uses generic "fitness device" wording (`true`) or Rolla
   * Band-specific naming, imagery, and copy (`false`). Unset keeps the SDK
   * default: generic wording.
   */
  removeRollaBandReferences?: boolean;
}

export interface RollaConfiguration {
  token: string;
  refreshToken?: string;
  /** Seconds until the access token expires. */
  tokenExpiresIn?: number;
  userId?: string;
  partnerId: string;
  environment: RollaEnvironment;
  /** Modules to disable everywhere in the SDK UI. Unset disables nothing. */
  disabledModules?: RollaDisabledModule[];
  /** Data sources to stop offering for new connections. Unset offers every source. */
  disabledDataSources?: RollaDataSource[];
  /** SDK UI language. Unset keeps the profile-driven behavior. */
  language?: RollaLanguage;
  branding?: RollaBranding;
  /** Whether the SDK UI shows its options (three-dot) app-bar action. Default `true`. */
  showOptionsButton?: boolean;
  /** Whether the SDK UI shows its goals section. Default `false`. */
  showGoalsSection?: boolean;
}

export interface RollaShowOptions {
  /** Presentation animation. Default `'default'`. */
  transition?: RollaTransition;
}

export interface RollaCloseEvent {
  reason: RollaCloseReasonKind;
  /** Present when reason is `'flutterRequested'`. */
  detail?: string;
}

export interface RollaErrorEvent {
  /** Native `RollaError` code, e.g. `'ENGINE_FAILED'`, `'INIT_FAILED'`, `'FLUTTER_ERROR'`. */
  code: string;
  message: string;
  /**
   * `true` when the error ended a pending `Rolla.show()`: the SDK UI is not on
   * screen, no `onClose` will follow, and that `show()` call rejects with this
   * error. `false` for errors raised while the SDK UI is running.
   */
  presentationFailed: boolean;
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
