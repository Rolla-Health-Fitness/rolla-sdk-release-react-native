import { NativeModules, Platform } from 'react-native';

import type { RollaConfiguration } from './types';

const LINKING_ERROR =
  `The package '@rolla-health/react-native-sdk' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You ran 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

export interface RollaNativeModule {
  show(config: RollaConfiguration): Promise<void>;
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
  /** No-ops; required by RN 0.65+ to silence the NativeEventEmitter warning. */
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export const NativeRollaWrapper: RollaNativeModule = NativeModules.RollaWrapper
  ? (NativeModules.RollaWrapper as RollaNativeModule)
  : (new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    ) as RollaNativeModule);
