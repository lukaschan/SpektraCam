# App Store v1.0 submission copy

Version **1.0**, build **10**, bundle ID `io.github.runzeni.spektracam`.
Frozen release branch: `release/1.0`. Candidate tag: `v1.0.0-rc.1`.
This is a submission candidate; it has not been uploaded or approved by Apple.

The independent local checkout is `/Users/runzeni/dev/Xcode/SpektraCam-AppStore-v1.0`.
Open `SpektraCam.xcodeproj` in that folder, select the SpektraCam scheme and an iOS device destination,
then use Product → Archive. Check the version, build and distribution signing in Organizer before
validation and upload. The unsigned build used for verification is not an uploadable distribution archive.

Use this checkout for the submission and any review fixes. Develop Formulae separately in
`/Users/runzeni/dev/Xcode/SpektraCam-formulae` on `codex/formulae`.
Keep review fixes on `release/1.0` and bring them back to main as needed; Formulae work must not be
included in a replacement 1.0 submission. If another build is uploaded, increment its build number
and record a new candidate tag instead of moving this tag.

Before upload, complete the release-candidate check on a physical device and review
[the listing drafts](AppStoreListing.md) and [the existing preflight report](AppStorePreflight.md).
The report contains historical observations, not a current clearance certificate; in particular,
the upstream GPL/App Store distribution-permission question is not resolved by this version freeze.

The repository retains original source attribution and licence notices. All 28 selectable profiles
use the agreed F· / K· aliases. Formulae is not part of this submission.
