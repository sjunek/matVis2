# matVis2.0 — Implementation Plan

## Summary

Rebuild [matVis](https://gitlab.mpcdf.mpg.de/mpibr/imag/matvis2.0), a MATLAB GUI for displaying multi-dimensional datasets as 2D images and 1D profiles, from scratch using modern MATLAB `uifigure` components. Split across multiple files for maintainability. Parallel development of an ImageJ2/Fiji plugin sharing the same core logic.

**Source:** Single ~2500-line file (`matVis.m` v1.2128) using legacy GUIDE-style `figure`/`uicontrol`
**Target:** Modern `uifigure` app, modular class-based architecture, ImageJ2 plugin in parallel
**MATLAB:** R2024b or latest stable
**ImageJ target:** ImageJ2/Fiji

---

## Old GUI Layout (reference)

The old GUI has 5 top-level figures:

| Figure | Size | Purpose |
|--------|------|---------|
| **Main GUI** (325px wide) | Fixed, bottom-aligned | Controls: sliders, colormaps, config |
| **Image Window(s)** | Square, ~450px | Full image + red crop indicator |
| **Zoom Window(s)** | Square, ~450px | Zoomed crop only |
| **Plot Window(s)** | ~1250x500 | Stacked 1D profiles per dimension |
| **Histogram Window** | Auto (Phase 3) |

Main GUI sections (top to bottom):
1. **Position controls** — per-dimension: name, position slider, zoom min/max sliders, play toggle, plot checkbox
2. **Image controls** — X/Y dim selectors, direction flips, filter/projection popups, contrast mode, gamma, colormap picker, toggle buttons (invert, flip, RGB, colorbar, aspect ratio)
3. **Windows/config** — toggle visibility of all sub-windows, save config, manual

---

## Directory Structure

```
matVis2.0/
├── matVis.m                    % Entry point — thin glue layer
├── core/                       % Framework-agnostic logic (reusable by ImageJ2)
│   ├── MatVisModel.m           % Data + metadata container
│   ├── MatVisRender.m          % Slice/zoom/profile extraction + display transform
│   └── MatVisRoi.m             % ROI data structure (Phase 4)
├── ui/                         % MATLAB uifigure components
│   ├── RangeSlider.m           % Custom: position + zoom range on one control
│   ├── MatVisMainWindow.m      % Main uifigure — control bar
│   ├── MatVisImageWin.m        % Standalone figure — full image + red crop indicator
│   ├── MatVisZoomWin.m         % Standalone figure — zoomed crop only
│   ├── MatVisPlotWin.m         % Standalone figure — stacked 1D profiles
│   ├── MatVisDimSelector.m     % X/Y dimension dropdowns + direction toggles
│   └── MatVisContrastWin.m     % Colormap, gamma, contrast min/max, histogram
├── io/
│   ├── loadFiles.m             % .mat, multi-page .tif, color .tif
│   └── parseArgs.m             % inputParser with documented properties
├── ij2/                        % ImageJ2/Fiji plugin (parallel with each phase)
│   ├── MatVisCommand.java      % @Plugin(Command.class) entry point
│   ├── CoreModel.java          % Wraps RandomAccessibleInterval
│   └── CoreRenderer.java       % Crop, colormap, gamma (reuses core/ logic)
└── tests/
    ├── parseArgsTest.m
    ├── loadFilesTest.m
    ├── MatVisModelTest.m
    ├── MatVisRenderTest.m
    └── RangeSliderTest.m       % Unit tests for the custom slider
```

---

## Data Flow

```
User input (slider/dropdown)
    → updates MatVisModel (CurrPos, ZoomRange, xySel, gamma, colormap, plotDims)
    → calls MatVisRender.renderSlice(model, xySel)  → 2D array
    → calls MatVisRender.renderProfile(model, dimIdx) → 1D array
    → MatVisImageWin displays 2D slice + red crop indicator
    → MatVisZoomWin displays cropped region
    → MatVisPlotWin displays 1D lines for selected dimensions
```

**Position definition:** Sliders across all N dimensions define a single coordinate in N-space.
- **Image:** 2D cross-section through that point (which dimensions = X/Y chosen by dropdowns)
- **Plot:** 1D profile through that point (which dimensions = checked checkboxes)

---

## RangeSlider Custom Component

`uislider` in MATLAB does not support range handles. `RangeSlider` is a custom `uipanel` + `uislider` + 3 indicator patches:

```
Full extent:  |--------------------------------------------------------|
Zoom region:       [======|======]
                    ^       ^
                  min     max
Position:        |  ^  |
                 ^  ^
               marker cursor
```

**Three indicator marks:**
1. **Zoom minimum** — left edge of zoom range
2. **Zoom maximum** — right edge of zoom range
3. **Position** — currently selected value

**Callbacks:** Dragging any indicator updates `Model.ZoomRange` or `Model.CurrPos` and triggers render.

---

## Phase 1 — Core Viewer (MVP)

**Goal:** Load a `.mat` or `.tif` matrix. Navigate with dimension sliders. View 2D slice + zoom crop + 1D profiles. Select colormap.

### Build order (interdependent, one after another):

| # | File | Description |
|---|------|-------------|
| 1 | `io/parseArgs.m` | `inputParser` — required: `data`. Optional: `'dimNames'`, `'dimUnits'`, `'dimScale'`, `'matNames'`, `'alphaMap'`, `'colorBarLabel'`, `'startPar'`, `'debug'`. Handles `'startPar'` cell array: `{'xySel';1; 'zoomVal';[...]; 'gamma';0.8; 'cmap';5; ...}`. Minimal: does NOT yet parse every old property. |
| 2 | `io/loadFiles.m` | Load `.mat` and `.tif` (single + multi-page, grayscale + color). Return raw numeric array. |
| 3 | `core/MatVisModel.m` | `classdef` with properties: `Data` (numeric array), `Size`, `DimNames`, `DimScale`, `DimUnits`, `CurrPos`, `ZoomRange`, `XDim`, `YDim`, `Gamma`, `ColormapIdx`, `PlotDims`, `ContrastMin`, `ContrastMax`. Getters/setters with validation (e.g., `set.XDim` validates not equal to YDim). |
| 4 | `core/MatVisRender.m` | Functions: `renderSlice(model, xyDims)` → 2D cropped array; `renderProfile(model, dimIdx)` → 1D cropped array; `applyGamma(data, gamma)`; `applyColormap(data, colormap)`; `computeHistogram(data)` |
| 5 | `ui/RangeSlider.m` | Custom `uipanel` subclass (or constructor function returning handles). Contains: label text, `uislider` for full range, two `uicontrol` patch objects for zoom min/max indicators, one position indicator. Public methods: `SetValue(val)`, `GetZoomRange()`, `SetZoomRange(lo, hi)`. |
| 6 | `ui/MatVisImageWin.m` | Standalone `figure` with `axes`. Displays current x/y slice via `imshow` (colormap + gamma applied). Red rectangle (`rectangle`) shows zoom crop region on full image. |
| 7 | `ui/MatVisZoomWin.m` | Standalone `figure` with `axes`. Displays only the cropped zoom region. Pan synced with image window (right-click to unzoom). |
| 8 | `ui/MatVisPlotWin.m` | Standalone `figure` with stacked `axes`. Each subplot is a 1D line plot for one dimension. Checkboxes in main window toggle which dims appear. |
| 9 | `ui/MatVisDimSelector.m` | Two `uidropdown` (X dim, Y dim) + two direction flip toggles (`uitogglebutton`). On change, updates `Model.XDim`/`Model.YDim` and triggers render. |
| 10 | `ui/MatVisContrastWin.m` | `uidropdown` for colormap (built-in list from old `popLutString`). `uislider` + edit for gamma. `uislider`s for contrast min/max. Tiny histogram of current image. |
| 11 | `ui/MatVisMainWindow.m` | `uifigure` layout: top section = `RangeSlider` rows (one per dimension, each with plot checkbox `uicheckbox`), play toggle button; middle section = `DimSelector` + `ContrastWin` panel; bottom = window visibility toggles (Image/Zoom/Plot), save config. Wires all callbacks: slider change → update Model → call Render → update all 3 display windows. |
| 12 | `matVis.m` | Thin glue: `varargout = matVis(data, varargin)` → parse args → load data → create `MatVisModel` → launch `MatVisMainWindow` → return handles. |

### Phase 1 — Scope

**Included:**
- Per-dimension `RangeSlider` with position + zoom range indicators
- Play toggle button (lower one: plays across zoom range only)
- Position text field (shows current value next to slider)
- X/Y dimension dropdowns + direction toggles
- Colormap dropdown
- Gamma slider + edit
- Contrast min/max sliders
- Plot dimension checkboxes
- Window visibility toggles (Image/Zoom/Plot)
- Single dataset loading (`.mat`, `.tif`)

**Excluded (later phases):**
- Saved position presets (set/get position buttons)
- Find local/global min/max
- Image filter popup
- Projection method + dim popup
- Threshold mode
- RGB display
- Alpha map / masking
- 2D histogram
- ROI manager
- Profile manager
- Video recorder
- Multi-dataset mode
- Orthogonal views

---

## Phase 2 — Orthogonal Views + Saved Positions + Config

| File | What |
|------|------|
| `ui/MatVisOrthoWin.m` | 3 orthogonal slices (XY, XZ, YZ) in one figure, linked to main position |
| Config save/load | Write `startPar` to `customConfig.mat`; auto-load on startup if available |
| Position presets | Save/current position + jump-to presets in `MatVisModel` |
| Aspect ratio toggle | Fix image axes aspect ratio (old `tbAspRatio`) |

---

## Phase 3 — RGB + Alpha + Histogram Contrast

| File | What |
|------|------|
| RGB toggle | RGB display mode (per-dimension RGB channels + stretch mode) |
| Alpha map | `alphaMap` input + alpha-aware rendering |
| 2D histogram | Full histogram window with 2D contrast adjustment |

---

## Phase 4 — ROI Manager + Profile Manager

| File | What |
|------|------|
| `ui/MatVisRoiManager.m` | Create/shift/rotate/scale ROIs, ROI list, rename, export |
| `ui/MatVisProfileManager.m` | Define profile ROIs, view profiles, export |

---

## Phase 5 — Projections + Video

| File | What |
|------|------|
| Projection toolbar | Max/min/mean/std/var/diff/tile projections on selected dimension |
| `ui/MatVisRecorder.m` | Movie generator combining content of multiple windows |

---

## Phase 6 — Multi-Dataset + Refactoring

- `MatVisModel` → per-dataset wrapper (`MatVisDataset`)
- Shared position across datasets, independent windows per dataset
- Refactor remaining old `inputParser` properties

---

## ImageJ2/Fiji Integration

For each phase, after the MATLAB code is complete:

1. **Translate `core/` logic to Java:**
   - `MatVisModel` → `CoreModel` wrapping `RandomAccessibleInterval`
   - `MatVisRender` → `CoreRenderer` using ImgLib2 `Views` + `Crop` + custom colormap

2. **Write ImageJ2 plugin entry point:**
   - `@Plugin(type=Command.class)` annotated class
   - Uses `NetImgView` or `ImageJ2` viewer for display
   - UI built with `scijava`/`imagej-ui-swing` components

3. **Parallel development:** Each phase's MATLAB code → ImageJ2 wrapper immediately after

---

## Coding Conventions

- **No single-file everything.** Each component in its own `.m` file.
- **Class-based:** `MatVisModel`, `MatVisRender` as `classdef` in `core/`
- **Constructor functions for UI components:** `RangeSlider.m` returns handles struct, not a full classdef
- **Callbacks use function handles** attached to UI components, not `eval` or string callbacks
- **No absolute pixel positioning.** Use `uigridlayout` or `uifixlayout` as appropriate for `uifigure`
- **Error handling:** `inputParser` validation for args; dimension consistency checks in Model setters
- **Testing:** Unit tests for `core/` functions and `io/` functions in `tests/` directory
- **ImageJ2 code:** Java source in `ij2/`, follows ImgLib2 conventions

---

## Files for Reference

| File | Location | Content |
|------|----------|---------|
| `matVis.m` | `D:\Matlab\GitRepositories\matvis2.0\matVis.m` | Original single-file GUI (~2500 lines, v1.2128) |
| `ProjectBrief.txt` | `D:\Matlab\GitRepositories\matvis2.0\ProjectBrief.txt` | Feature list, input/output specs, mouse/keyboard actions |
| `MainGUI_Screenshot.png` | `D:\Matlab\GitRepositories\matvis2.0\MainGUI_Screenshot.png` | Visual reference of old GUI layout |

---

## Key Decisions Made

1. **UI framework:** `uifigure` (modern MATLAB UI, App Designer compatible)
2. **MATLAB version:** Latest stable (R2024b+), so `uislider`, `uigridlayout`, `uidropdown` all available
3. **Single vs multi-window:** Separate top-level figures for Image, Zoom, Plot (matches old GUI)
4. **RangeSlider:** Custom component combining position + zoom range (3 indicators)
5. **ImageJ target:** ImageJ2/Fiji (modern Java, ImgLib2)
6. **Parallel dev:** Each MATLAB phase → ImageJ wrapper immediately after
7. **Phase 1 scope:** Up to and including colormap controls; position sliders + zoom range; plot checkboxes
