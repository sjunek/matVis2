# Memory-efficient mode — implementation plan

Open and navigate datasets larger than RAM (or merely slow to load) by reading
only what is displayed, using resolution levels that already exist inside the
file wherever the format provides them.

## 1. Goal and non-goals

**Goal.** A dataset opens in ~1 s instead of ~40 s and runs in a bounded RAM
budget, at the cost of a per-navigation-step disk read. Every feature either
keeps working, works from a decimated overview and says so, or is disabled
with a visible reason — never silently wrong.

**Non-goals.** Building a resolution pyramid by brute force at load time (that
is the cost we are avoiding). Changing behaviour for datasets passed in from
the workspace as numeric arrays: `matVis2(myStack)` must be byte-identical to
today.

## 2. Measured baseline

All figures from `tests/LargeTestFiles` on a 256 GB / NVMe workstation. Treat
them as an optimistic bound: the OS page cache held the whole file, and a 16 GB
laptop reads cold.

| Stage (5.88 GB CZI, 1924x1920x57x15) | Time |
|---|---|
| `loadFiles` — Bio-Formats, 855 planes | **39.99 s** |
| `min` / `max` / argmax over the full array | 0.10 s each |
| `MatVisModel` constructor, total | 0.48 s |
| `histcounts`, 10k bins | 0.38 s |
| max-projection over Z=57 | 0.16 s |

**Startup is ~99 % file reading.** Every in-memory pass is noise against it.
This is the most important finding in this document: memory-efficient mode
means "read less", and nothing else. No contrast, histogram or projection code
needs to get cheaper.

Per-plane read costs:

| Backend | Per plane |
|---|---|
| Plane-chunked HDF5, uncompressed | 7 ms |
| Plane-chunked HDF5, deflate-1 + shuffle | 26–31 ms |
| Bio-Formats .czi | 60–92 ms |
| LZW BigTIFF via `Tiff` | 67 ms |
| Zstd/PackBits BigTIFF | unreadable by MATLAB `Tiff` |
| `matfile`, `save -v7.3` default chunks | 3.9 s |

Tiled reads from the 53865x29727 stitched plane: 512² 0.10 s, 1024² 0.066 s,
2048² 0.216 s, 4096² 0.53 s.

## 3. Pyramids that already exist — use them first

`ClaudiasSection2...czi` reports **5 series** that are in fact resolution
levels of one image:

| Level | Size | Full-plane read |
|---|---|---|
| 0 | 53865 x 29727 | **fails** — Java 2 GB array limit |
| 1 | 17955 x 9909 | 3.69 s |
| 2 | 5985 x 3303 | 0.50 s |
| 3 | 1995 x 1101 | 0.04 s |
| 4 | 665 x 367 | 0.01 s |

Two consequences:

1. **The overview is free for such files.** Level 3 loads in 40 ms and is
   immediately good enough for the global histogram, the 3-D viewer (which
   already decimates to a 4e6 voxel budget in `MatVis3DWin`) and the
   cross-section window. No decimation pass, no extra read.
2. **matVis2 cannot open this file at all today.** `loadBioFormats.m:21` reads
   series 0 and warns about the rest; series 0 throws
   `java.lang.IllegalArgumentException: Array size too large` from inside
   Bio-Formats regardless of available RAM. Level awareness fixes an outright
   failure, not just slowness.

Bio-Formats exposes levels either as separate series (the default,
`setFlattenedResolutions(true)`, which is what we observed) or as resolutions
of one series via `getResolutionCount` / `setResolution` when flattening is
turned off. The source layer normalizes both into one `LevelSizes` list, so
nothing above it needs to know which spelling a format used.

Where a format carries no levels (plain TIFF), the same interface is served by
levels synthesized on demand — see M2.

## 4. Architecture

One new abstraction, placed at the existing choke point. `MatVisRender`
already builds a complete recipe for every slice it needs — `rawSlicePlan`,
`core/MatVisRender.m:104` — consisting of a per-dimension index cell plus a
cache key. That plan is exactly a read request. Today it is executed against a
numeric array by `subarray_` (`core/MatVisRender.m:1337`); it will instead be
executed against a data source.

```
core/MatVisDataSource.m        abstract base
core/MatVisMemorySource.m      wraps a numeric array — today's behaviour
core/MatVisBioFormatsSource.m  reader handle + level table + plane cache
core/MatVisTiffSource.m        IFD offsets + per-page decode (incl. Zstd)
core/MatVisH5CacheSource.m     re-chunked cache (M5, optional)
core/MatVisPlaneCache.m        shared LRU under a byte budget
```

Interface:

```matlab
properties (Abstract, SetAccess = protected)
    Size          % 1xN, level 0
    ClassName     % 'uint16' — element class, NOT the container class
    IsInteger     % logical
    LevelSizes    % 1xL cell of 1xN sizes, level 1 = full resolution
    Capabilities  % struct: HasFileLevels, SupportsTiles, PlaneReadCost (s)
end

methods (Abstract)
    A = readPlan(obj, plan)              % plan may carry .level and strides
    v = readRegion(obj, idxCells, level) % arbitrary hyperrectangle
    [mn, mx] = valueRange(obj)           % exact, or from the overview
end
```

