require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  # `RollaWrapper` — the pod / iOS framework / Android module name. This is
  # the wrapper layer that adapts the native Rolla SDK to React Native.
  #
  # We cannot use the bare name "Rolla" or "RollaSdk" because either would
  # collide with the native iOS framework `RollaSDK.framework` (macOS is
  # case-insensitive) or with the native Android `com.rolla.sdk.wrapper.Rolla`
  # class we import. "RollaWrapper" stays distinct everywhere.
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

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES"
  }

  # Exact pin to the native iOS SDK. Bump in lockstep with the compatibility
  # matrix in README.md. CocoaPods will fail fast if the consumer's Podfile
  # pins a conflicting RollaSDK version — that is the intended behavior.
  s.dependency "RollaSDK", "0.1.10"

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency "React-Core"
  end
end
