# App Store preflight — SpektraCam

Audited 15 November 2026 against the working tree on top of `30c3671` (v0.3), using the
`app-store-preflight-skills` checklists (all-apps list plus the privacy, design, metadata and
entitlement rules). App type: free photo editor and RAW camera; no accounts, purchases,
user-generated content, AI services, or backend. No App Store Connect record exists yet, so the
metadata rules were applied to the drafts in [AppStoreListing.md](AppStoreListing.md) rather than
to pulled metadata.

Nothing here is committed or pushed.

## Preflight report

### ❌ Blocks submission (4)

- **[5.1.1(i)] Privacy policy URL is not live yet.** The policy is written
  ([PRIVACY.md](../PRIVACY.md)) and linked in-app (About → Legal → Privacy Policy), but the link
  points to `github.com/runzeni/SpektraCam/blob/main/PRIVACY.md`, which 404s until the file is
  pushed. Fix: push it before submitting, then paste the same URL into App Store Connect.
- **[Licensing] GPLv3 and App Store distribution.** spektrafilm is GPLv3 and SpektraCam is a
  native port of it, so the app is a derivative work. The App Store's usage rules add restrictions
  the GPL does not allow, which is why GPL apps have been pulled before (VLC, 2011). Apple will not
  check this; the copyright holders can. Fix: written permission from Andrea Volpato to distribute
  this port through the App Store (an additional-permission notice in `LICENSE` is the usual form),
  plus the same notice for your own code.
- **[2.1] App Store Connect record and metadata do not exist.** Bundle ID
  `io.github.runzeni.spektracam` must be registered (a signed device build with automatic signing
  does it), then the record created. Drafts for every field are in
  [AppStoreListing.md](AppStoreListing.md).
- **[2.1] No release-candidate device pass yet.** Everything below was verified on the iOS 27.2
  Simulator. RAW capture, ProRAW, location prompts, Save to Photos and full-size export on memory
  pressure only exist on a phone and need one run on the build you will upload.

### ⚠️ Warnings (7)

- **[4.1 / 2.3.7] Confusable names already on the store.** Search shows **SpektraCamera**
  (bundle `org.spektracam.app`) and **SPEKTRA CAM** (`app.spektracamera.ios`). The exact name
  "SpektraCam" is not visibly taken, but only creating the record proves it, and a reviewer may
  read the app as a copy of those. Have a fallback name ready and say in the review notes that
  this is the open-source project at `github.com/runzeni/SpektraCam`.
- **[5.2.1] Manufacturer references.** User-facing film and print names now use F· / K· aliases,
  including VoiceOver labels and the LUT effects note. About → Legal explains the aliases,
  simulation limitations and manufacturer non-affiliation in English and Simplified Chinese.
  Original source attribution, profile identifiers and licences are preserved. Aliases do not
  establish trademark clearance. Keep manufacturer branding **out of** the app name, subtitle,
  keywords and screenshot captions; the drafts do.
- **[China mainland] ICP filing.** Apps on the China mainland storefront need an ICP filing number
  in App Store Connect. Without one, deselect China mainland; Simplified Chinese still ships
  everywhere else.
- **[2.4.1 / review practice] iPad.** The target is iPhone-only, but reviewers may run it on iPad in
  compatibility mode. It launches correctly there (simulator); the editor and Darkroom were not
  exercised on iPad.
- **[iOS 26 floor] Compile-verified only.** The deployment target is now 26.0 and the project
  builds with no availability errors, but only the 27.2 runtime is installed here. Install an
  iOS 26 simulator runtime (Xcode → Settings → Components) or use an iOS 26 device before claiming
  it.
- **[Screenshots] iPhone Duo.** The skill's checklist lists Duo screenshots as required from
  April 2027. The app is portrait-only and does not adapt to the Duo yet; that is the next major
  version.
- **[EU] Trader status.** App Store Connect asks every developer to declare trader or non-trader
  status under the DSA before distributing in the EU.

### ✅ Passed (12)

- **[Privacy manifest]** `PrivacyInfo.xcprivacy` now declares UserDefaults (CA92.1) alongside
  system boot time (35F9.1). No file-timestamp or disk-space required-reason APIs are used. No
  tracking, no tracking domains, no collected data types. No third-party SDKs.
