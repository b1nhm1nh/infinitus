# Releasing Infinitus

A `v*` tag push runs `.github/workflows/release.yml`: build on the
macOS 26 runner, zip, GitHub release, tap cask bump. Nightly does the same
from `main` daily.

## Signing today

Builds are **ad-hoc signed** in CI (no identity on the runner) and
**Apple Development-signed** locally when such a cert is in the keychain
(`make-app.sh` picks it up — Notification Center refuses ad-hoc apps).
Neither satisfies Gatekeeper on another Mac: users see "Apple could not
verify…" and install with `--no-quarantine` or right-click → Open.

An Apple Development certificate — even one issued under an organization's
team — cannot be turned into distribution trust. Gatekeeper trusts exactly
one kind of identity outside the App Store: **Developer ID Application**,
plus notarization.

## Getting a Developer ID

- Only a team's **Account Holder** can create Developer ID certificates
  (developer.apple.com → Certificates → "+" → Developer ID Application).
  Under an organization's team, every Gatekeeper prompt names the
  organization as the signer and notarization runs under its account.
- Otherwise: a personal Apple Developer Program membership ($99/yr).

Export the cert + private key from Keychain Access as a `.p12`, and create
an App Store Connect API key (Users and Access → Integrations → Team keys,
role Developer) for notarization.

## Wiring it into CI

Repository secrets; the workflow's Developer ID steps run only when
`DEVELOPER_ID_P12_BASE64` is set, otherwise the ad-hoc path is unchanged.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12 export password |
| `NOTARY_KEY_ID` | API key id (e.g. `ABC123DEFG`) |
| `NOTARY_ISSUER_ID` | issuer UUID from the same page |
| `NOTARY_KEY_BASE64` | `base64 -i AuthKey_ABC123DEFG.p8` |

The steps: import the cert into a throwaway keychain → `make-app.sh`
signs with `--options runtime --timestamp` → `notarytool submit --wait` →
`stapler staple Infinitus.app` → zip. Stapling attaches to the app, so the
released zip is built after it. Once a notarized release exists, drop the
`--no-quarantine` wording from the README and the cask.

Local check of a Developer ID build: `SIGN_IDENTITY="Developer ID
Application: …" ./make-app.sh && spctl --assess --type execute -vv
Infinitus.app`.
