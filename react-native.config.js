// Library autolinking config.
//
// Declaring this file explicitly is required so the React Native CLI's
// autolinking pass marks the library with a `libraryName` and populates
// the C++ TurboModule provider in the consumer app's `autolinking.cpp`.
// Without it, autolinking stops at the Kotlin `RollaWrapperPackage` and
// never wires `RollaWrapperSpec_ModuleProvider`, causing
// `TurboModuleRegistry.getEnforcing('RollaWrapper')` to throw under Bridgeless.
//
// The CLI infers `libraryName` from `codegenConfig.name` in package.json
// and `cmakeListsPath` from the standard android codegen output path —
// we only need to opt in to that behavior here.
module.exports = {
  dependency: {
    platforms: {
      android: {},
      ios: {},
    },
  },
};
