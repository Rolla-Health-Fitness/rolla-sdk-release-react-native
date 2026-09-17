# rolla-sdk-release-react-native

Hand-authored source of the npm package `@rolla-health/react-native-sdk`: a New Architecture TurboModule over the
native Rolla SDK (iOS pod `RollaSDK`, Android `com.rolla.sdk:android_release`). Despite the `release-` name this is a
normal source repo, not a bot-owned artifact repo. `README.md` is the partner-facing guide; the RN demo
(`rolla-sdk-demo-react-native`) is the reference integration and must stay in step with the native demo apps.

## Versioning contract

- Lockstep: npm `X.Y.Z` links native SDK `X.Y.Z`. The one exception is `0.1.16`, a React Native-only release that
  links native `0.1.15`; native 0.1.16 never exists and lockstep resumes at 0.2.0. Never publish a `-test.` pin.
- Single pin source: `package.json` → `nativeSdkVersion`. `RollaWrapper.podspec` and `android/build.gradle` read it;
  `getNativeSdkVersion()` reports it. `version` is the npm version.
- The README's partner-docs links point at `rolla-sdk-documentation` branch `release/<nativeSdkVersion>`.

## Pin-bump / release checklist

1. `package.json`: `version` and `nativeSdkVersion`.
2. `README.md`: Versioning table, install snippets, the `getNativeSdkVersion()` example value, and every
   `rolla-sdk-documentation/blob/release/<version>/` link (`grep -c 'blob/release/' README.md`).
3. `CHANGELOG.md`: vendor the SDK changelog section for the release; keep the *React Native only* sections.
4. `yarn typecheck && yarn lint && yarn test`; the example builds on a physical iPhone and Android device
   (`cd example/android && ./gradlew --refresh-dependencies` after a native bump — stale Maven metadata trap).
5. Merge to `dev`, then `git tag vX.Y.Z && git push origin vX.Y.Z` on the merge commit — `release.yml` verifies the
   tag equals `package.json` `version`, refuses `-test.` pins, publishes with npm trusted publishing (OIDC) and
   creates the GitHub Release from the `## X.Y.Z` changelog section. Publishing is idempotent.

## Working rules

- CI (`ci.yml`): lint, build-library, build-android, build-ios on every PR to `dev`. Local `yarn lint` also picks up
  `example/ios/build`, `example/ios/Pods` and `example/android/app/build` when they exist — ignore those hits.
- `example/` is a maintainer smoke harness, not a partner sample; keep partner-facing samples in the demo repo.
- Native error codes reach JS verbatim (`RollaError.code`); wrapper-owned codes are `INVALID_CONFIG`,
  `ALREADY_PRESENTING`, `NO_ACTIVE_SESSION`, `NO_PRESENTER` (iOS), `NO_ACTIVITY` (Android).
- Git: branch `PE-<n>-<slug>` off `dev`, never track `origin/dev`, push with
  `git push -u origin HEAD:$(git branch --show-current)`, squash-merge with a `PE-<n>: Imperative summary` title. No
  ticket IDs in code comments, no `Co-Authored-By` trailers.