`Capabilities` is what keeps this from becoming one lazy implementation
pretending every format behaves alike: CZI has file levels and tiles, TIFF has
neither, and `PlaneReadCost` — probed from 2–3 reads at open — drives prefetch
depth and the entry gate.

`model.Datasets{k}` holds sources rather than arrays. `MatVisModel` gains
`ClassName` / `IsInteger` delegating to the source; this is required because
`isinteger(model.Datasets{...})` at `ui/MatVisMainWindow.m:1931` currently
drives integer contrast snapping and would silently return false for an object.

## 5. Milestones

### M1 — Data-source interface, in-memory only  *(done)*

No behaviour change; this is the refactor that makes everything else possible.

Implemented: `core/MatVisDataSource.m` (abstract) and `core/MatVisMemorySource.m`.
`MatVisModel.Datasets` and `AlphaMaps` now hold sources; `MatVisModel.ClassName`
and `.IsInteger` delegate to the active one.  All 18 direct dataset reads plus
the ROI linear-index paths go through `readSub` / `readLinear`, and the
whole-dataset queries through `histCounts` / `channelRange` / `valueRange` /
`peakIndex`.  `MatVisRender.subarray_` is gone -- its job moved into
`MatVisMemorySource.readSub`.

Verified: 214 tests, the same 23 pre-existing failures as before the change
(18 RangeSliderTest, 5 MatVisModelTest); a GUI smoke test covering projection,
tile, RGB triad and stretch, cross-dimension plots, ROI and profile traces, all
four contrast modes, alpha maps and multi-dataset; and an A/B timing run on a
200 MB stack (ctor 0.178 -> 0.202 s, 200 slices 0.344 -> 0.341 s, projections
and profiles unchanged).

A note on strictness: a bare numeric array handed to `MatVisRender` is now an
error rather than being wrapped on the fly.  That is deliberate -- once lazy
sources exist, silently accepting an array would hide exactly the accidental
full materializations this work is meant to prevent.  `MatVisRenderTest`'s mock
model was updated to hold a source, matching the real one.

- Add the classes above with `MatVisMemorySource` only.
- Route the 18 direct `model.Datasets{ds}` reads through the source. They are
  a finite list: `core/MatVisFrameComposer.m` (835, 927, 1068, 1357),
  `core/MatVisRender.m:478`, `ui/MatVis3DWin.m:376`, `ui/MatVisImageWin.m:444`,
  `ui/MatVisMainWindow.m` (1055, 1568, 1617, 1628, 1931, 2172),
  `ui/MatVisXSecWin.m` (313, 448, 1168, 1184), `ui/MatVisZoomWin.m:417`.
- Relax `validateattributes(datasets, {'numeric'})` in the `MatVisModel`
  constructor to accept a source.
- Give the ROI paths a source method instead of linear indexing: the
  `data(lin)` / `sub2ind` reads in `renderRoiProfileFromData`
  (`core/MatVisRender.m:290`) and `getRoiValuesFromData` (`:317`) cannot be
  expressed as a plan.

**Exit criterion:** the existing test suite passes unchanged, and
`matVis2(numericArray)` startup time is unchanged within noise.

### M2 — Lazy sources and the entry gate  *(core done; gaps listed below)*

Implemented: `core/MatVisLazySource.m` (all the N-dimensional bookkeeping --
one hyperrectangle request becomes a set of plane reads plus in-plane crops),
`core/MatVisBioFormatsSource.m`, `core/MatVisPlaneCache.m` (session-wide LRU,
budget from free memory), `io/matVisOpenSource.m`, `io/matVisLoadPolicy.m`, and
a `'LoadMode'` name-value pair on `matVis2` (`auto` | `lazy` | `full`).
`io/bfReadMetadata.m` was split out of `loadBioFormats` so both paths carry
identical dimension metadata.  `parseArgs` accepts a source.

Bio-Formats covers .czi and standard TIFF, so no separate TIFF backend was
needed -- `loadFiles` already routes TIFFs through it.

Measured:

| | full load | lazy |
|---|---|---|
| 5.88 GB .czi, open to model | 40.5 s | **2.4 s** |
| navigation, per step | instant | 47-53 ms (180 ms through a full GUI render) |
| overview (no file pyramid) | -- | 1.5 s |
| 3.4 GB LZW BigTIFF, open | ~83 s + 9.6 GB RAM | **2.7 s** |
| 10.1 GB stitched .czi, open | **impossible** | **6.4 s** |

Correctness: against a synthetic OME-TIFF, `readSub` over the whole array,
25 random hyperrectangles, `readLinear`, rendered slices under projection and
RGB triad, and profiles are all byte-identical to the in-memory path.  Against
the 5.88 GB .czi loaded in full, six random sub-blocks and a 300-element
`readLinear` match, as do the dimension names and size.  Suite: 239 tests, the
same 23 pre-existing failures as the baseline.

