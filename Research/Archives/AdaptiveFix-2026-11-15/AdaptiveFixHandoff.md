# SpektraCam adaptive camera fix: session handoff

## Start here

Open `/Users/runzeni/dev/Xcode/SpektraCam-adaptive` as the active workspace in the new session.
The original worktree is **unchanged**. This session was started in the sibling `SpektraCam`
workspace, whose write policy rejected edits to `SpektraCam-adaptive`. No attempt was made
to bypass that restriction. Changes were implemented in an isolated copy instead.

- Intended worktree: `/Users/runzeni/dev/Xcode/SpektraCam-adaptive`
- Branch: `codex/ipad-iphone-duo` (two commits ahead of its remote at session start)
- Working implementation: `/tmp/spektracam-adaptive-fix`
- Complete delta against the original **uncommitted** worktree:
  `/Users/runzeni/dev/Xcode/SpektraCam/Research/SpektraCam-adaptive-fix.patch`
- Baseline file hashes and HEAD:
  `/Users/runzeni/dev/Xcode/SpektraCam/Research/AdaptiveFixBaseline.json`

The three files in this handoff directory are migration artifacts, not intended changes
to the sibling/main app branch. The patch is also at `/tmp/SpektraCam-adaptive-fix.patch`.
The implementation copy excludes `.git`, `.agents`, and `Reference`; do not replace the
real worktree wholesale with this copy. Preserve all existing uncommitted changes.

Before applying, compare the baseline hashes with the intended worktree and run
`git apply --check /Users/runzeni/dev/Xcode/SpektraCam/Research/SpektraCam-adaptive-fix.patch`.
That check passed before the handoff. If files have changed since then, reconcile the
delta instead of overwriting newer user work. No commits or pushes were made.

## User's goals

Diagnose why the Duo simulator would not run and why the library stopped responding after
closing the camera. Fix the underlying problem using a lean, consistent approach, and
check iPad. The user explicitly cautioned against continuing the prior speculative
"portrait hold" and "hardware capture hook swallows Close" diagnoses.

Additional steering: camera/lens detection should adapt to each model's RAW capabilities;
explain compatibility (including iPhone 11 Pro) in the README. Make horizontal lens selection
consistent with vertical/expanded Duo. Keep the shutter strictly centered.

## Confirmed root cause

The original Xcode session was paused in a **Metal validation abort**, not a build error:
`Dispatch Threads with Non-Uniform Threadgroup Size is not supported on this device`.
The stack was `LibraryImages.rebuild` -> `PhotoRenderer` -> `MetalFilmPipeline.encodeGraph`
-> `dispatchThreads`. The failing kernel was `camera_exposure_image`, count 250717.
This explains a frozen app/library when thumbnail work runs; moving the capture hook
alone cannot fix it.

The same nonuniform dispatch assumption existed in tone, color, film, grain, diffusion,
and experimental stage code. All affected shaders were audited for logical bounds guards.

## Changes prepared

- `MetalDispatch.swift`: one `dispatchGrid` helper using rounded-up **uniform** threadgroups.
  Every independent pixel-dispatch call in the app now uses it. Explicit cooperative
  reduction dispatches remain unchanged. No GPU/device-name special cases or image-math changes.
- Native GPU regression check: tiny/aligned/partial/517x337 grids with canary memory;
  wired into existing core checks. Test compilation inputs include the new helper.
- Camera readiness: hardware hook uses active scene + `model.canCapture`; held/inactive/
  busy/closed cameras do not consume hardware capture. Close is terminal, and late events
  cannot restore readiness. The on-screen shutter can still resume LVF hold.
- Lens discovery: probe RAW formats with each input attached to the photo output before
  exposing a lens. Prefer supported rear wide, then rear, then front. Recheck when switching.
  Keep physical rear sensors for Bayer RAW, but retain the system virtual front camera so
  Duo can follow folding automatically. Enable Flip only when a supported opposite camera exists.
- A distinct, localized RAW-unsupported screen preserves import/editing access. Simulator
  fixtures cover Bayer-only and no-RAW configurations. Removed a universal "Bayer RAW = 12 MP"
  label; hardware determines Bayer dimensions.
- README: bilingual camera compatibility section. iPhone 11 Pro supports Bayer RAW on wide
  and telephoto, lacks Apple ProRAW and ultrawide RAW. ProRAW is a separate capability.
- Shared optics row (flash, centered lens capsule, flip) and separate EV row in every layout.
- `CameraLifecycleTests`: self-generated odd-sized image; LVF/background/resume, rotation,
  both exits, real library actions, reopening, film rendering/grading, editor navigation,
  strict window-axis shutter centering, Bayer-only/no-RAW behavior.
- `layout-matrix.py --camera-only` runs without an external image. Logs and xcresults are kept.
  `Research/AdaptiveValidation.md` records the standard and commands.

## Latest shutter change: MUST VERIFY NEXT

The stronger tests found real inset-dependent offsets:

- iPad landscape: shutter Y=450, window center Y=417 (33 points low).
- Closed Duo portrait: shutter X=191, window center X=233 (42 points left).

