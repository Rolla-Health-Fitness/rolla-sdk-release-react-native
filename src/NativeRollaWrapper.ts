import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type { UnsafeObject } from 'react-native/Libraries/Types/CodegenTypes';

export interface Spec extends TurboModule {
  show(config: UnsafeObject): Promise<void>;
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
