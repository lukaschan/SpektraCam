# v0.3 Darkroom — implementation and verification record

Updated 2026-11-10. This file is the repository handoff point; read it before continuing Darkroom work. Changes are local and uncommitted. Preserve the preexisting Xcode project version/signing edits.

## Nov 10 (evening) — Seeded distress, BH perforations and penumbra

`FilmEdgeLayout.distress` (`FilmEdgeDistress`, algorithm revision 2) is saved with the edge. Six presets (Clean, Lab scan, Filed carrier, Hand print, Old camera, Light leak) plus a global **Amount** (scales intensities only) and a dice seed; every physical field is under **Fine-tune**. All fields are in film millimetres with independent seeded streams; Strength activates fixed candidates, never reshuffles them. Edge-only cache key is now `v14-distress-`.

| Mechanism | Stage (CPU `FilmPipeline` = Metal kernel) |
| --- | --- |
| Gate penumbra (default 20 µm ≈ gap/2N), gate wear, film tilt | Exposure coverage after lens optics (`film_edge_gate`); the padded scene is sampled in tilted film coordinates |
| Front (through-lens) leak: glow / streak / flare | Added to scene exposure *before* the gate, so it never exposes the rebate |
| Back (door/seal) leak, edge fog, perforation fog | Added after the gate; fog and perforation fog use base-path (warm) light |
| Emulsion scratches | Density stage (`film_edge_density`): remove yellow → magenta → cyan with depth; colour then follows print or scan |
| Scatter scratches, dust, worn-hole shoulder | Source-film transmission (`film_edge_transmission` mode 1); scatter weights 0.55/0.75/1.0 |
| Filed carrier, tape | Print or scan transmission (mode 2); carrier is canvas-fixed, tape film-fixed |
| Carrier-edge reflection | Paper printing only (mode 16): unmasked enlarger light just inside the opening |

Scratches default to the rebate (rails/sprockets); **Scratches cross the picture** releases them. Perforations follow the source stock: `kodak_vision3_*` uses **BH-1866** (C 2.794 circle cut by flat edges D 1.854, sharp corners, pitch 4.740); still film and cinema print film use **KS-1870**. Source: Kodak *Essential Reference Guide for Filmmakers*, printed p. 96–97. Creative centres (LUT, disabled Develop, cross-family) receive dust/scratches with route polarity in `FilmEdgeRenderer.applyCenterDamage`.

**Verification:** `python3 Scripts/core-checks.py film-edge` passes. It covers CPU/Metal agreement with every node active for all four routes plus BH, released scratches, front-streak and back-flare leaks (max 1.2e-4), Amount 0 identity, stable seeds, 256↔1024 physical-size dust/carrier, intact KS/BH sizes, eight BH holes per frame, 120 without sprockets, dust polarity, rebate-clamped scratches, and depth/route scratch colour. A shallow cut prints yellow from a negative and looks blue on a slide; scatter prints light/bluish. It also covers the front leak gated out of the rebate vs the back leak reaching it, carrier reflection darkening the print edge, and aged tape printing lighter/bluer. Proof PNGs: `/private/tmp/spektrafilm-build/film-edge-proof/distress-*.png`. The complete `python3 Scripts/check-darkroom.py` suite then passed: all native stages, localization coverage and **6/6 UI tests** (`/private/tmp/spektrafilm-build/darkroom-workflow-1794334199525595000.xcresult`). The UI tests do not open the Distress panel; it has not been visually reviewed in an automated capture. Signed Release installed on the iPhone 15 Pro Max; on-device feel not yet reviewed.

**Limits:** all amplitudes are uncalibrated engineering ranges. No B&W negative profile exists, so B&W remains final conversion of the colour model. Rear-leak colour uses an empirical layer blend, not measured backing response. Destination print-film damage is not modelled. RA-4 *beyond-film-edge* spill (carrier wider than the strip) needs a full-width canvas and is a separate proposal.

## Nov 10 — Upright dimensions, paper orientation and black openings

