# The Zig iOS app: building, signing, releasing, and the cutover

The Zig iOS app is `apps/nano` built for iOS (nanoui draws it). The Swift app
in `apps/ios` stays the shipping app until the Zig app reaches parity; until
then the two install side by side and ship on separate App Store Connect
records. This page covers how the Zig app is built and signed, how it reaches
TestFlight (`.github/workflows/nano-ios.yml`), and how it replaces the Swift
app.

## Identity

| | Zig app (default) | Zig app at the cutover | Swift app |
| --- | --- | --- | --- |
| Bundle id | `harness.codegraff.ios.nano` | `harness.codegraff.ios` | `harness.codegraff.ios` |
| Name under the icon | Harness Nano | Harness | Harness |
| App Store Connect record | its own | the Swift app's | — |
| Build option | (none) | `-Dios-bundle-id=harness.codegraff.ios` / `ios.sh --bundle-id` | — |

The name follows the bundle id unless `-Dios-display-name` is given
(`src/ios_build_rules.zig`, `displayName`). The version is build.zig.zon's
unless `-Dios-version` / `--version` sets it; the build number
(`CFBundleVersion`) is `-Dios-build-number` / `--build-number`.

## Building

```sh
cd apps/nano
sh scripts/ios.sh sim                      # zig-out/ios/Harness.app, signed ad hoc
sh scripts/ios.sh install-sim [--udid U]   # builds, installs and launches with demo data
sh scripts/ios.sh device --adhoc           # device compile check (won't install)
sh scripts/ios.sh device --identity "<identity>" --profile <dev.mobileprovision>
sh scripts/ios.sh ipa --distribution --identity "<identity>" --profile <store.mobileprovision> \
    --build-number 42                      # zig-out/ios/Harness.ipa
sh scripts/ios.sh <mode> ... --dry-run     # prints the zig build command only
```

Signing comes from arguments or the environment (`HARNESS_IOS_SIGN_IDENTITY`,
`HARNESS_IOS_PROFILE`, `HARNESS_IOS_TEAM_ID`, `HARNESS_IOS_BUNDLE_ID`,
`HARNESS_IOS_BUILD_NUMBER`, `HARNESS_IOS_VERSION`), never from the repository.
The team defaults to the one already public in `testflight.yml`.

- **Simulator**: always ad hoc. The signature carries no entitlements (a
  Simulator app is a Mac process, and the Mac refuses to start one whose ad
  hoc signature claims `aps-environment`: "Launchd job spawn failed", POSIX
  163). Its entitlements go in the program's `__TEXT,__entitlements` section
  instead, as Xcode links them; without an application identifier there the
  Simulator's Keychain refuses every call.
- **Device**: signed with the identity and profile given. With no identity
  the build stops and says what to pass; `--adhoc` is the explicit compile
  check. `--distribution` signs for App Store / TestFlight: production push,
  `beta-reports-active`, no `get-task-allow`.
- **ipa**: only from a real signature (`ipaRefusal`), `Payload/Harness.app`
  zipped with `ditto --norsrc --noextattr`, the signature checked first.

