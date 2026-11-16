# Adaptive camera and rendering checks

The copied fix was restored to this adaptive worktree on November 15, 2026.
Transfer details, verified archives, current test results, and remaining checks are in
[the archive record](Archives/AdaptiveFix-2026-11-15/README.md).

The Duo launch failure was a Metal validation abort in library thumbnail rendering:
`Dispatch Threads with Non-Uniform Threadgroup Size is not supported on this device`.
The failing stack reached `MetalFilmPipeline.encodeGraph` through `LibraryImages.rebuild`.
Camera dismissal can expose pending thumbnail work, so an apparent unresponsive library
does not establish that a camera event handler consumed a tap.

## Implementation rules

- Dispatch independent pixel kernels through `MTLComputeCommandEncoder.dispatchGrid`.
  It rounds up uniform threadgroups, which every Metal GPU supports. Every kernel must
  guard its logical dimensions before memory access. Keep explicit fixed-size dispatches
  for cooperative reductions, whose barriers require all lanes to participate.
- Do not add device-name or simulator checks to rendering. Audit both buffer and texture
  paths when changing GPU submission, including tone, diffusion, grain, and tiled rendering.
- Hardware capture uses the same `canCapture` predicate as the shutter and is disabled
  outside the active scene. The on-screen shutter can separately resume a user hold.
- Treat a closed camera as terminal: late events cannot restore readiness or start capture.
- Discover lenses from AVFoundation and probe each attached input's RAW output formats before
  offering it. Recheck after switching. Distinguish Bayer RAW from ProRAW; an unsupported
  camera must preserve access to import/editing. A Simulator demo checks UI policy only.
- Keep the optics row identical across layouts. Center the shutter independently of accessory
  controls and navigation insets; verify its actual window coordinates in UI tests.

## Regression gate

Run `python3 Scripts/layout-matrix.py --camera-only` with phone, Duo, and iPad simulators booted.
Run Duo once closed and once unfolded. Run iPad full screen and in a resized window.
The suite makes its own odd-sized image and checks LVF hold across background/foreground,
rotation, both camera exits, reopening, actual library actions, film rendering, grading,
and preservation of editor navigation. Logs and result bundles are retained under `--shots`.
The suite also exercises Bayer-only and no-RAW configurations. Physical-device checks remain
necessary to validate lens capability discovery, capture dimensions, flash, and hardware buttons.

For the full editor/Darkroom layout tour, supply `--photo /absolute/path/to/photo.jpg`.
For GPU bounds and numerical checks, run
`python3 Scripts/core-checks.py metal-dispatch metal-color metal-film metal-grain metal-diffusion tone`
in an environment with GPU access. `metal-dispatch` checks logical output and untouched
canary memory for tiny, aligned, partial, and odd two-dimensional grids.