The vertical-photo squeeze came from mixing coordinate systems: source previews were EXIF-oriented, but PhotoSource.Description used unrotated raster/native RAW dimensions. CIRAWFilter's nativeSize explicitly ignores orientation. Descriptions now provide upright dimensions for EXIF 1–8, including RAW. The fixed-gate crop therefore uses the same axes as decoded pixels.

Darkroom paper sizing now reads the current cropped recipe dimensions, rather than a stale preview bitmap. During orientation/shape changes a mismatched old image is withheld instead of stretched into the new paper. Automatic paper follows the cropped result; explicit paper orientation stays explicit.

Negative-print output uses clear openings as an exact linear black endpoint after scanner optics. Fully covered rebate pixels retain their existing color. Direct negative/slide/cinema transmission routes retain clear openings. This implements the requested black-reference presentation; it does not claim zero physical paper reflectance.

**Verification:** 24 TIFF/JPEG/HEIC × EXIF 1–8 matrix cases pass, including circle roundness, default paper orientation and explicit override. The full updated native suite and five existing UI tests pass: `/private/tmp/spektrafilm-build/darkroom-workflow-1794287611779622000.xcresult`, combined log `/private/tmp/spektracam-upright-full-workflow.log`. The added portrait-paper UI case also passed: `/private/tmp/spektrafilm-build/portrait-paper-ui-1794288013162792000.xcresult`. It checks portrait paper immediately after Crop, then automatic landscape paper after reframing. Its screenshot was visually reviewed. Thus six current UI cases passed (five in the full run plus the targeted regression); the wrapper now includes all six.

**Actual iPhone 15 Pro Max:** signed Release build with opt-in read-only checks installed. Eight real library photos pass session crop, 720 preview and 1080 PNG/paper export, including Canon CR2, portrait/landscape ProRAW/DNG, portrait/landscape HEIC and JPEG. Two real portrait exports were also visually inspected. Anonymous dimensions/results are in `orientation-device-summary.json`. This is not full-native export memory profiling.

Device preservation: private preflight backup is `/private/tmp/spektracam-orientation-device-before`; post-check snapshot `/private/tmp/spektracam-orientation-device-after`; real diagnostic images/report `/private/tmp/spektracam-orientation-device-results`. All 49 original files and 28 LUT/index files match byte-for-byte, and all six Photos links match. Two saved recipes changed while the user was actively editing (explicitly confirmed); both current versions were preserved, with no restore or rollback. The validator never attaches a save callback and each tested photo passed its source/recipe preservation check. Real photographs/backups must stay out of the repository.

**Next feature research:** [DISTRESS-AND-LEAKS.md](DISTRESS-AND-LEAKS.md) contains primary sources, physical-coordinate seed/strength behavior, separate camera/carrier/material/exposure nodes, stock dependence, missing rear-response data and the staged acceptance plan. It is a design contract, not shipped distress/leak controls.

## Accepted behavior

- Develop → Darkroom → explicit Export. Opening Darkroom does not allocate a native export.
- One editor session owns recipe, undo, saving, camera navigation and export. Camera stays top right except Library; History sits beside Back/Close. Shared PanelTabs and toolbar components are reused.
- New Develop defaults: C200 + Crystal Archive Type II. Original entry remains neutral. Existing saved choices and upstream/reference defaults are preserved.
- Clean print is default. Paper: As image, 4×6, 5×7, 8×10. Scale changes the photograph inside fixed white paper. Fit/Fill/rotate paper use the shared PrintGeometry; table/shadow are preview-only.
- Film edge: Auto follows Develop; Manual permits Negative print, Negative scan, Slide scan and Cinema print film in every Develop mode. Auto/Manual and last manual choice are stored separately. Picking an edge never rewrites Develop.
- B&W is the existing whole-photo toggle, applied after image + edge, for every family. Paper stays white. No separate Darkroom B&W switch.
- Two explicit support geometries: nominal 35 mm KS and 120 without perforations. The gates are fixed: 36×24 mm (3:2 or 2:3) for 135, 56×56 mm (1:1) for this first 120 format. Incompatible photos are cropped; the gate never changes to fit them. First carrier is clean and fixed. No markings/logos, random roughness or extra appearance presets.

