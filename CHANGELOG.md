# Changelog

**Tags used in this changelog:**

- `[breaking]` — changes that require immediate attention in order to avoid a failed build.
- `[feature]` — new SDK capability.
- `[improvement]` — existing behavior enhanced, optimized or refactored.
- `[documentation]` — documentation-only change.
- `[fix]` — bug fix.

---

## 0.1.15

### Both platforms

- **[feature] Rolla notifications now identify themselves and name their tap destination.** Every notification the SDK shows carries a structured payload, and the new `Rolla.notificationTarget(...)` resolver (iOS and Android wrappers) turns the tap your app receives into a typed destination: `null`/`nil` for a notification that is not Rolla's, an app-settings request for the background-location permission warning, or a `RollaScreen` to pass straight to `openScreen`. The inactivity reminder targets Insights (Home when the insights module is disabled), the band battery warning targets Home, and both Android ongoing workout notifications ("Workout in progress" and "Location Tracking" — the latter previously did nothing when tapped) target `resume`, the live workout. Flutter integrations route taps on the SDK-shown notifications automatically, including a tap that cold-launched the app; the two Android workout notifications are posted natively and resolve through `notificationTarget` in native hosts.

- **[fix] The loading indicator shown while the SDK starts now follows the host's `primaryColor` and `themeMode`.** Native iOS/Android hosts saw an off-brand spinner (mauve in light mode, teal in dark mode) between the host app and the SDK UI even when `RollaBranding.primaryColor` was set. It is now seeded from the configured primary color, matching the SDK's in-app indicators, and follows the configured theme mode instead of always following the device.

- **[fix] Manually added activities now count toward the daily Active Points and Active Calories totals.** Previously a manual activity kept its own points, but the daily totals on Home never included them.

- **[improvement] Swimming activities now show pace per 100 m (per 100 yd for imperial units) instead of per km.** Swim summaries also display distance and average pace when the activity carries that data, such as swims imported from Garmin.

- **[improvement] General bugfixes and stability improvements.**

### Android

- **[fix] Swiping the host app away from Recents mid-workout no longer resumes a stale SDK session on the next launch.** While a GPS or Bluetooth workout (or a band firmware update) is running, the SDK's foreground service keeps the app process alive through a Recents swipe, so the cached engine survived and the next `show()` re-presented the in-progress activity screen instead of a fresh Home with the resume-activity prompt. The swipe now stops workout tracking and tears the engine down, so the next launch behaves like a cold start and the interrupted activity is offered for Continue / Save / Discard, as on iOS. Closing the SDK with the back button and re-opening it in the same session still resumes seamlessly.

- **[fix] `openScreen` now brings an already-presented SDK UI back to the front when the host's own activities cover it.** Previously the navigation succeeded — the status reported `OPENED` — but happened invisibly behind the covering activity, leaving the user where they were. The common trigger is a notification tap, which always launches a host activity on top of the presenting SDK.

- **[fix] Scheduled reminders (the inactivity reminder and the evening battery warning) never displayed.** The broadcast receivers `flutter_local_notifications` fires scheduled notifications through were missing from every consuming app's merged manifest, so the alarms were silently dropped. The SDK now declares them itself — no host change needed, and a host that already declares these receivers with the standard attributes (`android:exported="false"`, per the `flutter_local_notifications` README) merges cleanly — along with `RECEIVE_BOOT_COMPLETED` so pending reminders survive a reboot. Scheduling also falls back to an inexact alarm when the app may not schedule exact alarms (`SCHEDULE_EXACT_ALARM` not declared or not granted — denied by default on Android 14+), instead of silently dropping the reminder.

- **[fix] Steps, sleep and HRV data no longer silently go missing on Android.** The failure fixed for pulse in 0.1.14 could hit every other band transfer too: an interrupted transfer froze the sync on that stage, and a corrupt band record could push the sync window a day or two into the future, making the metric vanish until the clock caught up. Every band transfer now recovers on its own within seconds, a corrupt record can no longer push the sync window into the future, and a transfer cut short defers its remainder to the next sync instead of skipping it.

---

## 0.1.14

### Both platforms

