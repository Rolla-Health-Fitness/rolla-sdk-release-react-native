import { TurboModuleRegistry, type TurboModule } from 'react-native';

/**
 * TurboModule spec for the native RollaWrapper bridge. Method parameter types
 * use `Object` for complex configuration shapes — the typed contracts live in
 * `src/index.tsx` / `src/types.ts` (the partner-facing surface).
 *
 * Events (onClose, onError, onTokenRefreshed, onTokenExpired) are not declared
 * here; they flow through RCTDeviceEventEmitter on Android and the Swift
 * class's RCTEventEmitter inheritance on iOS, which both work under Bridgeless.
 * `addListener` / `removeListeners` are required by NativeEventEmitter and must
 * exist on the TurboModule.
 */
export interface Spec extends TurboModule {
  show(config: Object): Promise<void>;
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
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RollaWrapper');
