# Formulae 配方

Status: Phases A and B are implemented on `codex/formulae`; file sharing (C) and link, QR and
formula card (D) are not started. Nothing here ships in 1.0.

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

## Checks

`python3 Scripts/core-checks.py recipe library` covers the part model, the file format
(including a newer writer and a hostile file), and paste, undo and the formula store across a
restart. UI: `LookPasteTests`, `FormulaTests` (set `TEST_RUNNER_SPEKTRACAM_LAYOUT_PHOTO` and
`TEST_RUNNER_SPEKTRACAM_SECOND_PHOTO` to two host images).

## Not done

- Sharing: the exported type, share sheet, import preview and the missing-LUT import flow.
- Link and QR that carry the formula, the formula card, a starter set, a default formula for
  new edits and the camera, a Shortcuts action.
- A photo does not yet remember which formula it was developed with.
- In the editor the strip shows names only; the editor owns the renderer while it is open.
