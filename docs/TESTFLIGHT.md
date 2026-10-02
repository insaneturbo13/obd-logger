# Getting builds onto the iPad without a Mac

GitHub Actions builds on a hosted Mac and uploads to App Store Connect; TestFlight installs
it on the iPad. One-time setup, about 20 minutes.

## 1. Pick the bundle ID

Choose a reverse-DNS prefix you control, e.g. `com.yourname`. The app's bundle ID becomes
`<prefix>.obdlogger` and the Live Activity's `<prefix>.obdlogger.widget`.

In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list)
→ Identifiers → **+** → App IDs → App: register `<prefix>.obdlogger` (explicit). No
capabilities need ticking. The widget ID is created automatically on the first build.

## 2. Create the app record

[App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App:
platform iOS, any name that isn't taken on the App Store (it can change later), the bundle
ID from step 1, SKU anything (e.g. `obdlogger`).

## 3. Create an API key

App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys →
**+**. Access: **Admin** (needed so the build can create signing certificates and
profiles on its own). Download the `.p8` file (only possible once) and note the **Key ID**
and the **Issuer ID** shown above the list.

Your **Team ID** is under Membership details in the developer portal.

## 4. Add secrets to the GitHub repository

Repository → Settings → Secrets and variables → Actions.

Secrets:

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | Team ID |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | the `.p8` file, base64-encoded (below) |

Variables tab:

| Name | Value |
|---|---|
| `BUNDLE_ID_PREFIX` | e.g. `com.yourname` |

Base64 of the key in PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AuthKey_XXXXXXXXXX.p8")) | Set-Clipboard
```

Then delete the downloaded `.p8` or keep it somewhere private; never commit it.

## 5. Build and install

Actions → **TestFlight** → Run workflow. About 10 minutes to build; Apple then processes
the build for 5–30 minutes.

App Store Connect → your app → TestFlight → Internal Testing → **+** create a group, add
yourself. Install the **TestFlight** app on the iPad and accept the invite. Later builds
appear there automatically.

Each run numbers its build from the workflow run number. Tags starting with `v` (e.g.
`v0.1.0`) also trigger an upload.

## Costs

GitHub bills macOS minutes at 10× on private repositories; the free plan's 2,000 minutes
are about 200 macOS minutes a month, roughly 15–25 app builds between CI and TestFlight.
Public repositories don't use minutes.

## If the archive step fails on signing

The workflow relies on Xcode's automatic signing with the API key
(`-allowProvisioningUpdates`). If it reports that no signing certificate was found, check
that the key has the Admin role. The log is attached to the run as `testflight-logs`.