## Fixed-gate correction — user direction

The earlier adaptive gate was rejected: it looked like a border added around an arbitrary photo. **Use a fixed photographic aperture and crop the photo to it.** Film-stock/perforation dimensions follow Kodak / SMPTE KS geometry. The 36×24 mm still aperture is our 135 format; the cited motion-picture stock/perforation table does not itself prescribe that still-camera aperture. Carrier reveal remains a design choice, separate from perforation dimensions.

Selecting Film edge, or changing film format, opens the existing Crop tool only if the current crop is incompatible. The selection is trimmed around its current center, within the existing crop, as one undoable recipe change. Free/aspect-preset controls are replaced by a fixed-gate label. Existing drag/resize/portrait/landscape/rotate/flip/straighten remain; 120 hides irrelevant orientation controls. Done returns to Darkroom and restores the previous editor tool. An inline Adjust crop button revisits the same tool. Turning Film edge off unlocks ordinary Crop; it retains the current crop, and Undo can restore the state before edge activation.

`CropSelection.constrain` is shared with `FilmEdgeLayout`; it is idempotent. Editor session initialization, live changes, history restore and the renderer normalize the crop. Old adaptive v5 recipes therefore render through the fixed gate even in batch/library paths. `FilmEdgeGeometry` rejects incompatible input dimensions instead of adapting or stretching the gate (one source-pixel rounding tolerance). Edge-only disk caches now use `v13-upright-gate-black-`; unrelated preview caches stay v11.

Perforations remain procedural signed-distance shapes with 4×4 coverage, full nominal KS size, and a half-pitch phase giving eight per nominal 135 frame. The 1.2 mm carrier reveal clips 0.5165 mm of each perforation's inner edge; holes are not resized into a decorative ring. Negative paper prints can show very little hole/base contrast because both transmit enough enlarger light to produce dense paper; direct scans have different polarity. No artificial white perforations are painted onto paper.

## Rendering ownership

`FilmEdgeLayout` enables the feature (nil = clean). `FilmEdgeSelection` recommends/overrides the material family. Both are optional in unreleased recipe v5; v1–v4 remain compatible. `processingRecipe` strips finishing so Develop does not rerender for paper or edge selection.

`FilmEdgeGeometry` defines the capture gate and carrier extent, pixel pitch and coverage. `FilmPipeline` is the Double CPU reference. `MetalFilmPipeline` accepts a separate per-frame edge domain; existing no-edge graph remains unchanged. Material setup remains reusable; there is no cached edge bitmap keyed only by the old processing recipe.

Order: original scene-only metering → source and linear crop/rotation → scene extension for lens convolution → lens/diffusion → gate exposure → emulsion halation/development/grain → source support mixed in transmitted print light → print chemistry / direct scan → destination support when applicable → scanner → final B&W → white paper placement → SDR file encoding.

Auto matched Spektrafilm/Mix 100% uses one full-support graph. Manual cross-family, disabled Develop, LUT and partial Mix preserve the chosen developed center and use the selected material for the surrounding support. These combinations are creative presentations, not a claim that the two routes are one physical process. Compatible edge defaults are C200/Crystal, Provia or 2383 when the user's stock cannot produce the requested family; only the temporary edge recipe changes.

`PhotoRenderer.renderFilmEdge` is shared by Darkroom and export; `renderPresentation` adds saved viewer/library paper finishing. LibraryImages rebuilds from original bytes through that common path. BatchPhotoExporter uses the same export entry.

DarkroomWorkspace requests 720 then the configured editor maximum; task identity excludes paper layout. Cancelled tasks cannot publish old results. EditorSession owns cancellation of the worker, waits for its release before export and cancels on editor teardown/memory warning. Output long edge includes the rebate and never exceeds the native cropped long edge. Admission checks cover source decode, padded graph and retained finishing buffers. No paper-sized FP32 film graph and no full-frame mask bitmap.

