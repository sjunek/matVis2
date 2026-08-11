function mw = MatVisMainWindow(model)
% MatVisMainWindow  Main control panel uifigure for matVis 2.0.
%   Supports single and multiple datasets.  Navigation controls (position,
%   zoom, X/Y dims, projection) are synchronised across all datasets.
%   Contrast is either linearly-scaled across datasets (lock closed) or
%   applied independently per dataset (lock open).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
% addpath rehashes the toolbox cache — only do it when needed. Checking mere
% *existence* (isempty(which(...))) isn't enough: this machine has multiple
% sibling matVis/matVis2 checkouts on the path, so a stale copy of
% matVisConfig from a DIFFERENT checkout can already resolve and silently
% pass the isempty check while pointing at the wrong repo (and, via
% GetConfigPath, the wrong saved-config file). Compare by identity instead.
if isempty(which('MatVisRender')) || ...
        ~strcmpi(which('matVisConfig'), fullfile(rootDir, 'io', 'matVisConfig.m'))
    addpath(fullfile(rootDir, 'core'));
    addpath(fullfile(rootDir, 'ui'));
    addpath(fullfile(rootDir, 'io'));
end

if nargin < 1 || isempty(model)
    error('MatVisMainWindow:invalidInput', 'A MatVisModel instance must be provided.');
end

nDims     = numel(model.Size);
nDatasets = model.NumDatasets;
withAlpha = model.WithAlpha;

mvTiming_ = struct('labels', {{}}, 'times', []);
mvT0_     = tic;

%% Figure setup
% Window title shows the dataset name(s). The live playback framerate is shown
% in a label next to the play-speed control (see updateFrameRateDisplay).
if isempty(model.DatasetNames)
    baseTitle = 'matVis 2.0';
else
    baseTitle = ['matVis 2.0: ' strjoin(model.DatasetNames, ', ')];
end
fig = uifigure('Name', baseTitle, 'Resize', 'off', 'Visible', 'off', 'HandleVisibility', 'on');
mvTiming_.labels{end+1} = 'uifigure created'; mvTiming_.times(end+1) = toc(mvT0_);

% Layout parameters
rowH_slider     = 54;
rowH_dimSel     = 32;
% contrastGrid: 9 rows {24,8,24,6,22,104,25,6,25} = 244 content + 8 spacings = 252
% (+31 when an alpha channel adds rows 10/11: 6px spacer + 25px controls)
rowH_contrast   = 252 + 31 * withAlpha;
rowH_bottom     = 40;
rowH_plotBtns   = 32;   % height of the plot-tools button row inside posPanel
rowH_playSpeed  = 26;   % height of the play-speed control row inside posPanel
rowH_spacing    = 10;
panelTitleH     = 36;
panelPadV       = 5;
figWidth        = 436;

posPanelH      = nDims * rowH_slider + max(0, nDims-1) * rowH_spacing + rowH_playSpeed + rowH_spacing + rowH_plotBtns + rowH_spacing + 2*panelPadV + panelTitleH;
imagePanelH    = 3*rowH_dimSel + 4 + 2*4 + panelTitleH;   % three rows (dims/proj + RGB/aspect + filter)
contrastPanelH = rowH_contrast + 2*panelPadV + panelTitleH;
bottomH        = rowH_bottom;

figHeight = posPanelH + imagePanelH + contrastPanelH + bottomH + 3*rowH_spacing + 200;
fig.Position(3:4) = [figWidth, figHeight];

nRows = 4;
grid  = uigridlayout(fig, [nRows, 1]);
grid.RowHeight   = {posPanelH, imagePanelH, contrastPanelH, bottomH};
grid.ColumnWidth = {'1x'};
grid.Padding     = [6 6 6 6];
grid.RowSpacing  = rowH_spacing;

%% Position and plot controls panel
posPanel = uipanel(grid, 'Title', 'Position and plot controls', ...
    'BorderType', 'line', ...
    'FontSize', 13, 'FontWeight', 'bold', 'TitlePosition', 'centertop');
posPanel.Layout.Row    = 1;
posPanel.Layout.Column = 1;

posGrid = uigridlayout(posPanel, [nDims + 2, 1]);
posGrid.RowHeight   = [repmat({rowH_slider}, 1, nDims), {rowH_playSpeed}, {rowH_plotBtns}];
posGrid.ColumnWidth = {'1x'};
posGrid.Padding     = [5 5 5 5];
posGrid.RowSpacing  = rowH_spacing;

mvTiming_.labels{end+1} = 'main grid + posPanel created'; mvTiming_.times(end+1) = toc(mvT0_);
%% RangeSliders
rangeSliders = cell(1, nDims);
playTimers   = cell(1, nDims);
playModes    = cell(1, nDims);
isPlayingAny = false;        % true while any play timer runs (gates hist updates)
% --- Playback speed / framerate state (see playSpeedParams, updateFrameRateDisplay) ---
basePeriod  = 0.06;          % timer period at speed 0 (preserves prior default ~16 fps)
playInc     = 1;             % frames advanced per tick (frame skipping when >1)
playTimeBuf = nan(1, 10);    % circular buffer of tick timestamps for fps estimate
playCt      = 0;             % tick counter into playTimeBuf
playTic     = uint64(0);     % tic reference for the active playback run
lastBoundsAds = [];          % [cmin cmax] of active dataset from last render
histObjs = [];               % persistent histogram graphics objects (see ensureHistObjects)

for d = 1:nDims
    nSteps   = model.Size(d);
    dimLabel = getDimLabel(model, d);

    rs = RangeSlider(posGrid);
    rs.Layout.Row    = d;
    rs.Layout.Column = 1;
    rs.Limits   = [1, nSteps];
    rs.DimLabel = dimLabel;
    rs.ScaleFactor = model.pixelSize(d);
    rs.ScaleUnit   = model.dimUnit(d);
    rs.Value    = model.CurrPos(d);
    rs.ZoomMin  = model.ZoomRange(d, 1);
    rs.ZoomMax  = model.ZoomRange(d, 2);

    addlistener(rs, 'ValueChanged',    @(src, ~) onSliderPos(d, src.Value));
    addlistener(rs, 'ZoomChanged',     @(src, ~) onSliderZoom(d, src.ZoomMin, src.ZoomMax));
    addlistener(rs, 'PlotToggled',     @(src, ~) onPlotToggled(d, src.ShowPlot));
    addlistener(rs, 'PlayModeChanged', @(src, ~) onPlayModeChanged(d, src.PlayMode, src.IsPlaying));
    addlistener(rs, 'PlotLockToggled', @(src, ~) onPlotLockToggled(d, src.PlotLock));

    rangeSliders{d} = rs;
    playModes{d} = 'none';
end

mvTiming_.labels{end+1} = sprintf('RangeSliders x%d created', nDims); mvTiming_.times(end+1) = toc(mvT0_);
%% ---- Plot-tools button row (row nDims+1 of posGrid) --------------------
%  State lives here in MainWindow; plotWins are driven via Set* methods.
plotAvgMode   = 0;      % 0=1x1, 1=3x3, 2=5x5, 3=zoom
plotFixX      = false;
plotFixXLimits = [1, max(model.Size)];
plotFixY      = false;
plotFixYLimits = [0, 1];   % overwritten on first fix-Y activation

% --- Play-speed control row (above the Y-scale / Export plot buttons) -------
%  Controls sit on the left; the live playback framerate is shown to their right.
playSpeedRow = uigridlayout(posGrid, [1, 3]);
playSpeedRow.Layout.Row    = nDims + 1;
playSpeedRow.Layout.Column = 1;
playSpeedRow.ColumnWidth   = {75, 60, '1x'};
playSpeedRow.RowHeight     = {'1x'};
playSpeedRow.Padding       = [2 1 2 1];
playSpeedRow.ColumnSpacing = 6;

lblPlaySpeed = uilabel(playSpeedRow, 'Text', 'Play speed:', ...
    'HorizontalAlignment', 'left', 'FontSize', 11);
lblPlaySpeed.Layout.Column = 1;

playSpeedTooltip = sprintf(['Speed of playback (live framerate shown to the right).\n' ...
    '1 = native speed (no pause, no skipping).\n' ...
    'Values > 1: faster playback by skipping frames (advance round(value) frames).\n' ...
    'Values between 0 and 1: slower playback by introducing pauses.']);
edtPlaySpeed = uieditfield(playSpeedRow, 'numeric', ...
    'Value', 1, 'Limits', [0.1, 50], 'RoundFractionalValues', false, ...
    'ValueDisplayFormat', '%g', 'FontSize', 11, ...
    'Tooltip', playSpeedTooltip, ...
    'ValueChangedFcn', @(~, ~) onPlaySpeedChanged());
edtPlaySpeed.Layout.Column = 2;

lblFrameRate = uilabel(playSpeedRow, 'Text', '', ...
    'HorizontalAlignment', 'left', 'FontSize', 11, ...
    'Tag', 'matVisFrameRate', ...
    'Tooltip', 'Measured playback framerate');
lblFrameRate.Layout.Column = 3;

plotBtnRow = uigridlayout(posGrid, [1, 5]);
plotBtnRow.Layout.Row    = nDims + 2;
plotBtnRow.Layout.Column = 1;
plotBtnRow.ColumnWidth   = {'1x', '1x', '1x', '1x', '1x'};
plotBtnRow.RowHeight     = {'1x'};
plotBtnRow.Padding       = [2 2 2 2];
plotBtnRow.ColumnSpacing = 4;

% 1) Averaging neighborhood — icon cycles through modes on click
btnPlotAvg = uibutton(plotBtnRow, 'push', ...
    'Icon', makePlotAvgIcon(0), 'Text', '', ...
    'Tooltip', 'Plot averaging: 1x1 pixel', ...
    'ButtonPushedFcn', @onPlotAvgToggle);
btnPlotAvg.Layout.Column = 1;

% 2) Show/hide markers — icon is a line with a dot in the middle
btnPlotMarker = uibutton(plotBtnRow, 'state', ...
    'Text', '', 'Icon', makeMarkerIcon(), ...
    'Tooltip', 'Show/hide point markers on plots', ...
    'ValueChangedFcn', @onPlotMarkerToggle);
btnPlotMarker.Layout.Column = 2;

% 3) Fix X-scale  (right-click → enter limits)
btnPlotFixX = uibutton(plotBtnRow, 'state', ...
    'Text', 'x lim', 'FontSize', 10, ...
    'Tooltip', 'Fix plot X-axis scale (right-click to set limits)', ...
    'ValueChangedFcn', @onPlotFixXToggle);
btnPlotFixX.Layout.Column = 3;
cmPlotX = uicontextmenu(fig);
uimenu(cmPlotX, 'Text', 'Set X limits...', 'MenuSelectedFcn', @onPlotSetXLimits);
btnPlotFixX.ContextMenu = cmPlotX;

% 4) Fix Y-scale  (right-click → enter limits)
btnPlotFixY = uibutton(plotBtnRow, 'state', ...
    'Text', 'y lim', 'FontSize', 10, ...
    'Tooltip', 'Fix plot Y-axis scale (right-click to set limits)', ...
    'ValueChangedFcn', @onPlotFixYToggle);
btnPlotFixY.Layout.Column = 4;
cmPlotY = uicontextmenu(fig);
uimenu(cmPlotY, 'Text', 'Set Y limits...', 'MenuSelectedFcn', @onPlotSetYLimits);
btnPlotFixY.ContextMenu = cmPlotY;

% 5) Export data subset
btnPlotExport = uibutton(plotBtnRow, 'push', ...
    'Text', 'Export', 'FontSize', 10, ...
    'Tooltip', 'Export data subset to workspace', ...
    'ButtonPushedFcn', @onPlotExportData);
btnPlotExport.Layout.Column = 5;

mvTiming_.labels{end+1} = 'plot-tools buttons created'; mvTiming_.times(end+1) = toc(mvT0_);
%% Display windows - one set per dataset
imageWins = cell(1, nDatasets);
zoomWins  = cell(1, nDatasets);
plotWins  = cell(1, nDatasets);

for ds = 1:nDatasets
    imageWins{ds} = MatVisImageWin(model, @onZoomFromMouse, @onPositionFromMouse, ds);
    zoomWins{ds}  = MatVisZoomWin(model,  @onZoomFromMouse, @onPositionFromMouse, ds);
    plotWins{ds}  = MatVisPlotWin(model, @onPlotPosChange, @onPlotZoomChange, ds);

    if nDatasets > 1
        dsName = model.DatasetNames{ds};
        imageWins{ds}.fig.Name = sprintf('Image - %s', dsName);
        zoomWins{ds}.fig.Name  = sprintf('Zoom - %s',  dsName);
        plotWins{ds}.fig.Name  = sprintf('Plot - %s',  dsName);
    end
end

mvTiming_.labels{end+1} = sprintf('display windows x%d created (ImageWin+ZoomWin+PlotWin)', nDatasets); mvTiming_.times(end+1) = toc(mvT0_);
renderFcn = @() doRender();

%% Image controls panel
imageCtrlPanel = uipanel(grid, 'Title', 'Image controls', ...
    'BorderType', 'line', ...
    'FontSize', 13, 'FontWeight', 'bold', 'TitlePosition', 'centertop');
imageCtrlPanel.Layout.Row    = 2;
imageCtrlPanel.Layout.Column = 1;

% The panel stacks the dimension/RGB/projection/filter controls on top and the
% RGB-stretch blue/red-point bar below them. The bar's row is reserved
% permanently (it fits in the existing panel height), so toggling a stretch
% mode only shows/hides the bar — it never resizes or repositions anything.
stretchBarH = 22;     % height (px) of the reserved stretch-bar row
imgWrap = uigridlayout(imageCtrlPanel, [2 1]);
imgWrap.ColumnWidth = {'1x'};
imgWrap.RowHeight   = {'1x', stretchBarH};
imgWrap.Padding     = [0 0 0 0];
imgWrap.RowSpacing  = 2;

dimSelHost = uipanel(imgWrap, 'BorderType', 'none', 'BackgroundColor', fig.Color);
dimSelHost.Layout.Row = 1;
dimSelector = MatVisDimSelector(dimSelHost, model, renderFcn);

% Dock the bar in row 2, indented to line up with the RGB dropdown (the
% DimSelector label column is 30 px) and ending at the lock's right edge.
barWrap = uigridlayout(imgWrap, [1 2]);
barWrap.Layout.Row    = 2;
barWrap.ColumnWidth   = {23, '1x'};
barWrap.RowHeight     = {'1x'};
barWrap.Padding       = [2 1 2 0];
barWrap.ColumnSpacing = 4;
stretchBar = MatVisRGBStretchBar(barWrap, @onRGBStretchRangeChanged);
stretchBar.root.Layout.Row    = 1;
stretchBar.root.Layout.Column = 2;
stretchBar.SetValue(model.RGBStretchRange);
stretchBar.SetVisible(false);

% Aspect ratio + window scaling: DimSelector builds the buttons; the
% behaviour lives here because it acts on the image/zoom windows.
dimSelector.btnAspect.ValueChangedFcn   = @(~,~) onAspectToggle();
cmAspect = uicontextmenu(fig);
uimenu(cmAspect, 'Text', 'Set aspect ratio...', 'MenuSelectedFcn', @(~,~) onAspectSetRatio());
dimSelector.btnAspect.ContextMenu = cmAspect;

dimSelector.btnWinScale.ButtonPushedFcn = @(~,~) applyWindowScale();
cmWinScale = uicontextmenu(fig);
uimenu(cmWinScale, 'Text', 'Set window scale...', 'MenuSelectedFcn', @(~,~) onWinScaleSet());
dimSelector.btnWinScale.ContextMenu = cmWinScale;
mvTiming_.labels{end+1} = 'DimSelector created'; mvTiming_.times(end+1) = toc(mvT0_);

%% Contrast Panel
contrastPanel = uipanel(grid, 'Title', 'Contrast', ...
    'BorderType', 'line', ...
    'FontSize', 13, 'FontWeight', 'bold', 'TitlePosition', 'centertop');
contrastPanel.Layout.Row    = 3;
contrastPanel.Layout.Column = 1;

% 9 rows x 8 columns
% Row 1: mode buttons
% Row 2: 8px spacer
% Row 3: dataset dropdown + lock
% Row 4: 6px spacer
% Row 5: hist min / percentile / hist max
% Row 6: histogram axes
% Row 7: contrast min / gamma / max
% Row 8: 6px spacer
% Row 9: colormap
% Rows 10/11 (alpha channel only): spacer + alpha min / BG / gamma / max
contrastRowH = {24, 8, 24, 6, 22, 104, 25, 6, 25};
if withAlpha
    contrastRowH = [contrastRowH, {6, 25}];
