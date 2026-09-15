#import "RollaWrapper.h"
#import <ReactCommon/RCTTurboModule.h>
#import <RollaWrapper/RollaWrapper-Swift.h>

// The native SDK pin is injected by RollaWrapper.podspec from package.json's
// `nativeSdkVersion` (GCC_PREPROCESSOR_DEFINITIONS), so the version this module
// reports is the version the podspec links — never a second hand-kept literal.
#ifndef ROLLA_NATIVE_SDK_VERSION
#error "ROLLA_NATIVE_SDK_VERSION is not defined. RollaWrapper.podspec injects it from package.json `nativeSdkVersion`."
#endif
#define ROLLA_STRINGIFY(x) #x
#define ROLLA_STRINGIFY_EXPAND(x) ROLLA_STRINGIFY(x)
static NSString *const kNativeSdkVersion = @ROLLA_STRINGIFY_EXPAND(ROLLA_NATIVE_SDK_VERSION);

static NSString *const kEventClose          = @"onClose";
static NSString *const kEventError          = @"onError";
static NSString *const kEventTokenRefreshed = @"onTokenRefreshed";
static NSString *const kEventTokenExpired   = @"onTokenExpired";

// Matches RollaBridgeError.codeUserInfoKey on the Swift side.
static NSString *const kBridgeErrorCodeKey  = @"code";

@interface RollaWrapper () <RollaBridgeListener>
@property (nonatomic, strong) RollaBridge *rollaBridge;
@property (nonatomic, assign) BOOL hasListeners;
@end

@implementation RollaWrapper

RCT_EXPORT_MODULE()

- (instancetype)init {
  if ((self = [super init])) {
    _rollaBridge = [[RollaBridge alloc] init];
    _rollaBridge.listener = self;
  }
  return self;
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ kEventClose, kEventError, kEventTokenRefreshed, kEventTokenExpired ];
}

- (void)startObserving {
  self.hasListeners = YES;
}

- (void)stopObserving {
  self.hasListeners = NO;
}

- (void)invalidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rollaBridge invalidate];
  });
  [super invalidate];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeRollaWrapperSpecJSI>(params);
}

#pragma mark - Helpers

- (UIViewController *)topPresentedViewController {
  UIWindowScene *foreground = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    UIWindowScene *ws = (UIWindowScene *)scene;
    if (ws.activationState == UISceneActivationStateForegroundActive) {
      foreground = ws;
      break;
    }
    if (foreground == nil) foreground = ws;
  }
  if (foreground == nil) return nil;

  UIWindow *keyWindow = nil;
  for (UIWindow *w in foreground.windows) {
    if (w.isKeyWindow) { keyWindow = w; break; }
  }
  if (keyWindow == nil) keyWindow = foreground.windows.firstObject;

  UIViewController *top = keyWindow.rootViewController;
  while (top.presentedViewController != nil) {
    top = top.presentedViewController;
  }
  return top;
}

#pragma mark - NativeRollaWrapperSpec

- (void)show:(NSDictionary *)config
  transition:(NSString *)transition
     resolve:(RCTPromiseResolveBlock)resolve
      reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *presenter = [self topPresentedViewController];
    if (presenter == nil) {
      reject(@"NO_PRESENTER", @"Unable to find a view controller to present from.", nil);
      return;
    }

    // Configuration parsing and the already-presenting guard live in Swift;
    // both surface here as an NSError carrying the JS rejection code.
    NSError *error = nil;
    BOOL started = [self.rollaBridge showWithConfig:config
                                         transition:transition ?: @"default"
                                          presenter:presenter
                                              error:&error];
    if (!started) {
      NSString *code = error.userInfo[kBridgeErrorCodeKey] ?: @"SHOW_FAILED";
      NSString *message = error.localizedDescription ?: @"Failed to launch Rolla.";
      reject(code, message, error);
      return;
    }
    resolve(nil);
  });
}

- (void)dismiss:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rollaBridge dismiss];
    resolve(nil);
  });
}

- (void)updateToken:(NSString *)token
       refreshToken:(NSString *)refreshToken
          expiresIn:(NSNumber *)expiresIn
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rollaBridge updateToken:token
                refreshToken:refreshToken
                   expiresIn:expiresIn
                  completion:^(NSString *_Nullable err) {
      if (err != nil) {
        reject(@"UPDATE_TOKEN_FAILED", err, nil);
      } else {
        resolve(nil);
      }
    }];
  });
}

- (void)clearSession:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rollaBridge clearSessionWithCompletion:^(NSString *_Nullable err) {
      if (err != nil) {
        reject(@"CLEAR_SESSION_FAILED", err, nil);
      } else {
        resolve(nil);
      }
    }];
  });
}

- (void)destroyEngine:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rollaBridge destroyEngine];
    resolve(nil);
  });
}

- (void)isPresenting:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    resolve(@(self.rollaBridge.isPresenting));
  });
}

- (void)getNativeSdkVersion:(RCTPromiseResolveBlock)resolve
                     reject:(RCTPromiseRejectBlock)reject
{
  resolve(kNativeSdkVersion);
}

// `RCTEventEmitter` provides `addListener:` and `removeListeners:` matching
// the codegen protocol selectors — no overrides needed.

#pragma mark - RollaBridgeListener

- (void)rollaBridgeDidCloseWithReason:(NSString *)reason detail:(NSString * _Nullable)detail {
  if (!self.hasListeners) return;
  NSMutableDictionary *payload = [@{ @"reason": reason } mutableCopy];
  if (detail != nil) payload[@"detail"] = detail;
  [self sendEventWithName:kEventClose body:payload];
}

- (void)rollaBridgeDidFailWithCode:(NSString *)code
                           message:(NSString *)message
                presentationFailed:(BOOL)presentationFailed {
  if (!self.hasListeners) return;
  [self sendEventWithName:kEventError
                     body:@{ @"code": code,
                             @"message": message,
                             @"presentationFailed": @(presentationFailed) }];
}

- (void)rollaBridgeDidRefreshTokenWithToken:(NSString *)token
                                refreshToken:(NSString * _Nullable)refreshToken
                                   expiresIn:(NSNumber * _Nullable)expiresIn {
  if (!self.hasListeners) return;
  NSMutableDictionary *payload = [@{ @"token": token } mutableCopy];
  if (refreshToken != nil) payload[@"refreshToken"] = refreshToken;
  if (expiresIn != nil) payload[@"expiresIn"] = expiresIn;
  [self sendEventWithName:kEventTokenRefreshed body:payload];
}

- (void)rollaBridgeDidRequestTokenRefresh {
  if (!self.hasListeners) return;
  [self sendEventWithName:kEventTokenExpired body:@{}];
}

@end
