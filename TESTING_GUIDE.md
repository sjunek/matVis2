# matVis 2.0 UI Refactoring — Testing Guide

## Quick Start

### Launch matVis
```matlab
cd('D:\Matlab\GitRepositories\matVis2_Claude')
matVis(rand(64, 64, 20))
```

## Feature Testing Checklist

### 1. **Compact Layout**
- [ ] Position controls are narrower (30px text field instead of 45px)
- [ ] Sliders are longer (~200px track, filling more space)
- [ ] Overall main window is wider but more compact height-wise
- [ ] Row spacing tighter between dimension sliders

### 2. **Stacked Play Buttons**
- [ ] Two buttons visible per dimension (stacked vertically)
- [ ] Top button (⏵): labeled "Play full range" (tooltip)
- [ ] Bottom button (⏵⊡): labeled "Play zoom range only" (tooltip)
- [ ] Only one can be active at a time
- [ ] Clicking top button: animation cycles through full dimension (1 to max)
- [ ] Clicking bottom button: animation cycles through zoom range only
- [ ] Clicking active button again: stops playback

### 3. **Histogram Display**
- [ ] Histogram visible in Contrast section
- [ ] Displays 256 bins (or fewer for small images)
- [ ] Updates when changing position, zoom, or dimensions
- [ ] Shows distribution of current 2D slice

### 4. **Contrast Mode Selection**
- [ ] Four state buttons visible: "Global", "Image", "Zoom", "Manual"
- [ ] Currently selected mode appears highlighted/pressed
- [ ] Radio button-like behavior: only one selected at a time
- [ ] Buttons are visual radio buttons (not traditional radio controls)

#### Mode Testing:
- **Global mode:**
  - [ ] Select "Global" button
  - [ ] Range slider disabled (grayed out)
  - [ ] Min/max fields show overall data min/max
  - [ ] Values don't change when moving position or zoom
  
- **Image mode:**
  - [ ] Select "Image" button
  - [ ] Range slider disabled (grayed out)
  - [ ] Min/max fields show current 2D slice min/max
  - [ ] Values update when changing position or XY dimensions
  - [ ] Values update when changing zoom
  
- **Zoom mode:**
  - [ ] Select "Zoom" button
  - [ ] Range slider disabled (grayed out)
  - [ ] Min/max fields show current zoom crop min/max
  - [ ] Values update only when changing zoom range (not position)
  
- **Manual mode:**
  - [ ] Select "Manual" button
  - [ ] Range slider becomes ENABLED
  - [ ] Min/max edit fields become editable
  - [ ] Drag slider or edit fields to adjust contrast
  - [ ] Image updates immediately with new contrast

### 5. **Range Slider Alignment**
- [ ] Contrast range slider aligned with histogram width
- [ ] Slider spans the same horizontal distance as histogram

### 6. **Right-Click Zoom Reset**
- [ ] In Image window: right-click → zoom resets to full range
- [ ] In Zoom window: right-click → zoom resets to full range
- [ ] Both X and Y dimensions reset simultaneously
- [ ] Visual feedback: image expands to show full extent

### 7. **Window Arrangement on Startup**
- [ ] Main window positioned on left
- [ ] Image window positioned center-right of main window
- [ ] Zoom window positioned to the right of image window
- [ ] Plot window positioned below image window
- [ ] Windows don't overlap significantly
- [ ] Layout matches `matVis_figures.png` template

### 8. **Configuration Save/Load**
- [ ] "Save Config" button visible in bottom toolbar
- [ ] "Load Config" button visible in bottom toolbar
- [ ] Click "Save Config":
  - [ ] No error message
  - [ ] Console message shows file saved
  - [ ] File created: `matVisConfig_[ComputerName].mat` in matVis root directory
  
- [ ] Move windows around, change colormap, gamma, contrast mode
- [ ] Close and reopen matVis
- [ ] Click "Load Config":
  - [ ] Windows move back to saved positions
  - [ ] Colormap restored
  - [ ] Gamma slider/edit show saved value
  - [ ] Contrast mode button restored
  - [ ] Manual contrast min/max restored (if in Manual mode)

