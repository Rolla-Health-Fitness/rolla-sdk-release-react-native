#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_REMAP_MODULE(RollaWrapper, RollaWrapper, RCTEventEmitter)

RCT_EXTERN_METHOD(show:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(dismiss:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(updateToken:(NSString *)token
                  refreshToken:(NSString *)refreshToken
                  expiresIn:(NSNumber *)expiresIn
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(clearSession:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(destroyEngine:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(isPresenting:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getNativeSdkVersion:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end

#ifdef RCT_NEW_ARCH_ENABLED
// TurboModule glue. When the consumer builds with `RCT_NEW_ARCH_ENABLED=1`,
// codegen emits `RollaWrapperSpec.h` (driven by `codegenConfig` in package.json)
// and we conform the existing Swift `RollaWrapper` class to it here so the
// TurboModule registry can vend a `NativeRollaWrapperSpecJSI` instance.
// Under Old Arch this whole block compiles out and `RCT_EXTERN_REMAP_MODULE`
// above is the only registration path.
#import <RollaWrapperSpec/RollaWrapperSpec.h>

@interface RollaWrapper (TurboModule) <NativeRollaWrapperSpec>
@end

@implementation RollaWrapper (TurboModule)
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeRollaWrapperSpecJSI>(params);
}
@end
#endif
