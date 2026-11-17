# v0.3 Darkroom — implementation and verification record

Updated 2026-11-10. This file is the repository handoff point; read it before continuing Darkroom work. Changes are local and uncommitted. Preserve the preexisting Xcode project version/signing edits.

## Nov 14 (night) — Scans: framing, direct camera scans, inverted holder

- `FilmEdgeLayout.scanZoom` (0.75–1.05, default 0.85): non-enlarger canvases are the scanner's crop window, gate / zoom. Its edge is a digital crop.
- `FilmEdgeDistress.scanHolder` / `invertedScan` (resolved, not saved): negative scans (direct and inverted) have a holder, open along the strip (`carrierHalf.along = 1e4`) and masking across at gate + 0.83 mm on 35 mm (12.83 mm; KS hole inner edge 12.68 mm). Measured on P1485707 at 318 px/mm (hole pitch 1513 px = 4.75 mm): ≈ 0.17 mm of hole shows. Positive scans have no holder (`carrierHalf = 1e4`). Default `scanZoom` 0.9.
- Inverted scan: no holder at the print stage; the final linear stage runs `[.endpoint]` then `[.invertedHolder]` (CPU `invertedHolder`, Metal `edge_inverted_holder`, mode 32). c = penumbra(d + 0.02·wear, holder blur) (core only, no tail); q = max(P, 0)·s + 0.012; v = 1 / (c^γ / q + (1 − c) / (1.1 W)), γ = (1.4, 1.0, 0.75), W = (1, 0.82, 0.78); noise ×10^(n σ (1 − c)), σ = 0.7 (1 − c) min(1, c / 0.15) + 0.08, streaked 3:1 along the strip at max(0.015 mm, 2.7 px radius) / max(0.045 mm, 5.4 px radius); s = 1 − 0.55 e^(d/0.07) inside the opening. To-scale proof at 100 px/mm against P1485707.
- `FilmEdgeGeometry.registration`: seeded ±0.3 mm along-strip shift of the source holes (`e[16].z`); destination (cinema print) holes fixed.
- `PrintLayout.marginRange` = −0.2…0.2, shown in %; Fill = `PrintGeometry.fillMargin` (negative when proportions differ). Film-edge enlarger prints default to `PrintLayout.enlargerDefault` (5 × 7).
- `NumericEntry` is a popover (`presentationCompactAdaptation(.popover)`) with the label's rounding, step nudges with repeat, range hint, reset, Done. Value labels sit in a quiet capsule.

## Nov 14 (evening) — Worn blade edges, easel border and Fill

**Negative scan** (`FilmEdgeType.invertedScan`, shown after Negative print): the print route's positive (`scanFilm = false`, same material defaults as Negative print) with `enlargerPrint = false`, so the scanner holder replaces the easel. The holder blocks the exposure and comes out paper-light; the thin rebate is dark (navy on a colour negative, as in P1485659); clear holes are black. No sheet by default (`printedLayout == nil`). Auto never selects it. Checked: no easel/sheet, inverted, holder light vs rebate dark; included in the CPU/Metal parity loop.

**Blade edge, measured on IMG_1670/1674** (≈ 25.7 px/mm on the print): the blade line is crisp, 10–90 % in about 3.5–5.5 px (0.14–0.21 mm including the phone lens), with fine nicks and small steps but no ruled straightness. The gate edge on 1670 is the soft, rough one.

- **One edge profile.** `FilmEdgeNoise.wear` (Metal `fe_wear`: 0.65 × broad 0.9 mm + 0.35 × fine 0.16 mm value noise) now drives both the camera gate's wear and the easel blades. On a film-edge enlarger print the blade is the carrier with `carrierRoughness = Easel.Kind.wear` (CPU and Metal, parity checked). On a clean print `Easel.mask` computes the same profile and the penumbra into an 8-bit mask (edge bands only), used by `PrintCompositor`, the Darkroom preview and the loupe.
- **Easel pills:** Precise / Natural / Worn = 0.004 / 0.009 / 0.02 mm on the film (× magnification on paper). Blade penumbra uses h = 4.5 mm and 0.05 mm paper spread (≈ 0.16 mm on a 4 × 6, matching the measured 0.14–0.21 mm). Proof: `Claude/Edge-proof-nov14/blade-edge_real-vs-precise-natural-worn.png` in the vault.
- **SwiftUI mask fix:** SwiftUI masks by alpha, so the grey blade mask needs `.luminanceToAlpha()`; without it the clean-print preview and loupe showed a hard edge (exports were right). Preview and loupe now draw one `PrintSheet` view, clipped to the sheet, so a borderless sheet never shows a border under the loupe.
- **Hand-set placement is unchanged** (0.8 % of the sheet, 0.3°, 0.18 mm) but now **off by default**.
- **Border replaces Image scale.** `PrintLayout.margin` is the narrowest white border as a fraction of the sheet's long side (mm on sized paper, % as image). The sheet never moves or resizes with it; as image it keeps the picture's proportions and the picture is inset. Nil is automatic: none for a clean print as image, 4 % on a sized sheet and around every film-edge enlarger print. **Fill** is borderless (covers the sheet, no blades). Old saved `scale` decodes as a border (< 1) or Fill (> 1). The film-edge canvas is placed so its nominal easel opening (`FilmEdgeLayout.easelFrame`) sits at the border; `EditRecipe.printedLayout` / `printContent` decide the sheet and what is on it.
- **Defaults:** new film edges are Natural gate + Lab scan (the gate choice is no longer remembered), enlarger zoom 97 %. **Negative direct scan** moved last in the type row. Explanatory notes under controls removed; the zoom readout is one line. Dark-mode accent darkened to #C8238E.
- Planned export size on paper now comes from the same integer sheet as the export; native sheet size uses a fine reference to avoid one-pixel rounding.

