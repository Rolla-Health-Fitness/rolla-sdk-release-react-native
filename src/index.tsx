import { NativeEventEmitter } from 'react-native';

import NativeRollaWrapper from './NativeRollaWrapper';
import type {
  RollaBatteryResult,
  RollaCloseEvent,
  RollaConfiguration,
  RollaErrorEvent,
  RollaEventMap,
  RollaEventName,
  RollaNotificationTarget,
  RollaOpenScreenOptions,
  RollaOpenScreenStatus,
  RollaPairedBandResult,
  RollaScreen,
  RollaShowOptions,
  RollaSubscription,
  RollaSyncOptions,
  RollaSyncResult,
} from './types';

export * from './types';

const SUPPORTED_EVENTS: readonly RollaEventName[] = [
  'onClose',
  'onError',
  'onTokenRefreshed',
  'onTokenExpired',
  'onSyncHealthDataCompleted',
  'onUiSyncCompleted',
  'onActivityCompleted',
  'onActivityStarted',
  'onActivityRemoved',
  'onBandPaired',
  'onBandUnpaired',
  'onBandConnected',
  'onBandDisconnected',
  'onPrimarySourceChanged',
  'onGoalsChanged',
  'onProfileUpdated',
  'onNotificationTap',
] as const;

// A host that mirrors the native demos wires every event (17) plus its own;
// warn only on counts that point at leaked effect subscriptions.
const LISTENER_WARN_THRESHOLD = 40;

/** Native shape of a resolved notification target; `'none'` maps to `null` in JS. */
type NativeNotificationTarget =
  | { kind: 'none' }
  | { kind: 'appSettings' }
  | { kind: 'screen'; screen: RollaScreen };