**Gaps still open in M2:**

- **Zstandard TIFFs have no lazy path.**  Bio-Formats fails on them
  (`NegativeArraySizeException`) and `io/loadZstdTiff` decodes whole-file only.
  Its `readPage` would have to be split out the way `bfReadMetadata` was.
  Such files fall back to a full load, which still works.
- **The overview is built on first need, not in the background.**  For a file
  with its own levels it is built at construction and costs nothing; without
  levels the first global-contrast or histogram use blocks for ~1.5 s.
- **Approximate values are labelled** *(done)*.  `MatVisDataSource` carries a
  `StatsApproximate` flag -- true for every file-backed source, because
  `valueRange` / `peakIndex` / `histCounts` / `channelRange` are answered from
  a sample.  `MatVisModel.StatsApproximate` surfaces it, and the main window
  marks it in three places: an italic `approx.` on the histogram axes, a
  `[memory-efficient]` suffix on the window title for as long as it is open,
  and tooltips on the Global contrast button and the histogram-range and
  percentile fields explaining where the numbers came from and that
  `matVis2(file, LoadMode, full)` gives exact ones.  Only Global is
  tooltipped: Image, Zoom and Manual work from arrays fully in hand and stay
  exact.  Traces, the cross-section panels and the 3-D view read real planes,
  so they are exact too and are deliberately left unmarked.

  There is no "compute exactly" action, because an exact pass means reading
  every plane -- roughly the cost of the full load the user chose to skip.
  The tooltip names the real remedy instead of offering a false shortcut.

  Sampled bounds now widen rather than replace: any sample gives a range that
  is too narrow, never too wide, so the estimate can only improve.  Before
  this the overview (decimated harder in-plane than the startup probe)
  *worsened* the estimate the first time a global feature was used -- [0 3365]
  fell back to [0 2696] against a true [0 4034].

  Still unlabelled: the histogram panel drawn into exported movies
  (`MatVisFrameComposer`), which renders the same approximate counts.
- **Status strip** *(done)*.  A strip at the foot of the main window, present
  only in memory-efficient mode, carrying: a `Memory-efficient mode` label that
  becomes `Loading... 23/57 planes` while a run of plane reads is in flight,
  and a **Load full dataset** button.  Sources report progress through
  `MatVisLazySource.ProgressFcn`, called every fourth plane of any read of four
  or more -- so a projection over a stack shows progress instead of an
  unexplained pause, while an ordinary one-plane navigation step stays silent.
  MATLAB is single-threaded, so the `drawnow` in the callback is what actually
  gets the text on screen.

  **Load full dataset** re-reads each file with the ordinary loader (far faster
  than streaming plane by plane through the source), swaps in
  `MatVisMemorySource`, closes the readers, refreshes the value range through
  the new `MatVisModel.RefreshDataRanges`, and drops the `approx.` marks and
  the title suffix.  Measured on the 5.88 GB .czi: 42.4 s, after which the
  range corrects itself from the sampled [0 3365] to the true [0 4034] and
  navigation drops from 175 to 135 ms per step.  The button is disabled, with a
  reason, for a file that cannot be held in one array at all.

- **Load-time dialog and preference** *(done)*.  `ui/MatVisLoadModeDlg.m` shows
  the file, its shape, what it needs against what is free, the estimated read
  time, and two options worded as consequences -- "waits about 78 seconds now,
  and keeps 5.9 GB in memory" against "opens now; reads each plane as you
  navigate (about 102 ms a step)".  The recommendation is emboldened, not
  enforced; the other option stays available, and "Load everything" is disabled
  with a reason for a file that cannot be held in one array.

  A dropdown records a *rule* rather than an answer -- Ask every time / Use
  memory-efficient / Always load everything -- stored with `setpref` under the
  `matVis2` group, so it survives sessions and is not tangled up with the
  window-layout config the user saves deliberately.  The rule is consulted only
  for files that already tripped a threshold, so a small dataset is never held
  up by a dialog.  A non-interactive session (`usejava(desktop)` false)
  skips the dialog and follows the policy, and `LoadMode` overrides
  everything.

  Verified: each button returns its choice, the dropdown round-trips, the
  disabled state appears when a full load is impossible, and a stored
  preference of `full` / `lazy` produces `MatVisMemorySource` /
  `MatVisBioFormatsSource` without a prompt.

- **Mixed selections still fall back together.**  Selecting a readable file
  alongside one with no lazy reader (a .mat, a Zstandard TIFF, a plain .h5)
  drops the whole selection to the full loader.  That is deliberate rather
  than unfinished: one window cannot hold one exact dataset and one sampled
  one under a single "approx." label.  What was wrong was the error -- an
  unreadable file produced a Java stack trace, and now produces a sentence.
- **Level-aware display (M3) is stubbed, not solved.**  A file whose plane is
  too large to render whole is opened at the finest level that fits 64 MB --
  the 53865x29727 stitched image is shown as 5985x3303, with `DimScale`
  rescaled so coordinates and scale bars stay right, and a warning saying so.
  Showing it at full resolution needs the display to request a decimated slice
  sized to the axes.