- **[breaking] `showSettingsButton` is renamed to `showOptionsButton`, and the entry moved into the top-right app bar actions.** The Settings button that was positioned at the very bottom of the Home scroll is now a three-dot options action at the trailing edge of the Home app bar, visible without scrolling. It opens the same bottom sheet of shortcuts as before, now titled "Options". The flag's meaning and default (`true`) are unchanged — so just rename the parameter on your `RollaConfiguration`.

- **[feature] Open a specific SDK screen from the host app.** The new `openScreen` API (Flutter: `RollaSDK.openScreen`, iOS/Android wrappers: `openScreen`) opens the Insights feed, the activity history, the goals editor, the SDK Home screen, or the last-opened state (`resume`) directly — presenting the SDK UI first when it is not on screen, honoring an optional presentation transition. The opened screen is the root of the SDK UI: back returns the user straight to your app, and `home` restores the regular Home entry point without an engine restart. Every outcome is a typed `RollaOpenScreenStatus`; the SDK's mandatory startup steps (onboarding, consent, permissions, data-source connection) always take precedence over the request.

- **[feature] Bluetooth heart rate monitor support.** A standard Bluetooth heart rate monitor (Polar, Garmin, Wahoo and similar chest straps and arm bands) can now be connected from the activity setup screen and used as a workout's heart rate source instead of the Rolla Band. Previously connected monitors are remembered and reconnected automatically when in range, and one that drops mid-workout reconnects on its own. A workout tracked with a monitor does not use a paired Band at all.

- **[feature] Manual sleep logging and editing.** A user can log a night their wearable missed, or correct one it got wrong, from the sleep detail screen — adjusting the sleep window on the chart or through time fields, and assigning a stage to stretches the device did not record. A night with no stage detail can be logged as a single in-bed block and is shown as a sleep-duration clock. A manual entry replaces whatever was stored for that night and survives later device syncs, and sleep metrics, scores and the home screen refresh as soon as one is saved. Available for the last 7 days.

- **[feature] One-time historical data import when a source is connected.** After connecting Apple Health, Health Connect, Garmin or Oura, the user is offered a backfill of the date range the backend reports as available, and can accept it, skip it (it stays re-offerable), or start it later from the "Import history" action in Data Sources. Apple Health and Health Connect are read on-device with per-stage progress while the screen stays open; Garmin and Oura are backfilled by the backend and the screen just confirms the job started. An on-device import that was interrupted is picked up again from the same action.

- **[fix] Leaderboard messages now follow the selected language.** The notice shown after leaving a leaderboard, which explains that rejoining is not possible for 7 days, along with the leaderboard error messages, always appeared in English regardless of the app language.

- **[fix] Home totals update immediately after deleting an activity.** The Active Points and Active Calories tiles and the Activity score card now refetch as soon as an activity is deleted, instead of correcting only after a manual reload.

- **[fix] Activity catalog search now ignores diacritics.** Searching is accent-insensitive (e.g. "trcanje" matches "Trčanje"), and the Yoga activity name is corrected in Bosnian/Serbian ("Joga" / "Јога").

- **[fix] Steps, Move Hours and Active Points show the full statistics grid over 7d/30d/1y.** These metric detail pages showed a single "Total" card; they now show Avg, Min, Max and Score, computed over the days that have data.

- **[fix] The Readiness and Activity screens no longer show an error while the user's session is being renewed.** They now wait for the renewal and load normally, and any error message they do show is translated into the selected language instead of appearing as technical text.

- **[improvement] Hardened token handling.** You can no longer break a session by passing outdated tokens — the SDK ignores anything older than what it already holds. And answering `onTokenExpired` (Android) / `rollaDidRequestTokenRefresh` (iOS) with `updateToken()` within 10 seconds now recovers the failing request invisibly, with no error state.

- **[improvement] Notification texts are now translated for every supported language.** The engagement and battery notification strings moved into the SDK's localization system, and date-of-birth fields now render month names in the selected language, including Latin-script Serbian.

- **[improvement] General bugfixes and stability improvements.**

### Android