The iPad offset was first fixed with a full-window trailing overlay, and that version
passed all four tests on iPad and unfolded Duo. The closed Duo then exposed the X offset.

The **latest implementation** replaces separate placement rules with one shutter view,
using a `CameraShutterBounds` anchor preference. Transparent 78x78 slots keep the normal
edge placement. A full-presentation GeometryReader uses the slot for the edge coordinate
and the complete window for the center axis. This preserves layout-driven edge placement
without fixed offsets or device tests, and keeps one shutter identity across layout changes.

The Mac locked immediately before rebuilding this final change. The user agreed to continue
in a new session. **Do not claim the final anchor implementation is built or runtime verified.**
Its PreferenceKey typechecks independently; all 109 app Swift files pass syntax parsing.
A full shell typecheck was blocked by sandbox denial of Swift macro plugin execution,
so those cascading macro diagnostics are not app source failures.

## Validation already observed in Xcode

| Configuration | Result | Version |
| --- | --- | --- |
| Duo unfolded, portrait + landscape round trips | Passed | Initial uniform GPU fix |
| Duo unfolded, all four lifecycle/compatibility tests | 4 passed, 0 failed | Before final anchor refactor |
| iPad Pro 11-inch M5, all four tests | 4 passed, 0 failed | Before final anchor refactor |
| Duo closed, all four tests | Bayer-only/no-RAW passed; both round trips failed **only** on X centering | Before final anchor refactor |
| Latest shared anchor refactor | Syntax parse + isolated PreferenceKey typecheck passed | Runtime pending |
| Standard phone; iPad resized window | Not yet run | Pending |

Latest passing iPad suite ended Nov 15, 2026, 8:33 PM America/New_York; unfolded Duo
passed at 8:36 PM. Closed Duo's centering failures ended at 8:38 PM. Native standalone
Metal tests could compile but could not access a GPU in the shell sandbox, so numerical
GPU suites/canary execution are pending. Simulator camera fixtures do not exercise actual
sensor capability probing; physical-device RAW/capture/flash/hardware-button checks remain needed.

## Continue efficiently

1. Unlock the Mac and build the final code. Apply the checked delta to the correct active
   worktree once its write policy allows it, or continue validating the isolated copy first.
2. Run `CameraLifecycleTests` on closed and unfolded Duo, iPad, and a standard phone. Keep
   the strict centering assertions; fix geometry rather than relaxing the tests. Check a
   resized iPad window too. The test treats wide spaces below 560 points as stacked, matching
   the existing workspace policy.
3. Inspect the actual ready/held camera layout and ensure the shutter overlay does not
   intercept library/hold/toolbar taps. Prior tests proved actual actions, not just visibility.
4. Review/prove physical RAW capability detection when a suitable phone is available.
   Do not promise a model-wide RAW guarantee based only on Simulator fixtures.
5. Finish with the applied change summary, actual tests passed, and remaining physical limits.

## Environment and simulator details

- Xcode 27.2: `/Applications/Xcode.app/Contents/Developer`; iOS deployment target 26.0.
- Scheme `SpektraCam`, app bundle `io.github.runzeni.spektracam`.
- Duo: `778ECA2C-38EA-4F70-BD66-6618F7063443` (last left **closed**).
- iPad Pro 11-inch M5: `A205A01C-59D4-4B1E-908F-8942E190EBA0`.
- Standard booted phone "SpektraCam UI Checks": `5208EE70-99A9-46FB-827E-8AC10F2B547B`.
- Xcode GUI currently opens `/tmp/spektracam-adaptive-fix/SpektraCam.xcodeproj`.
- Xcode's `ctrl+alt+cmd+g` repeats the last selected `CameraLifecycleTests` suite after
  changing destination. Use `cmd`, `ctrl`, `alt` key names in CUA; `super` and `option`
  did not work correctly in this environment. Destination popup: filter by device name,
  then Return. Device Hub exposes Closed/Open controls for Duo.
- Purpose-built Xcode tools could not enumerate devices because xcode-select points to
  CommandLineTools; shell simctl also lacked CoreSimulator access. GUI Xcode builds and
  native UI tests worked. Do not change global developer settings just to work around this.
- Test bundles are under
  `/Users/runzeni/Library/Developer/Xcode/DerivedData/SpektraCam-gqdjlvafscsejagojkrfjsszbaph/Logs/Test`.
  xcresulttool also hit cache-write restrictions in this session; Xcode's visible console
  supplied the results above. Reinitialize computer-use documentation in a new session.

## Primary references used

- https://developer.apple.com/documentation/metal/mtlcomputecommandencoder/dispatchthreads(_:threadsperthreadgroup:)
- https://developer.apple.com/documentation/metal/calculating-threadgroup-and-grid-sizes
- https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats
- https://developer.apple.com/documentation/avkit/choosing-a-camera-by-the-direction-it-faces.md
- https://support.apple.com/en-us/119916
- https://www.lux.camera/inside-the-iphone-11-camera-part-1-a-completely-new-camera/

The preexisting portrait orientation lock/timer was not rewritten: it was not the confirmed
failure, and the user specifically steered away from that speculative diagnosis.