function toNotificationTarget(native: Object): RollaNotificationTarget | null {
  const target = native as NativeNotificationTarget;
  switch (target.kind) {
    case 'appSettings':
      return { kind: 'appSettings' };
    case 'screen':
      return { kind: 'screen', screen: target.screen };
    default:
      return null;
  }
}

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
 *  - Events also fire — required for token-refresh signals while the SDK UI is
 *    open, and for the observational SDK events, which keep flowing for the
 *    engine's lifetime after the SDK UI closes.
 *
 * Every entry point takes the configuration it runs under, exactly as a native
 * host builds a `Rolla(configuration)` per call; the SDK engine itself is
 * process-wide and shared by all of them.
 *
 * The native SDK version this package pins (iOS pod `RollaSDK` and Android
 * `com.rolla.sdk:android_release`) is `nativeSdkVersion` in package.json —
 * see README.md → Versioning.
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

  /**
   * Pushes fresh credentials to the running engine — the answer to
   * `onTokenExpired`, or a proactive push after your app refreshed outside
   * the SDK. Needs an engine that an earlier call started (`show()`,
   * `openScreen()`, `warmUpEngine()` or a headless method); on a cold engine
   * it rejects with `NO_ACTIVE_SESSION` — pass the newest pair in your next
   * configuration instead. A pair older than the one the SDK holds is ignored
   * by design and still resolves.
   */
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

  /**
   * Purges the SDK's persisted tokens and session data — call it on logout,
   * then `destroyEngine()` once it has resolved. The native clear needs a
   * running engine: pass the current configuration and the wrapper warms the
   * engine first when none is running (the SDK's documented recipe). Without a
   * configuration, a cold engine rejects with `NO_ACTIVE_SESSION` rather than
   * reporting a clear that never happened.
   */
  static clearSession(config?: RollaConfiguration): Promise<void> {
    return NativeRollaWrapper.clearSession(
      (config as unknown as Object | undefined) ?? null
    );
  }

  /**
   * Tears down the shared Flutter engine. The next call that needs it (a
   * `show()`, `openScreen()` or headless call) builds a fresh one from the
   * configuration it is given — the way to apply a changed configuration.
   */
  static destroyEngine(): Promise<void> {
    return NativeRollaWrapper.destroyEngine();
  }

  static isPresenting(): Promise<boolean> {
    return NativeRollaWrapper.isPresenting();
  }

  /**
   * The native SDK version this package links (`nativeSdkVersion` in
   * package.json). Resolving proves the TurboModule is wired up.
   */
  static getNativeSdkVersion(): Promise<string> {
    return NativeRollaWrapper.getNativeSdkVersion();
  }

  /**
   * Starts and configures the engine ahead of time without presenting any UI,
   * so the first `show()` presents instantly. Optional: every other entry
   * point starts the engine itself on first use. Safe to call repeatedly.
   * Rejects with the SDK's `RollaError` code when start-up fails.
   */
  static warmUpEngine(config: RollaConfiguration): Promise<void> {
    return NativeRollaWrapper.warmUpEngine(config as unknown as Object);
  }

  /**
   * Runs a full headless sync of the user's primary data source. Resolves with
   * the terminal `RollaSyncResult` — including `outcome: 'skipped'` with a
   * `skipReason` when the sync could not run (the host owns permissions and the
   * SDK cannot prompt headlessly) and `outcome: 'failure'` with `error`. Rejects
   * only on a transport failure such as the engine not starting. The same
   * result is also delivered to `onSyncHealthDataCompleted` listeners.
   */
  static syncHealthData(
    config: RollaConfiguration,
    options?: RollaSyncOptions
  ): Promise<RollaSyncResult> {
    return NativeRollaWrapper.syncHealthData(
      config as unknown as Object,
      options?.includeSamples ?? false
    ) as Promise<RollaSyncResult>;
  }

  /**
   * Live BLE read of the paired Rolla band's battery level. Resolves with a
   * typed status; `level` is present only for `'available'`. Rejects only on a
   * transport failure.
   */
  static getBandBatteryLevel(
    config: RollaConfiguration
  ): Promise<RollaBatteryResult> {
    return NativeRollaWrapper.getBandBatteryLevel(
      config as unknown as Object
    ) as Promise<RollaBatteryResult>;
  }

  /**
   * Whether the account currently has a Rolla band paired — no Bluetooth
   * involved (network-first against the profile, local record as fallback).
   * Rejects only on a transport failure.
   */
  static getPairedBandInfo(
    config: RollaConfiguration
  ): Promise<RollaPairedBandResult> {
    return NativeRollaWrapper.getPairedBandInfo(
      config as unknown as Object
    ) as Promise<RollaPairedBandResult>;
  }

  /**
   * Opens the SDK UI directly on `screen`, presenting it first when needed
   * (an already-presented UI navigates in place). Resolves with the typed
   * `RollaOpenScreenStatus`; a presentation failure is also reported through
   * `onError`. The opened screen becomes the SDK's root, so back returns to
   * the host app. Close events arrive through `onClose` like a `show()`.
   */
  static openScreen(
    config: RollaConfiguration,
    screen: RollaScreen,
    options?: RollaOpenScreenOptions
  ): Promise<RollaOpenScreenStatus> {
    return NativeRollaWrapper.openScreen(
      config as unknown as Object,
      screen,
      options?.transition ?? 'default'
    ) as Promise<RollaOpenScreenStatus>;
  }

  /**
   * The Rolla notification tap that launched or resumed the app, if any —
   * consume it once a session exists and route it with `openScreen()`. Clears
   * on read. Taps while the app is running arrive as `onNotificationTap`.
   *
   * Android resolves the launching intent natively. On iOS the host's
   * `UNUserNotificationCenterDelegate` forwards the response with
   * `RollaBridgeNotifications.handle(response:)`; see README.
   */
  static async getInitialNotificationTarget(): Promise<RollaNotificationTarget | null> {
    return toNotificationTarget(
      await NativeRollaWrapper.getInitialNotificationTarget()
    );
  }

  /**
   * Resolves a notification payload the host received through its own
   * notification handling (e.g. a push library): the notification's user-info
   * dictionary on iOS, or `{ payload }` with the intent's `payload` extra on
   * Android. `null` when the notification is not Rolla's.
   */
  static async notificationTarget(
    payload: Record<string, unknown>
  ): Promise<RollaNotificationTarget | null> {
    return toNotificationTarget(
      await NativeRollaWrapper.notificationTarget(payload as Object)
    );
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
      // Pass the TurboModule on both platforms so RN reports every
      // subscription to native (`addListener` / `removeListeners`): iOS uses
      // that to skip emitting into the void, and both sides use it to queue a
      // notification tap for `getInitialNotificationTarget()` when no JS
      // listener is attached yet. Android emission itself still goes through
      // RCTDeviceEventEmitter.
      Rolla._emitter = new NativeEventEmitter(
        NativeRollaWrapper as unknown as never
      );
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