## Verified geometry sources

[SMPTE ST 139:2003, Figure 1 / Table 1](https://pub.smpte.org/pub/st139/st0139-2003.pdf), visually inspected 2026-11-09: stock width 34.975 mm; KS C=2.794, D=1.981, R=0.51; pitch 4.750; **outer-edge gap E=2.01**, not hole-center inset. Center from film midline =14.0805 mm; inner hole edge=12.6835 mm. A centered 24 mm aperture and 1.2 mm carrier reveal show only a clipped sliver of full-size holes. Along-strip reveal is 0.8 mm. These reveal/gate choices are our restrained design, not camera-specific calibration.

Other research and pinned source comparisons live in the Obsidian project's `Planning/v0.3_Film_Edge.md`, `v0.3_Darkroom.md` and `v0.3_Print.md`.

## Reproduce checks

Run the whole first-workflow suite with `python3 Scripts/check-darkroom.py`. It checks localized source coverage, CPU/Metal compatibility, geometry, native source handling, recipe/database persistence, batch/file parity, the real editor scheduler, and six focused UI tests. It produces an xcresult/log under `/private/tmp/spektrafilm-build`.

Use `/Applications/Xcode.app/Contents/Developer` (system xcode-select points at CommandLineTools). Existing simulator: **SpektraCam UI Checks**, `5208EE70-99A9-46FB-827E-8AC10F2B547B`, already authorized by user. Build tooling uses `/private/tmp/spektrafilm-build`. Xcode/Metal/CoreSimulator calls need graphics/simulator permissions in this workspace.

```
python3 Scripts/build-and-run.py
python3 Scripts/core-checks.py recipe darkroom
python3 Scripts/core-checks.py metal-film geometry source library
SPEKTRACAM_SIMULATOR_ID=5208EE70-99A9-46FB-827E-8AC10F2B547B python3 Scripts/core-checks.py film-edge --simulator
SPEKTRACAM_SIMULATOR_ID=5208EE70-99A9-46FB-827E-8AC10F2B547B python3 Scripts/core-checks.py editor-session-benchmark --simulator
```

UI tests: `testDarkroomPortraitPaperFollowsCrop`, `testFilmEdgeSelectionExportAndRestart`, `testDarkroomLayoutHistoryAndReopening`, `testDarkroomChineseLargeText`, `testWorkspaceToolbarAndSharedPills`; use xcodebuild, scheme SpektraCam, Debug, simulator id above, CODE_SIGNING_ALLOWED=NO, parallel testing NO. Keep an xcresult and visually inspect attachments; AX existence alone does not establish visibility.

## Evidence / status

**Current fixed-gate correction passed the complete `python3 Scripts/check-darkroom.py` suite.** All native stages and **5/5 UI tests passed, zero failures**. Result: `/private/tmp/spektrafilm-build/darkroom-workflow-1794282106153736000.xcresult`; combined log: `/private/tmp/spektrafilm-build/fixed-gate-workflow-final.log`. The build used the final fixed-gate/cache code.

Fixed-gate evidence: centered bounded trim, idempotence, 36×24 / 24×36 / 56×56 mm mapping, rejection of incompatible geometry, physical pixel pitch, eight clipped KS perforations, CPU/Metal agreement (max channel error 0.000003925), scene-only metering, no grain in holes, bright-edge optics, file/batch parity and cancellation all passed. Activation + forced crop undo together; reset/free edits cannot escape an active gate. Library restart test seeds an old v11 edge cache and verifies the new preview is rebuilt. Native UI verifies required Crop entry, locked ratio, portrait/landscape, subject dragging, Adjust crop, 120/135 changes, Done → Darkroom, final export and restart. English/Chinese screenshots were extracted and visually checked; current review artifacts are from this run.

### Earlier foundation checks (historical)

These entries document the earlier foundation and adaptive implementation. The current fixed-gate policy and result above supersede their adaptive-ratio claims.

- Build succeeded after first integrated edge UI.
- Existing no-edge Metal oracle: 74 cases, 42,624 values, max absolute error 0.000006751; geometry and source checks passed.
- New four-family CPU/Metal edge oracle: max absolute error 0.000003917; source/destination hole polarity, clipped geometry, portrait/adapted ratios and no grain/dye in open holes passed.
- First complete source → selection → recipe round-trip → paper + B&W → PNG: preview/export agreement passed, native output bounded, cancellation recovery passed. Synthetic 900×600 source; not physical calibration.
- Extended bright-edge probe, batch PNG equality, 120/crop/LUT/disabled-look paths and cancellation recovery passed. Auto-exposed preview/export/batch parity passed; CPU/Metal reject automatic metering of a padded canvas without an explicit scene-meter result.
- Native session checks passed, including edge undo/redo without restarting Develop and an active preview → export cancellation handoff. Warm optimized 720 edge check ≈34 ms on a synthetic 1024×768 source. This is a render-call measurement, not touch-to-screen latency.
- Grain-enabled 2160×1440 source → 720 → 2160 support graph passed in the simulator. Debug native check reported roughly 235–397 ms quick rendering (including setup) and 1.54–1.63 s settled; these are simulator/check-process observations, not phone performance claims.
- Initial four focused UI tests: 4/4 passed, `/private/tmp/spektrafilm-build/film-edge-ui-1794279103894499000.xcresult`.
- Final edge/restart, Chinese accessibility text (including edge controls) and export options: 3/3 passed, `/private/tmp/spektrafilm-build/film-edge-final-ui-1794279482735565000.xcresult`. All five unique focused cases have passed. Screenshots were extracted and visually reviewed, including the final complete-suite English and Chinese captures; the review artifacts below are from that final suite.
- Final app build succeeded. No missing localized source keys; all Darkroom messages have English/Chinese entries. Git whitespace check passed.
- **Complete single-command suite passed:** `python3 Scripts/check-darkroom.py`, all native stages and **5/5 focused UI cases, zero failures**. Result: `/private/tmp/spektrafilm-build/darkroom-workflow-1794279887464271000.xcresult`; combined log: `/private/tmp/spektrafilm-build/darkroom-workflow-final.log`; UI log: `/private/tmp/spektrafilm-build/darkroom-workflow-1794279887464271000.log`.
- Final export safeguard also passed: missing original bytes raises a decode error instead of substituting a preview. Native proof log: `/private/tmp/spektrafilm-build/film-edge-final-source-check.log`. Final app rebuilt successfully after that guard.

## Limits and next steps

No physical-device memory/energy or real-scanner calibration yet. First model is an ideal clean rectangular camera gate/carrier, registered source/destination KS stock, no BH/cine transport geometry, markings, stock fog fitting or roughness. With Film edge enabled, the fixed physical gate supplies optical/grain pitch and the matching diffusion-memory estimate. Develop's free film-long-edge control remains in use when Film edge is off. Existing stochastic fields are resolution-dependent; fixed-seed determinism does not establish identical grain across preview resolutions. No tiled edge renderer yet. 120 is the initial fixed 56×56 mm aperture, not a camera preset collection. Imported photos cannot reconstruct true off-frame scene content; lens convolution uses edge extension before the gate.

Localization catalog has five preexisting unused messages; do not remove unrelated keys. New English/Chinese copy still needs human editorial review. Existing RenderPerformanceChecks.swift trailing-closure warning predates this work. Keep public research PDFs outside the repo; link to primary sources instead.

## Review artifacts

- [Portrait paper regression](portrait-paper.png), [shared Crop tool with fixed gate](film-edge-fixed-crop.png), [native edge controls](film-edge-workflow.png), [Chinese accessibility size](film-edge-chinese-large-text.png), [prepared export](film-edge-export.png).
- `Optical-proof/`: same synthetic two-color source with each of the four material families, plus final B&W on paper. These fixtures reveal geometry, polarity and orientation; they are not photographic calibration targets. The direct negative/slide/cinema manual examples deliberately retain the C200-developed center.