- **[breaking] The Add-to-App public API types moved into sub-packages.** `Rolla` and `RollaListener` keep their package (`com.rolla.sdk.wrapper`); everything else moved, so imports need updating — no types were renamed and no behavior changed. `RollaConfiguration`, `RollaBranding`, `RollaLanguage`, `RollaThemeMode`, `RollaTransition`, `RollaDataSource` and `RollaDisabledModule` are now in `com.rolla.sdk.wrapper.config`; `RollaError` and `RollaCloseReason` in `com.rolla.sdk.wrapper.features.session`; the activity payloads in `…features.activity`, band payloads in `…features.band`, `RollaSyncResult` and `RollaPrimarySourceChanged` in `…features.sync`, `RollaGoalsChanged` in `…features.goals`, and `RollaProfileUpdated` in `…features.profile`. If you declare `RollaFlutterActivity` in your own manifest, it is now `com.rolla.sdk.wrapper.engine.RollaFlutterActivity`.

- **[fix] Pairing a band again right after unpairing it now works reliably.** Until now that attempt could quietly fail — the screen returned to the start of pairing with no message — and only succeeded after waiting around a minute.

- **[fix] Pulse data no longer silently goes missing on Android.** An interrupted band transfer could leave heart rate unsynced for days — the sync appeared to succeed while steps and sleep kept updating. The transfer now recovers on its own within seconds, and any missed stretch is fetched by the next sync.

---

## 0.1.13

### Both platforms

- **[feature] Insights entry on the Home screen.** A new Insights entry card in the Home Overview section shows the unread insights count and opens the insights feed page. This option can be disabled alongside all other insights UI by adding `RollaDisabledModule.insights` value to the `disabledModules`.

- **[feature] Optional Goals section on Home via the new `showGoalsSection` configuration flag.** `RollaConfiguration` gains an optional `showGoalsSection` (default `false`). When `true`, the bottom of the Home screen shows the user's enabled goals with an edit action — or a select-goals call-to-action when zero goals are selected.

- **[feature] New `RollaTransition` animation on the `show()` method.** A new optional `transition` parameter controls how the SDK UI opens and closes: `.default` is the existing animation, `.fade` is a cross-fade. The closing transition always mirrors the opening one.

- **[fix] Confirmation before changing the primary data source.** Switching your primary data source now asks for confirmation first, so it can no longer happen from an accidental tap.

- **[improvement] Refined Serbian translations.** Both Serbian scripts — Latin and Cyrillic — received a native-speaker terminology pass across the entire SDK UI.

- **[improvement] General bugfixes and stability improvements.**

---

## 0.1.12

### Both platforms

- **[feature] New headless public SDK methods.** Four new methods that all run **headlessly** — no SDK UI needs to be opened; after initializing the SDK, host apps can call them directly:
  - **`warmUpEngine()`** — starts and configures the SDK ahead of time without showing any UI, so the first `show()` is instant and the headless reads below work before the SDK has ever been presented. Optional: the methods below already warm up the engine if needed, but this method gives host apps the freedom to warm the engine separately and control the timing.
  - **`syncHealthData()`** — runs a full sync of the user's primary health data source and returns a typed result: `success` (with whether new data was uploaded, when it started and completed, and a `syncedData` breakdown of what was synced), `skipped` (with a documented reason, e.g. no band paired, the band not reachable, or a missing permission), or `failure`. It never throws, and reports the same result to the `rollaDidCompleteHealthDataSync` delegate method (iOS) / `onSyncHealthDataCompleted` listener method (Android) — named 1:1 after the method so it can't be confused with the UI-sync event. Pass `includeSamples: true` to also get the raw per-sample arrays.
  - **`getBandBatteryLevel()`** — a live battery read from the connected Rolla band, returning a typed result: a percentage when available, or a documented "unavailable" reason (no band paired, band not reachable, Bluetooth off, permission not granted).
  - **`getPairedBandInfo()`** — answers "does this account currently have a Rolla band?" with **zero Bluetooth** — no scan, no connect, no BLE permission; works with Bluetooth off. Returns a typed result: `bandPaired` (with the band's MAC address plus the last cached battery/firmware/serial, when available), `noBandPaired` (the user's profile confirms no band), or `unknown` (offline with no local record — reported instead of guessing). The lookup is network-first, so a band unpaired remotely from another device is reported correctly.

  All of these methods can be called without the SDK UI being opened or launched, hence the term "headless". But because headless calls have no UI to prompt from, the host owns OS permissions: when one is missing the methods fail fast with a source-specific reason (`bluetoothPermissionRequired`, `bluetoothUnavailable`, `appleHealthPermissionRequired`, `healthConnectPermissionRequired`) rather than prompting.