### M2 — original scope

- `MatVisBioFormatsSource`: hold the reader open for the session, keep the
  level table, serve `readPlan` from a plane cache.
- `MatVisTiffSource`: per-page decode from the offsets `parseTiffIfds` already
  returns. The Zstd/PackBits path needs `loadZstdTiff` refactored to decode one
  page rather than the whole file — contained, since offsets are in hand.
- `MatVisPlaneCache`: LRU under one global byte budget (default ~1 GB),
  **divided across datasets, not per dataset** — the render loop in
  `computeDatasetDisplay` touches every dataset on every frame.
- Overview: for sources with file levels, load the level nearest a target of
  ~4e6 voxels (free — 40 ms on the stitched CZI). For sources without, build it
  in the background by reading every Nth plane and decimating, ~1/N of a full
  read. Build it **after** the first plane is on screen, and enable the
  features that depend on it as it completes.
- Entry gate, two-factor, both measured rather than assumed: predicted
  uncompressed bytes against actually-available RAM, **and** predicted load
  time = probed `PlaneReadCost` × plane count. Either over threshold offers the
  choice — *Full load / Memory-efficient / Cancel* — with the answer remembered
  in `io/matVisConfig.m` as always/never/ask. `memory` is Windows-only and
  needs a fallback path.

**Exit criterion:** the 5.88 GB CZI opens in under 2 s; scrubbing Z and T stays
under ~150 ms per step; RAM stays inside the budget.

### M3 — Level-aware display  *(done)*

The display asks for at most `MatVisRender.DISPLAY_PIXEL_BUDGET` (4e6) in-plane
samples; when the region holds more, `decimateToBudget_` thins both axes by one
common stride.  A source then serves that strided request however it can:
`MatVisMemorySource` strides the array, `MatVisLazySource.readSub` picks the
coarsest resolution level whose own sampling is still at least as fine as the
stride.  So the level is chosen by *what was asked for*, not by plumbing the
axes size through the render path -- zoom in, the region shrinks, the stride
falls to 1, and the finest level is read.

The budget is opt-in (`Inf` by default).  Only the main window passes it; the
export menu and the video writer keep getting every pixel.

Placing the picture: a decimated slice has fewer pixels than the region it
covers, so `MatVisRender.planExtent` reports which data coordinates were
sampled and the image/zoom windows set the image object's `XData`/`YData` from
it while the axes keep spanning the full dimension.  Axis ticks, ROI outlines,
profiles and the crosshair all work in data coordinates and therefore need no
knowledge of the level behind the picture.  With no decimation the placement is
identical to before, so ordinary datasets are unaffected.

Result on `ClaudiasSection2...czi`, which could not be opened at all before
this work:

| | before M3 (stopgap) | after M3 |
|---|---|---|
| reported size | 5985 x 3303 | **29727 x 53865** (true) |
| pixel size | 2.076 um (rescaled) | **0.2306 um** (the file's own) |
| levels exposed | 3 of 5 | **5 of 5** |
| zoomed 512² crop | upsampled from level 3 | **full resolution, 0.13 s** |
| whole-image view | -- | 1416 x 2565 from a coarse level |

The base-level stopgap and its warning are gone; `FullLoadFeasible` is now
decided by whether a plane fits in one Java array, which is what actually
makes a full load impossible.

Also fixed here: `renderFilteredSpatialProfile` read the entire XY plane to
filter it and then took one line out, which on this file was a 3 GB read that
simply failed.  It now reads only a band around the line, sized to the
filter's support (3 sigma for a Gaussian), which is mathematically the same
for a local filter -- 0.67 s where it previously threw.

**Known limit:** an ROI on a gigapixel plane still allocates a full-size
logical mask -- 1.49 GB per ROI on this file.  It works (0.97 s) but will not
scale to several ROIs.  `mask` is part of the ROI struct that matVis 1.x reads
and writes, so making it sparse or bounding-box-relative is a format decision
rather than a local fix.

### M3 — original scope

- Add `level` and per-dimension strides to `rawSlicePlan`. **The level must be
  part of `plan.key`**, or the slice cache will hand a low-resolution array to
  a full-resolution request.
- Choose the level from the axes: `MatVisRender.pixelsPerDataUnit`
  (`core/MatVisRender.m:907`) and `axesDataAreaPixels` (`:1150`) already compute
  what is needed. Pick the coarsest level whose sampling still exceeds one
  screen pixel per data pixel.
- Tiled reads for the large-XY case: restrict `xIdx`/`yIdx` to the visible zoom
  window and read that region at the chosen level. Measured at 0.216 s for
  2048² from a 3 GB plane.
- Axis ticks and ROI/profile coordinates stay in level-0 units. Everything
  user-facing — ROI masks, profile points, `CurrPos`, `DimScale` — stays at full
  resolution; only the pixels fetched for display change.

**Exit criterion:** `ClaudiasSection2...czi` opens and pans smoothly — a file
that cannot be opened at all today.

### M4 — Prefetch

- Predict the next index from the scrub/playback direction and read ahead.
  Without this, playback is capped at the plane-read rate (~15 fps on CZI).
- A Bio-Formats reader is a Java object: it cannot be sent to a `parfeval`
  worker, and each worker must open the file itself. Budget for reader
  construction per worker — 1.26 s measured on the CZI, 0.16 s on the stitched
  file.

### M5 — Optional re-chunk cache

Opt-in, background, for files that will be reopened often.

- Write a plane-chunked HDF5 copy with **deflate-1 + shuffle**: 0.37× of raw
  size, 26–31 ms per plane (2–3× faster than Bio-Formats, 32–39 fps). deflate-6
  is 2 % smaller and slower everywhere — not worth it.
- HDF5 fixes chunk layout at creation, so this is always a second file. Never
  touch the original. Put the cache in a configurable directory, and only offer
  it when free disk exceeds the projected cache size. At 0.37× of raw the cache
  is often smaller than the source file (2.2 GB against the 5.88 GB CZI).
- **Known regression:** compressed chunks cannot be partially read, so a
  single-pixel trace across z,t went from 0.01 s to 7.0 s, and a 128² ROI trace
  from 0.12 s to 7.1 s — 285 whole-plane inflates either way. Serve traces from
  the overview, with an explicit "compute at full resolution" action.
- Do **not** build overviews from strided HDF5 reads: measured 27.5 s, against
  0.35 s to read 57 planes and decimate them in MATLAB.

## 6. Feature behaviour in memory-efficient mode

| Feature | Before overview | After overview |
|---|---|---|
| Current plane | full resolution, on demand | unchanged |
| Zoom / pan | tiled read at display level | unchanged |
| Image/Zoom contrast | exact (slice is in hand) | unchanged |
| Global contrast + histogram | disabled, labelled | from overview, marked approximate |
| Global percentile | disabled | overview CDF |
| 3-D viewer | disabled | overview — often lossless at the 4e6 budget |
| Cross-section planes | current plane only | overview, "full res" on request |
| Projection along a dim | streamed, progress shown | overview, or streamed on request |
| Plot traces along z/t | disabled | overview, decimated |
| ROI / profile traces | on request, streamed once, cached | same |
| Video export | streams — unchanged | unchanged |

## 7. Decisions still to validate

- **Chunk shape for M5.** Plane-shaped chunks are hostile to traces once
  compressed. Tile-shaped chunks (e.g. 256x256x1x1) should cost about the same
  per plane while cutting trace cost by roughly the ratio of plane area to tile
  area — ~56× on this data. Arithmetic only; measure before committing.
- Whether `setFlattenedResolutions(false)` is preferable to reading levels as
  series. Functionally equivalent here; the unflattened API is more explicit but
  changes series indexing for genuinely multi-scene files.
- Cold-cache figures on a modest machine. Every number above is warm.

## 8. Risks

- **`isinteger` on the container.** Breaks integer contrast snapping silently.
  Covered by `ClassName` / `IsInteger` on the model, but easy to reintroduce.
- **RGB stretch reads the whole RGB dimension.** `stretchRangeIdx_`
  (`core/MatVisRender.m:1350`) returns `1:Size(rd)` unless the zoom lock is on —
  a whole-file read per frame if `rd` is the large dimension. Force the zoom
  lock in memory-efficient mode, or serve stretch from the overview.
- **K datasets multiply every read.** One navigation step is K plane reads, and
  alpha maps (`MatVisModel.SetAlphaMaps`) are full-size arrays that double it
  again.
- **Reader lifetime.** Readers stay open for the session: explicit teardown on
  window close, and a defined failure when the file moves or a share drops.
- **Concatenated multi-file datasets.** `importMultiFile.m:105` uses
  `cat(catDim, data{:})` — a 2× memory peak today, and in lazy mode a global
  index has to map back to (file, plane). Design in from the start.
- **Perceived responsiveness.** Everything instant today becomes possibly slow.
  Needs a busy indicator, progress on streamed operations, and cancellation.
- **Stale class copies.** Sibling checkouts shadow `core/` sources; run tests
  with a clean path.

## 9. Test plan

- `MatVisMemorySource` against a raw array: identical output for every plan
  shape (projection, RGB triad, stretch, tile, flips, zoom crop).
- Lazy against in-memory source on the same file: identical slices, traces and
  histograms for the small test files, where both fit.
- Level selection: a zoomed region at level L matches the same region read at
  level 0 and decimated, within interpolation tolerance.
- Regression: `matVis2(numericArray)` startup unchanged within noise.
- `ClaudiasSection2...czi` opens — currently a hard failure.

## 10. Telling the user, and letting them choose

A mode that quietly changes what several features mean is only acceptable if
the change is visible. Three separate pieces, and the last is the one most
likely to be skipped and the one that matters most.

**Where the preference lives.** Not `io/matVisConfig.m`: that stores window
layout and model state, and only when the user presses *Save Config*
(`ui/MatVisMainWindow.m:683`). Tying "don't ask me again" to an explicit save
action is the wrong lifecycle. Use MATLAB's `setpref`/`getpref` under a
`matVis2` group -- per user, persists automatically, survives across checkouts,
nothing to manage.

**Split the policy from the dialog,** so the decision is testable without a
figure:

- `io/matVisProbeFile.m` -- geometry, dtype, predicted bytes, predicted load
  time, available RAM. Reads no pixels. Costs 0.16-1.3 s (reader init).
- `io/matVisLoadPolicy.m` -- probe + prefs + system state -> `{recommendation,
  shouldAsk, reasons}`. Pure function.
- `ui/MatVisLoadModeDlg.m` -- renders the policy result, returns a choice.

**What the screen says.** Facts first, consequences in the user's terms, never
mechanism:

```
02_AfterBicuculin_every20s-Processed.czi
1924 x 1920 x 57 (Z) x 15 (T), uint16

Full size in memory   5.9 GB        Available   12.4 GB
Estimated load time   ~40 s

( ) Load everything      Everything works. ~40 s wait.
(o) Memory-efficient     Opens now; reads each plane as you navigate
                         (~60 ms per step). Global histogram, 3-D view and
                         time traces use a reduced-resolution overview.
( ) Cancel

For files like this:  ( ) Ask every time  (o) Use memory-efficient
                      ( ) Always load everything
```

Pre-select the recommendation, show both, and show the numbers behind it so the
choice is inspectable.

**Remember a rule, not an answer.** A bare "don't ask again" checkbox is
ambiguous -- remembered for what? A size threshold is the only form that
generalizes to the next file.

**Keep the mode visible after the dialog is gone.**

- Title-bar suffix on the main window: `-- memory-efficient`.
- A clickable badge that reopens the info screen with current state and a
  **Load everything now** button (streams, with progress and cancel).
- Disabled controls explain themselves on hover rather than just greying out.
- Approximate values labelled where they are displayed: the histogram annotated
  "overview", the 3-D window title, plot traces. A histogram computed from a
  decimated overview must never look like the exact one.

**Escape hatches both ways.** Upgrade to a full load mid-session; and if a full
load is running slower than predicted, offer to abort into memory-efficient
mode rather than forcing a restart.

**The non-interactive path.** matVis2 gets called from scripts, where a modal
dialog would hang a batch job. Add `matVis2(file, 'LoadMode',
'full'|'lazy'|'auto')` to bypass the dialog, and skip it automatically when
`usejava('desktop')` is false -- the pattern `io/ensureBioFormats.m:40` already
uses. Non-interactive default is the policy recommendation, silently.

**Ask once per load, not once per file.** `importMultiFile` can open several
files at once; probe them all and present the aggregate in one dialog.

Two thresholds, separately worded, because they catch different failures:
predicted size against available RAM (the 16 GB laptop, where a full load fails
outright) and predicted load time (the workstation, where it merely costs 40 s).

## 11. Drawing cost (outside the original plan)

Profiling the render path to explain the waits turned up something the plan had
assumed away, and corrected an earlier reading of my own.

**Per-render cost is proportional to slice pixels, not a fixed GUI overhead.**
Measured on in-memory stacks, with the image axes 391x391 px on screen
throughout:

| slice | before | after |
|---|---|---|
| 256 x 256 (0.07 MP) | 7.1 ms | **5.8 ms** |
| 512 x 512 (0.26 MP) | 17.6 ms | **12.0 ms** |
| 1024 x 1024 (1.05 MP) | 42.9 ms | **27.4 ms** |
| 1448 x 1448 (2.10 MP) | 71.0 ms | **42.8 ms** |
| 1920 x 1920 (3.69 MP) | 111.7 ms | **52.1 ms** |

Three changes:

1. **`applyColormap` gathers from a uint8 lookup table.**  It used to index a
   double colormap, producing a 24 MB RGB array for a megapixel slice, write it
   again scaled by 255, and only then cast down to 3 MB of uint8.  It was 52 %
   of the whole render.  A pre-scaled uint8 table makes the gather produce the
   final bytes directly: 13.1 ms -> 4.8 ms per megapixel, output byte-identical
   (checked against the old implementation on random data).  The separate
   non-finite pass went too -- min/max already discard NaN the way `normalize_`
   does, so a NaN lands on the top of the map exactly as before.

2. **A slice is drawn at the resolution the window can show.**  A 1920x1920
   slice in a 391x391 axes is ~24x more samples than there are screen pixels,
   and every one of them was colour-mapped and uploaded.  It is now thinned to
   `DISPLAY_SAMPLES_PER_PIXEL` (2) samples per screen pixel -- above the
   Nyquist rate of the screen grid, so nearest-neighbour thinning cannot alias
   anything the window could have resolved.  Thinning happens *after* the
   contrast bounds, the histogram and any spatial filter, so all of those still
   see every pixel and none of their numbers change.  `shrinkExtent` trims the
   drawn extent to the samples actually kept, so ROI outlines stay on their
   pixels.

3. **The axes pixel size is cached.**  `getpixelposition` costs ~1.7 ms, twice
   per render; it is now re-measured at most twice a second, since it only
   changes on a resize.

On the 5.88 GB .czi this took a GUI navigation step from 177 ms to 120 ms.

**What this means for M4.**  Prefetch is a poor investment and should stay
unbuilt: a plane read is 10-55 ms against a render that is still tens of
milliseconds, so hiding the read entirely would not dominate what is left.

### Startup

Profiled separately.  A warm open of a 64x64x6 array costs ~4 s, of which the
first `drawnow` -- where MATLAB realizes the component tree -- is ~2.5 s.  The
profiler attributes that to MATLAB's own UI framework
(`ComponentControllerFactory.createController`, 171 calls), not to anything
here.  The windows hold **181 graphics objects, 134 of them in the main
window**: 26 nested GridLayouts, 26 StateButtons, 21 Labels, 8 DropDowns,
8 NumericEditFields.

One fix landed: `matVisConfig.GetConfigPath_` called `system(hostname)`,
spawning a shell at ~150 ms, twice per startup.  It now reads `COMPUTERNAME`
on Windows and caches the answer for the session.  Windows paths are
case-insensitive, so a config written under either spelling is still found.

One fix was tried and **reverted**: caching the panel-title and window-chrome
heights in `getpref` to skip the measurement `drawnow` appeared to cut warm
startup from ~4.1 s to ~1.3 s and a cold session from 15.0 s to 7.8 s.  It
also changed the layout -- the position panel came out 22 px shorter --
because the values measured at that point are not the ones the window settles
at.  The apparent saving is also suspect: in `matlab -batch` nothing forces a
final flush, so skipping the drawnow may only defer work an interactive
session still has to do.  Not worth a layout regression for a saving that may
not exist; the comment at that drawnow now records this so it is not retried
blind.

**Measured interactively** (by the user, since `-batch` renders headless and
cannot see this): the original matVis opens in 2.81 s warm, matVis2 in 4.54 s.
The original is built entirely on classic `figure` + `uicontrol` (264 calls,
no `uifigure` anywhere); matVis2 is `uifigure` throughout.  The interactive
stage breakdown puts **`drawnow #1` at 3.649 s of 4.729 s -- 77 %**, with all
component *creation* summing to 0.965 s.  So the cost is realizing the tree,
and the lever is building fewer things.

**Done: the plot window builds its axes on demand.**  `MatVisPlotWin` created
one `uiaxes` per dimension up front -- plus a line, an xline and a patch each
-- and then hid every one of them, because `PlotDims` starts all-false.  A
`uiaxes` is among the most expensive components in the stack.  They are now
built by `ensureAxes` the first time a dimension is actually plotted, and
`pw.axes` (a cell captured before they existed) became `pw.AxesFor(ii)`.
Startup goes from 4 UIAxes to 0 in the plot window, and the four windows from
181 graphics objects to 159.  Toggling a dimension on builds and draws it;
toggling it off keeps it, hidden, as before.

**The RangeSliders are not the bottleneck.**  Measured marginal cost of adding
sliders to a warm figure: 1 -> 2 costs 0.111 s, 2 -> 4 costs 0.068 s each,
4 -> 6 costs 0.128 s each.  So three sliders are ~0.2-0.4 s of a 4.45 s
startup.  (`findall` does not descend into a ComponentContainer, so the
earlier "134 objects" undercounted: each slider hides its own subtree.)  The
cost is close to uniform per component -- which is why removing the plot axes
bought ~0.36 s and no single control will buy much more.

**Also done: the RGB stretch bar builds on demand.**  `MatVisRGBStretchBar`
carries a uiaxes, an image and two lines, and was constructed and then
immediately `SetVisible(false)` -- RGB stretch is off by default.  Its row was
already reserved, so deferring it costs no relayout.  Main-window UIAxes at
startup: 2 -> 1.

**Not done, and not recommended for the remaining gap.**  Converting the three
display windows to classic figures was considered and dropped: their creation
is only 0.222 s of the 4.729 s, and a measurement of `uifigure` against
classic `figure` came back too noisy to act on (0.9x, 5.6x, 1.4x across three
repetitions).  They also carry all the mouse handling -- ROI drawing, profile
picking, zoom rectangles, panning -- which a headless harness cannot verify.
What remains is the main window itself: 134 objects including 26 nested
GridLayouts, on a `uifigure` that cannot be converted without a rewrite.

All figures above are from `matlab -batch`, which renders headless.  They may
not reflect an interactive desktop session, and the interactive numbers should
be checked before any redesign is justified on their basis.

## 12. A note on the test baseline

`MatVisVideoTest/testFillZoom_growsTheCropAndRestoresTheModel` fails at HEAD,
before any of this work: verified by running the composer at HEAD and with
these changes and getting byte-identical frames (`std` 97.172 / 88.661, content
in columns 241-330 either way).  The test asserts that filling the zoom puts
data in the frame's leftmost columns; the image is drawn centred and never
reaches them.  It passed in several intermediate runs, so it is sensitive to
what else ran in the same MATLAB process.  The honest baseline is **239 tests,
24 failures**; earlier notes in this document quoting 23 were reading a run
where it happened to pass.

## 13. Exchanging the data in a running viewer

matVis 1.x exposed `handles.fctHandles.loadNewData` (matVis.m:13288) and the
2.0 rewrite dropped it.  Restored, with the original's three modes:

| call | effect |
|---|---|
| `mw.LoadNewData(d)` | replace the dataset(s) |
| `mw.LoadNewData(d, 'replaceFrame', idx)` | overwrite plane(s) `idx` |
| `mw.LoadNewData(d, 'append')` | append along dimension 3 |

`mw.fctHandles.loadNewData` is an alias, so scripts written against 1.x keep
working.  Trailing arguments are passed to `applyStartPar`, as they were.

The contract is the original's: the number of datasets and the number of
dimensions are fixed (they decide how many windows and sliders exist), but the
lengths are free -- which is the case it exists for, the next recording of the
same kind with a different frame count.

`MatVisModel.ReplaceDatasets` does the model half: swaps the data, updates
`Size` and the value ranges, re-cuts each `DimScale` to the new length while
keeping its origin and spacing, clamps `CurrPos`, re-opens the zoom on any
dimension whose length changed (as 1.x did -- keeping the old interval would
show the first six frames of eleven with nothing saying so), drops ROIs and
profiles when the display plane changed shape, and drops an alpha map that no
longer matches.  The window half re-points slider limits, scale factors and
labels, the histogram range fields, and clears every dataset-keyed cache.

**The size-drift bug this depended on is fixed.**  `Size` is private and
computed in the constructor, but `Datasets` was a plain public property whose
setter never checked shape.  Assigning a larger array left its tail
unreachable in silence; assigning a smaller one produced
`MATLAB:badsubscript` from inside the renderer.  The setter now rejects a
shape change with `MatVisModel:sizeChangeNotAllowed` and points at
`ReplaceDatasets`, which is the supported way to change it.

Measured: replacing same-shaped data takes **0.06 s**, against **4.7 s** to
open a second window.  Verified across same shape, 6 -> 11 frames (slider max
follows, scale preserved, plane 11 reachable), 11 -> 4 frames (CurrPos
clamped, render survives), `replaceFrame`, `append`, the legacy alias, and all
three rejections.

`replaceFrame` and `append` build a new array from the old one, so they need
the dataset in memory; on a file-backed dataset they say so and point at
"Load full dataset" rather than quietly reading gigabytes to patch one plane.

Still open, and deliberately not built: reusing a window for a *different*
dataset shape or count, and pre-warming hidden windows at MATLAB startup.
Measurements for both are in section 11 -- a hidden window realizes its
components while hidden (1.5 s) and then shows in 0.1 s, so pre-warming would
work; it needs this same machinery plus a parking lot.

## 14. Opening data from inside a running viewer

**File > Open data...** (a menu bar, because the bottom button grid has no
free slot and adding a row changes the window height -- the arithmetic that
has already caused two bugs here).

`ui/MatVisOpenDataDlg.m` is one window with two panels: base-workspace
variables on the left (name, size, class, multi-select), a folder path with a
file list on the right.  Selecting on one side clears the other -- one load
comes from one place.  The bottom line states the verdict and offers
**Replace in this window** / **Open in a new window** / **Cancel**.

Workspace variables are judged immediately, because `whos` already knows their
size; the verdict names the reason when they do not fit ("this viewer holds 1
dataset(s)", "this viewer shows 3 dimensions") and only the new-window button
stays enabled.  Files cannot be judged without opening them, which costs a
reader open, so both buttons are offered and the caller falls back to a new
window if the dimensions turn out not to match.

Files go through `io/matVisOpenDatasets.m` -- `matVis2`'s own opening path,
extracted from it so both use the same policy, the same load-mode dialog and
the same lazy handling rather than two copies that drift.

Verified by driving the dialog: Replace swaps in place (one viewer, data
changed), Open-in-new leaves the original untouched and adds a second viewer,
Cancel changes nothing.

### A file was corrupted and rebuilt during this work

A shell quoting mistake fed a substitution script mis-split arguments, and it
ran three global replacements over `ui/MatVisMainWindow.m` (`replace`->`the`,
`in`->`this` 1531 times, `not`->`open`).  The corruption was not reversible --
the original text legitimately contained all three targets -- so the file was
restored from HEAD and the session's ~20 edits re-applied from the record.
Verified afterwards against every test written earlier in the session: suite
239/24 (baseline), GUI smoke, `loadNewData`, the lazy stretch bar, the status
strip and its full-load swap, M3 geometry on the stitched .czi, the render
scaling table (5.6 / 11.6 / 27.7 / 44.1 / 51.5 ms), and both large files end
to end -- all matching their pre-corruption values.