**Verification:** darkroom (incl. blade wander precise < natural < worn, determinism, legacy scale), film-edge (CPU/Metal parity with worn blades, easel wear bounded), orientation, session benchmark, recipe, library, Metal, geometry: all PASS with `--optimized`.

## Nov 14 (later) — Square gate corners, export sizes, a leaner Darkroom

- **Gate corner:** IMG_1675 (two Multigrade prints with rebate bands) shows inner corners of about 0.08–0.1 mm on film at about 97 px/mm. The 35 mm gate corner went from 0.4 mm to 0.1 mm.
- **120 bodies:** "Hasselblad V" is now **V** and "Toy camera" is now **Holga**. Saved raw values are unchanged.
- **Export sizes:** the renderer already cropped correctly (a 50 % crop exported at its own 3000 × 2000). The faults were in what the sizes meant:
  - on paper, "Full" made the sheet as large as the picture, so the picture was resampled;
  - the panel showed the uncropped original;
  - fixed S/M/L caps made L equal to Full on crops.

  Now `PhotoExporter.Size` is **Original / Long edge / Percent / Print (ppi)**, resolved against the native output and never enlarged. On paper the picture keeps one source pixel per output pixel (`PrintCompositor.nativeSize`), and a sheet that crops the picture keeps only the pixels shown. The planned W × H and MP appear before rendering (`PhotoRenderer.exportDimensions`), and the last choice is remembered. The presentation render uses the same picture size as export.
- **Darkroom simplified:**
  - Auto and the four edge types are one row of pills;
  - **Negative print is always an enlarger print** (`EditRecipe.renderedFilmEdgeLayout`), so the toggle and the Hand print preset are gone, and the easel appears for that type;
  - the Filed roughness, Edge reflection and Leak colour sliders are removed; leak colour follows the leak path;
  - unused strings were pruned.
- **Faster checks:** `core-checks.py --optimized` compiles with `-O -assert-config Debug`, which keeps every precondition and its message. `check-darkroom.py` uses it. The film-edge suite runs in about 40 s instead of about 25 min.
- **Known, older failure:** `tone-checks` still expects recipe version 4; the current version has been 5 since the Darkroom PoC.

## Nov 14 — Enlarger prints and the easel (one model for B&W and RA-4)

Runze's Ilford Multigrade prints (with a rebate border, borderless, and a close-up) and the RA-4 references showed that the old Hand print was wrong. Real prints have straight easel blades and a clean picture, with no filed edge, fog or vignette. The black border is a thin band of rebate that tapers where the projection is not quite square to the easel. B&W and colour use the same optics, so they share one model; monochrome stays an output choice.

Measurements from the full-resolution HEICs (hole pitch about 181 px per film mm in IMG_1673):
- **Blade edge:** about 8 px from paper to black, ≈ 0.04 mm on film including phone blur.
- **Gate edge into the picture:** a ramp of about 0.15 mm on film.
- **Holes:** as black as the rebate, with a thin light outline at the cut wall (our hole rim).
- **IMG_1670:** the band runs from zero on one side to about 0.3 mm on film on others.

**Model**
- **Easel (paper stage, `PrintLayout`/`PrintGeometry`/`Easel`):** each blade's edge lies about h = 3 mm above the emulsion. The lens pupil seen from the paper spans 1/(N(1+M)), so the penumbra is h/(N(1+M)) plus about 0.03 mm of paper spread. At f/8 that is about 0.1 mm on a 4×6.
- **Hand-set easel** (default on, with a toggle and a "New placement" dice):
  - every print: margins up to 0.8 % of the sheet's long side uneven, never more than 45 % of a margin;
  - clean print: the blade penumbra fades the picture into the paper;
  - film-edge enlarger print: the projection is up to 0.3° off square and up to 0.18 mm off centre in the opening, so the black band tapers. Off gives a centred machine print.