- **[feature] Added new module — Leaderboards.** Opt-in competitive rankings compare users on their Health Score or Active Points against others in the tenant over weekly and monthly periods. The profile screen shows a summary card with the user's rank per challenge type; the detail page lists ranked participants centered on the user's position with bidirectional pagination, supports weekly/monthly toggling and browsing up to 6 months of history, and lets users join or leave (with a 7-day rejoin cooldown). The module is wired end-to-end to the backend leaderboard API and can be hidden everywhere in the SDK UI by passing the new `RollaDisabledModule.leaderboards` value in `disabledModules`, alongside the existing `weight` and `bloodPressure` values.
- **[improvement] Onboarding profile data can be skipped by setting the profile in advance.** Host apps can now call `POST /api/setprofile` (with the user's bearer token and `Partner-ID` header, like the other auth-API endpoints) before first presenting the SDK: when the profile already carries a username, birthdate, gender, height, and weight, the SDK skips its account-details onboarding screen entirely. Weight remains mandatory when the weight module is disabled because calorie calculations depend on it. The completeness rule no longer demands units, country, or language (they default or self-heal), and a partially set profile pre-fills the onboarding form so users only complete the gaps.
- **[feature] Host-controlled SDK language.** `RollaConfiguration` gains an optional `language`, typed by the new `RollaLanguage` enum listing every language the SDK ships (`english`, `german`, `spanish`, `croatian`, `bosnian`, `serbianLatin`, `serbianCyrillic`, `arabic`). When set, that language is authoritative for the Flutter engine's lifetime: persisted picks and the backend profile cannot override it. Changing the configured language requires destroying and recreating the engine, like other SDK configuration changes. A configured language is also written to the user's backend profile at startup when it differs, so backend-generated content (goal labels, insights) matches the SDK UI language.
- **[feature] Host event listener: eleven SDK events pushed to the host app.** The existing `RollaDelegate` (iOS) / `RollaListener` (Android) gains eleven methods a host can override to observe what happens inside the SDK, without polling:

  | Event | iOS | Android | Payload |
  |---|---|---|---|
  | Activity completed | `rollaDidCompleteActivity` | `onActivityCompleted` | `RollaCompletedActivity` |
  | UI sync completed | `rollaDidCompleteUISync` | `onUiSyncCompleted` | `RollaSyncResult` |
  | Band paired | `rollaDidPairBand` | `onBandPaired` | `RollaBandInfo` |
  | Band unpaired | `rollaDidUnpairBand` | `onBandUnpaired` | `RollaBandInfo` |
  | Primary source changed | `rollaDidChangePrimarySource` | `onPrimarySourceChanged` | `RollaPrimarySourceChanged` |
  | Goals changed | `rollaDidChangeGoals` | `onGoalsChanged` | `RollaGoalsChanged` |
  | Profile updated | `rollaDidUpdateProfile` | `onProfileUpdated` | `RollaProfileUpdated` |
  | Band connected | `rollaDidConnectBand` | `onBandConnected` | `RollaBandInfo` |
  | Band disconnected | `rollaDidDisconnectBand` | `onBandDisconnected` | `RollaBandInfo` |
  | Activity started | `rollaDidStartActivity` | `onActivityStarted` | `RollaStartedActivity` |
  | Activity removed | `rollaDidRemoveActivity` | `onActivityRemoved` | `RollaRemovedActivity` |

  All methods have default no-op bodies, so existing integrations compile unchanged. Events are delivered for the engine's lifetime — they keep flowing after the SDK UI closes, as long as the engine is alive. Firing semantics and lifecycle guarantees are documented on the delegate/listener methods.
- **[feature] Hide selected data sources from the SDK UI.** A new `disabledDataSources` option hides specific data-source connect options (Band, Garmin, Oura, Apple Health, Health Connect) wherever a source is offered; omit it or pass an empty set to offer every source (default, no change for existing partners). Already-connected sources stay visible for viewing/disconnecting. When only the Band is left, the picker is skipped and onboarding goes straight to band pairing.
- **[feature] Added Spanish (Español) language support.**
- **[feature] Added Serbian language support in both scripts — Cyrillic (ћирилица) and Latin (latinica).**
- **[feature] Insights Settings page for personalized context.** Added a new Insights Settings screen that lets users provide additional personal context — such as lifestyle details, health goals, and preferences — so AI-generated insights can be more relevant and tailored to the individual.
- **[breaking] `RollaBranding` reworked to hold exactly the options that affect the SDK.** It now has six fields, all optional: `hostAppName` (names the host app in the consent intro and the permission prompts, in every SDK language), `primaryColor` (seeds the SDK's entire color scheme), `themeMode` (renamed from `defaultThemeMode`, now typed by the new `RollaThemeMode` enum), `headerLogoAsset`, `privacyUrl`, and `removeRollaBandReferences` (moved from `RollaConfiguration`, same semantics). A set field overrides the SDK's built-in default individually and an unset field keeps it — previously, passing any branding replaced all defaults at once, silently dropping e.g. the consent screen's privacy-policy link. The removed options — `appName`, `secondaryColor`, `accentColor`, `brightness`, `defaultLocale`, `termsUrl` — had no effect on the SDK UI.
- **[improvement] Added clearer guidance for profile metrics and data sources.** Profile details now explain BMI, BMR, and max heart rate with source links, and the Data Sources page clarifies how primary and secondary sources work.
- **[improvement] Split the combined permission screen into two separate pages for Bluetooth and Location.** Each permission now has its own dedicated page with contextual copy explaining why it is needed, giving users a clearer understanding before granting access.
- **[fix] Opening the app without an internet connection no longer signs you out or gets stuck on a loading spinner.** Your session is kept and you land on the home screen in offline mode, with data refreshing once you're back online.
- **[fix] Saving an interrupted activity now keeps the duration shown on the recovery prompt.** The saved activity's summary now matches the time displayed on the Save button instead of showing a different duration.
- **[fix] Activities with little or no distance no longer show a wrong average pace.** When there isn't enough distance to calculate a meaningful pace, the average pace is now left blank instead of displaying an unrealistic value.
- **[fix] Bugs and stability fixes.** Various internal fixes and stability improvements.

### Android

- **[improvement] Neutral Android notification channel names.** The two SDK-created Android notification channels that end users see in system settings were renamed from "Rolla Warnings" and "Engagement" to the brand-neutral "Important Alerts" and "Engagement Tips". This keeps the channels consistent with the host app's branding.

### iOS

- **[breaking] `RollaDelegate` error method renamed: `rolla(_:didFailWithError:)` → `rollaDidFailWithError(_:error:)`.** Aligns the one anonymous-form method with the rest of the `rollaDid…` delegate family. Migration is a signature change only — same parameters, same behavior: `func rollaDidFailWithError(_ rolla: Rolla, error: RollaError)`.

---

## 0.1.11

### Both platforms

- **[improvement] Updated Stale Data Notification Appearance to be less intrusive.** On app open, stale data now shows a brief toast instead of a full-screen dialog. Tapping the toast reveals the full details. Manual refresh still shows the full dialog. The refresh icon also turns orange when data is stale.

- **[feature] Activity History page.** Added a dedicated Activity History screen that displays all past workouts in a monthly calendar view with summary stats and shareable card previews.

- **[feature] Custom Rolla Analytics for SDK usage tracking.** Added a new `analytics` module that captures basic in-app usage events and reports them to the Rolla backend. Events are queued locally and delivered reliably across offline periods.

- **[feature] Added `disabledModules` to `RollaConfiguration`.** Pass a set of `RollaDisabledModule` values to hide a module's entire UI. `weight` and `bloodPressure` are the first two modules supported for disabling; see `RollaDisabledModule` for the current list.

- **[feature] Added `removeRollaBandReferences` flag to `RollaConfiguration`, default value `true`.** SDK partner apps now default to generic "fitness device" wording across the SDK UI, with Rolla Band references shown only when the flag is set to `false`.

- **[feature] Manual activity logging.** Added a new `manualActivity` module that lets users log a workout after the fact. Pick an activity type, set duration and intensity, and the SDK estimates calories — using available heart-rate samples for the window when present, or a metabolic-equivalents fallback otherwise.

- **[feature] New activities: Spa and Calisthenics.** Added a `Spa` category (Sauna, Steam Room, Cold Plunge, Jacuzzi) that is available only from the manual activity logger — these entries do not appear in the live-tracking start list. `Calisthenics` was added under Strength and can be both live-tracked and logged manually.

- **[feature] Smartphone-only workout tracking.** Workouts can now be started and tracked without a paired wearable, using the phone's pedometer and motion sensors. The activity session transparently falls back to phone sensors when no wearable is connected and merges streams when one is. New permissions are required on Android — see below.

- **[breaking] Removed the previously undocumented `enabledModules` parameter from `RollaConfiguration`.** Replaced by `disabledModules`. Partners weren't using the old parameter, but anything that referenced it must switch to the new API.

- **[improvement] Redesigned Insights experience.** Insights section has been moved off the SDK's Home page into its own dedicated **Insights tab** in the SDK's bottom navigation, visible only to partners using the bottom navigation bar. The tab shows a daily scrollable feed with filters, full article views (embedded charts, maps, route previews, highlight tiles), and ratings. Partners that don't use the SDK's bottom navigation will no longer see the Insights section.

- **[improvement] Redesigned the bottom navigation bar.** The SDK's bottom navigation has been redesigned from Material's default bottom bar into a floating pill with a blurred backdrop, an animated sliding indicator behind the active tab, and a separated circular FAB for starting workouts. Three primary tabs (Home, Insights, Profile) replace the previous layout. Partners that aren't using the SDK's bottom navigation will only see the positional change of the Plus button for starting activities, from bottom centre to bottom right.

- **[improvement] FAB quick-actions overlay redesigned.** The home FAB now opens a quick-actions sheet with entries for starting a live workout and logging a manual activity. The overlay replaces the previous quick-actions header behavior on the Home tab.

- **[improvement] Active calories model updated to the Compendium of Physical Activities.** Walking, running, and cycling kcal output now uses a speed-based MET table instead of fixed or curve-fitted values. The same workout will report different calorie totals than prior SDK versions — typically higher for walking, comparable for running and cycling.

- **[fix] Fixed incorrect Active Points abbreviation translations.** Active Points values now use the `AP`/`AB` abbreviation instead of a translated word, fixing incorrect plural forms in some locales.

- **[fix] Apple Health and Health Connect now sync data when connected as a secondary source.** Previously, when a user's primary source was the band (or another service), workouts, weight, and blood pressure from a secondary Apple Health / Health Connect connection stopped syncing entirely. These data types are now uploaded automatically on each Home resume, while heart rate, HRV, steps, and sleep remain owned by the primary source.

- **[feature] Added a Privacy screen to Account Settings.** The screen fetches partner-specific privacy notice markdown from the backend and renders it with placeholders already resolved.

- **[fix] Restored the original Terms of Use and Privacy Policy links.**

- **[improvement] Reduced SDK payload size by approximately 73 MB by dropping unused bundled media assets.**

- **[fix] Active workout distance no longer resets to 0 after the app is closed or loses connection.** If a workout is interrupted (for example by closing the app or switching to airplane mode), the previously tracked distance is now restored on resume so it continues from where it left off instead of starting over.

- **[fix] Fixed incorrect activity session being restored after an interrupted workout.** Recovery now targets your most recent session and clears out stale, abandoned ones.

- **[fix] Workout pause segments no longer leak to workout data.** Fixed a bug where samples recorded during a pause leaked into the workout samples.

- **[fix] Fixed Rolla band activities being auto-ended mid-workout during low-motion sessions.** Disabled a band firmware flag that was being toggled on unintentionally, which let the band terminate user-started activities after long stationary stretches.

- **[fix] Remaining connected data source is now promoted to primary when the Rolla Band is unpaired.** Previously, if the band was the primary source and another service (e.g. Garmin or Apple Health) was connected as secondary, unpairing the band left that service as secondary until the app was restarted. The remaining connected service is now switched to primary right away, with no restart required.

- **[improvement] Reworked the in-app FAQ content.** The Help & Support FAQ screen is now organised into clear sections — Understanding Your Health Metrics, Wearable Connection & Syncing, Why Can't I See a Specific Metric?, and Wearable Compatibility. Answers now cover all supported wearables (Rolla Band, Garmin, and Apple Watch / Apple Health) with device-specific guidance for connecting, syncing, and missing metrics, rather than focusing on the Rolla Band alone. Updated across all supported languages.

- **[fix] Home screen no longer flickers or briefly shows 0 when refreshing.** When pulling down to refresh the Home screen, the Readiness, Activity, Health Score, and metrics cards used to blink and momentarily display a 0 before the new numbers arrived. They now stay on screen showing your current values and update smoothly in place once the latest data is ready.

- **[fix] Stale-data warning now names the correct data source.** The dialog referenced Garmin even when Oura was the connected source; it now names the actual primary source.

- **[feature] Unread Insights badge & filtering.** The Insights tab now displays an unread badge indicating new articles since the user's last visit, and adds filter controls to narrow the feed by read/unread status.

- **[fix] Account details screen improvements during sign-up.** The name field now validates on blur, country/city selection handles offline gracefully, and the screen's text field and searchable dropdown are now exported for reuse in the white-label app.

- **[fix] Indoor workouts no longer wait 30–45s on "Waiting for GPS…" before showing you on the map.** The map now appears almost immediately using a cached position while precise GPS warms up, without affecting recorded route accuracy.

### Android

- **[breaking] `ACTIVITY_RECOGNITION` permission now required.** The bundled SDK manifest declares `android.permission.ACTIVITY_RECOGNITION` (API 29+) to read the phone's step counter for smartphone-only workouts. Ensure your host app does not strip it via `tools:node="remove"` and that your Play Console listing covers the new permission rationale.

### iOS

- **[breaking] `NSMotionUsageDescription` now required in the host app's `Info.plist`.** Smartphone-only workouts use `CMPedometer` to count steps and measure cadence. iOS terminates any app that calls `CMPedometer.startUpdates` without a `NSMotionUsageDescription` string declared. Add the key with a user-facing rationale (e.g. "Used to count steps and measure cadence during workouts when no fitness band is connected") to your host app's `Info.plist`, or smartphone-only workouts will crash the app on first start.

- **[improvement] Live Workout widget honors phone-only mode.** `LiveWorkoutAttributes.ContentState` gained an `isPhoneOnly` flag so the Dynamic Island and Lock Screen views can hide band-specific elements (heart rate, band-disconnected banner) when a workout is being tracked from the phone alone. The flag is defaulted to `false` so Live Activities started before this update continue to decode cleanly across the upgrade.

---

## 0.1.10

### Both platforms

- **[feature] Added the `showSettingsButton` boolean config on `RollaConfiguration`.** Renders a Settings button on the Home screen that opens a sheet with Data Sources and Goals shortcuts. Defaults to `true` since most partners need it automatically.

- **[improvement] Improved the GPS tracking to be more accurate on iOS and Android.** The location pipeline has been refactored on both platforms to hold steady when you're standing still, filter out GPS zig-zags, and recover cleanly when you start moving again. Additionally, the in-app map views got some general UX improvements and polishing.

- **[documentation] Added a permissions rationale matrix to the iOS and Android permissions docs.** Each permission is grouped by capability (Location, Bluetooth, Health Connect / Apple Health, etc.) and carries a required/optional status plus a partner-ready rationale suitable for App Store and Play Console submissions.

### Android

- **[breaking] `minSdk` raised from 24 to 26.** Required by the bundled Health Connect plugin's manifest.

- **[breaking] Host-app Kotlin floor raised to 2.2.0.** Required by the bundled `health` plugin's transitive `kotlin-stdlib-jdk7:2.2.10`. Kotlin ≥ 2.1.0 should work as well because of the [version tolerance](https://kotlinlang.org/docs/metadata-jvm.html#maven) rule, but 2.2.0 is still the recommended minimum.

- **[feature] Google Health Connect support.** Android health data can now be synced and tracked from Health Connect.

- **[improvement] Build JDK floor lowered from 21 to 17.** AAR is now compiled with Java 17 (class file major version 61).

### iOS

- **[improvement] Simulator support added (Debug configuration).** `0.1.10` runs on iPhone simulators under the Debug configuration, in addition to the existing Release-on-device support. Hardware-backed features (Bluetooth, etc.) still only work on physical devices.

---

## 0.1.9 — First stable release

`0.1.9` is the first stable release of the Rolla SDK. Per-change entries begin at `0.1.10`.
