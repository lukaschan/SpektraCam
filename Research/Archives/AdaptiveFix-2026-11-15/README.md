# Adaptive fix transfer — November 15, 2026

The fix was restored to `/Users/runzeni/dev/Xcode/SpektraCam-adaptive`, on
`codex/ipad-iphone-duo`, at HEAD `46bf81d9706a8f112c085100973bd731fa9fb67c`.
The restored changes are uncommitted. No commit, push, or merge was performed.

## Preservation and archive

- The handoff's HEAD and all 19 baseline file hashes matched before transfer.
- `git apply --check` passed, and the patch was applied to the existing worktree.
- All 19 resulting files matched the isolated implementation byte for byte.
- Every pre-existing file outside the patch remained unchanged.
- `adaptive-before-transfer.tar.gz`, its SHA-256 manifest, and its Git patch preserve
  the adaptive worktree before transfer, including existing uncommitted work.
- `isolated-fix-copy.tar.gz` preserves all 267 files from the temporary implementation.
  Every archived file was read back and checked against `isolated-fix-copy-sha256.json`.
- The temporary Xcode workspace had no unsaved changes. It was closed before the
  final archive was created. `/tmp/spektracam-adaptive-fix` and its redundant patch
  were then removed. Xcode now has the adaptive project open.
- The original handoff, baseline, and transfer patch are retained here as historical
  migration records. Do not reapply the patch to the restored worktree.
- The previous ZIP could not be opened by Python's ZIP reader. It is retained with
  an `.incomplete` suffix; use the verified TAR archive instead.
- The migration artifacts were moved out of the main worktree, which is clean.

## Verification after transfer

The final anchor-based shutter implementation built successfully from the adaptive
worktree with Xcode 27.2. Simulator commands used a per-command `DEVELOPER_DIR`;
the global Xcode selection was not changed.

| Check | Result |
| --- | --- |
| Duo closed: `CameraLifecycleTests` | 4 passed, 0 failed |
| iPad Pro 11-inch M5, full screen: `CameraLifecycleTests` | 4 passed, 0 failed |
| iPhone 15 Pro Max: `CameraLifecycleTests` | 4 passed, 0 failed; see `phone-verified-test.log` |
| Native `metal-dispatch` | Passed; tiny/aligned/partial/odd grids, canaries intact |
| Native `metal-color` | Passed; 52 cases, 9,984 values; maximum error 2.62e-6 |
| Native `metal-film` | Passed; 74 cases, 42,624 values; maximum error 6.75e-6 |
| Native `metal-grain` | Passed; official Philox vectors and 12,000,000 samples |
| Native `metal-diffusion` | Passed; 112 FFT cases, 36 mappings, 334,680 values; maximum error 3.17e-6 |
| Native `tone` | Existing assertion failure at `Scripts/tone-checks.swift:129` |
| `git diff --check` | Passed |

The tone assertion expects recipe version 4; `EditRecipe.currentVersion` is 5.
The identical assertion failure was reproduced from `adaptive-before-transfer.tar.gz`;
see `tone-baseline-test.log`. The transfer did not change that test or recipe version.

The initial phone suite passed three tests and failed the portrait round trip at the
About import-row lookup. A targeted repeat reproduced it. The diagnostic screenshot
`phone-about-before-scroll.png` confirms that About opened successfully in landscape:
the import section was below the viewport and had not been created by the lazy List.
The follow-up test verifies the About navigation bar appears and disappears after
tapping Done. This directly checks a library action and its dismissal in every window
shape. It changes no app code or centering assertions. `post-transfer-followup.patch`
records this test change and the validation-document link relative to the archived copy.

The lifecycle tests keep the strict one-point shutter-centering assertions and exercise
LVF hold/resume, background/foreground, rotation, both exits, actual library actions,
odd-sized image rendering, grading, editor navigation, and RAW compatibility fixtures.
Test logs and `.xcresult` bundles are alongside this note; result bundles are Git-ignored.

Final-code checks on unfolded Duo and a resized iPad window remain unperformed in this
session. Physical sensor RAW detection, capture, flash, and hardware buttons still need
device testing. Earlier pre-anchor results are described in `AdaptiveFixHandoff.md`.
