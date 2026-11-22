# One-time Mac App Store setup (team S6K8YB57AB)

After these steps, running the **App Store Edition** workflow on GitHub (Actions ▸ App Store Edition ▸ Run workflow) builds, signs and uploads BoostBar to App Store Connect.

## 1. Register the App ID
developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ **Identifiers ▸ +**
- Type **App IDs ▸ App**, Platform **macOS**
- Description: BoostBar
- Bundle ID (Explicit): `com.macsboost.boostbar`
- Capabilities: none needed. In-App Purchase is on by default.

## 2. Two certificates (same CSR flow as the Developer ID one)
**Certificates ▸ +**, using a new CSR from Keychain Access ▸ Certificate Assistant for each:
1. **Apple Distribution** (signs the app for the App Store)
2. **Mac Installer Distribution** (signs the .pkg)

Download both `.cer` files, double-click to install, then in Keychain Access ▸ My Certificates select **both**
(Apple Distribution: John McAlpine and 3rd Party Mac Developer Installer / Mac Installer Distribution) ▸ **File ▸ Export Items…** ▸ save each as its own `.p12` **using the same password**.

## 3. Provisioning profile
**Profiles ▸ +** ▸ **Distribution ▸ Mac App Store Connect** ▸ App ID `com.macsboost.boostbar` ▸ certificate **Apple Distribution** ▸ name `BoostBar App Store` ▸ Download.

## 4. GitHub secrets (github.com/macsboost/BoostBar ▸ Settings ▸ Secrets ▸ Actions)
| Secret | How to get it |
|---|---|
| `MAS_APP_CERT_P12` | `base64 -i ~/Downloads/BoostBar-AppStore.p12 \| pbcopy` (one .p12 holding both certificates) |
| `MAS_CERT_PASSWORD` | the export password |
| `MAS_PROVISION_PROFILE` | `base64 -i ~/Downloads/BoostBar_App_Store.provisionprofile \| pbcopy` |

The existing `APPLE_API_KEY_*` secrets are reused for the upload.

## 5. App Store Connect record
appstoreconnect.apple.com ▸ **Apps ▸ + ▸ New App**
- Platform **macOS**, Name **BoostBar**, Language English (U.S.), Bundle ID `com.macsboost.boostbar`, SKU `BOOSTBAR-MAC-001`, Full Access.
- **App Information**: category Utilities, privacy policy URL.
- **Pricing**: Free.
- **App Privacy**: answers in `listing.md`.
- **In-App Purchases ▸ +**: Consumable `com.macsboost.boostbar.energydrink` (details in `listing.md`).
- **Agreements, Tax, and Banking**: the *Paid Apps* agreement must be active for the IAP tip to work.

## 6. Build & submit
1. GitHub ▸ Actions ▸ **App Store Edition** ▸ **Run workflow** (upload = true).
2. About 10–30 minutes later the build appears in App Store Connect ▸ your app ▸ **Build**.
3. Add screenshots, description, keywords and review notes (`listing.md`), attach the IAP to the version, and **Submit for Review**.
