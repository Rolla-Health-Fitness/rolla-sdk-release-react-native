require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Single source of truth for the native SDK pin. `android/build.gradle` reads the
# same field, and both platforms surface it through `Rolla.getNativeSdkVersion()`,
# so the reported version can never drift from what is actually linked.
native_sdk_version = package["nativeSdkVersion"]
if native_sdk_version.nil? || native_sdk_version.empty?
  raise "package.json is missing `nativeSdkVersion`"
end

Pod::Spec.new do |s|
  s.name         = "RollaWrapper"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.swift_version = "5.0"
  s.source       = { :git => "https://github.com/Rolla-Health-Fitness/rolla-sdk-release-react-native.git", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  # Keep our ObjC++ headers OUT of the auto-generated umbrella so the
  # framework module (consumed as ObjC) doesn't try to scan ObjC++ stdlib
  # imports like <utility>, <optional>, <tuple>.
  s.private_header_files = "ios/**/*.h"

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    # Stringified in RollaWrapper.mm — the value getNativeSdkVersion() returns.
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) ROLLA_NATIVE_SDK_VERSION=#{native_sdk_version}"
  }

  # Exact pin to the native iOS SDK. CocoaPods fails fast if the consumer's
  # Podfile pins a conflicting RollaSDK version — that is the intended behavior.
  s.dependency "RollaSDK", native_sdk_version

  install_modules_dependencies(s)
end
