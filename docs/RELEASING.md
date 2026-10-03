# Getting Emperor onto a phone

Everything here runs on GitHub Actions. **No Mac is needed to build.** A Mac is only needed if
you choose the sideload route and want to re-sign the app yourself.

## A note on Actions minutes

This repository is **public**, so GitHub's macOS runners are free and unmetered and every job
runs on every push. That was not always true, and the reason is worth keeping:

> On a **private** repo, macOS bills at **10×**, and *every job rounds up to a whole minute* — a
> 40-second job costs ten. With several macOS jobs per run, a single push cost ~40 billable
> minutes against a 2,000-minute month. A duplicate build job that proved nothing the test job
> did not consumed **460 minutes** before it was spotted.

If this repo is ever made private again, gate the three macOS jobs behind
`if: github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/')` on the
same day. The Linux jobs bill at 1× and catch most of what breaks.

## The three outputs

| What | Apple account | Runs on a phone? | How long it lasts |
|---|---|---|---|
| Simulator tests (`simulator-tests` job) | none | no — Mac simulator only | n/a |
| **Unsigned `.ipa`** (`unsigned-ipa` job) | none | yes, after you re-sign it | **7 days** |
| **TestFlight** (`testflight` job) | $99/yr | yes, normally | 90 days |

The first two need nothing from you. The third needs the secrets below.

---

## Route A — sideload, free, 7 days

The `unsigned-ipa` job runs on every push and attaches `Emperor-unsigned.ipa` to the run.

> ### Read this before sending it to anyone
>
> **This build talks to production** — `app.emperorailabs.com`, the web app's own host. It is a
> Release build: whoever signs in sees their real account, the same matters, files and
> conversations as on the web, and anything they do is done for real. Only send it to someone
> who should have an account on the live platform.

