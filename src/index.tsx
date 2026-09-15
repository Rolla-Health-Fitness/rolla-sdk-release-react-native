import { NativeEventEmitter, Platform } from 'react-native';

import NativeRollaWrapper from './NativeRollaWrapper';
import type {
  RollaCloseEvent,
  RollaConfiguration,
  RollaErrorEvent,
  RollaEventMap,
  RollaEventName,
  RollaShowOptions,
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
 *  - Events also fire — required for token-refresh signals while the SDK UI is open.
 *
 * The package version equals the native SDK version it pins (iOS pod
 * `RollaSDK` and Android `com.rolla.sdk:android_release`) — see README.md.
 */
export class Rolla {
  private static _emitter: NativeEventEmitter | null = null;
  private static _showResolver: ((value: RollaCloseEvent) => void) | null =
    null;
  private static _showRejecter: ((reason: Error) => void) | null = null;
  private static _closeSub: { remove(): void } | null = null;
  private static _errorSub: { remove(): void } | null = null;
  private static _userSubs: Set<{ remove(): void }> = new Set();

  /**
   * Presents the SDK UI. Resolves with the close event once the SDK UI is
   * dismissed. Rejects with `{ code, message }` when the SDK UI could not be
   * presented — an invalid configuration (`INVALID_CONFIG`), a second call
   * while one is pending (`ALREADY_PRESENTING`), or a native start-up failure
   * reported by the SDK (its `RollaError` code, e.g. `ENGINE_FAILED`).
   */
  static async show(
    config: RollaConfiguration,
    options?: RollaShowOptions
  ): Promise<RollaCloseEvent> {
    if (Rolla._showResolver) {
      throw Object.assign(
        new Error(
          'Rolla.show() is already in flight. Await the existing call or call Rolla.dismiss() first.'
        ),
        { code: 'ALREADY_PRESENTING' }
      );
    }

    const emitter = Rolla.getEmitter();

    const result = new Promise<RollaCloseEvent>((resolve, reject) => {
      Rolla._showResolver = resolve;
      Rolla._showRejecter = reject;
    });

    Rolla._closeSub = emitter.addListener('onClose', ((
      event: RollaCloseEvent
    ) => {
      const resolver = Rolla._showResolver;
      Rolla.cleanupShowSubs();
      resolver?.(event);
    }) as (...args: readonly Object[]) => unknown);

    Rolla._errorSub = emitter.addListener('onError', ((
      event: RollaErrorEvent
    ) => {
      if (event.presentationFailed) {
        // The SDK never presented, so no onClose will arrive — settle the
        // pending show() here instead of leaving it hanging forever.
        const rejecter = Rolla._showRejecter;
        Rolla.cleanupShowSubs();
        rejecter?.(
          Object.assign(new Error(event.message), { code: event.code })
        );
        return;
      }
      if (__DEV__ && Rolla._userSubs.size === 0) {
        console.warn(
          '[RollaWrapper] Native error received but no JS listener attached:',
          event
        );
      }
    }) as (...args: readonly Object[]) => unknown);

    try {
      await NativeRollaWrapper.show(
        config as unknown as Object,
        options?.transition ?? 'default'
      );
    } catch (err) {
      Rolla.cleanupShowSubs();
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

  /**
   * The native SDK version this package links — equal to the package version
   * (lockstep). Resolving proves the TurboModule is wired up.
   */
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
    const sub = emitter.addListener(
      event,
      listener as (...args: readonly Object[]) => unknown
    );
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
      // On iOS pass the TurboModule (it inherits RCTEventEmitter on the
      // native side) so RN does not log "Sending event with no listeners".
      // On Android pass nothing; emission goes via RCTDeviceEventEmitter.
      Rolla._emitter =
        Platform.OS === 'ios'
          ? new NativeEventEmitter(NativeRollaWrapper as unknown as never)
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
    Rolla._showRejecter = null;
  }
}

export default Rolla;
