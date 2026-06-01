function mw = MatVisMainWindow(model)
% MatVisMainWindow  Main control panel uifigure for matVis 2.0.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'));
addpath(fullfile(rootDir, 'ui'));
addpath(fullfile(rootDir, 'io'));

if nargin < 1 || isempty(model)
    error('MatVisMainWindow:invalidInput', 'A MatVisModel instance must be provided.');
end

nDims = numel(model.Size);

%% Figure
fig = uifigure('Name', 'matVis 2.0', 'Resize', 'on', 'Visible', 'off');

rowH_slider   = 50;
rowH_dimSel   = 60;
rowH_contrast = 160;
rowH_bottom   = 40;
figWidth      = 360;
figHeight     = nDims * rowH_slider + rowH_dimSel + rowH_contrast + rowH_bottom + 50;
fig.Position(3:4) = [figWidth, figHeight];

nRows = nDims + 3;
grid  = uigridlayout(fig, [nRows, 1]);
grid.RowHeight   = [repmat({rowH_slider}, 1, nDims), ...
                    {rowH_dimSel}, {rowH_contrast}, {rowH_bottom}];
grid.ColumnWidth = {'1x'};
grid.Padding     = [6 6 6 6];
grid.RowSpacing  = 6;

%% RangeSliders — created before display windows so onZoomFromMouse can use them
rangeSliders = cell(1, nDims);
playTimers   = cell(1, nDims);

for d = 1:nDims
    nSteps   = model.Size(d);
    dimLabel = getDimLabel(model, d);

    rs = RangeSlider(grid);
    rs.Layout.Row    = d;
    rs.Layout.Column = 1;
    rs.Limits   = [1, nSteps];
    rs.DimLabel = dimLabel;
    rs.Value    = model.CurrPos(d);
    rs.ZoomMin  = model.ZoomRange(d, 1);
    rs.ZoomMax  = model.ZoomRange(d, 2);

    % Anonymous functions capture d by value at each iteration (MATLAB closure semantics).
    addlistener(rs, 'ValueChanged', @(src, ~) onSliderPos(d, src.Value));
    addlistener(rs, 'ZoomChanged',  @(src, ~) onSliderZoom(d, src.ZoomMin, src.ZoomMax));
    addlistener(rs, 'PlotToggled',  @(src, ~) onPlotToggled(d, src.ShowPlot));
    addlistener(rs, 'PlayToggled',  @(src, ~) onPlayToggled(d, src.IsPlaying));

    rangeSliders{d} = rs;
end

%% Display windows
imageWin = MatVisImageWin(model, @onZoomFromMouse);
zoomWin  = MatVisZoomWin(model,  @onZoomFromMouse);
plotWin  = MatVisPlotWin(model);

renderFcn = @() doRender();

%% DimSelector
dimSelPanel = uipanel(grid, 'BorderType', 'none', 'BackgroundColor', fig.Color);
dimSelPanel.Layout.Row    = nDims + 1;
dimSelPanel.Layout.Column = 1;
dimSelector = MatVisDimSelector(dimSelPanel, model, renderFcn); %#ok<NASGU>

%% ContrastWin
contrastPanel = uipanel(grid, 'BorderType', 'line', 'Title', 'Contrast');
contrastPanel.Layout.Row    = nDims + 2;
contrastPanel.Layout.Column = 1;
contrastWin = MatVisContrastWin(contrastPanel, model, renderFcn);

%% Bottom toggle buttons
bottomGrid = uigridlayout(grid, [1, 3]);
bottomGrid.Layout.Row    = nDims + 3;
bottomGrid.Layout.Column = 1;
bottomGrid.ColumnWidth   = {'1x', '1x', '1x'};
bottomGrid.RowHeight     = {'1x'};
bottomGrid.Padding       = [0 0 0 0];

btnToggleImage = uibutton(bottomGrid, 'state', 'Text', 'Image', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(imageWin, src.Value));
btnToggleImage.Layout.Column = 1;