- **[5.1.1(i)] In-app privacy policy** — About → Legal, with a one-line summary above the link.
- **[5.1.1(iii)] Minimal permissions** — camera, when-in-use location (optional; capture works
  without it) and add-only Photos. Imports use the system picker, so there is no library read
  permission. All three purpose strings are specific and localized.
- **[5.1.1(v), 4.8]** No accounts, no sign-in.
- **[5.1.2(i)]** No third-party data sharing, no AI services, no ATT needed.
- **[3.1.1]** No purchases; every feature is free.
- **[2.5.19] Hidden features** — no remote config, date gates, storefront checks, review-mode
  switches, downloaded code or obfuscation. The `--ui-test-*` launch arguments and the
  performance/validation harnesses are compiled out of Release (`#if DEBUG`).
- **[2.5.1]** Public APIs only.
- **[2.5.5]** One network call (MapKit reverse geocoding); nothing IPv4-specific.
- **[4.2]** Native editor, camera, darkroom, LUT manager and batch export; works offline.
- **[2.4.5] Entitlements** — none declared.
- **[Export compliance]** `ITSAppUsesNonExemptEncryption = NO`; the app has no cryptography.
- **[Licence notices]** GPLv3, the spektrafilm CC BY-SA 4.0 profile licence and third-party
  notices ship in the bundle and are now readable in About → Legal → Licenses.

## What changed in this pass

| Area | Change |
| --- | --- |
| Deployment target | 27.2 → **26.0** (project, `core-checks.py`, README). |
| Privacy | UserDefaults reason added to the manifest; `PRIVACY.md` (English + 简体中文); About → Legal section with policy, support, licences and a non-affiliation note. |
| Release logging | Camera `print` calls replaced with `os.Logger` debug messages (one `Log` namespace, shared with the editor). |
| Localization keys | 567 → 545. Duplicate messages merged, hash-suffixed and sentence-derived keys renamed to what the message is for (`camera_preview.iso_87650f` → `camera.iso_unknown`), five dead strings removed. |
| Chinese | 裁切 everywhere; one word each for straighten (校正), contrast (反差), gate (片门), print (印相), save (存储), reset (重置); missing strings translated. The R01–R18 decisions in the translation worksheet are untouched. |
| English | Parameter labels that read like variable names fixed ("Lens blur um" → "Lens blur · µm", "Gamma interlayer b to rg · Red" → "Interlayer gamma · Blue→Red"); the microstructure labels corrected to what the parameters are (blur, clump size). |
| Editor / Darkroom | `EditorView` tool panel and tabs as single switches; one `setEdge`/`edgeBinding` path for film-edge changes instead of eight copies; shared `glassIconButton`; Adjust panel conditions named (`filmDisabled`, `printDisabled`) and bindings routed through `session.binding`. `EditorSession`'s render loop was left as is. |
| Code | Shared `failureAlert`, flexible toolbar spacers, About rewritten around small helpers, empty duplicate `AppIcon.appiconset` removed (the Icon Composer file is the icon), compiler warning in the performance harness fixed. |

Not changed: version stays **0.3 (9)** — set 1.0.0 when you cut the release. The rendering core
and Metal pipeline were left alone; they are fixture-verified ports and nothing in the audit
called for touching them.

## Verification

- Debug simulator build at deployment target 26.0: succeeds; one remaining warning
  (`PhotoCanvas.swift:313`, a Sendable conversion that predates this pass).
- `Scripts/core-checks.py` — recipe, geometry, darkroom, export, histogram, geotag, statistics,
  photo-color, image-requests: all pass.
- `Scripts/localization.py` source/catalog verification: 542 referenced keys, none missing, none
  unused, none untranslated, placeholders match in both languages.
- UI tests (iOS 27.2 Simulator), ten run against this tree, all pass: About links (now also
  asserts the privacy policy, support and licence screens), Chinese panels, Darkroom in Chinese at
  large text, new-edit defaults, Files import, LUT manager, library filters and original export,
  photo revert, export options, straighten. The full 39-test suite was not completed in this
  session.
