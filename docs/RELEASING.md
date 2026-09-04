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
> **This build talks to the development server, and that is deliberate.** It is archived from
> the *Debug* configuration, because `APIConfig.resolveEnvironment` forces a Release build to
> the production host, which **is not yet stood up**. A Release `.ipa` would install, launch,
> and then fail every request at DNS, which is indistinguishable from a broken app.
>
> Two consequences, both real:
>
> 1. **This build talks to the development deployment.** Only send it to someone already
>    entitled to access that server.
> 2. **A debug build is debuggable.** Anyone with USB access to the phone can read the app's
>    data. Fine for an internal test; not a build to leave on a device long-term.
>
> **The day production exists, change `-configuration Debug` back to `Release`** in the
> `unsigned-ipa` job and this note stops applying. The Android client ships its internal APK
> the same way, for the same reason.

1. Actions → the run → **Artifacts** → download `Emperor-unsigned-ipa`.
2. Sign it with your own free Apple ID:
   - **[Sideloadly](https://sideloadly.io)** — Windows or macOS, simplest.
   - **[AltStore](https://altstore.io)** — keeps a helper running that re-signs automatically,
     which matters given the 7-day limit.
3. On the phone: Settings → General → VPN & Device Management → trust your developer profile.

**The 7 days is Apple's rule, not ours.** A free Apple ID signature expires and the app then
refuses to launch until re-signed. AltStore automates the refresh; Sideloadly does not. Three
apps at a time is also the free-account ceiling.

## Route B — TestFlight, $99/yr, the real thing

You need the [Apple Developer Program](https://developer.apple.com/programs/). Then:

### 1. Register the app

App Store Connect → Apps → **+** → New App. Bundle ID must be **`com.emperorailabs.Emperor`**
(from `bundleIdPrefix` in `project.yml`). Register that identifier first under Certificates,
Identifiers & Profiles → Identifiers.

### 2. Create the signing material

Under Certificates, Identifiers & Profiles:

- an **Apple Distribution** certificate — download the `.cer`, add it to Keychain Access on a
  Mac, then export it as a **`.p12`** with a password. The `.p12` is the certificate *and* its
  private key; the `.cer` alone cannot sign.
- an **App Store** provisioning profile for `com.emperorailabs.Emperor`, tied to that
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

`Sources/EmperorCore` already compiles and its 618 tests pass, so anything that breaks is in the
view layer only.

**Two things Apple will ask about at submission**, both already handled:
`PrivacyInfo.xcprivacy` ships, and `NSCameraUsageDescription` is set — without the latter iOS
terminates the app the moment the scanner opens.

**Background upload is not built.** It was deliberately left out rather
than written blind, because it cannot be exercised on Linux and its failure mode is a 200-page
scan lost silently. Build it once you can run the app.