end
contrastGrid = uigridlayout(contrastPanel, [numel(contrastRowH), 8]);
contrastGrid.RowHeight   = contrastRowH;
contrastGrid.ColumnWidth = {50, '1x', '1x', '1x', '1x', '1x', '1x', 50};
contrastGrid.Padding     = [5 5 5 5];
contrastGrid.RowSpacing  = 1;
contrastGrid.ColumnSpacing = 2;

% Row 1: Contrast mode buttons
rbPanel = uipanel(contrastGrid, 'BorderType', 'none', 'BackgroundColor', fig.Color);
rbPanel.Layout.Row    = 1;
rbPanel.Layout.Column = [1, 8];

rbSubGrid = uigridlayout(rbPanel, [1, 4]);
rbSubGrid.ColumnWidth   = {'1x', '1x', '1x', '1x'};
rbSubGrid.RowHeight     = {'1x'};
rbSubGrid.Padding       = [0 0 0 0];
rbSubGrid.ColumnSpacing = 2;

rbGlobal = uibutton(rbSubGrid, 'state', 'Text', 'Global', 'FontSize', 11, ...
    'ValueChangedFcn', @(src, ~) onContrastModeButtonChanged('Global', src));
rbGlobal.Layout.Column = 1;
rbGlobal.Value = strcmp(model.ContrastMode, 'Global');

rbImage = uibutton(rbSubGrid, 'state', 'Text', 'Image', 'FontSize', 11, ...
    'ValueChangedFcn', @(src, ~) onContrastModeButtonChanged('Image', src));
rbImage.Layout.Column = 2;
rbImage.Value = strcmp(model.ContrastMode, 'Image');

rbZoom = uibutton(rbSubGrid, 'state', 'Text', 'Zoom', 'FontSize', 11, ...
    'ValueChangedFcn', @(src, ~) onContrastModeButtonChanged('Zoom', src));
rbZoom.Layout.Column = 3;
rbZoom.Value = strcmp(model.ContrastMode, 'Zoom');

rbManual = uibutton(rbSubGrid, 'state', 'Text', 'Manual', 'FontSize', 11, ...
    'ValueChangedFcn', @(src, ~) onContrastModeButtonChanged('Manual', src));
rbManual.Layout.Column = 4;
rbManual.Value = strcmp(model.ContrastMode, 'Manual');

% Row 3: Dataset selector + contrast lock  (row 2 = 8px spacer)
dsPanel = uipanel(contrastGrid, 'BorderType', 'none', 'BackgroundColor', fig.Color);
dsPanel.Layout.Row    = 3;
dsPanel.Layout.Column = [1, 8];

dsSubGrid = uigridlayout(dsPanel, [1, 2]);
dsSubGrid.ColumnWidth   = {'1x', 32};
dsSubGrid.RowHeight     = {'1x'};
dsSubGrid.Padding       = [0 0 0 0];
dsSubGrid.ColumnSpacing = 4;

dropDataset = uidropdown(dsSubGrid, ...
    'Items',  model.DatasetNames, ...
    'Value',  model.DatasetNames{model.ActiveDataset}, ...
    'FontSize', 10, ...
    'Enable', nDatasets > 1, ...
    'ValueChangedFcn', @(src, ~) onDatasetDropdownChanged(src));
dropDataset.Layout.Column = 1;

btnLock = uibutton(dsSubGrid, 'state', ...
    'Text',    char(128274), ...
    'FontSize', 14, ...
    'Value',   model.ContrastLocked, ...
    'Tooltip', 'Linked (locked): contrast scaled linearly across datasets. Click to toggle independent.', ...
    'Enable',  nDatasets > 1, ...
    'ValueChangedFcn', @(src, ~) onLockButtonChanged(src));
btnLock.Layout.Column = 2;

