function mw = MatVisMainWindow(model)
%MatVisMainWindow  Main control panel uifigure for matVis 2.0.
%
%   mw = MatVisMainWindow(model)
%
%   Creates the main uifigure that wires all matVis components together.
%
%   Returns struct mw with fields:
%     mw.fig            - uifigure (main control panel)
%     mw.rangeSliders   - 1xN cell array of RangeSlider structs
%     mw.dimSelector    - MatVisDimSelector struct
%     mw.contrastWin    - MatVisContrastWin struct
%     mw.imageWin       - MatVisImageWin struct
%     mw.zoomWin        - MatVisZoomWin struct
%     mw.plotWin        - MatVisPlotWin struct
%     mw.btnToggleImage - uibutton for show/hide ImageWin
%     mw.btnToggleZoom  - uibutton for show/hide ZoomWin
%     mw.btnTogglePlot  - uibutton for show/hide PlotWin
%     mw.Render         - function handle: mw.Render() triggers full re-render

%   Add component directories to path so all helper constructors are found.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'));
addpath(fullfile(rootDir, 'ui'));
addpath(fullfile(rootDir, 'io'));

%% Validate input
if nargin < 1 || isempty(model)
    error('MatVisMainWindow:invalidInput', ...
          'A MatVisModel instance must be provided.');
end

nDims = numel(model.Size);

%% Create main uifigure
fig = uifigure('Name', 'matVis 2.0', ...
               'Resize', 'on', ...
               'Visible', 'off');

% Fixed width, height scales with number of dimensions:
%   Each RangeSlider row: 50 px
%   DimSelector panel:    60 px
%   ContrastWin panel:   160 px
%   Bottom toggle row:    50 px
%   Padding/gap:          10 px per section boundary
rowHeightSlider    = 50;
rowHeightDimSel    = 60;
rowHeightContrast  = 160;
rowHeightBottom    = 50;
nGaps              = 4;
gapHeight          = 10;

figWidth  = 340;
figHeight = nDims * rowHeightSlider ...
          + rowHeightDimSel ...
          + rowHeightContrast ...
          + rowHeightBottom ...
          + nGaps * gapHeight;

fig.Position(3:4) = [figWidth, figHeight];

%% Build outer grid layout (rows top to bottom)
%  Rows:
%   1..nDims  : RangeSlider rows
%   nDims+1   : DimSelector
%   nDims+2   : ContrastWin
%   nDims+3   : toggle buttons

nRows = nDims + 3;
rowHeights = [repmat({rowHeightSlider}, 1, nDims), ...
              {rowHeightDimSel}, ...
              {rowHeightContrast}, ...
              {rowHeightBottom}];

grid = uigridlayout(fig, [nRows, 1]);
grid.RowHeight   = rowHeights;
grid.ColumnWidth = {'1x'};
grid.Padding     = [8, 8, 8, 8];
grid.RowSpacing  = gapHeight;

%% Create display windows (standalone figures)
imageWin = MatVisImageWin(model);
zoomWin  = MatVisZoomWin(model);
plotWin  = MatVisPlotWin(model);

%% Create render function handle (forward declaration, defined below)
% Use a container so the nested function can be referenced before
% rangeSliders and contrastWin are constructed.
renderFcn = @() doRender();

%% Create RangeSliders (one per dimension)
rangeSliders = cell(1, nDims);
for d = 1:nDims
    nSteps   = model.Size(d);
    dimLabel = getDimLabel(model, d);

    % Callbacks that update model then trigger render
    onPosCb  = @(val) onSliderPos(d, val);
    onZoomCb = @(lo, hi) onSliderZoom(d, lo, hi);

    sliderPanel = uipanel(grid, ...
                          'BorderType', 'none', ...
                          'BackgroundColor', fig.Color);
    sliderPanel.Layout.Row    = d;
    sliderPanel.Layout.Column = 1;

    rangeSliders{d} = RangeSlider(sliderPanel, d, nSteps, dimLabel, ...
                                  onPosCb, onZoomCb);
end

%% Create DimSelector
dimSelPanel = uipanel(grid, 'BorderType', 'none', 'BackgroundColor', fig.Color);
dimSelPanel.Layout.Row    = nDims + 1;
dimSelPanel.Layout.Column = 1;
dimSelector = MatVisDimSelector(dimSelPanel, model, renderFcn);

%% Create ContrastWin panel
contrastPanel = uipanel(grid, 'BorderType', 'line', 'Title', 'Contrast');
contrastPanel.Layout.Row    = nDims + 2;
contrastPanel.Layout.Column = 1;
contrastWin = MatVisContrastWin(contrastPanel, model, renderFcn);

%% Bottom row: window visibility toggle buttons
bottomGrid = uigridlayout(grid, [1, 3]);
bottomGrid.Layout.Row    = nDims + 3;
bottomGrid.Layout.Column = 1;
bottomGrid.ColumnWidth   = {'1x', '1x', '1x'};
bottomGrid.RowHeight     = {'1x'};
bottomGrid.Padding       = [0, 0, 0, 0];

btnToggleImage = uibutton(bottomGrid, 'state', ...
    'Text',    'Image', ...
    'Value',   true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(imageWin, src.Value));
btnToggleImage.Layout.Row    = 1;
btnToggleImage.Layout.Column = 1;