1. Actions → the run → **Artifacts** → download `Emperor-unsigned-ipa`.
2. Sign it with your own free Apple ID:
   - **[Sideloadly](https://sideloadly.io)** — Windows or macOS, simplest.
   - **[AltStore](https://altstore.io)** — keeps a helper running that re-signs automatically,
     which matters given the 7-day limit.
3. On the phone: Settings → General → VPN & Device Management → trust your developer profile.

**The 7 days is Apple's rule, not ours.** A free Apple ID signature expires and the app then
refuses to launch until re-signed. AltStore automates the refresh; Sideloadly does not. Three
apps at a time is also the free-account ceiling.

## Route A′ — sign and install from Linux, no Mac and no VM

Route A says Windows or macOS because that is what Sideloadly and AltStore require. **Those tools
are not the only way to sign an `.ipa`.** Signing is a file operation, and the tools that do it
run natively on Linux — which matters here, because this project is developed on Linux and the
Mac in Route A exists only to run someone else's GUI.

Nothing in this route needs a Mac, a macOS VM, or Xcode.

### What has to be installed

`usbmuxd` and `libimobiledevice` are in the official Arch/Manjaro repositories. `ideviceinstaller`
and `zsign` are in the AUR:

```bash
sudo pacman -S --needed usbmuxd libimobiledevice
pamac build ideviceinstaller zsign
```

### The signing material, entirely on Linux

Apple accepts a plain CSR, so Keychain Access is not in the path. With a **paid** account the
certificate lasts a year, which is the real argument for this route over Route A's seven days.

```bash
openssl genrsa -out emperor-signing.key 2048
openssl req -new -key emperor-signing.key -out emperor.csr \
  -subj "/emailAddress=you@example.com/CN=Emperor Signing/C=IN"
```

Upload `emperor.csr` at Certificates, Identifiers & Profiles → Certificates → **+**, take an
**Apple Development** certificate for device installs, and download `ios_development.cer`. Then:

```bash
openssl x509 -in ios_development.cer -inform DER -out cert.pem -outform PEM
# OpenSSL 3 writes a format Apple's tooling will not read without -legacy.
openssl pkcs12 -export -legacy -out emperor.p12 \
  -inkey emperor-signing.key -in cert.pem
```

The device has to be registered on the profile, and its UDID comes off the phone itself — no
Apple software involved:

```bash
idevice_id -l                            # the phone must be plugged in and trusted
ideviceinfo -k UniqueDeviceID
```

Register that UDID under Devices, then create an **iOS App Development** provisioning profile for
`com.emperorailabs.emperor` tied to this certificate *and* this device, and download the
`.mobileprovision`.

### Sign and install

```bash
zsign -k emperor.p12 -p '<p12 password>' -m Emperor.mobileprovision \
      -o Emperor-signed.ipa Emperor-unsigned.ipa
ideviceinstaller -i Emperor-signed.ipa
```

Then on the phone: Settings → General → VPN & Device Management → trust the profile.

> The `unsigned-ipa` artifact carries no `_CodeSignature` and no `embedded.mobileprovision`, and
> the app bundle has no nested frameworks or dylibs. That is the simplest case there is for
> `zsign` — it writes both, and has no inner code to sign first.

### The free-Apple-ID variant

A free Apple ID can sign too, and then everything above still applies except that the certificate
is issued through Apple's own client flow rather than the web portal. On Linux that is
[AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) (AUR: `altserver-linux`), or
[Althea](https://github.com/vyvir/althea), a GUI over it that packages for Arch.

It costs nothing and it is a treadmill: **seven days**, three apps at a time, and a re-sign every
week. The paid route above is a year per signature. For a phone that is being used to test this
app continuously, the arithmetic favours paying.

## Route B — TestFlight, $99/yr, the real thing

You need the [Apple Developer Program](https://developer.apple.com/programs/). Then:

### 1. Register the app

App Store Connect → Apps → **+** → New App. Bundle ID must be **`com.emperorailabs.emperor`** —
**lower-case**, as set by `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and as recorded in the
shipped `.ipa`'s `Info.plist`. Not `bundleIdPrefix` plus the target name: the prefix is only
`com.emperorailabs`, and the target is called `Emperor`, so guessing from those two yields
`com.emperorailabs.Emperor`, which is a **different identifier**. Bundle IDs are case-sensitive,
and a profile issued for the capitalised one fails to match at install with an error that names
neither the cause nor the difference.

Register that identifier first under Certificates, Identifiers & Profiles → Identifiers.

### 2. Create the signing material

Under Certificates, Identifiers & Profiles:

- an **Apple Distribution** certificate — download the `.cer`, add it to Keychain Access on a
  Mac, then export it as a **`.p12`** with a password. The `.p12` is the certificate *and* its
  private key; the `.cer` alone cannot sign.
- an **App Store** provisioning profile for `com.emperorailabs.emperor`, tied to that
  certificate. Download the `.mobileprovision`.

> Creating a distribution certificate needs a Mac once, for the Keychain export. If you have no
> Mac at all, generate the certificate signing request with OpenSSL instead — Apple accepts a
> plain CSR — or use [fastlane match](https://docs.fastlane.tools/actions/match/), which
> manages the whole set from any machine.

### 3. Create an App Store Connect API key

Users and Access → **Integrations** → App Store Connect API → **+**. Role: **App Manager**.
Download the `.p8` — **it is downloadable exactly once**. Note the Key ID and the Issuer ID.

An API key rather than your Apple ID password: it is revocable, scoped to this one job, and
unaffected by two-factor auth, which would otherwise make an unattended upload impossible.

### 4. Add the secrets

Settings → Secrets and variables → Actions → New repository secret. Base64-encode the binaries
so they survive as text:

```bash
base64 -w0 Certificates.p12          # → APPLE_DIST_CERT_P12
base64 -w0 Emperor.mobileprovision    # → APPLE_PROVISIONING_PROFILE
base64 -w0 AuthKey_XXXXXXXXXX.p8     # → APP_STORE_CONNECT_KEY
```

| Secret | What it is |
|---|---|
| `APPLE_DIST_CERT_P12` | base64 of the `.p12` |
| `APPLE_DIST_CERT_PASSWORD` | the password you set exporting it |
| `APPLE_PROVISIONING_PROFILE` | base64 of the `.mobileprovision` |
| `APPLE_TEAM_ID` | 10 characters, top-right of the developer portal |
| `APP_STORE_CONNECT_KEY_ID` | the key's ID |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer UUID on the same page |
| `APP_STORE_CONNECT_KEY` | base64 of the `.p8` |

Until `APPLE_DIST_CERT_P12` and `APP_STORE_CONNECT_KEY` both exist, the `testflight` job checks,
prints a notice and stops. The rest of CI stays green.

### 5. Ship

The job only runs from `main`, and only on a tag or a deliberate run — so a push to a feature
branch cannot burn a build number.

```bash
git tag v0.1.0 && git push github v0.1.0
```

or Actions → CI → **Run workflow**. Processing at Apple's end takes 5–15 minutes, then invite
testers in App Store Connect → TestFlight.

---

## What will go wrong the first time

**The `ios` job will probably fail, and that is the point of it.** The SwiftUI layer in
`Emperor/` has never been type-checked — `swiftc -parse` catches syntax but not types, so this is
its first real compile. Expect a handful of errors; expect them to be small. Three classes have
already been found and fixed by building minimal repros, and they are the ones to look for
first:

- a mutable `@Bindable var` local captured in a `@Sendable` closure (`.task`, `.refreshable`),
- a non-`Sendable` type inside a `Sendable` struct,
- a ternary inside `.foregroundStyle` whose two branches are different `ShapeStyle` types.

`Sources/EmperorCore` already compiles and its tests pass, so anything that breaks is in the
view layer only.

**Two things Apple will ask about at submission**, both already handled:
`PrivacyInfo.xcprivacy` ships, and `NSCameraUsageDescription` is set — without the latter iOS
terminates the app the moment the scanner opens.

**Background upload is built but unverified — test this first on a real device.**

Picking a document from Files now hands it to a background `URLSession`, so it continues with
the app closed and resumes if the app is killed. The arithmetic underneath is covered by 34
tests on Linux. The lifecycle is not covered by anything, because a simulator does not evict
apps the way a phone under memory pressure does.

What to actually try, in order, with a document large enough to take a minute or two:

1. Start an upload, then background the app. It should still complete — the file appears in the
   library when you come back.
2. Start an upload, background the app, then **force-quit it from the app switcher**. Reopen
   after a minute. The upload should have continued while it was dead, or resume on reopening.
3. Start an upload and turn on Airplane Mode partway. It should recover when the connection
   returns, rather than failing the whole document.
4. Check `Application Support/Uploads` is empty afterwards. Each abandoned upload keeps a copy
   of the document, so a leak there is a privacy problem, not just a disk one.

If (2) fails, the likely cause is the app not being relaunched — check that
`AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` fires and
that the handler is called, because not calling it makes the system stop relaunching the app for
later transfers.