% Row 5: Histogram range fields (row 4 = 6px spacer)
lblHistMin = uilabel(contrastGrid, 'Text', 'Hist Min:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblHistMin.Layout.Row    = 5;
lblHistMin.Layout.Column = 1;

edtHistMin = uieditfield(contrastGrid, 'numeric', ...
    'Value', model.DataMin, ...
    'Limits', [model.DataMin, model.DataMax], ...
    'RoundFractionalValues', false, 'FontSize', 10, ...
    'ValueChangedFcn', @(src, ~) onHistMinChanged(src));
edtHistMin.Layout.Row    = 5;
edtHistMin.Layout.Column = 2;

lblHistMax = uilabel(contrastGrid, 'Text', 'Hist Max:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblHistMax.Layout.Row    = 5;
lblHistMax.Layout.Column = 7;

edtHistMax = uieditfield(contrastGrid, 'numeric', ...
    'Value', model.DataMax, ...
    'Limits', [model.DataMin, model.DataMax], ...
    'RoundFractionalValues', false, 'FontSize', 10, ...
    'ValueChangedFcn', @(src, ~) onHistMaxChanged(src));
edtHistMax.Layout.Row    = 5;
edtHistMax.Layout.Column = 8;

% Percentile controls
lblPerc = uilabel(contrastGrid, 'Text', 'Perc:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblPerc.Layout.Row    = 5;
lblPerc.Layout.Column = 3;

edtPercLow = uieditfield(contrastGrid, 'numeric', ...
    'Value', 0, 'Limits', [0, 1], ...
    'RoundFractionalValues', false, 'ValueDisplayFormat', '%.4f', 'FontSize', 10, ...
    'Tooltip', 'Lower percentile cutoff (0-1). Ignored in Manual mode.', ...
    'ValueChangedFcn', @(~,~) doRender());
edtPercLow.Layout.Row    = 5;
edtPercLow.Layout.Column = 4;
edtPercLow.Enable = ~strcmp(model.ContrastMode, 'Manual');

edtPercHigh = uieditfield(contrastGrid, 'numeric', ...
    'Value', 1, 'Limits', [0, 1], ...
    'RoundFractionalValues', false, 'ValueDisplayFormat', '%.4f', 'FontSize', 10, ...
    'Tooltip', 'Upper percentile cutoff (0-1). Ignored in Manual mode.', ...
    'ValueChangedFcn', @(~,~) doRender());
edtPercHigh.Layout.Row    = 5;
edtPercHigh.Layout.Column = 5;
edtPercHigh.Enable = ~strcmp(model.ContrastMode, 'Manual');

% Histogram-during-playback toggle (off = faster playback, as in original matVis)
btnPlayHist = uibutton(contrastGrid, 'state', ...
    'Text', 'H', 'FontSize', 10, 'Value', false, ...
    'Tooltip', sprintf(['Toggle update of histogram during playback.\n' ...
    'As updating the histogram takes considerable time,\n' ...
    'keeping this off speeds up the playback.']));
btnPlayHist.Layout.Row    = 5;
btnPlayHist.Layout.Column = 6;

% Row 6: Interactive histogram
histAx = uiaxes(contrastGrid);
histAx.Layout.Row    = 6;
histAx.Layout.Column = [1, 8];
histAx.XTick = [];
histAx.YTick = [];
histAx.Box   = 'off';
histAx.Color = [0.95 0.95 0.95];
disableDefaultInteractivity(histAx);
% Remove the axes toolbar entirely — since R2026a it carries a collapse/
% expand chevron that Visible='off' does not hide and that steals height.
try; histAx.Toolbar = []; catch; end
setappdata(fig, 'HistYScale', 'linear');

% Row 7: Contrast min / gamma / max
lblContrastMin = uilabel(contrastGrid, 'Text', 'Min:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblContrastMin.Layout.Row    = 7;
lblContrastMin.Layout.Column = 1;

edtContrastMin = uieditfield(contrastGrid, 'numeric', ...
    'Value', model.ContrastMin, ...
    'Limits', [model.DataMin, model.DataMax], ...
    'RoundFractionalValues', false, 'FontSize', 10, ...
    'ValueChangedFcn', @(src, ~) onContrastMinChanged(src));
edtContrastMin.Layout.Row    = 7;
edtContrastMin.Layout.Column = 2;
edtContrastMin.Enable = strcmp(model.ContrastMode, 'Manual');

lblGamma = uilabel(contrastGrid, 'Text', 'y:', 'HorizontalAlignment', 'right', ...
    'FontSize', 11, 'FontWeight', 'bold');
lblGamma.Layout.Row    = 7;
lblGamma.Layout.Column = 4;

edtGamma = uieditfield(contrastGrid, 'numeric', ...
    'Value', model.Gamma, 'Limits', [0.1, 5.0], ...
    'RoundFractionalValues', false, 'ValueDisplayFormat', '%.2f', 'FontSize', 10, ...
    'ValueChangedFcn', @(src, ~) onGammaEditChanged(src));
edtGamma.Layout.Row    = 7;
edtGamma.Layout.Column = 5;

lblContrastMax = uilabel(contrastGrid, 'Text', 'Max:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblContrastMax.Layout.Row    = 7;
lblContrastMax.Layout.Column = 7;

edtContrastMax = uieditfield(contrastGrid, 'numeric', ...
    'Value', model.ContrastMax, ...
    'Limits', [model.DataMin, model.DataMax], ...
    'RoundFractionalValues', false, 'FontSize', 10, ...
    'ValueChangedFcn', @(src, ~) onContrastMaxChanged(src));
edtContrastMax.Layout.Row    = 7;
edtContrastMax.Layout.Column = 8;
edtContrastMax.Enable = strcmp(model.ContrastMode, 'Manual');

% Row 9: Colormap (row 8 = 6px spacer)
lblColormap = uilabel(contrastGrid, 'Text', 'Colormap:', 'HorizontalAlignment', 'right', 'FontSize', 10);
lblColormap.Layout.Row    = 9;
lblColormap.Layout.Column = 1;

cmapItems = getColormapItems();
dropColormap = uidropdown(contrastGrid, ...
    'Items', cmapItems, ...
    'Value', cmapItems{min(model.ColormapIdx, numel(cmapItems))}, ...
    'ValueChangedFcn', @(src, ~) onColormapChanged(src), ...
    'FontSize', 10);
dropColormap.Layout.Row    = 9;
dropColormap.Layout.Column = [2, 8];

% Row 11 (alpha channel only, row 10 = 6px spacer):
% alpha min / background toggle / alpha gamma / alpha max
edtAlphaMin   = [];
edtAlphaMax   = [];
edtAlphaGamma = [];
btnAlphaBg    = [];
btn2DHist     = [];
% 2D data-vs-alpha histogram window state (created on demand)
hist2DFig    = [];
hist2DAx     = [];
hist2DImg    = [];
hist2DGuides = struct('dmin', [], 'dmax', [], 'amin', [], 'amax', []);
if withAlpha
    adsInit = model.ActiveDataset;

    lblAlphaMin = uilabel(contrastGrid, 'Text', [char(945) ' Min:'], ...
        'HorizontalAlignment', 'right', 'FontSize', 10, ...
        'Tooltip', 'Minimum of alpha contrast');
    lblAlphaMin.Layout.Row    = 11;
    lblAlphaMin.Layout.Column = 1;

    edtAlphaMin = uieditfield(contrastGrid, 'numeric', ...
        'Value', model.AlphaContrastMins(adsInit), ...
        'RoundFractionalValues', false, 'FontSize', 10, ...
        'Tooltip', 'Set minimum of alpha contrast (pixels at/below are fully transparent)', ...
        'ValueChangedFcn', @(src, ~) onAlphaMinChanged(src));
    edtAlphaMin.Layout.Row    = 11;
    edtAlphaMin.Layout.Column = 2;

    btnAlphaBg = uibutton(contrastGrid, 'state', ...
        'Text', 'BG', 'FontSize', 10, ...
        'Value', model.AlphaBgWhite, ...
        'Tooltip', 'Toggle alpha background color (black/white) in the image windows', ...
        'ValueChangedFcn', @(src, ~) onAlphaBgChanged(src));
    btnAlphaBg.Layout.Row    = 11;
    btnAlphaBg.Layout.Column = 3;

    lblAlphaGamma = uilabel(contrastGrid, 'Text', [char(945) ' y:'], ...
        'HorizontalAlignment', 'right', 'FontSize', 11, 'FontWeight', 'bold', ...
        'Tooltip', 'Gamma value for alpha map');
    lblAlphaGamma.Layout.Row    = 11;
    lblAlphaGamma.Layout.Column = 4;

    edtAlphaGamma = uieditfield(contrastGrid, 'numeric', ...
        'Value', model.AlphaGamma, 'Limits', [0.1, 5.0], ...
        'RoundFractionalValues', false, 'ValueDisplayFormat', '%.2f', 'FontSize', 10, ...
        'Tooltip', 'Gamma applied to the alpha map', ...
        'ValueChangedFcn', @(src, ~) onAlphaGammaChanged(src));
    edtAlphaGamma.Layout.Row    = 11;
    edtAlphaGamma.Layout.Column = 5;

    btn2DHist = uibutton(contrastGrid, 'state', ...
        'Text', '2D', 'FontSize', 10, ...
        'Value', false, ...
        'Tooltip', 'Show/hide the 2D data-vs-alpha histogram (contrast guidance)', ...
        'ValueChangedFcn', @(src, ~) onHist2DToggle(src));
    btn2DHist.Layout.Row    = 11;
    btn2DHist.Layout.Column = 6;

    lblAlphaMax = uilabel(contrastGrid, 'Text', [char(945) ' Max:'], ...
        'HorizontalAlignment', 'right', 'FontSize', 10, ...
        'Tooltip', 'Maximum of alpha contrast');
    lblAlphaMax.Layout.Row    = 11;
    lblAlphaMax.Layout.Column = 7;

    edtAlphaMax = uieditfield(contrastGrid, 'numeric', ...
        'Value', model.AlphaContrastMaxs(adsInit), ...
        'RoundFractionalValues', false, 'FontSize', 10, ...
        'Tooltip', 'Set maximum of alpha contrast (pixels at/above are fully opaque)', ...
        'ValueChangedFcn', @(src, ~) onAlphaMaxChanged(src));
    edtAlphaMax.Layout.Row    = 11;
    edtAlphaMax.Layout.Column = 8;
end

addlistener(model, 'ContrastModeChanged',  @(~,~) onModelContrastModeChanged());
addlistener(model, 'ActiveDatasetChanged', @(~,~) onModelActiveDatasetChanged());

mvTiming_.labels{end+1} = 'contrast panel created'; mvTiming_.times(end+1) = toc(mvT0_);
%% Bottom controls
bottomGrid = uigridlayout(grid, [1, 9]);
bottomGrid.Layout.Row    = 4;
bottomGrid.Layout.Column = 1;
bottomGrid.ColumnWidth   = {'1x', '1x', '1x', '1x', '1x', '1x', '1x', '1x', '1x'};
bottomGrid.RowHeight     = {'1x'};
bottomGrid.Padding       = [0 0 0 0];

btnToggleImage = uibutton(bottomGrid, 'state', 'Text', 'Image', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleAllWindows(imageWins, src.Value));
btnToggleImage.Layout.Column = 1;

btnToggleZoom = uibutton(bottomGrid, 'state', 'Text', 'Zoom', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleAllWindows(zoomWins, src.Value));
btnToggleZoom.Layout.Column = 2;

btnTogglePlot = uibutton(bottomGrid, 'state', 'Text', 'Plot', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) toggleAllWindows(plotWins, src.Value));
btnTogglePlot.Layout.Column = 3;

btnToggleRoi = uibutton(bottomGrid, 'state', 'Text', 'ROI', 'Value', false, ...
    'Tooltip', 'Show/hide the ROI Manager', ...
    'ValueChangedFcn', @(src, ~) toggleRoiWindow(src.Value));
btnToggleRoi.Layout.Column = 4;

btnToggleProfile = uibutton(bottomGrid, 'state', 'Text', 'Prof', 'Value', false, ...
    'Tooltip', 'Show/hide the Profile Manager', ...
    'ValueChangedFcn', @(src, ~) toggleProfileWindow(src.Value));
btnToggleProfile.Layout.Column = 5;

btnOverlay = uibutton(bottomGrid, 'state', 'Text', 'Overlay', 'Value', true, ...
    'Tooltip', 'Show/hide crop rectangle and position lines', ...
    'ValueChangedFcn', @(src, ~) setOverlay(src.Value));
btnOverlay.Layout.Column = 6;

btnToggleMetadata = uibutton(bottomGrid, 'state', 'Text', 'Info', 'Value', false, ...
    'Tooltip', 'Show/hide acquisition metadata (microscope, objective, channels, scale)', ...
    'ValueChangedFcn', @(src, ~) toggleMetadataWindow(src.Value));
btnToggleMetadata.Layout.Column = 7;

btnSaveConfig = uibutton(bottomGrid, 'Text', 'Save Config', ...
    'ButtonPushedFcn', @(~,~) onSaveConfig());
btnSaveConfig.Layout.Column = 8;

btnLoadConfig = uibutton(bottomGrid, 'Text', 'Load Config', ...
    'ButtonPushedFcn', @(~,~) onLoadConfig());
btnLoadConfig.Layout.Column = 9;

setappdata(fig, 'OverlayVisible', true);

mvTiming_.labels{end+1} = 'bottom controls created'; mvTiming_.times(end+1) = toc(mvT0_);
%% ROI Manager window — created lazily on first use (saves a uifigure at startup)
roiCbs = struct();
roiCbs.setRoiMode    = @setRoiModeAllWins;
roiCbs.applyPosition = @applyRoiPosition;
roiCbs.onHide        = @() set(btnToggleRoi, 'Value', false);
roiCbs.onActivate    = @deactivateProfileTools;   % engaging an ROI tool frees profile tools
roiMgr = [];
roiMgrDefaultPos = [];   % set by onWindowShown, applied at creation
mvTiming_.labels{end+1} = 'ROI manager (deferred)'; mvTiming_.times(end+1) = toc(mvT0_);

%% Profile Manager window — also created lazily on first use
profCbs = struct();
profCbs.setRoiMode    = @setRoiModeAllWins;       % shares the image/zoom mouse funnel
profCbs.applyPosition = @applyRoiPosition;
profCbs.onHide        = @() set(btnToggleProfile, 'Value', false);
profCbs.onActivate    = @deactivateRoiTools;      % engaging a profile tool frees ROI tools
profMgr = [];
profMgrDefaultPos = [];

%% Metadata window — also created lazily on first use
metadataCbs = struct();
metadataCbs.onHide = @() set(btnToggleMetadata, 'Value', false);
metadataWin = [];
metadataWinDefaultPos = [];

addlistener(model, 'RoiChanged',     @(~,~) doRender());
addlistener(model, 'ProfileChanged', @(~,~) doRender());

%% Output struct
mw.fig          = fig;
mw.model        = model;
mw.rangeSliders = rangeSliders;
mw.dimSelector  = dimSelector;
mw.imageWins    = imageWins;
mw.zoomWins     = zoomWins;
mw.plotWins     = plotWins;
mw.imageWin     = imageWins{1};   % legacy single-window fields
mw.zoomWin      = zoomWins{1};
mw.plotWin      = plotWins{1};
mw.getRoiMgr    = @getRoiMgr;     % ROI manager is created lazily
mw.getProfileMgr = @getProfileMgr;% Profile manager is created lazily
mw.getMetadataWin = @getMetadataWin; % Metadata window is created lazily
mw.histAx       = histAx;
mw.rbGlobal     = rbGlobal;
mw.rbImage      = rbImage;
mw.rbZoom       = rbZoom;
mw.rbManual     = rbManual;
mw.Render       = renderFcn;

fig.CloseRequestFcn       = @(~,~) onMainWindowClosing();
fig.WindowButtonDownFcn   = @(~,~) onFigureButtonDown();
fig.WindowButtonMotionFcn = @(~,~) onFigureMotion();

setappdata(fig, 'CursorLR', makeHistCursor('lr'));
setappdata(fig, 'CursorUD', makeHistCursor('ud'));

%% Resize figure to exact fit
mvTiming_.labels{end+1} = 'pre-drawnow'; mvTiming_.times(end+1) = toc(mvT0_);
drawnow;
mvTiming_.labels{end+1} = 'drawnow #1 (layout measurement)'; mvTiming_.times(end+1) = toc(mvT0_);
actualTitleH  = panelTitleH;
actualChromeH = 58;
try
    actualTitleH  = round(posPanel.Position(4) - posPanel.InnerPosition(4));
    actualTitleH  = max(10, min(80, actualTitleH));
catch
end
try
    actualChromeH = round(fig.Position(4) - fig.InnerPosition(4));
    actualChromeH = max(20, min(150, actualChromeH));
catch
end

posPanelH      = nDims*rowH_slider + max(0,nDims-1)*rowH_spacing + rowH_playSpeed + rowH_spacing + rowH_plotBtns + rowH_spacing + 2*panelPadV + actualTitleH;
contrastPanelH = rowH_contrast + 2*panelPadV + actualTitleH;
applyPanelHeights();

for ds = 1:nDatasets
    imageWins{ds}.fig.Visible = 'off';
    zoomWins{ds}.fig.Visible  = 'off';
    plotWins{ds}.fig.Visible  = 'off';
end

mvTiming_.labels{end+1} = 'pre-doRender'; mvTiming_.times(end+1) = toc(mvT0_);
doRender();
mvTiming_.labels{end+1} = 'doRender #1 (first render)'; mvTiming_.times(end+1) = toc(mvT0_);
onWindowShown();
mvTiming_.labels{end+1} = 'onWindowShown (positioning)'; mvTiming_.times(end+1) = toc(mvT0_);

% ── Print startup timing report ──────────────────────────────────────────
mvDts_ = diff([0, mvTiming_.times]);
[~, mvOrd_] = sort(mvDts_, 'descend');
fprintf('\n[matVis2] Startup timing  (data size: %s, nDims=%d)\n', ...
        mat2str(model.Size), nDims);
fprintf('  %-45s  %6s  %6s\n', 'Section', 'sec', 'cumul');
fprintf('  %s\n', repmat('-', 1, 62));
for mvK_ = 1:numel(mvTiming_.labels)
    fprintf('  %-45s  %6.3f  %6.3f\n', ...
        mvTiming_.labels{mvK_}, mvDts_(mvK_), mvTiming_.times(mvK_));
end
fprintf('  %s\n  %-45s  %6.3f\n\n', repmat('-', 1, 62), 'TOTAL', mvTiming_.times(end));
fprintf('[matVis2] Top-5 slowest sections:\n');
for mvK_ = 1:min(5, numel(mvOrd_))
    fprintf('  %d. %-45s  %.3f s\n', mvK_, mvTiming_.labels{mvOrd_(mvK_)}, mvDts_(mvOrd_(mvK_)));
end
fprintf('\n');

%% =========================================================================
%  Nested callback functions
%% =========================================================================

    function onMainWindowClosing()
        try
            for d = 1:nDims
                if ~isempty(playTimers{d}) && isvalid(playTimers{d})
                    stop(playTimers{d}); delete(playTimers{d});
                end
            end
        catch
        end
        for ds = 1:nDatasets
            try; if isvalid(imageWins{ds}.fig), delete(imageWins{ds}.fig); end; catch; end
            try; if isvalid(zoomWins{ds}.fig),  delete(zoomWins{ds}.fig);  end; catch; end
            try; if isvalid(plotWins{ds}.fig),  delete(plotWins{ds}.fig);  end; catch; end
        end
        try; if ~isempty(roiMgr) && isvalid(roiMgr.fig), delete(roiMgr.fig); end; catch; end
        try; if ~isempty(hist2DFig) && isvalid(hist2DFig), delete(hist2DFig); end; catch; end
        delete(fig);
    end

    function onMainWindowRightClick()
        for ds = 1:nDatasets
            try; if isvalid(imageWins{ds}.fig), figure(imageWins{ds}.fig); end; catch; end
            try; if isvalid(zoomWins{ds}.fig),  figure(zoomWins{ds}.fig);  end; catch; end
            try; if isvalid(plotWins{ds}.fig),  figure(plotWins{ds}.fig);  end; catch; end
        end
        figure(fig);
    end

    % ------------------------------------------------------------------
    %  Main render loop
    % ------------------------------------------------------------------
    function doRender()
        xd       = model.XDim;
        yd       = model.YDim;
        xr       = model.ZoomRange(xd, :);
        yr       = model.ZoomRange(yd, :);
        zoomRect  = [xr(1), yr(1), diff(xr), diff(yr)];
        posX      = model.CurrPos(xd);
        posY      = model.CurrPos(yd);
        posXLocal = posX - xr(1) + 1;
        posYLocal = posY - yr(1) + 1;

        cmin_arr = zeros(1, nDatasets);
        cmax_arr = zeros(1, nDatasets);

        % Selected ROIs in the current display plane → traces in the plots
        selRois = model.RoiSelection;
        selRois = selRois(ismember(selRois, model.VisibleRoiIndices()));
        roiNames = cell(1, numel(selRois));
        for k = 1:numel(selRois)
            roiNames{k} = model.RoiList(selRois(k)).name;
        end
        roiCols = MatVisRender.roiColors(max(numel(selRois), 1));

        % When a spatial filter is active, plots along the X/Y display dims
        % overlay the unfiltered and filtered profiles (see profile loop).
        filtOn = MatVisRender.filterActive(model);

        % Whole-dimension RGB colour coding (MeanStretch / MaxStretch): the
        % raw slices below are H×W×N stacks composed via renderStretchImage.
        stretchOn = MatVisRender.stretchActive(model);

        rf_ads = [];
        rz_ads = [];
        for ds = 1:nDatasets
            dsData   = model.Datasets{ds};
            raw_full = MatVisRender.getRawFullSliceFromData(model, dsData);
            raw_zoom = MatVisRender.getRawSliceFromData(model, dsData);
            if ds == model.ActiveDataset
                rf_ads = raw_full;   % reuse below — avoids slicing twice
                rz_ads = raw_zoom;
            end

            model.SetImageData(raw_full, ds);
            model.SetZoomData(raw_zoom,  ds);

            [cmin_ds, cmax_ds] = getBoundsForDataset(ds, raw_full, raw_zoom);
            cmin_arr(ds) = cmin_ds;
            cmax_arr(ds) = cmax_ds;
            gamma_ds     = getGammaForDataset(ds);

            if stretchOn
                % Whole RGB dimension colour-coded into one image; contrast/
                % gamma/filter are handled inside renderStretchImage.
                rgb_full = MatVisRender.renderStretchImage(model, raw_full, cmin_ds, cmax_ds, gamma_ds);
                rgb_zoom = MatVisRender.renderStretchImage(model, raw_zoom, cmin_ds, cmax_ds, gamma_ds);
                if withAlpha
                    aMap  = model.AlphaMaps{ds};
                    aLo   = model.AlphaContrastMins(ds);
                    aHi   = model.AlphaContrastMaxs(ds);
                    aFull = stretchAlpha_(MatVisRender.getRawFullSliceFromData(model, aMap), aLo, aHi, model.AlphaGamma);
                    aZoom = stretchAlpha_(MatVisRender.getRawSliceFromData(model, aMap),     aLo, aHi, model.AlphaGamma);
                    rgb_full = blendStretchAlpha_(rgb_full, aFull, model.AlphaBgWhite);
                    rgb_zoom = blendStretchAlpha_(rgb_zoom, aZoom, model.AlphaBgWhite);
                end
            else
                % Spatial filter is applied to the displayed image only; contrast
                % bounds above are computed from the unfiltered data (as in the
                % original matVis, which kept currImVal before filtering).
                disp_full = MatVisRender.filterImage(raw_full, model.FilterType, model.FilterPar);
                disp_zoom = MatVisRender.filterImage(raw_zoom, model.FilterType, model.FilterPar);

                norm_full = MatVisRender.normalizeData(disp_full, cmin_ds, cmax_ds);
                norm_zoom = MatVisRender.normalizeData(disp_zoom, cmin_ds, cmax_ds);

                if withAlpha
                    % Slice the alpha map exactly like the data (zoom /
                    % projection / flips), then blend against the background.
                    aMap  = model.AlphaMaps{ds};
                    aLo   = model.AlphaContrastMins(ds);
                    aHi   = model.AlphaContrastMaxs(ds);
                    aFull = MatVisRender.renderAlphaSlice( ...
                        MatVisRender.getRawFullSliceFromData(model, aMap), ...
                        aLo, aHi, model.AlphaGamma);
                    aZoom = MatVisRender.renderAlphaSlice( ...
                        MatVisRender.getRawSliceFromData(model, aMap), ...
                        aLo, aHi, model.AlphaGamma);
                    rgb_full = MatVisRender.composeImageWithAlpha(norm_full, gamma_ds, ...
                        model.ColormapIdx, aFull, model.AlphaBgWhite);
                    rgb_zoom = MatVisRender.composeImageWithAlpha(norm_zoom, gamma_ds, ...
                        model.ColormapIdx, aZoom, model.AlphaBgWhite);
                else
                    rgb_full = MatVisRender.composeImage(norm_full, gamma_ds, model.ColormapIdx);
                    rgb_zoom = MatVisRender.composeImage(norm_zoom, gamma_ds, model.ColormapIdx);
                end
            end

            imageWins{ds}.Update(rgb_full, zoomRect, posX, posY);
            zoomWins{ds}.Update(rgb_zoom, posXLocal, posYLocal);

            if withAlpha
                aMapDs = model.AlphaMaps{ds};
            else
                aMapDs = [];
            end

            profiles = cell(1, nDims);
            for ii = 1:nDims
                if model.PlotDims(ii)
                    if filtOn && (ii == xd || ii == yd) && ~withAlpha && isempty(selRois)
                        % Spatial profile + its filtered counterpart, drawn in
                        % two colours (matches the original matVis behaviour of
                        % overlaying filtered/unfiltered along x/y).
                        [pRaw, pFilt] = MatVisRender.renderFilteredSpatialProfile( ...
                            model, dsData, ii, model.PlotLock(ii));
                        profiles{ii} = struct('data', [pRaw, pFilt], ...
                            'names', {{'unfiltered', 'filtered'}}, ...
                            'colors', [0 0 0; 0.85 0.33 0.10]);
                    elseif ~isempty(selRois) && ii ~= xd && ii ~= yd
                        % ROI traces: mean over each ROI mask along dim ii
                        % (alpha-weighted mean + mean-alpha trace with alpha)
                        if model.PlotLock(ii)
                            nT = model.ZoomRange(ii, 2) - model.ZoomRange(ii, 1) + 1;
                        else
                            nT = model.Size(ii);
                        end
                        M = NaN(nT, numel(selRois));
                        A = NaN(nT, numel(selRois));
                        for k = 1:numel(selRois)
                            if withAlpha
                                [p, a] = MatVisRender.renderRoiProfileAlphaFromData(model, ...
                                    dsData, aMapDs, ii, model.RoiList(selRois(k)), model.PlotLock(ii));
                                if ~isempty(p), M(:, k) = p; A(:, k) = a; end
                            else
                                p = MatVisRender.renderRoiProfileFromData(model, dsData, ...
                                    ii, model.RoiList(selRois(k)), model.PlotLock(ii));
                                if ~isempty(p), M(:, k) = p; end
                            end
                        end
                        if withAlpha
                            profiles{ii} = struct('data', M, ...
                                'names', {roiNames}, 'colors', roiCols, 'alpha', A);
                        else
                            profiles{ii} = struct('data', M, ...
                                'names', {roiNames}, 'colors', roiCols);
                        end
                    elseif withAlpha
                        % Alpha-weighted trace sum(data.*alpha)/sum(alpha)
                        % plus the mean-alpha trace (avgMode 0 = single pixel)
                        if model.PlotLock(ii)
                            [p, a] = MatVisRender.renderProfileNeighborAlphaFromData( ...
                                model, dsData, aMapDs, ii, plotAvgMode);
                        else
                            [p, a] = MatVisRender.renderFullProfileNeighborAlphaFromData( ...
                                model, dsData, aMapDs, ii, plotAvgMode);
                        end
                        profiles{ii} = struct('data', p, 'alpha', a);
                    elseif plotAvgMode == 0
                        if model.PlotLock(ii)
                            profiles{ii} = MatVisRender.renderProfileFromData(model, dsData, ii);
                        else
                            profiles{ii} = MatVisRender.renderFullProfileFromData(model, dsData, ii);
                        end
                    else
                        if model.PlotLock(ii)
                            profiles{ii} = MatVisRender.renderProfileNeighborFromData(model, dsData, ii, plotAvgMode);
                        else
                            profiles{ii} = MatVisRender.renderFullProfileNeighborFromData(model, dsData, ii, plotAvgMode);
                        end
                    end
                end
            end
            plotWins{ds}.Update(profiles);
        end

        % Histogram and contrast fields: active dataset only.
        % During playback this is skipped (unless the 'H' toggle is on) —
        % rebuilding the histogram each frame dominates the frame time.
        ads = model.ActiveDataset;
        lastBoundsAds = [cmin_arr(ads), cmax_arr(ads)];
        if ~isPlayingAny || btnPlayHist.Value
            updateHistogram(rf_ads, rz_ads, cmin_arr(ads), cmax_arr(ads));
            updateContrastDisplay(cmin_arr(ads), cmax_arr(ads));

            if withAlpha && ~isempty(btn2DHist) && btn2DHist.Value
                update2DHist(rf_ads, cmin_arr(ads), cmax_arr(ads));
            end
        end

        % Reconcile RGB-stretch controls + stretch-bar visibility with state.
        syncStretchUI();

        % Keep the Profile Manager's 1-D/straightened view in sync with the
        % current slice while it is open (it samples the live data).
        if ~isempty(profMgr) && isvalid(profMgr.fig) && ...
                strcmp(profMgr.fig.Visible, 'on')
            try; profMgr.Refresh(); catch; end
        end
    end

    % ------------------------------------------------------------------
    %  RGB stretch (MeanStretch / MaxStretch) UI plumbing
    % ------------------------------------------------------------------
    function applyPanelHeights()
        % Panel + figure heights. The stretch-bar row is reserved inside the
        % existing image-panel height, so this does not depend on stretch state.
        imgPanelH = 3*rowH_dimSel + 4 + 2*4 + actualTitleH;
        figH      = posPanelH + imgPanelH + contrastPanelH + bottomH ...
                  + 3*rowH_spacing + 12 + actualChromeH;
        grid.RowHeight    = {posPanelH, imgPanelH, contrastPanelH, bottomH};
        fig.Position(3:4) = [figWidth, figH];
    end

    function syncStretchUI()
        % Enable/value of the Mean/Max/lock buttons and stretch-bar visibility
        % follow the model. Programmatic Value writes don't fire callbacks.
        rgbOn = MatVisRender.rgbActive(model);
        if ~rgbOn && ~strcmp(model.RGBStretchMode, 'none')
            model.RGBStretchMode = 'none';   % drop stale mode when RGB is off
        end
        mode       = model.RGBStretchMode;
        dimSelector.btnRGBMean.Enable = onOffStr_(rgbOn);
        dimSelector.btnRGBMax.Enable  = onOffStr_(rgbOn);
        dimSelector.btnRGBMean.Value  = rgbOn && strcmp(mode, 'mean');
        dimSelector.btnRGBMax.Value   = rgbOn && strcmp(mode, 'max');
        shown = rgbOn && ~strcmp(mode, 'none');
        dimSelector.btnRGBLock.Enable = onOffStr_(shown);
        dimSelector.btnRGBLock.Value  = logical(model.RGBStretchZoomLock);
        % The bar's row is always reserved, so this only shows/hides it —
        % no figure resize or element repositioning.
        stretchBar.SetVisible(shown);

        syncRGBIndicator(rgbOn, mode);
    end

    function syncRGBIndicator(rgbOn, mode)
        % Overlay the RGB triad/stretch colour-coding on the position track
        % of whichever slider is the RGB dimension; all others stay plain.
        rd = model.RGBDim;
        for d = 1:nDims
            if d == rd && rgbOn
                if strcmp(mode, 'none')
                    idx3 = MatVisRender.rgbTriadIndices(model);
                    rangeSliders{d}.RGBTriadPos      = idx3([1 3]);
                    rangeSliders{d}.RGBIndicatorMode = 'triad';
                else
                    spanIdx = MatVisRender.rgbStretchSpanIndices(model);
                    rangeSliders{d}.RGBStretchSpan   = [spanIdx(1), spanIdx(end)];
                    rangeSliders{d}.RGBStretchColors = MatVisRender.stretchSliceColors(model, numel(spanIdx));
                    rangeSliders{d}.RGBIndicatorMode = 'stretch';
                end
            else
                rangeSliders{d}.RGBIndicatorMode = 'none';
            end
        end
    end

    function onRGBStretchRangeChanged(v)
        model.RGBStretchRange = v;
        doRender();
    end

    function a = stretchAlpha_(rawA, lo, hi, g)
        % Collapse an N-slice alpha stack (stretch mode) to a 2-D weight map.
        if ndims(rawA) == 3, rawA = mean(rawA, 3); end
        a = MatVisRender.renderAlphaSlice(rawA, lo, hi, g);
    end

    function img = blendStretchAlpha_(img, a, bgWhite)
        a  = max(0, min(1, double(a)));
        bg = 0;
        if bgWhite, bg = 255; end
        img = uint8(double(img) .* a + bg * (1 - a));
    end

    function s = onOffStr_(tf)
        if tf, s = 'on'; else, s = 'off'; end
    end

    % ------------------------------------------------------------------
    %  2D data-vs-alpha histogram (contrast guidance)
    % ------------------------------------------------------------------
    function onHist2DToggle(src)
        if src.Value
            ensureHist2DWindow();
            hist2DFig.Visible = 'on';
            doRender();
        elseif ~isempty(hist2DFig) && isvalid(hist2DFig)
            hist2DFig.Visible = 'off';
        end
    end

    function ensureHist2DWindow()
        if ~isempty(hist2DFig) && isvalid(hist2DFig), return; end
        hist2DFig = uifigure('Name', '2D Histogram: data vs alpha', ...
            'NumberTitle', 'off', 'Visible', 'off');
        % Top edge aligned with the other figure windows (zoom window's
        % inner top), placed to its right.  Falls back to the standard
        % winInnerTop convention from onWindowShown.
        histW = 560;
        histH = 420;
        screenSize = get(0, 'ScreenSize');
        topY  = screenSize(4) - 8 - 32;   % safeMargin + titleBarH
        histX = 100;
        try
            zp    = zoomWins{1}.fig.Position;
            histX = zp(1) + zp(3) + 10;
            topY  = zp(2) + zp(4);
        catch
        end
        histX = max(10, min(histX, screenSize(3) - histW - 10));
        hist2DFig.Position = [histX, topY - histH, histW, histH];
        g = uigridlayout(hist2DFig, [1, 1]);
        g.Padding = [4 4 18 4];   % extra right padding for the colorbar label
        hist2DAx = uiaxes(g);
        hist2DImg = imagesc(hist2DAx, 'XData', [0 1], 'YData', [0 1], 'CData', 0);
        hist2DAx.YDir = 'normal';
        colormap(hist2DAx, turbo(256));
        xlabel(hist2DAx, 'Data value');
        ylabel(hist2DAx, 'Alpha value');
        cb = colorbar(hist2DAx);
        cb.Label.String = 'log_{10}(count + 1)';
        % Guide lines at the current data / alpha contrast bounds
        guideCol = [1 1 1];
        hist2DGuides.dmin = xline(hist2DAx, 0, '--', 'Color', guideCol, 'LineWidth', 1.0, 'Alpha', 0.8);
        hist2DGuides.dmax = xline(hist2DAx, 1, '--', 'Color', guideCol, 'LineWidth', 1.0, 'Alpha', 0.8);
        hist2DGuides.amin = yline(hist2DAx, 0, '--', 'Color', guideCol, 'LineWidth', 1.0, 'Alpha', 0.8);
        hist2DGuides.amax = yline(hist2DAx, 1, '--', 'Color', guideCol, 'LineWidth', 1.0, 'Alpha', 0.8);
        hist2DFig.CloseRequestFcn = @(~,~) onHist2DClose();
    end

    function onHist2DClose()
        if ~isempty(hist2DFig) && isvalid(hist2DFig)
            hist2DFig.Visible = 'off';
        end
        if ~isempty(btn2DHist) && isvalid(btn2DHist)
            btn2DHist.Value = false;
        end
    end

    function update2DHist(rawFull, cmin, cmax)
        % 2D histogram of the current full slice: data values vs alpha
        % values of the active dataset (mirrors update2DHist in the
        % original matVis, drawn in-place instead of a recursive matVis).
        ensureHist2DWindow();
        ads2 = model.ActiveDataset;
        aRaw = MatVisRender.getRawFullSliceFromData(model, model.AlphaMaps{ads2});

        d = rawFull(:);
        a = aRaw(:);
        ok = isfinite(d) & isfinite(a);

        nBins = 201;
        xlo = model.AllDataMins(ads2);  xhi = model.AllDataMaxs(ads2);
        ylo = model.AlphaMins(ads2);    yhi = model.AlphaMaxs(ads2);
        if ~(xhi > xlo), xhi = xlo + 1; end
        if ~(yhi > ylo), yhi = ylo + 1; end
        xE = linspace(xlo, xhi, nBins + 1);
        yE = linspace(ylo, yhi, nBins + 1);
        counts = histcounts2(d(ok), a(ok), xE, yE);

        xC = (xE(1:end-1) + xE(2:end)) / 2;
        yC = (yE(1:end-1) + yE(2:end)) / 2;
        hist2DImg.XData = xC;
        hist2DImg.YData = yC;
        hist2DImg.CData = log10(counts' + 1);
        hist2DAx.XLim = [xlo, xhi];
        hist2DAx.YLim = [ylo, yhi];

        hist2DGuides.dmin.Value = cmin;
        hist2DGuides.dmax.Value = cmax;
        hist2DGuides.amin.Value = model.AlphaContrastMins(ads2);
        hist2DGuides.amax.Value = model.AlphaContrastMaxs(ads2);
    end

    % ------------------------------------------------------------------
    %  Per-dataset contrast bounds
    % ------------------------------------------------------------------
    function [cmin, cmax] = getBoundsForDataset(ds, raw_full, raw_zoom)
        mode = model.ContrastMode;
        dmin = model.AllDataMins(ds);
        dmax = model.AllDataMaxs(ds);

        if strcmp(mode, 'Manual')
            if model.ContrastLocked
                if ds == model.ActiveDataset
                    cmin = model.ContrastMin;
                    cmax = model.ContrastMax;
                else
                    % Linearly scale active dataset bounds to this dataset
                    cmin_ref = model.ContrastMin;
                    cmax_ref = model.ContrastMax;
                    dmin_ref = model.AllDataMins(model.ActiveDataset);
                    dmax_ref = model.AllDataMaxs(model.ActiveDataset);
                    range_ref = max(dmax_ref - dmin_ref, eps);
                    flo = (cmin_ref - dmin_ref) / range_ref;
                    fhi = (cmax_ref - dmin_ref) / range_ref;
                    range_ds = dmax - dmin;
                    cmin = dmin + flo * range_ds;
                    cmax = dmin + fhi * range_ds;
                end
            else
                % Unlocked: per-dataset independent Manual bounds
                cmin = model.DatasetContrastMins(ds);
                cmax = model.DatasetContrastMaxs(ds);
            end
        else
            % Global / Image / Zoom: compute independently per dataset
            switch mode
                case 'Global'
                    cmin = dmin; cmax = dmax;
                case 'Image'
                    if ~isempty(raw_full)
                        cmin = double(min(raw_full(:)));
                        cmax = double(max(raw_full(:)));
                    else
                        cmin = dmin; cmax = dmax;
                    end
                case 'Zoom'
                    if ~isempty(raw_zoom)
                        cmin = double(min(raw_zoom(:)));
                        cmax = double(max(raw_zoom(:)));
                    else
                        cmin = dmin; cmax = dmax;
                    end
                otherwise
                    cmin = dmin; cmax = dmax;
            end

            % Percentile clipping
            pLow  = edtPercLow.Value;
            pHigh = edtPercHigh.Value;
            if pLow > 0 || pHigh < 1
                pLow  = max(0, min(pLow,  1));
                pHigh = max(0, min(pHigh, 1));
                if pLow < pHigh
                    switch mode
                        case 'Global'
                            [cmin, cmax] = applyGlobalPercentile(ds, pLow, pHigh);
                        case 'Image'
                            q = quantile(raw_full(:), [pLow, pHigh]);
                            cmin = q(1); cmax = q(2);
                        case 'Zoom'
                            q = quantile(raw_zoom(:), [pLow, pHigh]);
                            cmin = q(1); cmax = q(2);
                    end
                end
            end
        end

        if cmin >= cmax
            cmax = cmin + max(1, abs(cmin) * eps * 1e6);
        end
    end

    function [cmin, cmax] = getCachedBounds()
        % Contrast bounds of the active dataset as of the last render.
        % Used by mouse handlers (hover/click hit-tests) so they don't have
        % to re-slice the data on every mouse event.
        if ~isempty(lastBoundsAds)
            cmin = lastBoundsAds(1);
            cmax = lastBoundsAds(2);
        else
            ads      = model.ActiveDataset;
            adsData  = model.Datasets{ads};
            raw_full = MatVisRender.getRawFullSliceFromData(model, adsData);
            raw_zoom = MatVisRender.getRawSliceFromData(model, adsData);
            [cmin, cmax] = getBoundsForDataset(ads, raw_full, raw_zoom);
        end
    end

    function [cmin, cmax] = applyGlobalPercentile(dsIdx, pLow, pHigh)
        cdfKey = sprintf('GlobalPercentileCDF_%d', dsIdx);
        cdf = getappdata(fig, cdfKey);
        if isempty(cdf)
            dsData = model.Datasets{dsIdx};
            dmin   = model.AllDataMins(dsIdx);
            dmax   = model.AllDataMaxs(dsIdx);
            nBins  = 10000;
            edges  = linspace(dmin, dmax, nBins + 1);
            % Pass native-type data — double() would copy the whole dataset
            counts = histcounts(dsData(:), edges);
            cumC   = cumsum(double(counts));
            cdf.frac  = cumC / max(cumC(end), 1);
            cdf.edges = edges;
            setappdata(fig, cdfKey, cdf);
        end
        iLo = find(cdf.frac >= pLow,  1, 'first');
        iHi = find(cdf.frac >= pHigh, 1, 'first');
        if isempty(iLo), iLo = 1; end
        if isempty(iHi), iHi = numel(cdf.frac); end
        cmin = cdf.edges(iLo);
        cmax = cdf.edges(min(iHi + 1, numel(cdf.edges)));
    end

    % ------------------------------------------------------------------
    %  Histogram rendering
    % ------------------------------------------------------------------
    function ensureHistObjects()
        % Create the histogram graphics objects once; updateHistogram then
        % only updates their data.  Recreating ~10 objects in a uiaxes on
        % every render is far more expensive than property updates.
        if ~isempty(histObjs) && isgraphics(histObjs.fillG), return; end
        hold(histAx, 'on');
        fillArgs = {'EdgeColor', 'none', 'HitTest', 'off', 'PickableParts', 'none'};
        histObjs.fillG = fill(histAx, NaN, NaN, [0.82 0.82 0.82], 'FaceAlpha', 0.90, fillArgs{:});
        histObjs.fillI = fill(histAx, NaN, NaN, [0.50 0.50 0.50], 'FaceAlpha', 0.90, fillArgs{:});
        histObjs.fillZ = fill(histAx, NaN, NaN, [0.08 0.08 0.08], 'FaceAlpha', 0.92, fillArgs{:});
        histObjs.cbImg = image(histAx, 'XData', [0 1], 'YData', [0 1], ...
            'CData', zeros(2, 256, 3), 'HitTest', 'off', 'PickableParts', 'none');
        histObjs.lineMin = line(histAx, [NaN NaN], [NaN NaN], ...
            'Color', [0.85 0.15 0.15], 'LineWidth', 2.5, 'HitTest', 'off');
        histObjs.lineMax = line(histAx, [NaN NaN], [NaN NaN], ...
            'Color', [0.15 0.15 0.85], 'LineWidth', 2.5, 'HitTest', 'off');
        histObjs.gammaLine = line(histAx, NaN, NaN, ...
            'Color', [0.5 0.5 0.5], 'LineWidth', 2, 'HitTest', 'off');
        histObjs.gammaDot = line(histAx, NaN, NaN, 'LineStyle', 'none', ...
            'Marker', 'o', 'Color', [0.4 0.4 0.4], 'MarkerSize', 8, ...
            'MarkerFaceColor', [0.8 0.8 0.8], 'HitTest', 'off');
        histObjs.scaleTxt = text(histAx, NaN, NaN, '', ...
            'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
            'FontSize', 12, 'Color', [0.45 0.45 0.45], 'FontAngle', 'italic', ...
            'HitTest', 'off', 'PickableParts', 'none');
        hold(histAx, 'off');
        histAx.YDir = 'normal';
    end

    function updateHistogram(rawFull, rawZoom, cmin, cmax)
        if isempty(rawFull) || ~isnumeric(rawFull), return; end
        ensureHistObjects();

        histXMin = edtHistMin.Value;
        histXMax = edtHistMax.Value;
        nBins    = 100;
        binEdges = linspace(histXMin, histXMax, nBins + 1);
        bw       = binEdges(2) - binEdges(1);
        centers  = binEdges(1:end-1) + bw/2;

        % Cache key includes active dataset index.  Note: pass native-type
        % data directly — double() would copy the whole dataset.
        ads      = model.ActiveDataset;
        cacheKey = [ads, histXMin, histXMax];
        if ~isequal(getappdata(fig,'GlobalHistKey'), cacheKey)
            countsG = histcounts(model.Data(:), binEdges);
            setappdata(fig, 'GlobalHistKey',    cacheKey);
            setappdata(fig, 'GlobalHistCounts', countsG);
        else
            countsG = getappdata(fig, 'GlobalHistCounts');
        end

        countsI = histcounts(rawFull(:), binEdges);
        countsZ = histcounts(rawZoom(:), binEdges);

        normG = countsG / max([max(countsG), 1]);
        normI = countsI / max([max(countsI), 1]);
        normZ = countsZ / max([max(countsZ), 1]);

        yScale = getappdata(fig, 'HistYScale');
        if isempty(yScale), yScale = 'linear'; end
        logFloor = 1e-3;
        yBase    = 0;
        if strcmp(yScale, 'log'), yBase = logFloor; end

        setHistFill(histObjs.fillG, centers, bw, normG, yBase);
        setHistFill(histObjs.fillI, centers, bw, normI, yBase);
        setHistFill(histObjs.fillZ, centers, bw, normZ, yBase);

        yMax     = 1.0;
        yLineBot = max(yBase, eps);
        set(histObjs.lineMin, 'XData', [cmin cmin], 'YData', [yLineBot yMax]);
        set(histObjs.lineMax, 'XData', [cmax cmax], 'YData', [yLineBot yMax]);

        gamma  = getGammaForDataset(model.ActiveDataset);
        xGamma = linspace(cmin, cmax, 100);
        if cmax > cmin
            yGamma = ((xGamma - cmin) / (cmax - cmin)) .^ gamma * yMax;
        else
            yGamma = zeros(1, 100);
        end
        yGamma = max(yGamma, yBase);
        set(histObjs.gammaLine, 'XData', xGamma, 'YData', yGamma);
        set(histObjs.gammaDot, 'XData', (cmin+cmax)/2, ...
            'YData', max(0.5^gamma * yMax, yBase));

        cbH     = yMax * 0.15;
        nColors = 256;
        cmap_   = MatVisRender.getColormap(model.ColormapIdx, nColors);
        pixX    = linspace(histXMin, histXMax, nColors);
        pixNorm = max(0, min(1, (pixX - cmin) ./ max(cmax - cmin, eps)));
        tGam    = pixNorm .^ gamma;
        idx_    = max(1, min(nColors, round(tGam * (nColors-1)) + 1));
        cbImg   = repmat(reshape(cmap_(idx_, :), [1, nColors, 3]), 2, 1, 1);

        if strcmp(yScale, 'linear')
            cbYBot = -cbH; cbYTop = 0;
        else
            f      = cbH / (cbH + yMax);
            cbYTop = logFloor;
            cbYBot = 10 ^ ((log10(logFloor) - f * log10(yMax * 1.1)) / (1 - f));
        end
        set(histObjs.cbImg, 'XData', [histXMin, histXMax], ...
            'YData', [(3*cbYBot+cbYTop)/4, (3*cbYTop+cbYBot)/4], 'CData', cbImg);

        set(histObjs.scaleTxt, 'String', yScale, ...
            'Position', [histXMin + 0.015 * (histXMax - histXMin), yMax, 0]);

        histAx.XLim = [histXMin, histXMax];
        if strcmp(yScale, 'linear')
            histAx.YScale = 'linear';
            histAx.YLim   = [-cbH, yMax];
        else
            histAx.YScale = 'log';
            histAx.YLim   = [cbYBot, yMax * 1.1];
        end
    end

    function setHistFill(h, centers, bw, counts, baseline)
        if all(counts == 0)
            set(h, 'Visible', 'off');
            return;
        end
        nB    = numel(centers);
        xL    = centers - bw/2;
        xR    = centers + bw/2;
        yVals = max(counts(:)', baseline);
        xStep = reshape([xL; xR], 1, 2*nB);
        yStep = reshape([yVals; yVals], 1, 2*nB);
        set(h, 'XData', [xL(1), xStep, xR(end)], ...
               'YData', [baseline, yStep, baseline], 'Visible', 'on');
    end

    function updateContrastDisplay(cmin, cmax)
        % Only write widget properties that actually changed — every write
        % on a uifigure widget is a roundtrip to the web renderer.
        ads     = model.ActiveDataset;
        dmin    = model.AllDataMins(ads);
        dmax    = model.AllDataMaxs(ads);
        padded  = max((dmax - dmin) * 0.5, 1);
        safeMin = min(cmin, dmin) - padded;
        safeMax = max(cmax, dmax) + padded;
        setIfChanged(edtContrastMin, 'Limits', [safeMin, safeMax]);
        setIfChanged(edtContrastMax, 'Limits', [safeMin, safeMax]);
        setIfChanged(edtContrastMin, 'Value',  cmin);
        setIfChanged(edtContrastMax, 'Value',  cmax);
        setIfChanged(edtGamma,       'Value',  getGammaForDataset(ads));

        isManual = strcmp(model.ContrastMode, 'Manual');
        setEnableIfChanged(edtContrastMin, isManual);
        setEnableIfChanged(edtContrastMax, isManual);
        setEnableIfChanged(edtPercLow,     ~isManual);
        setEnableIfChanged(edtPercHigh,    ~isManual);

        if withAlpha
            setIfChanged(edtAlphaMin,   'Value', model.AlphaContrastMins(ads));
            setIfChanged(edtAlphaMax,   'Value', model.AlphaContrastMaxs(ads));
            setIfChanged(edtAlphaGamma, 'Value', model.AlphaGamma);
        end
    end

    function setIfChanged(h, prop, val)
        if ~isequal(h.(prop), val)
            h.(prop) = val;
        end
    end

    function setEnableIfChanged(h, tf)
        if logical(h.Enable) ~= logical(tf)
            h.Enable = tf;
        end
    end

    function g = getGammaForDataset(ds)
        if model.ContrastLocked || isempty(model.DatasetGammas) || ds > numel(model.DatasetGammas)
            g = model.Gamma;
        else
            g = model.DatasetGammas(ds);
        end
    end

    % ------------------------------------------------------------------
    %  Dataset dropdown / lock callbacks
    % ------------------------------------------------------------------
    function onDatasetDropdownChanged(src)
        newIdx = find(strcmp(model.DatasetNames, src.Value), 1);
        if ~isempty(newIdx) && newIdx ~= model.ActiveDataset
            model.ActiveDataset = newIdx;
            setappdata(fig, 'GlobalHistKey', []);   % invalidate global hist cache
            updateHistLimitsForActiveDataset();
            doRender();
        end
    end

    function onLockButtonChanged(src)
        model.ContrastLocked = logical(src.Value);
        src.Text = lockIcon(src.Value);
        doRender();
    end

    function updateHistLimitsForActiveDataset()
        ads  = model.ActiveDataset;
        dmin = model.AllDataMins(ads);
        dmax = model.AllDataMaxs(ads);
        % Allow wider limits so linearly-scaled values outside data range can display
        padded = (dmax - dmin) * 0.5;
        lo = dmin - padded; hi = dmax + padded;
        edtHistMin.Limits = [lo, hi];
        edtHistMax.Limits = [lo, hi];
        edtHistMin.Value  = dmin;
        edtHistMax.Value  = dmax;
        edtContrastMin.Limits = [lo, hi];
        edtContrastMax.Limits = [lo, hi];
        edtGamma.Value = getGammaForDataset(ads);
    end

    function onModelActiveDatasetChanged()
        ads = model.ActiveDataset;
        if ads <= numel(model.DatasetNames)
            dropDataset.Value = model.DatasetNames{ads};
        end
    end

    % ------------------------------------------------------------------
    %  Slider / navigation callbacks
    % ------------------------------------------------------------------
    function onSliderPos(dimIdx, val)
        model.CurrPos(dimIdx) = round(val);
        doRender();
    end

    function onSliderZoom(dimIdx, lo, hi)
        model.ZoomRange(dimIdx, :) = [lo, hi];
        doRender();
    end

    function onPlotLockToggled(dimIdx, locked)
        model.PlotLock(dimIdx) = locked;
        applyPlotZoomLock();
    end

    function onPlotPosChange(dimIdx, newPos)
        model.CurrPos(dimIdx) = max(1, min(model.Size(dimIdx), round(newPos)));
        rangeSliders{dimIdx}.Value = model.CurrPos(dimIdx);
        doRender();
    end

    function onPlotZoomChange(dimIdx, lo, hi)
        lo = max(1, round(lo));
        hi = min(model.Size(dimIdx), round(hi));
        if lo < hi
            model.ZoomRange(dimIdx, :) = [lo, hi];
            rangeSliders{dimIdx}.ZoomMin = lo;
            rangeSliders{dimIdx}.ZoomMax = hi;
            doRender();
        end
    end

    function applyPlotZoomLock()
        for ds = 1:nDatasets
            plotWins{ds}.UpdatePos();
        end
    end

    % ------------------------------------------------------------------
    %  Plot-tool button callbacks
    % ------------------------------------------------------------------

    function onPlotAvgToggle(~, ~)
        plotAvgMode = mod(plotAvgMode + 1, 4);
        modeNames = {'1x1 pixel', '3x3 average', '5x5 average', 'Zoom average'};
        btnPlotAvg.Icon    = makePlotAvgIcon(plotAvgMode);
        btnPlotAvg.Tooltip = sprintf('Plot averaging: %s', modeNames{plotAvgMode + 1});
        doRender();
    end

    function onPlotMarkerToggle(src, ~)
        for ds = 1:nDatasets
            plotWins{ds}.SetShowMarker(src.Value);
        end
    end

    function onPlotFixXToggle(src, ~)
        plotFixX = src.Value;
        if plotFixX
            % Snapshot current XLim from first visible axis of first plotWin
            try
                ax1 = plotWins{1}.axes{1};
                if isvalid(ax1) && strcmp(ax1.Visible, 'on')
                    plotFixXLimits = ax1.XLim;
                end
            catch
            end
        end
        for ds = 1:nDatasets
            plotWins{ds}.SetFixX(plotFixX, plotFixXLimits);
        end
    end

    function onPlotFixYToggle(src, ~)
        plotFixY = src.Value;
        if plotFixY
            try
                ax1 = plotWins{1}.axes{1};
                if isvalid(ax1) && strcmp(ax1.Visible, 'on')
                    plotFixYLimits = ax1.YLim;
                end
            catch
            end
        end
        for ds = 1:nDatasets
            plotWins{ds}.SetFixY(plotFixY, plotFixYLimits);
        end
    end

    function onPlotSetXLimits(~, ~)
        answer = inputdlg({'X Min:', 'X Max:'}, 'Set Plot X-axis Limits', 1, ...
            {num2str(plotFixXLimits(1)), num2str(plotFixXLimits(2))});
        if isempty(answer), return; end
        xmin = str2double(answer{1});
        xmax = str2double(answer{2});
        if ~isfinite(xmin) || ~isfinite(xmax) || xmin >= xmax, return; end
        plotFixXLimits = [xmin, xmax];
        plotFixX       = true;
        btnPlotFixX.Value = true;
        for ds = 1:nDatasets
            plotWins{ds}.SetFixX(true, plotFixXLimits);
        end
    end

    function onPlotSetYLimits(~, ~)
        answer = inputdlg({'Y Min:', 'Y Max:'}, 'Set Plot Y-axis Limits', 1, ...
            {num2str(plotFixYLimits(1)), num2str(plotFixYLimits(2))});
        if isempty(answer), return; end
        ymin = str2double(answer{1});
        ymax = str2double(answer{2});
        if ~isfinite(ymin) || ~isfinite(ymax) || ymin >= ymax, return; end
        plotFixYLimits = [ymin, ymax];
        plotFixY       = true;
        btnPlotFixY.Value = true;
        for ds = 1:nDatasets
            plotWins{ds}.SetFixY(true, plotFixYLimits);
        end
    end

    function onPlotExportData(~, ~)
        openPlotExportDialog();
    end

    function openPlotExportDialog()
        ads     = model.ActiveDataset;
        dlgH    = 30 * (nDims + 2) + 80;
        dlg     = uifigure('Name', 'Export Data Subset', ...
            'Position', [200, 200, 380, dlgH], 'Resize', 'off');

        nRows   = nDims + 1 + 1 + 1;   % dim ranges + varname + spacer + buttons
        dlgGrid = uigridlayout(dlg, [nRows, 2]);
        dlgGrid.RowHeight   = [repmat({28}, 1, nDims + 1), {8}, {32}];
        dlgGrid.ColumnWidth = {110, '1x'};
        dlgGrid.Padding     = [10 10 10 10];
        dlgGrid.RowSpacing  = 4;

        rangeFields = cell(1, nDims);
        for d = 1:nDims
            lbl = uilabel(dlgGrid, 'Text', model.DimNames{d}, ...
                'HorizontalAlignment', 'right', 'FontSize', 11);
            lbl.Layout.Row = d;  lbl.Layout.Column = 1;

            defRange = sprintf('%d:%d', model.ZoomRange(d,1), model.ZoomRange(d,2));
            edt = uieditfield(dlgGrid, 'text', 'Value', defRange, 'FontSize', 11);
            edt.Layout.Row = d;  edt.Layout.Column = 2;
            rangeFields{d} = edt;
        end

        lblVar = uilabel(dlgGrid, 'Text', 'Variable name:', ...
            'HorizontalAlignment', 'right', 'FontSize', 11);
        lblVar.Layout.Row = nDims + 1;  lblVar.Layout.Column = 1;
        edtVar = uieditfield(dlgGrid, 'text', 'Value', 'exportedData', 'FontSize', 11);
        edtVar.Layout.Row = nDims + 1;  edtVar.Layout.Column = 2;

        % Spacer: row nDims+2 (height 8)

        btnSub = uigridlayout(dlgGrid, [1, 2]);
        btnSub.Layout.Row = nDims + 3;  btnSub.Layout.Column = [1, 2];
        btnSub.ColumnWidth = {'1x', '1x'};  btnSub.RowHeight = {'1x'};
        btnSub.Padding = [0 0 0 0];  btnSub.ColumnSpacing = 10;

        uibutton(btnSub, 'push', 'Text', 'Export', 'FontSize', 11, ...
            'ButtonPushedFcn', @(~,~) doPlotExport(rangeFields, edtVar, dlg, ads));
        uibutton(btnSub, 'push', 'Text', 'Cancel', 'FontSize', 11, ...
            'ButtonPushedFcn', @(~,~) delete(dlg));

        dlg.Visible = 'on';
    end

    function doPlotExport(rangeFields, edtVar, dlg, dsIdx)
        data = model.Datasets{dsIdx};
        idx  = cell(1, nDims);
        for d = 1:nDims
            rangeStr = strtrim(strrep(rangeFields{d}.Value, 'end', num2str(model.Size(d))));
            try
                result = eval(rangeStr); %#ok<EVLEQ>
                result = round(result(:)');
                result = result(result >= 1 & result <= model.Size(d));
                if isempty(result)
                    uialert(dlg, sprintf('Empty range for "%s".', model.DimNames{d}), 'Export Error');
                    return;
                end
                idx{d} = result;
            catch me
                uialert(dlg, sprintf('Bad range for "%s": %s', model.DimNames{d}, me.message), 'Export Error');
                return;
            end
        end
        varName = strtrim(edtVar.Value);
        if ~isvarname(varName)
            uialert(dlg, 'Invalid variable name.', 'Export Error');
            return;
        end
        try
            exportData = data(idx{:});
            assignin('base', varName, exportData);
            fprintf('[matVis2] Exported %s → workspace variable "%s"\n', ...
                mat2str(size(exportData)), varName);
            delete(dlg);
        catch me
            uialert(dlg, sprintf('Export failed: %s', me.message), 'Export Error');
        end
    end

    function onPlotToggled(dimIdx, show)
        model.PlotDims(dimIdx) = show;
        doRender();
    end

    function onPlayModeChanged(dimIdx, playMode, isPlaying)
        playModes{dimIdx} = playMode;
        for ii = 1:nDims
            if ii ~= dimIdx
                rangeSliders{ii}.SetPlayButtonsEnabled(~isPlaying);
            end
        end
        if isPlaying && ~strcmp(playMode, 'none')
            isPlayingAny = true;
            % Reset framerate measurement for this run and apply current speed
            [playInc, ps] = playSpeedParams();
            playTimeBuf = nan(1, 10);
            playCt      = 0;
            playTic     = tic;
            period      = max(0.001, basePeriod + ps);
            if strcmp(playMode, 'full')
                t = timer('Period', period, 'ExecutionMode', 'fixedRate', ...
                          'TimerFcn', @(~,~) stepPlayFull(dimIdx));
            elseif strcmp(playMode, 'zoom')
                t = timer('Period', period, 'ExecutionMode', 'fixedRate', ...
                          'TimerFcn', @(~,~) stepPlayZoom(dimIdx));
            else
                t = timer('Period', period, 'ExecutionMode', 'fixedRate', ...
                          'TimerFcn', @(~,~) stepPlayShift(dimIdx));
            end
            playTimers{dimIdx} = t;
            start(t);
        else
            t = playTimers{dimIdx};
            if ~isempty(t) && isvalid(t)
                stop(t); delete(t);
            end
            playTimers{dimIdx} = [];
            isPlayingAny = any(cellfun(@(tt) ~isempty(tt) && isvalid(tt), playTimers));
            % Histogram/contrast fields were skipped during playback — refresh once
            if ~isPlayingAny
                lblFrameRate.Text = '';   % clear the framerate readout
                doRender();
            end
        end
    end

    % Map the play-speed setting to a frame increment and an inter-frame pause.
    % The setting is a speed multiplier relative to native playback:
    %   value == 1     -> native: advance one frame per tick, no pause
    %   value  > 1     -> faster: skip frames (advance round(value) frames per tick)
    %   0 < value < 1  -> slower: pause so the tick period becomes basePeriod/value
    function [inc, ps] = playSpeedParams()
        v = 1;
        if exist('edtPlaySpeed', 'var') && ~isempty(edtPlaySpeed) && isvalid(edtPlaySpeed)
            v = edtPlaySpeed.Value;
        end
        if ~(v > 0), v = 1; end          % guard against invalid / non-positive
        if v >= 1
            inc = max(1, round(v)); ps = 0;
        else
            inc = 1;                ps = basePeriod * (1 / v - 1);
        end
    end

    % Re-apply the speed while playing: update the frame increment and, when the
    % pause changed, restart the running timer(s) with the new period.
    function onPlaySpeedChanged()
        [playInc, ps] = playSpeedParams();
        if ~isPlayingAny, return; end
        newPeriod = max(0.001, basePeriod + ps);
        for ii = 1:nDims
            t = playTimers{ii};
            if ~isempty(t) && isvalid(t) && abs(t.Period - newPeriod) > 1e-9
                wasRunning = strcmp(t.Running, 'on');
                stop(t);
                t.Period = newPeriod;
                if wasRunning, start(t); end
            end
        end
        % Cadence changed — restart the framerate estimate so it converges quickly
        playTimeBuf = nan(1, 10);
        playCt      = 0;
        playTic     = tic;
    end

    % Update the framerate readout shown next to the play-speed control, from
    % the tick timestamps.
    function updateFrameRateDisplay()
        playCt = playCt + 1;
        playTimeBuf(mod(playCt - 1, 10) + 1) = toc(playTic);
        d = diff(sort(playTimeBuf));
        if ~any(~isnan(d)), return; end
        fps = 1 / mean(d, 'omitnan');
        [inc, ps] = playSpeedParams();
        if inc > 1
            lblFrameRate.Text = sprintf('%.1f fps  (skip every %d frames)', fps, inc);
        elseif ps > 0
            lblFrameRate.Text = sprintf('%.1f fps  (%.2g s pause)', fps, ps);
        else
            lblFrameRate.Text = sprintf('%.1f fps', fps);
        end
    end

    function stepPlayFull(dimIdx)
        lo  = 1; hi = model.Size(dimIdx);
        nxt = model.CurrPos(dimIdx) + playInc;
        if nxt > hi, nxt = lo; end
        model.CurrPos(dimIdx)      = nxt;
        rangeSliders{dimIdx}.Value = nxt;
        doRender();
        updateFrameRateDisplay();
        drawnow limitrate;
    end

    function stepPlayZoom(dimIdx)
        lo  = model.ZoomRange(dimIdx, 1);
        hi  = model.ZoomRange(dimIdx, 2);
        nxt = model.CurrPos(dimIdx) + playInc;
        if nxt > hi, nxt = lo; end
        model.CurrPos(dimIdx)      = nxt;
        rangeSliders{dimIdx}.Value = nxt;
        doRender();
        updateFrameRateDisplay();
        drawnow limitrate;
    end

    function stepPlayShift(dimIdx)
        lo      = 1; hi = model.Size(dimIdx);
        zWidth  = model.ZoomRange(dimIdx, 2) - model.ZoomRange(dimIdx, 1);
        newZMin = model.ZoomRange(dimIdx, 1) + playInc;
        if newZMin + zWidth > hi, newZMin = lo; end
        newZMax = newZMin + zWidth;
        model.ZoomRange(dimIdx, :)   = [newZMin, newZMax];
        rangeSliders{dimIdx}.ZoomMin = newZMin;
        rangeSliders{dimIdx}.ZoomMax = newZMax;
        model.CurrPos(dimIdx)        = newZMin;
        rangeSliders{dimIdx}.Value   = newZMin;
        doRender();
        updateFrameRateDisplay();
        drawnow limitrate;
    end

    function onZoomFromMouse(xDim, xRange, yDim, yRange)
        model.ZoomRange(xDim, :)   = xRange;
        model.ZoomRange(yDim, :)   = yRange;
        rangeSliders{xDim}.ZoomMin = xRange(1);
        rangeSliders{xDim}.ZoomMax = xRange(2);
        rangeSliders{yDim}.ZoomMin = yRange(1);
        rangeSliders{yDim}.ZoomMax = yRange(2);
        doRender();
    end

    function onPositionFromMouse(xDim, xPos, yDim, yPos)
        model.CurrPos(xDim) = max(1, min(model.Size(xDim), round(xPos)));
        model.CurrPos(yDim) = max(1, min(model.Size(yDim), round(yPos)));
        rangeSliders{xDim}.Value = model.CurrPos(xDim);
        rangeSliders{yDim}.Value = model.CurrPos(yDim);
        doRender();
    end

    % ------------------------------------------------------------------
    %  Contrast UI callbacks
    % ------------------------------------------------------------------
    function onColormapChanged(src)
        idx = find(strcmp(getColormapItems(), src.Value), 1);
        if ~isempty(idx)
            model.ColormapIdx = idx;
            doRender();
        end
    end

    function onContrastModeButtonChanged(mode, src)
        if src.Value
            rbGlobal.Value = strcmp(mode, 'Global');
            rbImage.Value  = strcmp(mode, 'Image');
            rbZoom.Value   = strcmp(mode, 'Zoom');
            rbManual.Value = strcmp(mode, 'Manual');
            model.ContrastMode = mode;
            doRender();
        else
            src.Value = true;
        end
    end

    function onModelContrastModeChanged()
        updateRadioButtons();
        doRender();
    end

    function updateRadioButtons()
        rbGlobal.Value = strcmp(model.ContrastMode, 'Global');
        rbImage.Value  = strcmp(model.ContrastMode, 'Image');
        rbZoom.Value   = strcmp(model.ContrastMode, 'Zoom');
        rbManual.Value = strcmp(model.ContrastMode, 'Manual');
    end

    function onContrastMinChanged(src)
        if strcmp(model.ContrastMode, 'Manual')
            newMin = src.Value;
            if ~model.ContrastLocked
                model.DatasetContrastMins(model.ActiveDataset) = newMin;
                model.ContrastMin = newMin;
                doRender();
            elseif newMin < model.ContrastMax
                model.ContrastMin = newMin;
                doRender();
            else
                src.Value = model.ContrastMin;
            end
        end
    end

    function onContrastMaxChanged(src)
        if strcmp(model.ContrastMode, 'Manual')
            newMax = src.Value;
            if ~model.ContrastLocked
                model.DatasetContrastMaxs(model.ActiveDataset) = newMax;
                model.ContrastMax = newMax;
                doRender();
            elseif newMax > model.ContrastMin
                model.ContrastMax = newMax;
                doRender();
            else
                src.Value = model.ContrastMax;
            end
        end
    end

    function onHistMinChanged(src)
        newMin = src.Value;
        if newMin < edtHistMax.Value && isvalid(histAx)
            histAx.XLim = [newMin, edtHistMax.Value];
            doRender();
        else
            src.Value = histAx.XLim(1);
        end
    end

    function onHistMaxChanged(src)
        newMax = src.Value;
        if newMax > edtHistMin.Value && isvalid(histAx)
            histAx.XLim = [edtHistMin.Value, newMax];
            doRender();
        else
            src.Value = histAx.XLim(2);
        end
    end

    function onGammaEditChanged(src)
        newGamma = src.Value;
        if newGamma >= 0.1 && newGamma <= 5.0
            model.Gamma = newGamma;
            if ~model.ContrastLocked && ~isempty(model.DatasetGammas)
                model.DatasetGammas(model.ActiveDataset) = newGamma;
            end
            doRender();
        else
            src.Value = getGammaForDataset(model.ActiveDataset);
        end
    end

    % ------------------------------------------------------------------
    %  Alpha channel callbacks
    % ------------------------------------------------------------------
    function onAlphaMinChanged(src)
        ads = model.ActiveDataset;
        if src.Value < model.AlphaContrastMaxs(ads)
            model.AlphaContrastMins(ads) = src.Value;
            doRender();
        else
            src.Value = model.AlphaContrastMins(ads);
        end
    end

    function onAlphaMaxChanged(src)
        ads = model.ActiveDataset;
        if src.Value > model.AlphaContrastMins(ads)
            model.AlphaContrastMaxs(ads) = src.Value;
            doRender();
        else
            src.Value = model.AlphaContrastMaxs(ads);
        end
    end

    function onAlphaGammaChanged(src)
        model.AlphaGamma = src.Value;
        doRender();
    end

    function onAlphaBgChanged(src)
        model.AlphaBgWhite = logical(src.Value);
        doRender();
    end

    % ------------------------------------------------------------------
    %  Figure-level mouse handlers (histogram)
    % ------------------------------------------------------------------
    function onFigureButtonDown()
        inHist = isMouseInHistogram();

        if strcmp(fig.SelectionType, 'alt')
            if ~inHist, onMainWindowRightClick(); end
            return;
        end

        if strcmp(fig.SelectionType, 'extend')
            if inHist
                cur = getappdata(fig, 'HistYScale');
                if isempty(cur) || strcmp(cur, 'linear')
                    setappdata(fig, 'HistYScale', 'log');
                else
                    setappdata(fig, 'HistYScale', 'linear');
                end
                doRender();
            else
                % Middle-click outside histogram: start drag-to-move all windows
                startDragMove();
            end
            return;
        end

        if ~inHist || ~strcmp(fig.SelectionType, 'normal'), return; end

        try
            curPt    = histAx.CurrentPoint(1, 1:2);
            xClick   = curPt(1);
            hitZone  = range(histAx.XLim) * 0.05;
            [cmin, cmax] = getCachedBounds();
            isManual = strcmp(model.ContrastMode, 'Manual');

            dragTarget = '';
            if isManual && abs(xClick - cmin) < hitZone
                dragTarget = 'MinLine';
            elseif isManual && abs(xClick - cmax) < hitZone
                dragTarget = 'MaxLine';
            elseif abs(xClick - (cmin + cmax) / 2) < hitZone
                dragTarget = 'GammaCurve';
            end

            if ~isempty(dragTarget)
                setappdata(fig, 'HistogramDragTarget', dragTarget);
                setappdata(fig, 'HistogramDragging', true);
                fig.WindowButtonUpFcn = @(~,~) onHistogramUp();
            end
        catch
        end
    end

    function onFigureMotion()
        if isequal(getappdata(fig, 'DragMoveActive'), true)
            onDragMove();
            return;
        end
        isDragging = getappdata(fig, 'HistogramDragging');
        if isDragging
            onHistogramDrag();
            return;
        end
        if isMouseInHistogram()
            updateHistogramCursor();
            return;
        end
        list = getappdata(fig, 'RS_HoverList');
        if ~isempty(list)
            for k_ = 1:numel(list)
                rs_ = list{k_};
                if isa(rs_, 'function_handle')
                    % External hover provider (e.g. the RGB stretch bar):
                    % returns a Pointer string or '' when not applicable.
                    c_ = rs_();
                elseif ~isempty(rs_) && isvalid(rs_)
                    c_ = rs_.GetHoverCursor();
                else
                    continue;
                end
                if ~isempty(c_)
                    fig.Pointer = c_;
                    return;
                end
            end
        end
        if ~strcmp(fig.Pointer, 'arrow'), fig.Pointer = 'arrow'; end
    end

    function onHistogramDrag()
        if ~isvalid(histAx), return; end
        dragTarget = getappdata(fig, 'HistogramDragTarget');
        if isempty(dragTarget), return; end
        try
            ads      = model.ActiveDataset;
            dmin_ads = model.AllDataMins(ads);
            dmax_ads = model.AllDataMaxs(ads);
            curPt = histAx.CurrentPoint(1, 1:2);
            xDrag = max(min(curPt(1), dmax_ads), dmin_ads);
            switch dragTarget
                case 'MinLine'
                    if strcmp(model.ContrastMode, 'Manual') && xDrag < model.ContrastMax
                        model.ContrastMin    = xDrag;
                        edtContrastMin.Value = xDrag;
                        doRender();
                    end
                case 'MaxLine'
                    if strcmp(model.ContrastMode, 'Manual') && xDrag > model.ContrastMin
                        model.ContrastMax    = xDrag;
                        edtContrastMax.Value = xDrag;
                        doRender();
                    end
                case 'GammaCurve'
                    yMax_ = histAx.YLim(2);
                    if yMax_ > 0
                        normY    = max(0.002, min(0.998, curPt(2) / yMax_));
                        newGamma = max(0.1, min(5.0, log(normY) / log(0.5)));
                        if abs(getGammaForDataset(model.ActiveDataset) - newGamma) > 0.005
                            model.Gamma = newGamma;
                            if ~model.ContrastLocked && ~isempty(model.DatasetGammas)
                                model.DatasetGammas(model.ActiveDataset) = newGamma;
                            end
                            edtGamma.Value = newGamma;
                            doRender();
                        end
                    end
            end
        catch
        end
    end

    function onHistogramUp()
        setappdata(fig, 'HistogramDragging', false);
        setappdata(fig, 'HistogramDragTarget', '');
        fig.WindowButtonUpFcn = '';
    end

    % ------------------------------------------------------------------
    %  Middle-mouse drag to move all windows together
    % ------------------------------------------------------------------
    function startDragMove()
        % Use get(0,'PointerLocation') for stable absolute screen coords.
        % fig.CurrentPoint + fig.Position would shift each frame as the
        % window moves, causing jumps.
        p1 = get(0, 'PointerLocation');

        snapMain  = fig.Position;
        snapImage = cellfun(@(w) w.fig.Position, imageWins, 'UniformOutput', false);
        snapZoom  = cellfun(@(w) w.fig.Position, zoomWins,  'UniformOutput', false);
        snapPlot  = cellfun(@(w) w.fig.Position, plotWins,  'UniformOutput', false);
        if ~isempty(roiMgr) && isvalid(roiMgr.fig)
            snapRoi = roiMgr.fig.Position;
        else
            snapRoi = [];
        end

        % Load the .NET assembly used by mouseButtonsDown() once, here (off
        % the per-frame motion path).  Harmless / no-op on non-Windows.
        try; NET.addAssembly('System.Windows.Forms'); catch; end

        setappdata(fig, 'DragMoveActive',    true);
        setappdata(fig, 'DragMoveP1',        p1);
        setappdata(fig, 'DragMoveSnapMain',  snapMain);
        setappdata(fig, 'DragMoveSnapImage', snapImage);
        setappdata(fig, 'DragMoveSnapZoom',  snapZoom);
        setappdata(fig, 'DragMoveSnapPlot',  snapPlot);
        setappdata(fig, 'DragMoveSnapRoi',   snapRoi);

        fig.Pointer = 'fleur';
        fig.WindowButtonUpFcn = @(~,~) stopDragMove();
    end

    function onDragMove()
        if ~isequal(getappdata(fig, 'DragMoveActive'), true), return; end

        % Safety net: a uifigure can drop the button-up event when the window
        % is repositioned mid-drag, leaving the move mode "stuck".  If the OS
        % reports no mouse button pressed, exit immediately.
        if ~mouseButtonsDown()
            stopDragMove();
            return;
        end

        p1    = getappdata(fig, 'DragMoveP1');
        p2    = get(0, 'PointerLocation');
        delta = p2 - p1;

        snap = getappdata(fig, 'DragMoveSnapMain');
        fig.Position(1:2) = snap(1:2) + delta;

        snapImage = getappdata(fig, 'DragMoveSnapImage');
        snapZoom  = getappdata(fig, 'DragMoveSnapZoom');
        snapPlot  = getappdata(fig, 'DragMoveSnapPlot');
        for ds = 1:nDatasets
            imageWins{ds}.fig.Position(1:2) = snapImage{ds}(1:2) + delta;
            zoomWins{ds}.fig.Position(1:2)  = snapZoom{ds}(1:2)  + delta;
            plotWins{ds}.fig.Position(1:2)  = snapPlot{ds}(1:2)  + delta;
        end

        snapRoi = getappdata(fig, 'DragMoveSnapRoi');
        if ~isempty(snapRoi) && ~isempty(roiMgr) && isvalid(roiMgr.fig)
            roiMgr.fig.Position(1:2) = snapRoi(1:2) + delta;
        end
    end

    function stopDragMove()
        setappdata(fig, 'DragMoveActive', false);
        fig.Pointer = 'arrow';
        fig.WindowButtonUpFcn = '';
    end

    function tf = mouseButtonsDown()
        % True if any mouse button is currently pressed (queried at OS level).
        % Used so the middle-drag window-move can't get stuck if the figure
        % drops the button-up event.  Windows-only via .NET; defaults to true
        % elsewhere so behaviour falls back to WindowButtonUpFcn as before.
        tf = true;
        try
            tf = double(System.Windows.Forms.Control.MouseButtons) ~= 0;
        catch
            tf = true;
        end
    end

    function tf = isMouseInHistogram()
        tf = false;
        try
            % Pixel-based guard first: a UIAxes' CurrentPoint keeps
            % extrapolating through the axes' own data<->pixel map even when
            % the mouse is nowhere near it on screen, so an XLim/YLim check
            % alone can false-positive for cursor positions elsewhere in the
            % window (e.g. over a RangeSlider track) and silently swallow
            % that widget's hover-cursor update (see the identical guard in
            % RangeSlider.getHoverCursor_).
            figPt = fig.CurrentPoint;
            axPos = getpixelposition(histAx, true);
            xRel  = figPt(1) - axPos(1);
            yRel  = figPt(2) - axPos(2);
            if xRel < 0 || xRel > axPos(3) || yRel < 0 || yRel > axPos(4)
                return;
            end
            cp = histAx.CurrentPoint(1, 1:2);
            xl = histAx.XLim; yl = histAx.YLim;
            tf = cp(1) >= xl(1) && cp(1) <= xl(2) && cp(2) >= yl(1) && cp(2) <= yl(2);
        catch
            tf = false;
        end
    end

    function updateHistogramCursor()
        try
            if ~isMouseInHistogram()
                if ~strcmp(fig.Pointer, 'arrow'), fig.Pointer = 'arrow'; end
                return;
            end
            curPt    = histAx.CurrentPoint(1, 1:2);
            xl       = histAx.XLim; yl = histAx.YLim;
            hitZone  = range(xl) * 0.05;
            [cmin, cmax] = getCachedBounds();
            isManual = strcmp(model.ContrastMode, 'Manual');

            if isManual && (abs(curPt(1)-cmin) < hitZone || abs(curPt(1)-cmax) < hitZone)
                fig.Pointer = 'custom';
                fig.PointerShapeCData   = getappdata(fig, 'CursorLR');
                fig.PointerShapeHotSpot = [8, 8];
            elseif abs(curPt(1) - (cmin+cmax)/2) < hitZone
                yDot = 0.5^model.Gamma * yl(2);
                if abs(curPt(2) - yDot) < yl(2) * 0.12
                    fig.Pointer = 'custom';
                    fig.PointerShapeCData   = getappdata(fig, 'CursorUD');
                    fig.PointerShapeHotSpot = [8, 8];
                else
                    if ~strcmp(fig.Pointer,'arrow'), fig.Pointer = 'arrow'; end
                end
            else
                if ~strcmp(fig.Pointer,'arrow'), fig.Pointer = 'arrow'; end
            end
        catch
            try; fig.Pointer = 'arrow'; catch; end
        end
    end

    % ------------------------------------------------------------------
    %  Window visibility / overlay
    % ------------------------------------------------------------------
    function setOverlay(tf)
        setappdata(fig, 'OverlayVisible', tf);
        for ds = 1:nDatasets
            imageWins{ds}.SetOverlayVisible(tf);
            zoomWins{ds}.SetOverlayVisible(tf);
        end
    end

    function toggleAllWindows(wins, isVisible)
        for k = 1:numel(wins)
            if isVisible
                wins{k}.fig.Visible = 'on';
            else
                wins{k}.fig.Visible = 'off';
            end
        end
    end

    % ------------------------------------------------------------------
    %  ROI Manager wiring
    % ------------------------------------------------------------------
    function rm = getRoiMgr()
        % Lazy creation of the ROI manager window.
        if isempty(roiMgr) || ~isvalid(roiMgr.fig)
            roiMgr = MatVisRoiWin(model, roiCbs);
            if ~isempty(roiMgrDefaultPos)
                roiMgr.fig.Position(1:2) = roiMgrDefaultPos;
            end
        end
        rm = roiMgr;
    end

    function toggleRoiWindow(isVisible)
        if isVisible
            rm = getRoiMgr();
            rm.fig.Visible = 'on';
            figure(rm.fig);
        elseif ~isempty(roiMgr) && isvalid(roiMgr.fig)
            roiMgr.fig.Visible = 'off';
            setRoiModeAllWins('', []);
        end
    end

    function setRoiModeAllWins(mode, modeCb)
        for ds = 1:nDatasets
            try; imageWins{ds}.SetRoiMode(mode, modeCb); catch; end
            try; zoomWins{ds}.SetRoiMode(mode, modeCb);  catch; end
        end
    end

    function deactivateRoiTools()
        if ~isempty(roiMgr) && isvalid(roiMgr.fig)
            try; roiMgr.DeactivateTools(); catch; end
        end
    end

    function deactivateProfileTools()
        if ~isempty(profMgr) && isvalid(profMgr.fig)
            try; profMgr.DeactivateTools(); catch; end
        end
    end

    % ------------------------------------------------------------------
    %  Profile Manager wiring
    % ------------------------------------------------------------------
    function pm = getProfileMgr()
        if isempty(profMgr) || ~isvalid(profMgr.fig)
            profMgr = MatVisProfileWin(model, profCbs);
            if ~isempty(profMgrDefaultPos)
                profMgr.fig.Position(1:2) = profMgrDefaultPos;
            end
        end
        pm = profMgr;
    end

    function toggleProfileWindow(isVisible)
        if isVisible
            pm = getProfileMgr();
            pm.fig.Visible = 'on';
            figure(pm.fig);
        elseif ~isempty(profMgr) && isvalid(profMgr.fig)
            profMgr.fig.Visible = 'off';
            setRoiModeAllWins('', []);
        end
    end

    % ------------------------------------------------------------------
    %  Metadata window wiring
    % ------------------------------------------------------------------
    function mw2 = getMetadataWin()
        if isempty(metadataWin) || ~isvalid(metadataWin.fig)
            metadataWin = MatVisMetadataWin(model, metadataCbs);
            if ~isempty(metadataWinDefaultPos)
                metadataWin.fig.Position(1:2) = metadataWinDefaultPos;
            end
        end
        mw2 = metadataWin;
    end

    function toggleMetadataWindow(isVisible)
        if isVisible
            mw2 = getMetadataWin();
            mw2.Refresh();
            mw2.fig.Visible = 'on';
            figure(mw2.fig);
        elseif ~isempty(metadataWin) && isvalid(metadataWin.fig)
            metadataWin.fig.Visible = 'off';
        end
    end

    function applyRoiPosition(pos, zoomVal)
        % Jump navigation state to an ROI's stored position/zoom and sync sliders.
        if numel(pos) == nDims
            model.CurrPos = pos;
        end
        if isequal(size(zoomVal), [nDims, 2])
            model.ZoomRange = zoomVal;
        end
        for d = 1:nDims
            rangeSliders{d}.Value   = model.CurrPos(d);
            rangeSliders{d}.ZoomMin = model.ZoomRange(d, 1);
            rangeSliders{d}.ZoomMax = model.ZoomRange(d, 2);
        end
        doRender();
    end

    % ------------------------------------------------------------------
    %  Config save / load
    % ------------------------------------------------------------------
    function onSaveConfig()
        configPath = matVisConfig('GetConfigPath');
        imgFigs  = cellfun(@(w) w.fig, imageWins, 'UniformOutput', false);
        zoomFigs = cellfun(@(w) w.fig, zoomWins,  'UniformOutput', false);
        plotFigs = cellfun(@(w) w.fig, plotWins,  'UniformOutput', false);
        matVisConfig('SaveConfig', model, fig, imgFigs, zoomFigs, plotFigs, configPath);
        fprintf('Configuration saved to: %s\n', configPath);
    end

    function onLoadConfig()
        configPath = matVisConfig('GetConfigPath');
        config     = matVisConfig('LoadConfig', configPath);

        if isempty(config) || ~isstruct(config) || isempty(fieldnames(config))
            fprintf('No config file found at: %s\n', configPath);
            return;
        end

        if isfield(config, 'colormapIdx') && config.colormapIdx > 0
            model.ColormapIdx = config.colormapIdx;
            items = getColormapItems();
            if config.colormapIdx <= numel(items)
                dropColormap.Value = items{config.colormapIdx};
            end
        end

        if isfield(config, 'gamma')
            model.Gamma    = config.gamma;
            edtGamma.Value = config.gamma;
        end

        if isfield(config, 'contrastMode')
            model.ContrastMode = config.contrastMode;
            updateRadioButtons();
        end

        if isfield(config, 'contrastLocked')
            model.ContrastLocked = logical(config.contrastLocked);
            btnLock.Value = model.ContrastLocked;
            btnLock.Text  = lockIcon(model.ContrastLocked);
        end

        if isfield(config, 'datasetContrastMins') && ...
           numel(config.datasetContrastMins) == nDatasets
            model.DatasetContrastMins = config.datasetContrastMins;
        end
        if isfield(config, 'datasetContrastMaxs') && ...
           numel(config.datasetContrastMaxs) == nDatasets
            model.DatasetContrastMaxs = config.datasetContrastMaxs;
        end
        if isfield(config, 'datasetGammas') && ...
           numel(config.datasetGammas) == nDatasets
            model.DatasetGammas = config.datasetGammas;
            edtGamma.Value = getGammaForDataset(model.ActiveDataset);
        end

        if isfield(config, 'contrastMin') && isfield(config, 'contrastMax') && ...
           strcmp(model.ContrastMode, 'Manual')
            model.ContrastMin = config.contrastMin;
            model.ContrastMax = config.contrastMax;
        end

        if withAlpha
            if isfield(config, 'alphaContrastMins') && ...
               numel(config.alphaContrastMins) == nDatasets
                model.AlphaContrastMins = config.alphaContrastMins;
            end
            if isfield(config, 'alphaContrastMaxs') && ...
               numel(config.alphaContrastMaxs) == nDatasets
                model.AlphaContrastMaxs = config.alphaContrastMaxs;
            end
            if isfield(config, 'alphaGamma')
                model.AlphaGamma = config.alphaGamma;
            end
            if isfield(config, 'alphaBgWhite')
                model.AlphaBgWhite = logical(config.alphaBgWhite);
                btnAlphaBg.Value   = model.AlphaBgWhite;
            end
        end

        % Image/zoom axes display state (aspect ratio + window scale)
        if isfield(config, 'aspectRatioFixed')
            model.AspectRatioFixed = logical(config.aspectRatioFixed);
        end
        if isfield(config, 'aspectRatio') && numel(config.aspectRatio) == 2
            model.AspectRatio = config.aspectRatio(:)';
        end
        if isfield(config, 'winScalePct') && isfinite(config.winScalePct) && config.winScalePct > 0
            model.WinScalePct = config.winScalePct;
        end
        dimSelector.Update();   % refresh aspect/win-scale button captions
        applyAspectRatio();     % window-scale is applied only on explicit click

        % Window positions (support per-dataset keys and legacy single keys).
        % Saved positions come from a prior session's screen/monitor layout
        % and are clamped back on-screen (clampFigPosToScreen) so a config
        % saved on a different display never reopens fully off-screen.
        %
        % get(0,'MonitorPositions') is not portable across MATLAB releases on
        % the same machine (older releases can under-detect monitors or
        % report a display's resolution differently under Windows
        % per-monitor-DPI-awareness than newer ones, even on identical
        % hardware), and the config file is shared by hostname, not MATLAB
        % version. Applying saved absolute pixel coordinates computed under a
        % different monitor layout can land windows in nonsensical places, so
        % only trust them when the current session's monitor layout matches
        % the one they were saved under; otherwise fall back to a fresh
        % layout for this session's actual monitors.
        monitorsMatch = isfield(config, 'monitorPositions') && ...
            isequal(config.monitorPositions, get(0, 'MonitorPositions'));
        if isfield(config, 'windowPositions') && monitorsMatch
            pos = config.windowPositions;
            if isfield(pos, 'Main')
                mainP = clampFigPosToScreen([pos.Main(1:2), fig.Position(3:4)]);
                fig.Position(1:2) = mainP(1:2);
            end

            for ds = 1:nDatasets
                dsKey = num2str(ds);
                if isfield(pos, ['Image' dsKey])
                    imageWins{ds}.fig.Position = clampFigPosToScreen(pos.(['Image' dsKey]));
                elseif ds == 1 && isfield(pos, 'Image')
                    imageWins{ds}.fig.Position = clampFigPosToScreen(pos.Image);
                end
                if isfield(pos, ['Zoom' dsKey])
                    zoomWins{ds}.fig.Position = clampFigPosToScreen(pos.(['Zoom' dsKey]));
                elseif ds == 1 && isfield(pos, 'Zoom')
                    zoomWins{ds}.fig.Position = clampFigPosToScreen(pos.Zoom);
                end
                if isfield(pos, ['Plot' dsKey])
                    plotWins{ds}.fig.Position = clampFigPosToScreen(pos.(['Plot' dsKey]));
                elseif ds == 1 && isfield(pos, 'Plot')
                    plotWins{ds}.fig.Position = clampFigPosToScreen(pos.Plot);
                end
            end
        elseif isfield(config, 'windowPositions')
            fprintf(['[matVis2] Saved window positions were recorded under a different ' ...
                'monitor layout (e.g. a different MATLAB release''s display detection, ' ...
                'or a monitor added/removed/rearranged since); using a fresh layout for ' ...
                'this session''s displays instead.\n']);
            applyFreshLayout();
        end

        % Window visibility
        if isfield(config, 'windowVisibility')
            vis = config.windowVisibility;
            if isfield(vis, 'Overlay')
                btnOverlay.Value = vis.Overlay;
                setOverlay(vis.Overlay);
            end

            anyImg = false; anyZoom = false; anyPlot = false;
            for ds = 1:nDatasets
                dsKey = num2str(ds);
                imgVis = getVisBool(vis, ['Image' dsKey], ds, 'Image', true);
                zomVis = getVisBool(vis, ['Zoom'  dsKey], ds, 'Zoom',  true);
                pltVis = getVisBool(vis, ['Plot'  dsKey], ds, 'Plot',  true);
                if imgVis, imageWins{ds}.fig.Visible = 'on'; else, imageWins{ds}.fig.Visible = 'off'; end
                if zomVis, zoomWins{ds}.fig.Visible  = 'on'; else, zoomWins{ds}.fig.Visible  = 'off'; end
                if pltVis, plotWins{ds}.fig.Visible  = 'on'; else, plotWins{ds}.fig.Visible  = 'off'; end
                anyImg  = anyImg  || imgVis;
                anyZoom = anyZoom || zomVis;
                anyPlot = anyPlot || pltVis;
            end
            btnToggleImage.Value = anyImg;
            btnToggleZoom.Value  = anyZoom;
            btnTogglePlot.Value  = anyPlot;
        end

        fprintf('Configuration loaded from: %s\n', configPath);
        doRender();
    end

    function onWindowShown()
        if ~isempty(fig.UserData) && fig.UserData == 1, return; end
        fig.UserData = 1;

        configPath = matVisConfig('GetConfigPath');
        if isfile(configPath)
            onLoadConfig();
        else
            applyFreshLayout();
        end

        fig.Visible = 'on';
        for ds = 1:nDatasets
            if btnToggleImage.Value, imageWins{ds}.fig.Visible = 'on'; end
            if btnToggleZoom.Value,  zoomWins{ds}.fig.Visible  = 'on'; end
            if btnTogglePlot.Value,  plotWins{ds}.fig.Visible  = 'on'; end
        end
    end

    function applyFreshLayout()
        % Tile Main/Image/Zoom/Plot (and remember ROI/Profile/Metadata
        % default positions) from scratch for this session's actual
        % monitors -- used both when no saved config exists yet, and when a
        % saved config's window positions don't apply (see onLoadConfig:
        % monitor layout mismatch across MATLAB releases/monitor changes).
        %
        % Anchor to the monitor the user is actually working on (the one
        % under the mouse pointer), not always the OS-designated primary
        % display -- get(0,'ScreenSize') is primary-only and, on a
        % multi-monitor setup where MATLAB lives on a secondary/tertiary
        % display, would otherwise place every fresh layout on a monitor
        % the user isn't looking at.
        targetMon  = targetMonitorBounds();
        monL       = targetMon(1);
        monB       = targetMon(2);
        screenH    = targetMon(4);
        gap        = 10;

        % uifigure.Position is the inner (client) area; the title bar
        % sits ABOVE Position and adds ~32 px to the outer height.
        % We account for this so windows stay on screen and don't overlap.
        titleBarH = 32;   % typical Windows 11 title bar (OuterPosition unsupported)
        safeMargin = 8;   % gap between title bar top and screen edge

        % Sub-window inner tops are set from screenH directly so they
        % never depend on how tall the main GUI is.
        % outer top = inner top + titleBarH = screenH - safeMargin  →
        % inner top = screenH - safeMargin - titleBarH
        winInnerTop = monB + screenH - safeMargin - titleBarH;

        % Main GUI: place its top at the same reference level. A dataset
        % with more navigation dimensions (e.g. an OME/Bio-Formats file
        % with both a Z-stack and multiple channels, each getting its own
        % slider row) makes this window taller; clamp so its bottom row
        % (Save/Load Config, window toggles) can never end up below the
        % target monitor's bottom edge even when the window no longer
        % fits top-to-bottom.
        mainPos    = fig.Position;
        mainPos(1) = monL + 50;
        mainPos(2) = max(monB, winInnerTop - mainPos(4));   % inner bottom
        fig.Position = mainPos;
        % Use mainPos as-is — no drawnow re-read, which can let the OS
        % reposition the figure to an unexpected location before we read it.
        leftX = mainPos(1) + mainPos(3) + gap;

        if nDatasets == 1
            % ── Single dataset ──────────────────────────────────────────
            % Image and zoom: identical squares side by side.
            % Plot: below both, width = image+gap+zoom.
            sqSz = 460;
            pltH = 280;
            pltW = sqSz + gap + sqSz;
            topY = winInnerTop - sqSz;   % inner bottom of image/zoom

            imageWins{1}.fig.Position = [leftX,          topY, sqSz, sqSz];
            zoomWins{1}.fig.Position  = [leftX+sqSz+gap, topY, sqSz, sqSz];

            % Plot outer top must clear image inner bottom (topY):
            %   plot outer top = plot inner top + titleBarH
            %                 = (topY - gap - titleBarH - pltH + pltH) + titleBarH
            %                 = topY - gap   ← gap pixels below image inner bottom ✓
            plotWins{1}.fig.Position  = [leftX, topY - gap - titleBarH - pltH, pltW, pltH];
        else
            % ── Multiple datasets ────────────────────────────────────────
            % Each row: image (square) | zoom (square) | plot (2:1), same height.
            rowH = 360;
            pltW = rowH * 2;

            for ds = 1:nDatasets
                % Row outer top = winInnerTop + titleBarH for ds=1,
                % then shifted down by (rowH + titleBarH + gap) per dataset.
                rowInnerBot = winInnerTop - rowH - (ds-1) * (rowH + titleBarH + gap);
                imageWins{ds}.fig.Position = [leftX,                    rowInnerBot, rowH, rowH];
                zoomWins{ds}.fig.Position  = [leftX+rowH+gap,           rowInnerBot, rowH, rowH];
                plotWins{ds}.fig.Position  = [leftX+rowH+gap+rowH+gap,  rowInnerBot, pltW, rowH];
            end
        end

        % ROI Manager (created lazily): remember its default position.
        % Offsets are relative to the target monitor's bottom edge (monB),
        % not absolute screen Y -- a monitor whose bottom isn't at y=0
        % (e.g. one offset above/below the primary in a multi-monitor
        % arrangement) would otherwise place these off that monitor entirely.
        roiMgrDefaultPos = [leftX, monB + 60];
        if ~isempty(roiMgr) && isvalid(roiMgr.fig)
            roiMgr.fig.Position(1:2) = roiMgrDefaultPos;
        end

        % Profile Manager (created lazily): offset from the ROI manager
        profMgrDefaultPos = [leftX + 60, monB + 40];
        if ~isempty(profMgr) && isvalid(profMgr.fig)
            profMgr.fig.Position(1:2) = profMgrDefaultPos;
        end

        % Metadata window (created lazily): offset from the Profile Manager
        metadataWinDefaultPos = [leftX + 120, monB + 20];
        if ~isempty(metadataWin) && isvalid(metadataWin.fig)
            metadataWin.fig.Position(1:2) = metadataWinDefaultPos;
        end
    end

    function pos = clampFigPosToScreen(pos)
        % Nudge a [x y w h] figure Position back on-screen ONLY if it isn't
        % usably visible (>= minVisible px in both axes) on ANY currently
        % connected monitor. get(0,'ScreenSize') covers just the primary
        % monitor, so clamping against it unconditionally used to drag every
        % window intentionally placed on a secondary/tertiary display back
        % onto the primary one on every restore -- a regression for
        % multi-monitor setups. A window already usable on some monitor
        % (including a non-primary one) is left exactly where it was.
        minVisible = 100;
        mp = get(0, 'MonitorPositions');   % Nx4: [left bottom width height], y-up
        for i = 1:size(mp, 1)
            monL = mp(i,1); monB = mp(i,2);
            monR = monL + mp(i,3);  monT = monB + mp(i,4);
            visW = min(pos(1) + pos(3), monR) - max(pos(1), monL);
            visH = min(pos(2) + pos(4), monT) - max(pos(2), monB);
            if visW >= minVisible && visH >= minVisible
                return;   % already usably visible on this monitor
            end
        end

        % Not usably visible on any monitor (e.g. a config saved on a
        % different machine/monitor arrangement) -- fall back to the monitor
        % under the mouse pointer.
        mon        = targetMonitorBounds();
        titleBarH  = 32;   % see onWindowShown
        safeMargin = 8;
        pos(1) = min(max(pos(1), mon(1)), mon(1) + mon(3) - minVisible);
        pos(2) = min(pos(2), mon(2) + mon(4) - safeMargin - titleBarH - pos(4));
        pos(2) = max(pos(2), mon(2) + safeMargin - pos(4) + minVisible);
    end

    function mon = targetMonitorBounds()
        % [left bottom width height] (MATLAB y-up convention, see
        % MonitorPositions) of the monitor currently under the mouse pointer
        % -- i.e. wherever the user is actually working -- falling back to
        % the primary monitor if the pointer isn't within any monitor's
        % bounds (shouldn't normally happen).
        mp = get(0, 'MonitorPositions');
        p  = get(0, 'PointerLocation');
        for i = 1:size(mp, 1)
            monL = mp(i,1); monB = mp(i,2);
            monR = monL + mp(i,3);  monT = monB + mp(i,4);
            if p(1) >= monL && p(1) < monR && p(2) >= monB && p(2) < monT
                mon = mp(i,:);
                return;
            end
        end
        mon = get(0, 'ScreenSize');
    end

    % ---- Aspect ratio & window scaling -------------------------------------
    function txt = aspectButtonText()
        if model.AspectRatioFixed
            r   = model.AspectRatio;
            txt = sprintf('%g:%g', r(1), r(2));
        else
            txt = 'fill';
        end
    end

    function applyAspectRatio()
        % Push the current aspect-ratio state onto every image/zoom axes.
        for ds = 1:nDatasets
            try, imageWins{ds}.SetAspectRatio(model.AspectRatioFixed, model.AspectRatio); catch; end
            try, zoomWins{ds}.SetAspectRatio(model.AspectRatioFixed, model.AspectRatio);  catch; end
        end
    end

    function onAspectToggle()
        % Left click: toggle between fixed aspect ratio and fill.
        model.AspectRatioFixed   = logical(dimSelector.btnAspect.Value);
        dimSelector.btnAspect.Text = aspectButtonText();
        applyAspectRatio();
    end

    function onAspectSetRatio()
        % Right click: prompt for a custom [x y] ratio and switch to fixed.
        r      = model.AspectRatio;
        answer = inputdlg('Aspect ratio [x y]:', 'Set Aspect Ratio', 1, ...
            {sprintf('%g %g', r(1), r(2))});
        if isempty(answer), return; end
        v = str2num(answer{1}); %#ok<ST2NM>
        if numel(v) ~= 2 || any(~isfinite(v)) || any(v <= 0), return; end
        model.AspectRatio        = v(:)';
        model.AspectRatioFixed   = true;
        dimSelector.btnAspect.Value = true;
        dimSelector.btnAspect.Text  = aspectButtonText();
        applyAspectRatio();
    end

    function applyWindowScale()
        % Resize every zoom window so the current zoom region is shown at
        % WinScalePct % (100 % ≈ one data pixel per screen pixel). The
        % top-left corner of each window is kept fixed.
        xd   = model.XDim;  yd = model.YDim;
        zwPx = diff(model.ZoomRange(xd, :)) + 1;   % zoom width  in data px
        zhPx = diff(model.ZoomRange(yd, :)) + 1;   % zoom height in data px
        if zwPx <= 0 || zhPx <= 0, return; end

        scale = model.WinScalePct / 100;
        ss    = get(0, 'ScreenSize');
        maxW  = ss(3) - 20;  maxH = ss(4) - 80;
        tW    = zwPx * scale;  tH = zhPx * scale;
        if tW > maxW || tH > maxH
            model.WinScalePct = max(1, floor(model.WinScalePct * min(maxW/tW, maxH/tH)));
            scale = model.WinScalePct / 100;
        end
        tW = max(50, round(zwPx * scale));
        tH = max(50, round(zhPx * scale));

        for ds = 1:nDatasets
            zf = zoomWins{ds}.fig;
            if ~isvalid(zf), continue; end
            p   = zf.Position;
            top = p(2) + p(4);                 % keep top edge fixed
            zf.Position = [p(1), max(0, top - tH), tW, tH];
        end
        dimSelector.btnWinScale.Text = sprintf('%d%%', round(model.WinScalePct));
    end

    function onWinScaleSet()
        % Right click: prompt for the scaling factor, then apply it.
        answer = inputdlg('Window scaling factor [%]:', 'Window Scale', 1, ...
            {num2str(round(model.WinScalePct))});
        if isempty(answer), return; end
        v = str2double(answer{1});
        if ~isfinite(v) || v <= 0, return; end
        model.WinScalePct = v;
        applyWindowScale();
    end

end % MatVisMainWindow

% =========================================================================
%  Module-level helper functions
% =========================================================================

function s = lockIcon(locked)
% Returns lock emoji: closed (linked) or open (independent).
if locked
    s = char(128274);   % 🔒
else
    s = char(128275);   % 🔓
end
end

function label = getDimLabel(model, dimIdx)
    if ~isempty(model.DimNames) && numel(model.DimNames) >= dimIdx
        label = model.DimNames{dimIdx};
    else
        label = sprintf('Dim%d', dimIdx);
    end
end

function v = getVisBool(vis, key, ds, legacyKey, defaultVal)
    % Look up visibility boolean from config struct with legacy key fallback.
    if isfield(vis, key)
        v = logical(vis.(key));
    elseif ds == 1 && isfield(vis, legacyKey)
        v = logical(vis.(legacyKey));
    else
        v = defaultVal;
    end
end

function cdata = makeHistCursor(type)
cdata = NaN(16, 16);
switch type
    case 'lr'
        cdata(6,  [4, 13])          = 1;
        cdata(7,  [3, 4, 13, 14])   = 1;
        cdata(8,  2:15)             = 1;
        cdata(9,  2:15)             = 1;
        cdata(10, [3, 4, 13, 14])   = 1;
        cdata(11, [4, 13])          = 1;
    case 'ud'
        cdata(2,  8)      = 1;
        cdata(3,  7:9)    = 1;
        cdata(4,  6:10)   = 1;
        cdata(5,  7:9)    = 1;
        cdata(6:11, 8)    = 1;
        cdata(12, 7:9)    = 1;
        cdata(13, 6:10)   = 1;
        cdata(14, 7:9)    = 1;
        cdata(15, 8)      = 1;
end
end

function items = getColormapItems()
    items = {
        'gray', 'Gray(Range)', '4x Gray', 'turbo', 'parula', 'jet', 'hsv', 'hot', 'cool', ...
        'Red1', 'Green1', 'Blue1', 'Cyan1', 'Magenta1', 'Yellow1', ...
        'Red2', 'Green2', 'Blue2', 'Cyan2', 'Magenta2', 'Yellow2', ...
        'Rainbow1', 'Rainbow2', 'Rainbow3', 'Rainbow4', 'Rainbow5', 'Rainbow6', ...
        'BlueGrayYellow', 'BlueGrayRed', 'GreenGrayRed', 'MagentaGrayGreen'
    };
end

function cdata = makePlotAvgIcon(mode)
% Build a 29×29 double RGB icon [0,1] showing the 5×5 averaging kernel.
%   mode 0 → only center pixel blue   (1×1)
%   mode 1 → center 3×3 blue          (3×3)
%   mode 2 → all 25 cells blue        (5×5)
%   mode 3 → all 25 cells green       (zoom)
%   The zoom mode also draws a red square outline (mirroring the red
%   zoom-crop indicator in the image window) so it is easy to recognise.
cellSz = 5;  gap = 1;  nC = 5;
sz = nC * cellSz + (nC - 1) * gap;   % 29

bgCol  = [0.82 0.82 0.82];
hiCol  = [0.18 0.52 0.88];
gapCol = [0.55 0.55 0.55];

cdata = zeros(sz, sz, 3);
for c = 1:3, cdata(:,:,c) = gapCol(c); end

for row = 1:nC
    for col = 1:nC
        r0 = (row-1)*(cellSz+gap)+1;  r1 = r0+cellSz-1;
        c0 = (col-1)*(cellSz+gap)+1;  c1 = c0+cellSz-1;
        dr = row-3;  dc = col-3;
        switch mode
            case 0,  active = (dr==0 && dc==0);           % 1x1
            case 1,  active = (abs(dr)<=1 && abs(dc)<=1); % 3x3
            case 2,  active = true;                        % 5x5
            case 3,  active = true;                        % zoom
            otherwise, active = (dr==0 && dc==0);
        end
        if active
            for c = 1:3, cdata(r0:r1,c0:c1,c) = hiCol(c); end
        else
            for c = 1:3, cdata(r0:r1,c0:c1,c) = bgCol(c); end
        end
    end
end

% Zoom mode: overlay a red square outline, like the image-window crop rect.
if mode == 3
    rc = [0.85 0.10 0.10];  bw = 3;
    for c = 1:3
        cdata(1:bw,         :, c)        = rc(c);
        cdata(end-bw+1:end, :, c)        = rc(c);
        cdata(:, 1:bw,         c)        = rc(c);
        cdata(:, end-bw+1:end, c)        = rc(c);
    end
end
end

function cdata = makeMarkerIcon()
% Icon for the "show point markers" toggle: a horizontal line with a filled
% dot at its centre (a line plot carrying a marker).
sz = 20;  bg = 0.94;  fg = 0.12;
cdata = repmat(bg, sz, sz, 3);
mid   = (sz + 1) / 2;
[X, Y] = meshgrid(1:sz, 1:sz);
lineMask = abs(Y - mid) <= 0.6 & X >= 2 & X <= sz - 1;   % 1-2 px line
dotMask  = (X - mid).^2 + (Y - mid).^2 <= 3.3^2;          % centred dot
mask     = lineMask | dotMask;
for c = 1:3
    ch = cdata(:, :, c);  ch(mask) = fg;  cdata(:, :, c) = ch;
end
end
