#import "RollaWrapper.h"
#import <ReactCommon/RCTTurboModule.h>
#import <RollaWrapper/RollaWrapper-Swift.h>

static NSString *const kEventClose          = @"onClose";
static NSString *const kEventError          = @"onError";
static NSString *const kEventTokenRefreshed = @"onTokenRefreshed";
static NSString *const kEventTokenExpired   = @"onTokenExpired";

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
     resolve:(RCTPromiseResolveBlock)resolve
      reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *token = config[@"token"];
    if (![token isKindOfClass:[NSString class]] || token.length == 0) {
      reject(@"INVALID_CONFIG", @"Missing required field 'token'.", nil);
      return;
    }
    NSString *partnerId = config[@"partnerId"];
    if (![partnerId isKindOfClass:[NSString class]] || partnerId.length == 0) {
      reject(@"INVALID_CONFIG", @"Missing required field 'partnerId'.", nil);
      return;
    }

    if (self.rollaBridge.isPresenting) {
      reject(@"ALREADY_PRESENTING",
             @"Rolla is already presenting. Dismiss it before calling show() again.",
             nil);
      return;
    }

    UIViewController *presenter = [self topPresentedViewController];
    if (presenter == nil) {
      reject(@"NO_PRESENTER", @"Unable to find a view controller to present from.", nil);
      return;
    }

    NSString *environment = config[@"environment"] ?: @"rnd";
    NSArray<NSString *> *modules = config[@"disabledModules"];
    if (![modules isKindOfClass:[NSArray class]]) {
      modules = config[@"modules"];
      if (![modules isKindOfClass:[NSArray class]]) modules = nil;
    }
    NSNumber *expiresIn = config[@"tokenExpiresIn"];
    if (![expiresIn isKindOfClass:[NSNumber class]]) expiresIn = nil;

    NSString *refresh = config[@"refreshToken"];
    if (![refresh isKindOfClass:[NSString class]]) refresh = nil;
    NSString *userId = config[@"userId"];
    if (![userId isKindOfClass:[NSString class]]) userId = nil;

    NSDictionary *branding = config[@"branding"];
    if (![branding isKindOfClass:[NSDictionary class]]) branding = nil;

    NSNumber *showSettings = config[@"showSettingsButton"];
    BOOL showSettingsBool = (showSettings != nil && [showSettings isKindOfClass:[NSNumber class]])
        ? [showSettings boolValue] : YES;

    NSString *err = [self.rollaBridge showWithToken:token
                                  refreshToken:refresh
                                tokenExpiresIn:expiresIn
                                        userId:userId
                                     partnerId:partnerId
                                   environment:environment
                                       modules:modules
                                      branding:branding
                            showSettingsButton:showSettingsBool
                                     presenter:presenter];
    if (err != nil) {
      reject(@"SHOW_FAILED", err, nil);
    } else {
      resolve(nil);
    }
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
  resolve([RollaBridge nativeSdkVersion]);
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

- (void)rollaBridgeDidFailWithCode:(NSString *)code message:(NSString *)message {
  if (!self.hasListeners) return;
  [self sendEventWithName:kEventError body:@{ @"code": code, @"message": message }];
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
