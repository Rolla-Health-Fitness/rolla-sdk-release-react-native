import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

import { NativeRollaWrapper } from './NativeRollaWrapper';
import type {
  RollaCloseEvent,
  RollaConfiguration,
  RollaEventMap,
  RollaEventName,
  RollaSubscription,
} from './types';

export * from './types';

const SUPPORTED_EVENTS: readonly RollaEventName[] = [
  'onClose',
  'onError',
  'onTokenRefreshed',
  'onTokenExpired',
] as const;

const LISTENER_WARN_THRESHOLD = 8;

/**
 * `Rolla` is the public surface of `@rolla-health/react-native-sdk`.
 *
 * It mirrors the native iOS/Android demo apps:
 *
 *   const close = await Rolla.show({ token, partnerId, environment, ... });
 *   if (close.reason === 'flutterRequested') { ... }
 *
 *   const sub = Rolla.addListener('onTokenExpired', async () => {
 *     const fresh = await myAuth.refresh();
 *     await Rolla.updateToken(fresh.token, fresh.refreshToken, fresh.expiresIn);
 *   });
 *   sub.remove();
 *
 * Two-track API by design:
 *  - `show()` resolves on close, so `await` is ergonomic.
 *  - Events also fire — required for token-refresh signals while the modal is open.
 *
 * The JS package version is decoupled from the native iOS pod / Android Maven
 * versions. See the compatibility matrix in README.md.
 */
export class Rolla {
  private static _emitter: NativeEventEmitter | null = null;
  private static _showResolver: ((value: RollaCloseEvent) => void) | null =
    null;
  private static _closeSub: { remove(): void } | null = null;
  private static _errorSub: { remove(): void } | null = null;
  private static _userSubs: Set<{ remove(): void }> = new Set();

  static async show(config: RollaConfiguration): Promise<RollaCloseEvent> {
    if (Rolla._showResolver) {
      throw Object.assign(
        new Error(
          'Rolla.show() is already in flight. Await the existing call or call Rolla.dismiss() first.'
        ),
        { code: 'ALREADY_PRESENTING' }
      );
    }

    const emitter = Rolla.getEmitter();

    const result = new Promise<RollaCloseEvent>((resolve) => {
      Rolla._showResolver = resolve;
    });

    Rolla._closeSub = emitter.addListener(
      'onClose',
      (event: RollaCloseEvent) => {
        const resolver = Rolla._showResolver;
        Rolla.cleanupShowSubs();
        resolver?.(event);
      }
    );

    Rolla._errorSub = emitter.addListener('onError', (event) => {
      // `onError` does not auto-resolve `show()` — close still arrives separately
      // from the native side. We just re-emit to user listeners. Keep `show()`'s
      // promise pending until `onClose` fires.
      if (__DEV__ && Rolla._userSubs.size === 0) {
        console.warn(
          '[RollaWrapper] Native error received but no JS listener attached:',
          event
        );
      }
    });

    try {
      await NativeRollaWrapper.show(config);
    } catch (err) {
      Rolla.cleanupShowSubs();
      Rolla._showResolver = null;
      throw err;
    }

    return result;
  }

  static dismiss(): Promise<void> {
    return NativeRollaWrapper.dismiss();
  }

  static updateToken(
    token: string,
    refreshToken?: string,
    expiresIn?: number
  ): Promise<void> {
    return NativeRollaWrapper.updateToken(
      token,
      refreshToken ?? null,
      expiresIn ?? null
    );
  }

  static clearSession(): Promise<void> {
    return NativeRollaWrapper.clearSession();
  }

  static destroyEngine(): Promise<void> {
    return NativeRollaWrapper.destroyEngine();
  }

  static isPresenting(): Promise<boolean> {
    return NativeRollaWrapper.isPresenting();
  }

  static getNativeSdkVersion(): Promise<string> {
    return NativeRollaWrapper.getNativeSdkVersion();
  }

  static addListener<K extends RollaEventName>(
    event: K,
    listener: (payload: RollaEventMap[K]) => void
  ): RollaSubscription {
    if (!SUPPORTED_EVENTS.includes(event)) {
      throw new Error(`[RollaWrapper] Unknown event '${event}'.`);
    }
    const emitter = Rolla.getEmitter();
    const sub = emitter.addListener(event, listener);
    Rolla._userSubs.add(sub);

    if (__DEV__ && Rolla._userSubs.size > LISTENER_WARN_THRESHOLD) {
      console.warn(
        `[RollaWrapper] ${Rolla._userSubs.size} listeners attached. ` +
          'This is usually caused by missing cleanup in useEffect — return sub.remove from your effect.'
      );
    }

    return {
      remove() {
        sub.remove();
        Rolla._userSubs.delete(sub);
      },
    };
  }

  static removeAllListeners(): void {
    Rolla._userSubs.forEach((sub) => sub.remove());
    Rolla._userSubs.clear();
  }

  private static getEmitter(): NativeEventEmitter {
    if (!Rolla._emitter) {
      // On iOS we hand the native module (it's an RCTEventEmitter subclass) so
      // RN does not log "Sending event with no listeners". On Android we pass
      // nothing because emission goes via DeviceEventManagerModule.
      Rolla._emitter =
        Platform.OS === 'ios'
          ? new NativeEventEmitter(NativeModules.RollaWrapper)
          : new NativeEventEmitter();
    }
    return Rolla._emitter;
  }

  private static cleanupShowSubs(): void {
    Rolla._closeSub?.remove();
    Rolla._errorSub?.remove();
    Rolla._closeSub = null;
    Rolla._errorSub = null;
    Rolla._showResolver = null;
  }
}

export default Rolla;
