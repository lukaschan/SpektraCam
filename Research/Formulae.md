# Formulae 配方

Status: Phases A, B and C are implemented on `codex/formulae`. Of Phase D, the link, the QR code
and the formula card are implemented; the starter set, a default formula and a Shortcuts action
are not started. Nothing here ships in 1.0.

## Before Phase D — 2026-11-16

- A report from the phone that the first saved formula followed later edits was not reproduced.
  Regression checks (`FormulaRegressionTests`) save C200 as the first formula, edit the source to
  400H and save another, then reapply the first from both Photo and Edit; separate checks compare
  settings and warm/fresh renderer pixels across two photos, and ensure the formula files remain
  byte-for-byte unchanged. They pass on Simulator with the Phase B/C saving code as it was, so the
  rewrite made for the report (a `FormulaDraft` captured at the tap, an immutable recipe, a strip
  disabled while developing, thumbnails cleared on every change) was withdrawn: it fixed nothing
  the checks can show, and it kept formulae from being switched during a render and replaced
  each thumbnail with a spinner whenever its photo changed. If the symptom persists on the
  phone, the affected `.rnformula` is needed.
- Covered enlarger paper is anchored to output white after scanner/tone processing, through
  the same seeded blade coverage. Its interior is untouched; only the perimeter is evaluated,
  using file-backed RGBA8 storage for the output and the same finishing for loupe regions.
  Paper spread increased from 0.05 to 0.06 mm for a very small softness increase.
- Export offers Original RAW for RAW sources, alongside Processed photo. Sharing and saving use
  a byte-for-byte copy, with its original filename/extension and metadata, without a RAW decode.
