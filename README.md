# matVis 2.0

Multi-dimensional data viewer for MATLAB — displays N-D arrays as 2D images and 1D profiles.

## Launch

```matlab
matVis2(myData)
matVis2(myData, 'dimNames', {'X','Y','Z'}, 'gamma', 0.8)
matVis2(myData, 'startPar', {'xySel', [1 2], 'gamma', 0.8})
handles = matVis2(myData)
```

## File Structure

| Path | Purpose |
|------|---------|
| `matVis2.m` | Entry point — path setup, arg parsing, model creation, GUI launch |
| `core/` | Framework-agnostic logic: `MatVisModel` (data + metadata), `MatVisRender` (slice/profile/colormap) |
| `ui/` | MATLAB uifigure components: main window, image/zoom/plot windows, sliders, contrast controls |
| `io/` | Input handling: `parseArgs` (inputParser wrapper), `loadFiles` (.mat and .tif loaders) |
| `tests/` | Unit tests for core and io components |
| `ij2/` | ImageJ2/Fiji plugin (parallel Java port of core/ logic) |

## Phase 1 Features

- Per-dimension range sliders with position and zoom-range indicators
- Play button (animates across zoom range)
- X/Y dimension dropdowns with direction flip toggles
- Colormap selector
- Gamma slider and numeric edit
- Contrast min/max sliders
- Plot dimension checkboxes (1D profiles)
- Window visibility toggles (Image / Zoom / Plot)
- Single dataset loading from `.mat` and `.tif` files