btnToggleZoom = uibutton(bottomGrid, 'state', 'Text', 'Zoom', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(zoomWin, src.Value));
btnToggleZoom.Layout.Column = 2;

btnTogglePlot = uibutton(bottomGrid, 'state', 'Text', 'Plot', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleWindow(plotWin, src.Value));
btnTogglePlot.Layout.Column = 3;

%% Output struct
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

fig.Visible = 'on';
doRender();

%% -------------------------------------------------------------------------
    function doRender()
        % Full (un-cropped) slice → ImageWin with zoom-rect overlay
        slice2D_full = MatVisRender.renderFullSlice(model);
        gammaFull    = MatVisRender.applyGamma(slice2D_full, model.Gamma);
        rgbFull      = MatVisRender.applyColormap(gammaFull, model.ColormapIdx);

        xr       = model.ZoomRange(model.XDim, :);
        yr       = model.ZoomRange(model.YDim, :);
        zoomRect = [xr(1), yr(1), diff(xr), diff(yr)];
        imageWin.Update(rgbFull, zoomRect);

        % Cropped (zoom-range) slice → ZoomWin
        slice2D_zoom = MatVisRender.renderSlice(model);
        gammaZoom    = MatVisRender.applyGamma(slice2D_zoom, model.Gamma);
        rgbZoom      = MatVisRender.applyColormap(gammaZoom, model.ColormapIdx);
        zoomWin.Update(rgbZoom);

        % 1-D profiles for checked dimensions
        profiles = cell(1, nDims);
        for ii = 1:nDims
            if model.PlotDims(ii)
                profiles{ii} = MatVisRender.renderProfile(model, ii);
            end
        end
        plotWin.Update(profiles);

        % Contrast histogram uses full slice (un-cropped, un-gamma'd)
        contrastWin.Update(slice2D_full);
    end

    function onSliderPos(dimIdx, val)
        model.CurrPos(dimIdx) = round(val);
        doRender();
    end

    function onSliderZoom(dimIdx, lo, hi)
        model.ZoomRange(dimIdx, :) = [lo, hi];
        doRender();
    end

    function onPlotToggled(dimIdx, show)
        model.PlotDims(dimIdx) = show;
        doRender();
    end

    function onPlayToggled(dimIdx, isPlaying)
        if isPlaying
            t = timer('Period', 0.06, 'ExecutionMode', 'fixedRate', ...
                      'TimerFcn', @(~,~) stepPlay(dimIdx));
            playTimers{dimIdx} = t;
            start(t);
        else
            t = playTimers{dimIdx};
            if ~isempty(t) && isvalid(t)
                stop(t);
                delete(t);
            end
            playTimers{dimIdx} = [];
        end
    end

    function stepPlay(dimIdx)
        lo  = model.ZoomRange(dimIdx, 1);
        hi  = model.ZoomRange(dimIdx, 2);
        cur = model.CurrPos(dimIdx);
        nxt = cur + 1;
        if nxt > hi, nxt = lo; end
        model.CurrPos(dimIdx)         = nxt;
        rangeSliders{dimIdx}.Value    = nxt;
        doRender();
    end

    function onZoomFromMouse(xDim, xRange, yDim, yRange)
        model.ZoomRange(xDim, :)      = xRange;
        model.ZoomRange(yDim, :)      = yRange;
        rangeSliders{xDim}.ZoomMin    = xRange(1);
        rangeSliders{xDim}.ZoomMax    = xRange(2);
        rangeSliders{yDim}.ZoomMin    = yRange(1);
        rangeSliders{yDim}.ZoomMax    = yRange(2);
        doRender();
    end

    function toggleWindow(win, isVisible)
        if isVisible
            win.fig.Visible = 'on';
        else
            win.fig.Visible = 'off';
        end
    end

end % MatVisMainWindow

function label = getDimLabel(model, dimIdx)
    if ~isempty(model.DimNames) && numel(model.DimNames) >= dimIdx
        label = model.DimNames{dimIdx};
    else
        label = sprintf('Dim%d', dimIdx);
    end
end
