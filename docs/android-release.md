# FitDesk Member App — Android APK & iOS install

Production web app: <https://fitdesk-usr.vercel.app/>

> The APK is a build artifact and is **not committed to git** (`release/` is ignored).
> The signed file for the current release lives at
> `release/android/FitDesk-member-release.apk`.

| File | What it is |
| --- | --- |
| `FitDesk-member-release.apk` | **Signed release APK — use this one.** Install on Android. |

- Package id: `com.fitdesk.gym`
- App name: **FitDesk**
- Version: `1.0` (versionCode `1`)
- Minimum Android: 7.0 (SDK 24) · Target SDK 36
- Size: 4,990,354 bytes (≈4.8 MB)
- SHA-256: `91B2EF4FC6A473D1079E50703834FA301605D90C481660D390F0D47CD59EC899`
- Signed with APK Signature Scheme v2 (verified with `apksigner`)
- Signing certificate SHA-256: `d39780f777747a437f1d703df973247897266601b770663e7aebb1d6cc504d9e`

The APK is a Capacitor build: it bundles the production web assets inside a native
WebView shell, so it opens as a normal app (own icon, no browser chrome) and talks to
the live Supabase project. A network connection is still required at runtime.

---

## Install on Android

1. Copy `FitDesk-member-release.apk` to the phone (USB, Google Drive, WhatsApp to yourself, etc.).
2. Open the file from the phone's file manager.
3. If prompted, allow **Install unknown apps** for that file manager or browser.
4. Tap **Install**, then **Open**.

> Play Protect may show a "scan" prompt for apps installed outside the Play Store.
> Choose **Install anyway** — the APK is signed, just not Play-distributed.

### Updating later

The update APK must use:

- the same package id (`com.fitdesk.gym`), and
- the **same signing key**,

otherwise Android refuses to install over the existing app. Bump `versionCode` in
`android/app/build.gradle` for every release.

---

## Install on iOS (PWA)

An APK cannot be installed on iOS. iOS users install the same web app to the home
screen, which gives a standalone app window with the FitDesk icon. This needs no
Apple Developer account.

1. Open **Safari** (not Chrome) on the iPhone/iPad and go to <https://fitdesk-usr.vercel.app/>.
2. Tap the **Share** button.
3. Tap **Add to Home Screen**.
4. Confirm the name **FitDesk** and tap **Add**.
5. Launch it from the home screen — it opens full-screen, without Safari's address bar.

Notes for iOS:

- Push notifications and background sync are limited by iOS for PWAs.
- Clearing Safari website data will sign the user out.
- A true `.ipa` (TestFlight / App Store) requires a macOS build with Xcode and an
  Apple Developer Program membership (USD 99/year). The Capacitor iOS project is
  scaffolded in `ios/` and ready for that step later.

---

## Rebuilding the APK

Requirements installed on this machine:

- JDK 21 — `C:\Program Files\Microsoft\jdk-21.0.13.21-hotspot`
  (Java 26 is also installed on PATH and **breaks Gradle**; always set `JAVA_HOME`)
- Android SDK — `%LOCALAPPDATA%\Android\Sdk` with platform 36 and build-tools 36.0.0
- Node 20.19+/22.12+

```powershell
# from D:\Gym App
$env:JAVA_HOME   = "C:\Program Files\Microsoft\jdk-21.0.13.21-hotspot"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

npm.cmd run build
.\node_modules\.bin\cap.cmd sync android

cd android
.\gradlew.bat assembleRelease --no-daemon
```

Output: `android\app\build\outputs\apk\release\app-release.apk`

Then copy it to the release folder and record the new hash:

```powershell
Copy-Item "android\app\build\outputs\apk\release\app-release.apk" `
          "release\android\FitDesk-member-release.apk" -Force
Get-FileHash "release\android\FitDesk-member-release.apk" -Algorithm SHA256
```

Verify the signature:

```powershell
& "$env:ANDROID_HOME\build-tools\36.0.0\apksigner.bat" verify --verbose --print-certs `
  "release\android\FitDesk-member-release.apk"
```

For a Play Store upload, build an app bundle instead:
`.\gradlew.bat bundleRelease` → `android\app\build\outputs\bundle\release\app-release.aab`.

> Use `npm.cmd` / `cap.cmd` on this machine — PowerShell script execution is
> disabled, so the bare `npm` shim is blocked.

---

## Signing key — preserve it

Release signing uses:

| Item | Value |
| --- | --- |
| Keystore | `android\fitdesk-release.jks` |
| Alias | `fitdesk` |
| Store/key password | `FitDesk#Release2026!` |
| Key | RSA 4096, validity 10,000 days |
| Distinguished name | `CN=FitDesk, OU=Mobile, O=FitDesk, L=Kolkata, ST=West Bengal, C=IN` |

Passwords live in `android\keystore.properties`, which is read by
`android/app/build.gradle`.

**Keep `fitdesk-release.jks` and its passwords safe and backed up.** It is excluded
from git (`.gitignore` covers `*.jks`, `release/`, and `android/keystore.properties`).
If it is lost, you can never publish an update to the installed app — users would have
to uninstall and reinstall, losing local app data.

There is no debug APK in this folder on purpose: a debug build is signed with a
different key, so it cannot be installed over the release build. Build one with
`.\gradlew.bat assembleDebug` only when testing on a separate device/emulator.

---

## Current build provenance

- Web bundle: `npm.cmd run build` (`tsc -b && vite build`), assets copied with
  `cap sync android`. The bundled `index.html` hash matched `dist\index.html`.
- Built: 1 November 2026, from the working tree at `D:\Gym App`.
- Not yet runtime-tested on a physical Android device (none was attached at build time).