The bundle is assembled in `build.zig` (`iosBundle`) from nanoui's own pieces
(`ios.infoPlist`, `ios.executable`, `tools/ios/finish.sh`) rather than
`ios.app`, so the Info.plist can carry what `ios.app`'s options don't reach.
Every rule (bundle id, signing plan, entitlements, the finishing and ipa
argv, the Info.plist patch, Xcode's DT keys) is a pure function with a test
in `src/ios_build_rules.zig`. If nanoui changes the lines `patchInfo`
replaces, the build stops instead of shipping a plist without them.

## Info.plist parity with the Swift app

| Swift app (`apps/ios/Harness/Info.plist`) | Zig app |
| --- | --- |
| Display name `Harness` | `Harness Nano`, `Harness` at the cutover |
| `ITSAppUsesNonExemptEncryption` false | same |
| URL scheme `harness` (`…auth`) | same, named `<bundle id>.auth` |
| Launch screen color `LaunchBackground` | same (patched into nanoui's `UILaunchScreen`) |
| Orientations, iPad's four, device families 1 and 2 | nanoui's, identical |
| Camera, photo-library-add, speech reasons | same, plus photo library and microphone for the Zig app's attachments and dictation |
| `UIRequiredDeviceCapabilities` arm64 | same |
| Local networking (ATS) | same (the in-process engine's loopback socket) |
| Background modes, associated domains | none in either |
| `NSSupportsLiveActivities` | only with the widget extension embedded |
| `UIAppFonts` | not needed: the Zig app embeds its fonts |
| Icons, `Assets.xcassets` | `apps/nano/assets/ios/Assets.xcassets`, identical to the Swift app's |
| — | DT* keys (DTXcode, DTSDKName, …) on device builds, which App Store Connect checks |

While both apps are installed, a sign-in finished in Safari (a magic link
handing `harness://callback` back) may open either app: both claim the
scheme. Sign-in in the app's own browser sheet is unaffected.

## Tokens: the Keychain

`src/session_store.zig` keeps `session.json`'s body (refresh token, user,
organization) on iOS as a generic password under the Swift app's Keychain
service (`harness.codegraff.ios`), account `harnessSession`, with the Swift
app's accessibility class (after first unlock) and its access group (the
default, the application identifier: no `keychain-access-groups`).

- A `session.json` an earlier build left is moved in once and deleted.
- A write the Keychain refuses (a locked phone) falls back to the private
  file, so a rotated refresh token is never lost; the next load moves it in.
- Signing out deletes ours and the Swift app's token items.
- Desktop keeps its file; tests use an in-memory store.
- `codegraff-key.json` (the CodeGraff gateway key) is still a file.

At the cutover the Zig app has the Swift app's bundle id, so the same default
access group: when it finds no session of its own it reads the Swift app's
`codegraffRefreshToken` and restores it as "needs organization" (the person
picks their organization again). That import is tested against the in-memory
store only; it has not run against a real Swift app's Keychain.

## Push

`src/ios_push.zig`, as `PushNotifications.swift` does it:

- The notification center's delegate is set before UIKit starts, so a tap
  that launched the app is routed: it opens `userInfo["chatId"]` once the app
  is signed in and knows the chat (or after 20 seconds, whatever the list
  says). No banner while the app is open.
- Signed in (or launched signed in) with notifications allowed, the app
  registers with APNs again; the token goes to
  `POST /registry/{org}/push-target?device=` as
  `{"token","environment","prefs":{"done","input","failed"}}`. Turning
  notifications off sends `DELETE`; so does signing out, while the sign-in
  still works (one line in `auth_host.signOutWithIo`).
- The system prompt only follows a yes: onboarding's, or the Notifications
  screen opened with notifications on (`askOnScreen`); never at launch.
- `environment` is `sandbox` in the Simulator and for a development profile,
  `production` otherwise.
- The choices live in NSUserDefaults under the Swift app's keys
  (`notifications.enabled`, `notifications.done|input|failed`). Screens call
  `ios_push.runtime.setEnabled`, `setKind` and `requestPermission`.

## Crash and hang reports

`src/ios_crash_reports.zig`, as `CrashReports.swift` does it: a MetricKit
subscriber saves each diagnostic payload once (`Application Support/
CrashReports/<ms>-<sha256 prefix>.json`, newest 50), and while signed in
sends the ones the edge hasn't taken, oldest first, to
`POST /diagnostics/crash-reports` as a JSON array (at most 10 reports and
about 900 KB a request; 200 or 413 marks them sent in `sent.list`). It is on
unless `crashReports.send` is false in NSUserDefaults, the Swift app's key;
the Settings screen's switch writes it. `summary` gives the list's headline
("Crash: EXC_BAD_ACCESS · SIGSEGV", "Hang (3.2 sec)", …). Reports carry
addresses only; the Zig build keeps no dSYM yet (see "What remains").

## TestFlight: `.github/workflows/nano-ios.yml`

Manual dispatch only, from `main` or a `zig/` branch. It reads the same
secrets as `testflight.yml` (`IOS_AC_API_KEY_P8`, `IOS_AC_API_KEY_ID`,
`IOS_AC_API_ISSUER_ID`). The Zig app isn't built by xcodebuild, so it can't
use Xcode's automatic signing; the run:

1. checks the app record and App ID for the chosen bundle id, adds Push
   Notifications to the App ID if missing, and picks the next build number;
2. creates an Apple Distribution certificate from a key made on the runner
   and an App Store profile for it, in a keychain of its own;
3. runs the nano tests, then `ios.sh ipa --distribution`, and checks the
   signature and the production push entitlement in the `.ipa`;
4. uploads with `xcrun altool --upload-app` and waits for processing;
5. for `external`, adds the build to the one external group and submits it
   for beta review;
6. always revokes the certificate, deletes the profile and the keychain.

One-time setup a person does in App Store Connect before the first run: the
App ID `harness.codegraff.ios.nano` and an app record for it (the API can't
create app records). The run stops with a message if either is missing.

Not verified: the workflow has never run. Certificate and profile creation,
the `altool` upload and App Store Connect's processing of a Zig-built binary
need the real key; everything before them (bundle, entitlements, ipa layout,
DT keys) was checked locally with ad hoc signatures.

## The cutover

1. Parity: the Zig app does what the Swift app does (screens are tracked
   elsewhere), and has run from TestFlight as `harness.codegraff.ios.nano`.
2. Run `nano-ios.yml` with `bundle_id: harness.codegraff.ios` and a
   `version` above the Swift app's live one: the Zig app's build.zig.zon
   version (0.2.x) is below the Swift app's 1.0, and the App Store takes no
   lower version. Its run queues with `testflight.yml`'s.
3. Stop running `testflight.yml` for the Swift app.
4. On phones, the update replaces the Swift app in place: same record, same
   Keychain access group (the sign-in carries over as above), same push
   App ID. NSUserDefaults choices carry over too (same keys, same container).
5. The widgets, Live Activities and Watch app go along as below, or are
   dropped from that version.
