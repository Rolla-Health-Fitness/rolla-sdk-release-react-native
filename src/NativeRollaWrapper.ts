import { TurboModuleRegistry, type TurboModule } from 'react-native';

/**
 * TurboModule spec for the native RollaWrapper bridge. Method parameter and
 * result types use `Object` / `string` for the structured shapes — the typed
 * contracts live in `src/index.tsx` / `src/types.ts` (the partner-facing
 * surface).
 *
 * Events are not declared here; they flow through RCTDeviceEventEmitter on
 * Android and the module's RCTEventEmitter inheritance on iOS, which both work
 * under Bridgeless. `addListener` / `removeListeners` are required by
 * NativeEventEmitter and must exist on the TurboModule.
 */
export interface Spec extends TurboModule {
  /** `transition` is a `RollaTransition` name; JS always passes one. */
  show(config: Object, transition: string): Promise<void>;
  dismiss(): Promise<void>;
  updateToken(
    token: string,
    refreshToken: string | null,
    expiresIn: number | null
  ): Promise<void>;
  clearSession(): Promise<void>;
  destroyEngine(): Promise<void>;
  isPresenting(): Promise<boolean>;
  getNativeSdkVersion(): Promise<string>;

  // Headless — every call carries the configuration it runs under, exactly as
  // a native host builds a `Rolla(configuration)` per call. Results resolve with
  // the SDK's typed status objects; the promise rejects only on a transport
  // failure (the SDK's `RollaError`).
  warmUpEngine(config: Object): Promise<void>;
  syncHealthData(config: Object, includeSamples: boolean): Promise<Object>;
  getBandBatteryLevel(config: Object): Promise<Object>;
  getPairedBandInfo(config: Object): Promise<Object>;

  /** Resolves with a `RollaOpenScreenStatus` name. */
  openScreen(
    config: Object,
    screen: string,
    transition: string
  ): Promise<string>;

  /**
   * Notification taps, resolved natively: `{ kind: 'none' }` when there is no
   * pending Rolla notification (or the payload is not Rolla's), otherwise
   * `{ kind: 'appSettings' }` or `{ kind: 'screen', screen }`.
   */
  getInitialNotificationTarget(): Promise<Object>;
  notificationTarget(payload: Object): Promise<Object>;

  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RollaWrapper');
