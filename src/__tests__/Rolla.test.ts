/// <reference types="jest" />
// TypeScript 6 no longer auto-includes @types/*; reference jest's globals here
// so they stay out of the library's own type build.
import type { RollaCloseEvent, RollaConfiguration } from '../types';

// Self-contained mock of the two react-native pieces the wrapper touches: the
// TurboModule registry (returns a recording native module) and the event
// emitter (a plain in-memory registry with an `__emit` back door). Everything
// lives inside the factory because jest hoists `jest.mock` above imports.
jest.mock('react-native', () => {
  // No local type aliases here: jest's hoisting plugin treats even a type
  // identifier as an out-of-scope reference.
  const listeners = new Map<string, Set<(payload: unknown) => void>>();
  const native = {
    show: jest.fn(async () => undefined),
    dismiss: jest.fn(async () => undefined),
    updateToken: jest.fn(async () => undefined),
    clearSession: jest.fn(async () => undefined),
    destroyEngine: jest.fn(async () => undefined),
    isPresenting: jest.fn(async () => false),
    getNativeSdkVersion: jest.fn(async () => '0.0.0'),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
  };
  class NativeEventEmitter {
    addListener(event: string, listener: (payload: unknown) => void) {
      if (!listeners.has(event)) {
        listeners.set(event, new Set());
      }
      listeners.get(event)!.add(listener);
      return {
        remove: () => {
          listeners.get(event)?.delete(listener);
        },
      };
    }
  }
  return {
    Platform: { OS: 'ios' },
    TurboModuleRegistry: { getEnforcing: () => native },
    NativeEventEmitter,
    __native: native,
    __emit: (event: string, payload: unknown) => {
      listeners.get(event)?.forEach((listener) => listener(payload));
    },
    __listenerCount: (event: string) => listeners.get(event)?.size ?? 0,
  };
});

type MockedReactNative = {
  __native: { show: jest.Mock };
  __emit: (event: string, payload: unknown) => void;
  __listenerCount: (event: string) => number;
};

type RollaModule = typeof import('../index');

const CONFIG: RollaConfiguration = {
  token: 'token',
  partnerId: 'partner',
  environment: 'rnd',
};

const CLOSE: RollaCloseEvent = { reason: 'programmatic' };

/** Lets the awaited native `show()` call settle before events are emitted. */
const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

let rn: MockedReactNative;
let Rolla: RollaModule['Rolla'];

beforeEach(() => {
  // `Rolla` keeps its in-flight show() state in static fields, so every test
  // gets a fresh module registry (and thereby a fresh mock emitter).
  jest.isolateModules(() => {
    rn = require('react-native') as MockedReactNative;
    Rolla = (require('../index') as RollaModule).Rolla;
  });
});

describe('Rolla.show()', () => {
  it('resolves with the close event when the SDK UI is dismissed', async () => {
    const pending = Rolla.show(CONFIG);
    await flush();

    rn.__emit('onClose', CLOSE);

    await expect(pending).resolves.toEqual(CLOSE);
    expect(rn.__listenerCount('onClose')).toBe(0);
    expect(rn.__listenerCount('onError')).toBe(0);
  });

  it('rejects the pending show() when the native side reports a failed presentation', async () => {
    const pending = Rolla.show(CONFIG);
    await flush();

    rn.__emit('onError', {
      code: 'ENGINE_FAILED',
      message: 'The Flutter engine failed to start.',
      presentationFailed: true,
    });

    await expect(pending).rejects.toMatchObject({
      code: 'ENGINE_FAILED',
      message: 'The Flutter engine failed to start.',
    });

    // The failed attempt must not wedge the wrapper: subscriptions are gone
    // and the next show() is accepted instead of throwing ALREADY_PRESENTING.
    expect(rn.__listenerCount('onClose')).toBe(0);
    expect(rn.__listenerCount('onError')).toBe(0);
    const next = Rolla.show(CONFIG);
    await flush();
    rn.__emit('onClose', CLOSE);
    await expect(next).resolves.toEqual(CLOSE);
    expect(rn.__native.show).toHaveBeenCalledTimes(2);
  });

  it('keeps show() pending on an error raised while the SDK UI is running', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const pending = Rolla.show(CONFIG);
    await flush();

    rn.__emit('onError', {
      code: 'FLUTTER_ERROR',
      message: 'Flutter error [x]: y',
      presentationFailed: false,
    });

    await expect(
      Promise.race([pending, flush().then(() => 'still pending')])
    ).resolves.toBe('still pending');
    expect(warn).toHaveBeenCalledTimes(1);

    rn.__emit('onClose', CLOSE);
    await expect(pending).resolves.toEqual(CLOSE);
    warn.mockRestore();
  });

  it('passes the configuration and transition to native, defaulting the transition', async () => {
    const first = Rolla.show(CONFIG);
    await flush();
    rn.__emit('onClose', CLOSE);
    await first;

    const second = Rolla.show(CONFIG, { transition: 'fade' });
    await flush();
    rn.__emit('onClose', CLOSE);
    await second;

    expect(rn.__native.show).toHaveBeenNthCalledWith(1, CONFIG, 'default');
    expect(rn.__native.show).toHaveBeenNthCalledWith(2, CONFIG, 'fade');
  });

  it('rejects a second show() while one is in flight without calling native', async () => {
    const pending = Rolla.show(CONFIG);
    await flush();

    await expect(Rolla.show(CONFIG)).rejects.toMatchObject({
      code: 'ALREADY_PRESENTING',
    });
    expect(rn.__native.show).toHaveBeenCalledTimes(1);

    rn.__emit('onClose', CLOSE);
    await expect(pending).resolves.toEqual(CLOSE);
  });

  it('propagates a native rejection and clears the in-flight state', async () => {
    rn.__native.show.mockRejectedValueOnce(
      Object.assign(new Error("Missing required field 'token'."), {
        code: 'INVALID_CONFIG',
      })
    );

    await expect(Rolla.show(CONFIG)).rejects.toMatchObject({
      code: 'INVALID_CONFIG',
    });
    expect(rn.__listenerCount('onClose')).toBe(0);
    expect(rn.__listenerCount('onError')).toBe(0);

    const next = Rolla.show(CONFIG);
    await flush();
    rn.__emit('onClose', CLOSE);
    await expect(next).resolves.toEqual(CLOSE);
  });
});