- A photo tap leaves the viewer controls visible. Easel is now 尺板 in Simplified Chinese.
- Remember flash status is off by default; leaving the camera resets flash unless enabled.
- Magenta remains the default accent. Black & White uses standard system-green switches;
  switch state is separate from navigation tint, preserving the native thumb and accessibility.
  See Apple's [toggles](https://developer.apple.com/design/human-interface-guidelines/toggles),
  [Liquid Glass colour](https://developer.apple.com/design/human-interface-guidelines/color), and
  [adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

A formula is a named, reusable look. It is one recipe without its framing, split into three
parts that follow the process:

- **Look** — film, print, tone, grain and effects, LUT slots, and the metering mode.
- **Exposure** — what was corrected for one negative: exposure amounts, white balance and the
  Y/M filter balance. Left out by default.
- **Darkroom** — paper, border and film edge.

Crop and rotation belong to the photograph and are never copied, pasted or saved.

## What exists

- `Models/RecipeParts.swift`: `EditRecipe.taking(_:from:rawTarget:)` replaces whole parts. Its
  switch over every stored field has no default, so a new field does not compile until it is
  given to a part.
- Copy Look / Paste Look in the viewer, editor and library; a library paste is one saved
  change with one Undo.
- `Models/Formula.swift`: the `.rnformula` file. `Features/Formulae/FormulaLibrary.swift`: one
  file per formula under `Application Support/SpektraCam/Formulae`, with an index for order
  and favourites only.
- Save as Formula and the formula strip in the information panel; Apply Formula for a library
  selection; a combined Formulae | LUTs manager.
- Sharing: the exported type `io.github.runzeni.spektracam.formula` and its document type are
  declared in `Configuration/SpektraCam-Info.plist`, which is merged into the generated
  Info.plist. `FormulaFile` is the share-sheet file. `FormulaImportSheet` previews a file
  from `onOpenURL` or the manager's Import before anything is added. `FormulaDetailView` is a
  formula's page: what it carries, the LUTs it needs, Rename and Share.
- Link and code: `Models/FormulaLink.swift` packs the stored file (white space and framing
  removed, raw DEFLATE, URL-safe Base64) after `#` in `https://runzeni.github.io/spektracam/f#1.…`,
  or `spektracam://f#1.…` for the app's own scheme, which is declared in the merged Info.plist.
  `Features/Formulae/FormulaCode.swift` draws the link as a QR code and reads codes from a picture.
- `Features/Formulae/FormulaProcess.swift` reads a formula as a procedure in the editor's own
  words. `FormulaCard` prints it with the code and an optional photo as a 1080 × 1350 picture;
  `FormulaCardSheet` (Formula Card… on a formula's page) chooses the photo and shares it. Copy
  Link is on the same page. The manager's Import takes a file, a card's picture or a pasted link.
- `Site/f/index.html` is the page for the link: it unpacks the formula in the browser, shows it
  and offers Open in SpektraCam and the file. It loads nothing and sends nothing.

## Rules that must keep holding

- Applying is a snapshot. Later changes to a formula change no photo.
- A formula that calls for a LUT that is not installed is refused, never applied in part. LUT
  ids are SHA-256 hashes of the file, so importing the same file again restores the link.
- A plain LUT delete keeps LUTs that formulae need. A forced delete leaves the formula asking
  for the file.
- Each part has its own version in the file. A build applies the parts it can read and lists
  the rest as needing a newer SpektraCam; an unknown paper or gate counts as a newer Darkroom,
  not a corrupt file.
- The stored file is never re-encoded for a rename, so settings an older build cannot read
  survive it.
- Files are untrusted: unknown parameter paths are dropped and values held to each control's
  limits.
- A shared file carries LUT files only when the sharer chooses "Share with LUT Files". Each
  is kept as its `.cube` text under `attachments`, and one whose bytes do not hash to its id
  is dropped. On import they go to the LUT library; the kept formula file never holds them.
- Opening a file adds nothing by itself. The same file again is recognised; a changed version
  asks Replace or Keep Both.
- "Choose Another LUT" is the only edit that changes a saved formula's look, and only the
  user makes it.
- A link or code is the formula file, not a summary of it: fields this build cannot read
  travel in it, and what it delivers is read by the same `Formula(data:)` as any file. LUT
  files never travel in a link. A packing number other than `1` is a newer SpektraCam's.
- A code's modules are a whole number of pixels on the card (four at 1080 px), and a link too
  long for that (`FormulaLink.codeLimit`) gets no code; the card says to ask for the file.

## Checks

`python3 Scripts/core-checks.py recipe library` covers the part model, the file format
(including a newer writer and a hostile file), the link (round trip, unknown fields, other
addresses, broken and newer packings), and paste, undo and the formula store across a
restart, and the exported share file. UI: `LookPasteTests`, `FormulaTests`,
`FormulaSharingTests`, `FormulaRegressionTests`, `FormulaCardTests` (set
`TEST_RUNNER_SPEKTRACAM_LAYOUT_PHOTO` and `TEST_RUNNER_SPEKTRACAM_SECOND_PHOTO` to two host
images). On the Simulator, debug builds take `--ui-test-open <file>`, `--ui-test-open-link <link>`
and `--ui-test-lut <file>` in place of "Open in SpektraCam", a tapped link and the system file
picker. `--check-formula-card <folder>` renders cards and reads each code back through the
import path, also from the picture at 720 px and as a 50 % JPEG.

## Not done

- Not exercised by any automated test: the system share sheet itself, and a real "Open in
  SpektraCam" from Files, Messages or AirDrop. Both need a check on a phone.
- The link's page is not published. Until `Site/f/index.html` is served at
  `runzeni.github.io/spektracam/f`, a code scanned with the Camera app or a link tapped outside
  SpektraCam leads nowhere; importing a card's picture and pasting a link work without it. The
  page's script was run against the app's links, but the page was not viewed in a browser.
- Universal links: opening the https link straight in the app needs the Associated Domains
  entitlement and an `apple-app-site-association` file at the root of `runzeni.github.io`.
  Neither exists; the page's Open in SpektraCam button uses `spektracam://` instead.
- Not tried on a phone: scanning a card with a camera (from a screen or a print), the photo
  picker route, and the `spektracam://` scheme opened from Safari.
- No scanner inside the app. A card is imported from its picture.
- Importing several formula files at once.
- A starter set, a default formula for new edits and the camera, a Shortcuts action.
- A photo does not yet remember which formula it was developed with.
- In the editor the strip shows names only; the editor owns the renderer while it is open.
