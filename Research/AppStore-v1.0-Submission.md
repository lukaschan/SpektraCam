# App Store 1.0 — Formulae submission candidate

Prepared 17 November 2026 at Runze's request. This candidate replaces build 10 as the intended
first App Store version. It includes the Formulae work through `a8e7fc4`, plus the release
packaging changes on `release/1.0-formulae`.

| Item | Value |
| --- | --- |
| Version / build | **1.0 / 11** |
| Bundle identifier | `io.github.runzeni.spektracam` |
| Team | `7GN2969G32` |
| Devices / minimum OS | iPhone and iPad / iOS 26.0 |
| Release checkout | `/Users/runzeni/dev/Xcode/SpektraCam-AppStore-v1.0-Formulae` |
| Submission package | `/Users/runzeni/Desktop/SpektraCam-AppStore-1.0-build11-2026-11-17` |

The older independent checkout at `/Users/runzeni/dev/Xcode/SpektraCam-AppStore-v1.0` and
`release/1.0` retain build 10 for reference. Their instruction to exclude Formulae is superseded
for this candidate. The Formulae development worktree remains on `codex/formulae`.

## What this version includes

The adaptive editor, RAW camera, Darkroom, LUTs and batch export, plus Copy/Paste by part,
saved Formulae, `.rnformula` sharing with optional LUT attachments, import preview, links,
QR codes and Formula Cards. A formula can contain Look, Exposure and Darkroom; crop and
rotation stay with the photograph. Links carry the formula in the URL fragment and exclude
LUT file contents. Importing a card image and pasting a link work locally.

The unfinished starter set, default formula, in-app scanner, universal links and Shortcuts
action are not advertised. They are not required to use the implemented Formulae features.

## Before submission

1. Publish the supplied `Site/f/index.html` at `https://runzeni.github.io/spektracam/f/`.
   The URL returned 404 during packaging. Until it is published, the Camera app's QR route
   and browser opening of copied links do not work. Test a real exported link after deployment.
2. Complete the physical-device checks listed in the package. This packaging pass does not
   install over the user's phone library or establish RAW/camera/share-sheet reliability.
3. Supply current product screenshots for the required iPhone and 13-inch iPad groups,
   and complete App Store Connect's contact, age-rating, availability and privacy fields.
   The package's Simulator captures are verification evidence, not a finished marketing set.
4. Resolve the upstream App Store distribution-permission question raised in the historical
   preflight. The package includes the licences; it does not contain new permission evidence.
5. Publish the matching source and updated policy before distributing. Confirm build 11 is
   unused in App Store Connect; no account metadata was read in this packaging pass.

## Upload

`Build/AppStoreExport/SpektraCam.ipa` is the App Store distribution export. Deliver it with
Transporter, or open `Build/SpektraCam-1.0-11.xcarchive` in Xcode Organizer and use the App Store
Connect distribution workflow. Validate the build, upload, wait for processing, install it
from TestFlight and complete the device checks before selecting it for review.

Use the package's English and Simplified Chinese metadata drafts. Prefer manual release for
the first submission. Nothing in this packaging operation uploads or submits the app.

The archive contains dSYMs. Keep it together with the source snapshot and checksums. If a new
binary is uploaded after build 11, use a higher build number and retain this candidate unchanged.

## References

- [Apple: upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple: screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple: App Review Guidelines, including completeness and functioning URLs](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: privacy details](https://developer.apple.com/app-store/app-privacy-details/)
