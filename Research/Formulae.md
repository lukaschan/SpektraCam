# Formulae 配方

Status: concept only; next development area after the frozen App Store 1.0 candidate.

Formulae are named, reusable editing recipes for customized looks and batch work.

Initial direction:

- Save the current look as a formula; name, rename, duplicate and delete saved formulae.
- Apply a formula to one photo or a selected batch, then use the existing batch export workflow.
- Build on `EditRecipe` and the existing renderer instead of introducing another processing path.
- Keep crop and framing optional. Decide explicitly how exposure, white balance and other
  photo-specific settings are included, so applying a look does not unexpectedly overwrite them.
- Preserve LUT dependencies; explain missing LUTs instead of silently changing the result.
- Keep applied photo edits independent of later changes to a saved formula, with Undo support.

Still open: the save/apply controls, recipe scope, organization and whether sharing belongs in
the first iteration. No feature implementation or saved-recipe migration is included yet.

Submission source: `release/1.0`, tag `v1.0.0-rc.1`, version 1.0 (10).
Use `/Users/runzeni/dev/Xcode/SpektraCam-AppStore-v1.0` for submission work and this separate
`SpektraCam-formulae` checkout for development. Keep Formulae changes out of the 1.0 release branch.
