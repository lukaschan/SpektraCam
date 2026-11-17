# Formulae 配方

Status: Phases A, B and C are implemented on `codex/formulae`; link, QR and formula card (D)
are not started. Nothing here ships in 1.0.

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

## Checks

`python3 Scripts/core-checks.py recipe library` covers the part model, the file format
(including a newer writer and a hostile file), and paste, undo and the formula store across a
restart, and the exported share file. UI: `LookPasteTests`, `FormulaTests`,
`FormulaSharingTests` (set `TEST_RUNNER_SPEKTRACAM_LAYOUT_PHOTO` and
`TEST_RUNNER_SPEKTRACAM_SECOND_PHOTO` to two host images). On the Simulator, debug builds take
`--ui-test-open <file>` and `--ui-test-lut <file>` in place of "Open in SpektraCam" and the
system file picker.

## Not done

- Not exercised by any automated test: the system share sheet itself, and a real "Open in
  SpektraCam" from Files, Messages or AirDrop. Both need a check on a phone.
- Importing several formula files at once.
- Link and QR that carry the formula, the formula card, a starter set, a default formula for
  new edits and the camera, a Shortcuts action.
- A photo does not yet remember which formula it was developed with.
- In the editor the strip shows names only; the editor owns the renderer while it is open.