btnToggleZoom = uibutton(bottomGrid, 'state', ...
    'Text',    'Zoom', ...
    'Value',   true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(zoomWin, src.Value));
btnToggleZoom.Layout.Row    = 1;
btnToggleZoom.Layout.Column = 2;

btnTogglePlot = uibutton(bottomGrid, 'state', ...
    'Text',    'Plot', ...
    'Value',   true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(plotWin, src.Value));
btnTogglePlot.Layout.Row    = 1;
btnTogglePlot.Layout.Column = 3;

%% Assemble output struct
mw.fig            = fig;
mw.rangeSliders   = rangeSliders;
mw.dimSelector    = dimSelector;
mw.contrastWin    = contrastWin;
mw.imageWin       = imageWin;
mw.zoomWin        = zoomWin;
mw.plotWin        = plotWin;
mw.btnToggleImage = btnToggleImage;
mw.btnToggleZoom  = btnToggleZoom;
mw.btnTogglePlot  = btnTogglePlot;
mw.Render         = renderFcn;

%% Initial render and show
fig.Visible = 'on';
doRender();

%% -------------------------------------------------------------------------
%  Nested helper: full render pipeline
%  -------------------------------------------------------------------------
    function doRender()
        % Render full (un-cropped) slice for ImageWin
        slice2D_full = MatVisRender.renderSlice(model);

        % Render zoom-cropped slice for ZoomWin
        slice2D_zoom = MatVisRender.renderSlice(model);  %#ok<NASGU>
        % NOTE: The distinction between full and cropped is handled inside
        % MatVisRender.renderSlice based on model.ZoomRange.  Here we pass
        % the same model; the two windows receive different images because
        % Update() implementations crop internally or because renderSlice
        % accepts an optional flag.  Per the spec, ZoomWin receives the
        % cropped version, so we obtain it by applying the zoom range.
        slice2D_zoom = cropToZoom(slice2D_full, model);

        % Apply gamma and colormap to full slice
        gammaSliceFull = MatVisRender.applyGamma(slice2D_full, model.Gamma);
        rgbImgFull     = MatVisRender.applyColormap(gammaSliceFull, model.ColormapIdx);

        % Apply gamma and colormap to zoom slice
        gammaSliceZoom = MatVisRender.applyGamma(slice2D_zoom, model.Gamma);
        rgbImgZoom     = MatVisRender.applyColormap(gammaSliceZoom, model.ColormapIdx);

        % Compute zoom rect in pixel coordinates of the full image
        xRange  = model.ZoomRange(model.XDim, :);
        yRange  = model.ZoomRange(model.YDim, :);
        zoomRect = [xRange(1), yRange(1), diff(xRange), diff(yRange)];

        % Update display windows
        imageWin.Update(rgbImgFull, zoomRect);
        zoomWin.Update(rgbImgZoom);

        % Compute 1D profiles for active plot dimensions
        nPlotDims = numel(model.PlotDims);
        profiles  = cell(1, nPlotDims);
        for idx = 1:nPlotDims
            if model.PlotDims(idx)
                profiles{idx} = MatVisRender.renderProfile(model, idx);
            end
        end
        plotWin.Update(profiles);

        % Update contrast histogram with the full slice
        contrastWin.Update(slice2D_full);
    end

%% -------------------------------------------------------------------------
%  Nested helper: crop 2D slice to zoom range
%  -------------------------------------------------------------------------
    function sliceCropped = cropToZoom(sliceFull, mdl)
        % sliceFull is H x W (rows = YDim, cols = XDim).
        % ZoomRange is nDims x 2 matrix with [lo, hi] indices.
        xr = mdl.ZoomRange(mdl.XDim, :);
        yr = mdl.ZoomRange(mdl.YDim, :);

        [H, W] = size(sliceFull);

        % Clamp to valid pixel indices (ZoomRange is 1-based)
        c1 = max(1, round(xr(1)));
        c2 = min(W, round(xr(2)));
        r1 = max(1, round(yr(1)));
        r2 = min(H, round(yr(2)));

        if c1 <= c2 && r1 <= r2
            sliceCropped = sliceFull(r1:r2, c1:c2);
        else
            sliceCropped = sliceFull;
        end
    end

%% -------------------------------------------------------------------------
%  Nested helper: slider position callback
%  -------------------------------------------------------------------------
    function onSliderPos(dimIdx, val)
        model.CurrPos(dimIdx) = val;
        doRender();
    end

%% -------------------------------------------------------------------------
%  Nested helper: slider zoom callback
%  -------------------------------------------------------------------------
    function onSliderZoom(dimIdx, lo, hi)
        model.ZoomRange(dimIdx, :) = [lo, hi];
        doRender();
    end

%% -------------------------------------------------------------------------
%  Nested helper: toggle window visibility
%  -------------------------------------------------------------------------
    function toggleWindow(win, isVisible)
        if isVisible
            win.fig.Visible = 'on';
        else
            win.fig.Visible = 'off';
        end
    end

end % MatVisMainWindow

%% =========================================================================
%  Local utility: build dimension label string
%  =========================================================================
function label = getDimLabel(model, dimIdx)
    if ~isempty(model.DimNames) && numel(model.DimNames) >= dimIdx
        label = model.DimNames{dimIdx};
    else
        label = sprintf('Dim%d', dimIdx);
    end
end