- A second run after the Editor and Darkroom cleanup covered eleven editor and darkroom tests;
  nine pass.
- Three tests failed on untouched `30c3671` too. All three were test problems, not app bugs, and
  the tests are fixed:
  - `testCameraPresentationKeepsEditor` expected the panel to open Expanded; the editor has
    opened collapsed since the Darkroom work (`1eed7e1`). It now expands the panel itself and
    checks the camera leaves it unchanged. Passes.
  - `testGroupedPanelsAndSliderReset` tapped the Black & White switch while the collapsed Color
    panel clipped it to a sliver, so the tap missed. A `reveal` helper scrolls a control fully
    into the panel first. Passes.
  - `testStraightenedCropCanReframe` cannot pass with a square photo: a straightened square has
    no slack to reframe. The test Simulator's first photo is square, so the test now skips with
    that reason. **The reframing drag is therefore still unverified** until a non-square photo is
    first in that Simulator's library.
- iPad: the iPhone build launches in compatibility mode on the iPad (A16) simulator and shows the
  library correctly. Nothing beyond launch was exercised there.
- Unsigned Release build for `generic/platform=iOS`: succeeds. The product reports
  `MinimumOSVersion 26.0`, carries both manifest reasons, and contains no UI-test launch hooks.
- Not done: signed archive, Validate App, device run, TestFlight upload.

## iPad and iPhone Duo (branch `codex/ipad-iphone-duo`)

The target is now universal (`TARGETED_DEVICE_FAMILY = 1,2`); iPad supports all four orientations
and iPhone adds landscape. Following Apple's Duo guidance, layout follows the size of the space,
never the device or orientation (`WorkspaceLayout`):

| Space | Editor and Darkroom | Viewer | Camera |
| --- | --- | --- | --- |
| Taller than wide (iPhone, iPad portrait, Duo outer display, Duo inner portrait) | The existing layout: controls over the bottom of the photo, tools in the bottom bar | Actions and filmstrip at the bottom | Shutter row at the bottom |
| Wider than tall and at least 560 pt (iPad landscape, Duo inner landscape, iPhone landscape) | Photo on the leading side, controls in an always-open column beside it with the section pills in a row on top, tools top-to-bottom in a rail on the trailing edge | Actions down the trailing edge, filmstrip at the bottom | Shutter column on the trailing edge, 4:3 viewfinder |

Verified by `AdaptiveLayoutTests` (two tests, both orientations) on iPhone, iPad Pro 11-inch and
the iPhone Duo outer display, plus twelve existing editor tests on iPhone. Screenshots are in the
vault under `Claude/Adaptive-proof-nov15`.

**Not verified:** the Duo's inner display. The simulator boots folded and neither `simctl` nor
XCTest can open it; use Device Hub in Xcode. By size it takes the same two layouts as iPad
(669 × 951 pt portrait, 951 × 669 pt landscape). The half-folded pose is the open question: the
photo/controls split is not at the hinge, and `ArrangementView` (iOS 27.1+) is the system
container that would align it. The camera layout could only be checked with the simulator's
"unavailable" state.

App Store consequences: iPad screenshots (13-inch set) are now required, and the earlier iPad
compatibility-mode warning no longer applies.

### Duo side bar, library and photo page (second pass)

- Where the system shows its bars vertically (`toolbarVerticalEdge`, iOS 27.1+), the editor
  tools, library actions and photo-page actions are plain title-and-symbol toolbar items, so the
  system stacks them in its own side bar. The custom tool rail remains only where there is no
  system side bar (iPad, iPhone landscape).
- Photo page: a tap on the photo hides all chrome on black; a second tap restores it.
- Library: long-press a thumbnail for Select and Delete; day grouping is one pass over the
  already-sorted photos instead of a dictionary grouping plus two sorts per update.
- Image cache: thumbnails (48 MB) and viewer previews (3 images) are cached separately. Before,
  one 32 MB cache held both, and three 2160 px previews evicted the whole grid. Edits, reverts
  and deletes now drop only the previews.
- Darkroom: an unchanged edit is no longer re-rendered (low then high quality) when the export
  sheet closes or a drag ends.

