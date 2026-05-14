#import <React/RCTEventEmitter.h>
#import <RollaWrapperSpec/RollaWrapperSpec.h>

// Forward declare the Swift bridge protocol. We can't import the Swift
// header here because consumers of this `.h` (the umbrella) compile as ObjC,
// not ObjC++. The actual conformance lives in the `.mm`.
@protocol RollaBridgeListener;

// `RollaWrapper` is the registered TurboModule. It conforms to the codegen
// protocol `<NativeRollaWrapperSpec>`, owns an instance of the Swift
// `RollaBridge` (which holds the RollaSDK API), and emits the four lifecycle
// events through `RCTEventEmitter`.
//
// Why pure ObjC++ + Swift bridge instead of "Swift TurboModule": Swift cannot
// `import` the codegen `<RollaWrapperSpec/RollaWrapperSpec.h>` (it requires
// `__cplusplus`). Pure ObjC++ here sidesteps that entirely.
@interface RollaWrapper : RCTEventEmitter <NativeRollaWrapperSpec>
@end