- **Enlarger zoom** (film edge, 90–110 %, default 98.5 %): the projected frame relative to the easel opening, with blades keeping the frame's proportions. The border is 18(1/z − 1) mm at the ends and 12(1/z − 1) mm at the sides. About 90 % reaches the holes; above 100 % the blades crop. The canvas is the opening plus a 2.5 % margin of the same sheet.
- **Enlarger print carrier:** straight, square-cornered, opaque, with no halo or reflection. Filed roughness and edge reflection apply only to scan holders and are hidden for enlarger prints. The Hand print preset is now just "enlarger print".
- **Metal:** `e[16]` carries the easel offset; scratches moved to `e[17…]`.

**Checks:**
- Paper: hand-set bounds, penumbra 0.05–0.2 mm, top-left vs CoreGraphics placement, legacy layouts default to hand-set.
- Film edge: clean preset; default shows a rebate band and no holes; 90 % reaches the holes; 105 % crops; opening and canvas follow the zoom; straight blade; hand-set ranges; machine print square; scans ignore the easel; CPU/Metal parity for a hand-set enlarger print.

## Nov 12 (later) — LUT / creative route fixed; test charts

Runze reported that the edge looks wrong with a LUT. Any recipe whose Develop differs from the edge material uses the creative composite: a LUT, Develop off, a cross-family stock, and also every scan or cinema type with the default Portra recipe. A probe rendered all four types through Spektrafilm, a LUT and Develop off and found three faults:

1. **Dashed black and white seam at the gate.** Rebate-only scratches were also applied to the composited centre wherever the gate mask was above zero. They now stay in the material render; only crossing scratches and dust are drawn over the centre.
2. **Darker 1 px border.** The centre image ended at the nominal gate, but the soft, worn or bulged gate opens past it, so its transparent border blended in. It is now clamped to its extent before placing.
3. **Leaks and fog stopped at the gate.** The centre is now prepared framed at gate size (the same framing as the support), and front/back leak and fog are added to it as exposure before the LUT or tone (`FilmEdgeRenderer.exposeCenter`, in the film graph's mid-grey units, linear up to 0.5 then a soft shoulder). With Mix below 100 % the developed endpoint uses the same framing.

New regression checks cover Develop off and a real LUT on all four types: no bright rim, dark seams in fewer than 2 % of columns, and a front leak brightens the LUT picture.

**Test charts:** `swift Scripts/make-test-images.swift [folder]` writes eight synthetic charts: gate edges, step wedge with colour patches, night, overcast, portrait grid, square 120, flat grey and fine detail. Each answers one question about the edge, LUT or loupe. Copies are in the vault (`Claude/Test-images/`, with a README), so they can be imported on the phone via Files. No real photos are in the repo.

## Nov 12 — Gate types, RA-4 hand print, picture-side rim, loupe (distress revision 4)

New reference: Runze's Kodak 5294 (Ektachrome 100D) slide scan, `IMG_0190 copy.jpg`, outside the repo.

- **Gate is separate from distress.** `FilmEdgeLayout.gate` (`FilmEdgeGate`) describes the camera and holder. There are four pill types: **Precise**, **Natural** (default) and **Loose**/**Rough**. Precise has softness 30 µm, wear 20 µm and no tilt or bulge. Natural has the same with a crisper/stronger holder, 0.2° tilt and 25 % bulge. Loose and Rough have softness 50 µm, wear 40 µm, more holder blur, 0.5°/0.8° tilt and 60 %/100 % bulge. The last type chosen is remembered (`darkroom.gateKind`). The old gate shapes (rounded/bulge/dip/keystone) were removed.
- **Tilt and bulge add up:** the gate gives the setup's inherent misalignment (direction from the seed), and distress "Handling" adds crooked loading (±3°) and film curl (±100 %). Bulge bows the gate outline up to ~0.22/0.15 mm.
- **Distress presets:** Clean (30 % rebate scratches by default), Lab scan (50 %), Hand print, Old camera (100 % scratches, 1° crooked loading, curl, dust, fog, leak) and Light leak. Removed controls: roughness scale (fixed), fog depth (derived from edge fog), light through holes (driven by edge fog), and holder blur/detail (now in the gate).
- **Hand print = enlarger RA-4 print** (`enlargerPrint`). The filed carrier sits in the negative plane: crisp edge (0.04 mm), no scan-holder specks or tail, opening stopped short of the holes (0.55 mm reveal), and edge reflection as the inward bleed. The result is a black filed border on white paper ([Photrio](https://www.photrio.com/forum/threads/black-frames-what-about-the-negative.55164)). A strongly tilted strip can still show slivers.
- **Holder model:** a crisp defocused core plus a faint tail (8 % over 0.12 mm), with abrasion specks. The paper shoulder makes the tail visible on inverted negatives and invisible against a slide's black holder, as in the scans.
- **Picture-side rim:** the hole-wall light-piping rim now has a bright yellow **core** (light reaching red and green layers; separate uniform `e[15]`) on the edge facing the picture. It sits under a warm streaky halo and sparkle points 0.05 mm into the rebate (P1485695). Slides reuse the same mechanism.
- **Cine perforations:** the format pills are 35 mm · 35 mm cine · 120. "35 mm cine" forces BH-1866 (5294 is BH-1866 per Kodak's [sell sheet](https://www.kodak.com/content/products-brochures/Film/EKTACHROME-100D-sell-sheet-EN.pdf)); 35 mm still follows the stock (Vision3 → BH).
- **UI:** manual scan method and format are pills. Darkroom Back saves and returns to the photo page. A **loupe** (`DarkroomLoupe`) sits at the upper right, can be dragged over the print, and shows 100 % of a full-resolution frame (≤ 4096 px, rendered after the preview settles); double-tap gives 200 %. It is toggled from the top-left button and the on/off state is remembered.
- Tests: the exact-geometry fixtures use the Precise gate. There are new checks for gate types, tilt/bulge, the enlarger print hiding holes, the holder tail, and the picture-side rim core. UI tests were updated for pills and Back to photo.

## Nov 11 — Edge refinement from Runze's scans (distress revision 3)

References: Runze's camera scans P1485659 (Gold 200), P1485695 and P1485707 (UltraMax 400), kept outside the repository. Edge cache key `v15`.

- **Presets:** Clean · Lab scan · Hand print · Old camera · Light leak. Filed carrier removed. Only Old camera carries dirt (dust and scratches). **Tape removed** everywhere.
- **White rim fixed (creative routes):** with Develop off, a LUT or a cross-family edge, the centre is composited through the soft gate over the material render. Inside the penumbra that render held its own developed image, which showed as a light rim (slide, cinema, faintly print). `FilmEdgeGeometry.erodesGate` now stops the material graph's scene at the inner edge of the penumbra, so the centre fades straight into rebate. Matched routes were already physical; the small DIR adjacency overshoot is film chemistry and kept. Regression test: creative slide/cinema/print with 100 µm softness show no peak above the interior.
- **Hole variation** (default 50 %, replaces hole wear): per-hole punch tolerance (±12 µm along, ±10 µm across, ±8 µm size, faint edge texture) plus a thin, streaky **light-piping rim** of base-path fog at the cut hole wall. That rim prints orange on RA-4/inverted scans, as in P1485695.
- **Sprockets stay pure:** new test, with leaks, fog and perforation fog at full: interior sprocket pixels are identical to a leak-free render on all four routes.
- **Holder:** the canvas now extends 0.5 mm past the carrier opening. Defaults are a defocused holder edge (`carrierBlur` 0.35 mm penumbra radius) and organic abrasion specks (`carrierDetail` 30 %). On a print the opaque holder is white and the clear holes fade through orange into it, as in P1485707/P1485659. Canvas is 38.6 × 27.4 mm for 135.
- **Scratches:** 16 candidates, clustered in four rail bands, mostly faint with a few strong, often dashed (per-scratch dash length/bias), thinner (3–15 µm), 75 % scatter (blue-white on prints), 25 % shallow emulsion cuts.
- **Gate shapes:** Standard (default), Rounded corners (0.45 mm), Film bulge, Film dip (edges bow 35–50 µm) and Tilted plane (keystone ~40 µm). The choice is saved per edit and remembered (`UserDefaults` `darkroom.gateShape`) as the default for the next film edge.

- **Scatter colour:** scratch scatter weights are now Rayleigh-like λ⁻⁴ (0.23 / 0.45 / 1.0), so rail scuffs print blue-violet as in the scans. Old camera scratches are stronger (65 %, wider 4–20 µm, stronger scatter).

Verification: `python3 Scripts/core-checks.py film-edge` passes on the final code. Default-route CPU/Metal max is 2.2e-5; full distress parity max is 5.3e-5. The complete `python3 Scripts/check-darkroom.py` suite passed, with 6/6 UI tests (`/private/tmp/spektrafilm-build/darkroom-workflow-1794442189678225000.xcresult`), before the final scatter-weight/scratch tweak, which film-edge then re-verified. `editor-session-benchmark` needed `PhotoCanvas` and `PhotoInfoPanel` in its compile list after the zoom-overlay commit. Proof crops against P1485707 are in the vault, `02_Projects/SpektraCam/Claude/Edge-proof-nov11/`, outside the repo. A generic iOS Release build succeeded; the iPhone was unavailable for install. The default-route CPU/Metal tolerance is now 3e-4 because defaults include seeded hole and holder noise (observed max ≈1.1e-4).

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