### 9. **Existing Functionality Preserved**
- [ ] Colormap selection dropdown works
- [ ] Gamma slider and edit field linked (change one, other updates)
- [ ] Position sliders navigate through dimensions
- [ ] Zoom sliders adjust zoom range
- [ ] Plot checkboxes show/hide 1D profile lines
- [ ] Image/Zoom/Plot/Overlay toggles work
- [ ] Drag-to-zoom in image windows works
- [ ] Scroll-wheel zoom in image windows works
- [ ] Cross-hair position lines visible when overlay enabled

## Automated Tests

```matlab
% Run component tests
test_ui_refactoring
```

Expected output:
```
Testing matVis 2.0 UI refactoring...
Test 1: Creating MatVisModel... OK
Test 2: Testing contrast mode property... OK
Test 3: Testing GetContrastBounds... OK
Test 4: Testing RangeSlider... OK
Test 5: Testing matVisConfig utilities... OK

All tests passed!
```

## Configuration File Content

After saving config, inspect the .mat file:
```matlab
load('matVisConfig_YourComputerName.mat')

% Should contain variables:
% windowVisibility (struct)
%   .Image = true/false
%   .Zoom = true/false
%   .Plot = true/false
%   .Overlay = true/false
% windowPositions (struct)
%   .Main = [left, bottom, width, height]
%   .Image = [left, bottom, width, height]
%   .Zoom = [left, bottom, width, height]
%   .Plot = [left, bottom, width, height]
% colormapIdx = scalar
% contrastMode = 'Global' | 'Image' | 'Zoom' | 'Manual'
% gamma = scalar
% contrastMin = scalar (if Manual mode)
% contrastMax = scalar (if Manual mode)
```

## Troubleshooting

### Issue: "Play buttons not visible"
- Check that RangeSlider grid layout updated correctly
- Verify Play buttons in stacked grid at column 4

### Issue: "Histogram not showing"
- Ensure histogram axes created in contrast panel
- Check that `doRender()` calls `updateHistogram()`
- Verify `slice2D_full` is a valid 2D array

### Issue: "Contrast mode buttons not working"
- Verify radio button (state button) callbacks defined
- Check that `onRBGlobalChanged`, etc. functions exist
- Ensure `model.ContrastMode` setter fires event

### Issue: "Window positioning not working"
- Verify `onWindowShown()` called after `doRender()`
- Check `matVisConfig('GetConfigPath')` returns valid path
- Ensure window figures passed to SaveConfig are valid

### Issue: "Right-click zoom not working"
- Verify `SelectionType == 'alt'` check in `onMouseDown`
- Ensure both ImageWin and ZoomWin have right-click handler
- Check that `zoomFromMouseFcn` is called with full range [1, max]

## Performance Observations

- **Image mode:** Slightly slower (computes min/max per image)
- **Zoom mode:** Slightly slower (computes min/max per zoom crop)
- **Global mode:** Fastest (pre-computed)
- **Manual mode:** Fastest (no computation)

Typical per-frame overhead: < 1ms additional

## Notes for Developers

1. **PlayMode enumeration:**
   - RangeSlider now uses 'full' and 'zoom' instead of just IsPlaying
   - Old code listening to `PlayToggled` still works
   - New code should listen to `PlayModeChanged`

2. **Contrast bounds computation:**
   - Model automatically caches LastImageData and LastZoomData
   - GetContrastBounds() uses cached data if available
   - Fallback to Global if data not cached

3. **Config file location:**
   - Computer name extracted via `system('hostname')`
   - Handles cases where hostname is unavailable (uses 'Unknown')
   - Config saved in same directory as matVis.m

4. **Radio button implementation:**
   - Using state buttons instead of traditional radio buttons
   - State buttons support ValueChangedFcn callback
   - Mutual exclusivity handled manually in callbacks

## Next Steps (Future Phases)

- [ ] Implement flip toggle functionality
- [ ] Add aspect ratio toggle
- [ ] Orthogonal views (XY/XZ/YZ)
- [ ] Multi-dataset support
- [ ] ROI manager
- [ ] Profile manager
- [ ] Video recorder
