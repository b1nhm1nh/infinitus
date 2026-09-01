# Releasing Infinitus

A `v*` tag push runs `.github/workflows/release.yml`: build on the
macOS 26 runner, zip, GitHub release, tap cask bump. Nightly does the same
from `main` daily.

## Signing today

Ad-hoc in CI, Apple Development locally (Gatekeeper on another Mac
needs `--no-quarantine` or right-click → Open). The full Developer ID
pipeline was proven end-to-end on 2026-09-01 under the company team —
cert → local notarization Accepted → staple → spctl pass → all five CI
secrets — then unsigned the same day (a different signing account is
coming). Redoing it with the new account is the checklist below plus
~10 minutes; nothing in the workflow needs to change.

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