Checked: layout test on the unfolded Duo (landscape), 17 editor/library/Darkroom UI tests on
iPhone, library and request-pool checks, editor-session benchmark in the simulator.
`testFilmstripAndEditedBadge` and `testPhotoPinchThenPage` fail, and fail the same way on `main`.

### Performance and bit depth

Mac GPU (M5 Max), 1080 x 810 full film graph: about 12.5 ms GPU, 18 ms wall per frame. This is
not a phone measurement. An optimized benchmark build is installed on the iPhone 15 Pro Max but
could not be launched while the phone was locked:

```sh
xcrun devicectl device process launch --device 00008130-001651AA3AA2001C --terminate-existing io.github.runzeni.spektracam --check-performance --performance-run base
xcrun devicectl device process launch --device 00008130-001651AA3AA2001C --terminate-existing io.github.runzeni.spektracam --check-performance --performance-sliders --performance-run sliders
```

Each writes `performance-<label>.json` to the app's Caches directory.

The film graph works in 32-bit float (16 bytes per pixel in Metal buffers; grading textures are
`rgba32Float`). Keep it: densities, FFT diffusion and Poisson grain need the range and
precision, and tiling already bounds peak memory by the tile, not the image. Half float would
only pay off for the file-backed scene-linear stores of a full-size export (16 to 8 bytes per
pixel on disk); that is a measured follow-up, not a pre-release change.

### Camera (third pass)

- **LVF hold.** A round `LVF` button right of the shutter stops the session (sensor and preview)
  and shows one "Camera on Hold" screen in the viewfinder. Tap the viewfinder, the button or the
  shutter to resume. Returning from the background does not undo a hold. System interruptions
  (another app, multitasking, thermal) use the same screen with their reason; only a user hold
  is tappable.
- **Capture.** Volume buttons and Camera Control fire the shutter (`onCameraCaptureEvent`); a
  Camera Control light-press adjusts exposure (`AVCaptureSystemExposureBiasSlider`), and the
  on-screen slider follows it. Zero shutter lag, responsive capture and fast-capture
  prioritisation are enabled where the output supports them. The shutter is free again as soon
  as the DNG is written; importing into the library now runs behind the next shot.
- **Flash.** Two states, off by default, shown only as available when the active lens and RAW
  format support it.
- **Layout.** Framed 3:4 viewfinder (4:3 in landscape) with nothing drawn over it; below it the
  exposure slider, then flash / lens capsule / flip, then library / shutter / LVF. The session's
  shot count is a badge on the library button. Rows keep their place while the camera starts or
  is on hold, so the shutter never moves.

Tested with `--ui-test-camera-demo`, a simulator-only stand-in camera (compiled out of Release):
`testCameraHoldFlashAndShutterInPortrait` / `InLandscape` plus four existing camera tests pass.
**Not tested on hardware:** the live feed, volume and Camera Control capture, flash, zero
shutter lag, and how much power a hold saves. These need a run on the phone.

### Camera (fourth pass)

- On an iPhone the camera interface is held in portrait (`AppDelegate.lockPortrait`) and only
  the symbols and labels turn with the device; the top row does not. Displays that ignore
  orientation locks (iPad multitasking, the Duo's inner display) keep the adaptive layout.
- The EV slider has equal side columns, so its track and zero sit on the screen's centre line.
- On hold the viewfinder is a flat gray panel and every control stays in place, inactive.
- The format chip now states what will be captured (`PRO 48`, `PRO 12`, `RAW 12`). Resolution is
  offered only for ProRAW: Bayer RAW is the sensor's binned 12 MP readout on these phones.
  Whether ProRAW at Max really writes 48 MP is **not confirmed**; it needs one capture on the
  phone with the console open (the app logs the resolved RAW dimensions under the Camera category).

## Order of work from here

1. Get Andrea Volpato's written permission for App Store distribution; add the notice.
2. Commit and push (makes the privacy policy URL live). Tag 1.0.0 when ready; bump the build.
3. Device pass on the release build, on iOS 26 if you can get one.
4. Register the bundle ID, create the record, enter the listing from `AppStoreListing.md`.
5. Capture screenshots on the device (6.9-inch iPhone set at minimum), record the review video.
6. Archive → Validate → upload → TestFlight install → submit with manual release.
