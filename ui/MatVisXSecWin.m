function xw = MatVisXSecWin(model, cbs, dsIdx)
% MatVisXSecWin  Cross-section window: up to four planes of one dataset.
%
%   xw = MatVisXSecWin(model, cbs, dsIdx)
%
%   Up to four panels in a 2×2 grid.  Each panel shows either a 2-D cross
%   section through a user-selectable pair of dimensions (like the main
%   image window, but for an arbitrary plane), a 3-D maximum-intensity
%   projection of three user-selectable dimensions, or nothing ("Off" — an
%   empty row or column collapses so the remaining panels get the space).
%
%   Defaults (derived from the main window's X/Y selection, dims are
%   re-derived automatically when that selection changes — unless a panel's
%   dropdowns were changed by hand):
%       panel 1 : (XDim, YDim)          — same plane as the image window
%       panel 2 : (XDim, other)         — orthogonal view
%       panel 3 : (other, YDim)         — orthogonal view
%       panel 4 : 3-D MIP of (XDim, YDim, other)
%   where "other" is the first dimension that is neither XDim nor YDim.
%
%   cbs (all optional):
%       .positionFromMouse(xDim, xPos, yDim, yPos)
%       .zoomFromMouse(xDim, xRange, yDim, yRange)   — shared-zoom mode only
%       .onHide()                                    — window was closed
%
%   xw.Update(cmin, cmax, gamma)  render all panels with the given contrast
%                                 bounds/gamma of this dataset (so every
%                                 matVis window shares one lookup table)
%   xw.SetOverlayVisible(tf)      show/hide position cross-hairs
%   xw.Refresh()                  force a re-render (bypasses the skip cache)
%
% Contrast, colormap, gamma, spatial filter, projection and RGB colour
% coding all follow the main window.  Projection / RGB apply to a panel
% whenever their dimension is not one of that panel's displayed dimensions;
% otherwise the panel shows the plain slice at the current position.
%
% Real-world scaling is respected: a panel whose two (or three) dimensions
% carry a DimScale in the same unit is displayed with the corresponding
% physical aspect ratio, otherwise with square pixels.
%
% Mouse interactions (2-D panels, mirroring the image/zoom windows):
%   Left-drag on a position line : move that position
%   Left-drag on the crossing    : move both positions
%   Left-drag elsewhere          : rubber-band zoom
%   Middle-drag                  : pan (drag the image inside the panel)
%   Right-click                  : reset this panel's zoom
%   Double-click                 : copy / export / save this panel's image
%   Scroll wheel                 : zoom in/out around the cursor
% 3-D panels with the Image Processing Toolbox are a viewer3d, which keeps
% every mouse event inside its own canvas — none of them reach this figure,
% so its gestures are the ones it defines: left-drag rotates, CTRL +
% LEFT-DRAG PANS, wheel and middle-drag zoom.  There is no MATLAB property
% to move the pan onto the middle button.  Its wheel zoom works on the
% centre of the view; MatVisVolumeView re-centres the result on the cursor.
% The toolbox-free fallback is driven from here instead and follows the
% 2-D bindings: left-drag rotates, middle-drag pans, wheel zooms.

if nargin < 2 || isempty(cbs),   cbs = struct();               end
if nargin < 3 || isempty(dsIdx), dsIdx = model.ActiveDataset;  end
if isempty(dsIdx), dsIdx = 1; end

nDims  = numel(model.Size);
NPANEL = 4;

% Voxel budget for interactive 3-D rendering.  A full-size volume is sent
% to the renderer only when the user asks for it ("3D full res"); otherwise
% the volume is strided down to this many voxels so the MIP keeps up with
% position changes and playback.
MAXVOX = 4e6;

posCb  = getCb_(cbs, 'positionFromMouse');
zoomCb = getCb_(cbs, 'zoomFromMouse');
hideCb = getCb_(cbs, 'onHide');

% ---- shared display state ------------------------------------------------
sharedZoom = false;                  % false = each panel keeps its own zoom
fullRes3D  = false;
overlayOn  = true;
cMin_ = model.AllDataMins(dsIdx);    % overwritten by every Update() call
cMax_ = model.AllDataMaxs(dsIdx);
gam_  = model.Gamma;
% Per-channel equalization ranges of the current RGB stack (N×2, data units),
% empty when RGB is off.  When set, cMin_/cMax_ are a normalized window over
% those ranges rather than data values — see MatVisRender.normalizeChannels.
chanRng_ = [];
lastMainXY = [model.XDim, model.YDim];

dsTag = '';
if model.NumDatasets > 1, dsTag = ['_ds' num2str(dsIdx)]; end

%% Figure and layout
fig = uifigure('Name', ['Cross sections: ' model.DatasetNames{dsIdx}], ...
    'NumberTitle', 'off', 'Resize', 'on', 'AutoResizeChildren', 'off', ...
    'Visible', 'off', 'Position', [120 120 900 740]);
fig.CloseRequestFcn = @(~,~) onCloseRequest();

root = uigridlayout(fig, [2 1]);
root.RowHeight  = {26, '1x'};
root.Padding    = [3 3 3 3];
root.RowSpacing = 3;

bar = uigridlayout(root, [1 4]);
bar.Layout.Row     = 1;
bar.Layout.Column  = 1;
bar.ColumnWidth    = {110, 100, 90, '1x'};
bar.Padding        = [0 0 0 0];
bar.ColumnSpacing  = 6;

chkShared = uicheckbox(bar, 'Text', 'Shared zoom', 'Value', sharedZoom, ...
    'Tooltip', ['Off: each panel zooms on its own.' newline ...
                'On: zooming a panel moves the shared zoom range of those ' ...
                'dimensions (sliders and image/zoom windows follow).'], ...
    'ValueChangedFcn', @(src, ~) onSharedZoomToggle(src.Value));
chkShared.Layout.Column = 1;

chkFullRes = uicheckbox(bar, 'Text', '3D full res', 'Value', fullRes3D, ...
    'Tooltip', sprintf(['Render the 3-D view from the full-resolution volume.\n' ...
        'Off (default): the volume is strided down to ~%.0fM voxels so the ' ...
        'view keeps up with navigation.'], MAXVOX/1e6), ...
    'ValueChangedFcn', @(src, ~) onFullResToggle(src.Value));
chkFullRes.Layout.Column = 2;

btnReset = uibutton(bar, 'Text', 'Reset zoom', ...
    'Tooltip', 'Reset every panel to the full extent of its dimensions', ...
    'ButtonPushedFcn', @(~, ~) resetAllZoom());
btnReset.Layout.Column = 3;

lblInfo = uilabel(bar, 'Text', '', 'HorizontalAlignment', 'right', ...
    'FontSize', 10);
lblInfo.Layout.Column = 4;

pgrid = uigridlayout(root, [2 2]);
pgrid.Layout.Row    = 2;
pgrid.Layout.Column = 1;
pgrid.RowHeight     = {'1x', '1x'};
pgrid.ColumnWidth   = {'1x', '1x'};
pgrid.Padding       = [0 0 0 0];
pgrid.RowSpacing    = 2;      % the default 10 px would be given away twice
pgrid.ColumnSpacing = 2;

%% Panel state
P = struct([]);
userSetDims = false(1, NPANEL);

% NOTE on loop variables: a nested function shares any variable that also
% exists in this parent scope.  The nested callbacks below all loop over
% k / j / i, so those names are deliberately avoided out here — otherwise a
% re-render triggered from the middle of a mouse callback (Update() loops
% over its panels) would overwrite the callback's own panel index.
for pk_ = 1:NPANEL
    P(pk_).mode      = '2d';
    P(pk_).dims      = [1 1 1];
    P(pk_).zoom      = [ones(3,1), ones(3,1)];
    P(pk_).cell      = [];
    P(pk_).holder    = [];
    P(pk_).dropMode  = [];
    P(pk_).dropDim   = gobjects(1, 3);
    P(pk_).ax        = [];
    P(pk_).img       = [];
    P(pk_).lineV     = [];
    P(pk_).lineH     = [];
    P(pk_).selRect   = [];
    P(pk_).roiLines  = gobjects(1, 0);
    P(pk_).roiTexts  = gobjects(1, 0);
    P(pk_).profLines = gobjects(1, 0);
    P(pk_).vv        = [];
    P(pk_).sig       = [];
    P(pk_).lastHW    = [NaN NaN];
    P(pk_).tickSig   = [];
end

[defDims, defModes] = defaultAssignment();
for pk_ = 1:NPANEL
    P(pk_).mode = defModes{pk_};
    P(pk_).dims = defDims{pk_};
    P(pk_).zoom = fullZoomFor(defDims{pk_});
end

% Build the four cells: [dim controls | display holder]
for pk_ = 1:NPANEL
    cell_ = uigridlayout(pgrid, [2 1]);
    cell_.Layout.Row    = ceil(pk_ / 2);
    cell_.Layout.Column = 2 - mod(pk_, 2);
    cell_.RowHeight     = {24, '1x'};
    cell_.Padding       = [1 1 1 1];
    cell_.RowSpacing    = 1;
    P(pk_).cell         = cell_;

    ctrl = uigridlayout(cell_, [1 7]);
    ctrl.Layout.Row    = 1;
    ctrl.Layout.Column = 1;
    ctrl.ColumnWidth   = {52, 14, '1x', 14, '1x', 14, '1x'};
    ctrl.Padding       = [0 0 0 0];
    ctrl.ColumnSpacing = 3;

    P(pk_).dropMode = uidropdown(ctrl, 'Items', {'2D', '3D', 'Off'}, ...
        'ItemsData', {'2d', '3d', 'off'}, 'Value', P(pk_).mode, 'FontSize', 9, ...
        'Tooltip', sprintf(['2-D cross section, 3-D maximum-intensity ' ...
                    'projection, or off\n(a whole empty row/column ' ...
                    'collapses away).\n\n2-D: middle-drag pans, wheel ' ...
                    'zooms, right-click resets.\n3-D: left-drag rotates, ' ...
                    'ctrl + left-drag pans, wheel zooms.']), ...
        'ValueChangedFcn', @(src, ~) onModeChanged(pk_, src.Value));
    P(pk_).dropMode.Layout.Column = 1;

    axisTags = {'X', 'Y', 'Z'};
    for js_ = 1:3
        lbl = uilabel(ctrl, 'Text', axisTags{js_}, 'FontSize', 9, ...
            'HorizontalAlignment', 'right');
        lbl.Layout.Column = 2*js_;
        P(pk_).dropDim(js_) = uidropdown(ctrl, ...
            'Items', dimItems(), 'ItemsData', 1:nDims, ...
            'Value', P(pk_).dims(js_), 'FontSize', 9, ...
            'ValueChangedFcn', @(src, ~) onDimChanged(pk_, js_, src.Value));
        P(pk_).dropDim(js_).Layout.Column = 2*js_ + 1;
    end

    syncPanelControls(pk_);
    buildPanel(pk_);
end

%% Mouse interaction state
dragPanel = 0;
dragMode  = '';    % '', 'posV', 'posH', 'pos2D', 'sel', 'orbit'
dragStart = [];    % [x y] in local panel coords (or pixels while orbiting)
orbitView = [];    % [az el] at the start of a 3-D orbit drag
panRef    = [];    % [lo; width] of both dims when a pan drag started
ptCalib   = [];    % fig.CurrentPoint minus the root pointer, see ptFig()

fig.WindowButtonDownFcn   = @(src, ~) onMouseDown(src);
fig.WindowButtonMotionFcn = @(~, ~)   onMouseMove();
fig.WindowButtonUpFcn     = @(~, ~)   onMouseUp();
fig.WindowScrollWheelFcn  = @(~, evt) onScrollWheel(evt);

%% Public interface
xw.fig               = fig;
xw.dsIdx             = dsIdx;
xw.Update            = @updateAll;
xw.SetOverlayVisible = @setOverlayVisible;
xw.Refresh           = @forceRefresh;

% =========================================================================
%  Rendering
% =========================================================================
    function updateAll(cmin, cmax, gamma, chanRange)
        % Render every panel.  Called by the main window's render loop with
        % this dataset's contrast bounds and gamma, so all windows share one
        % mapping from data values to colours.
        if ~isvalid(fig), return; end
        if nargin >= 1 && ~isempty(cmin),  cMin_ = cmin;  end
        if nargin >= 2 && ~isempty(cmax),  cMax_ = cmax;  end
        if nargin >= 3 && ~isempty(gamma), gam_  = gamma; end
        if nargin >= 4,                    chanRng_ = chanRange; end
        if strcmp(fig.Visible, 'off'), return; end

        followMainPlane();
        for k = 1:NPANEL
            renderPanel(k);
        end
    end

    function forceRefresh()
        for k = 1:NPANEL
            P(k).sig = [];
        end
        updateAll();
    end

    function followMainPlane()
        % Re-derive the default planes when the main window's X/Y selection
        % changes, so the cross sections keep showing the orthogonal views of
        % whatever plane is on display.  Panels whose dropdowns the user
        % touched keep their manual assignment.
        if isequal(lastMainXY, [model.XDim, model.YDim]), return; end
        lastMainXY = [model.XDim, model.YDim];
        [dd, dm] = defaultAssignment();
        for k = 1:NPANEL
            if userSetDims(k), continue; end
            modeChanged = ~strcmp(P(k).mode, dm{k});
            P(k).mode = dm{k};
            P(k).dims = dd{k};
            P(k).zoom = fullZoomFor(dd{k});
            syncPanelControls(k);
            if modeChanged
                buildPanel(k);
            else
                P(k).sig = [];
            end
        end
    end

    function renderPanel(k)
        switch P(k).mode
            case 'off'  % nothing to draw
            case '3d',  render3D(k);
            otherwise,  render2D(k);
        end
    end

    % ---------------------------------------------------------------- 2-D
    function render2D(k)
        if isempty(P(k).ax) || ~isvalid(P(k).ax), return; end
        xd = P(k).dims(1);
        yd = P(k).dims(2);
        [xLo, xHi] = rangeFor(k, 1);
        [yLo, yHi] = rangeFor(k, 2);
        xIdx = xLo:xHi;
        yIdx = yLo:yHi;

        sig = sliceSignature(k, {xIdx([1 end]), yIdx([1 end])});
        if ~isequal(sig, P(k).sig)
            P(k).sig = sig;
            data = model.Datasets{dsIdx};
            % The panel repaints whenever contrast, gamma or the colormap
            % change, but the slice behind it does not: its plan omits them,
            % so the cache hands back the array it already holds instead of
            % re-projecting.
            plan = MatVisRender.rawSlicePlanForDims(model, xd, yd, xIdx, yIdx);
            raw  = model.CachedSlice(sprintf('xsec%d_%d', dsIdx, k), plan.key, ...
                @() MatVisRender.rawSliceFromPlan(data, model, plan));

            % In RGB mode the pages are equalized exactly as in the main
            % window before the (normalized) contrast window is applied;
            % panels showing scalar data fall back to data-unit bounds.
            rgbPanel = ~isempty(chanRng_) && ...
                       MatVisRender.rgbActiveForDims(model, xd, yd) && ...
                       size(raw, 3) == size(chanRng_, 1);
            if rgbPanel
                raw = MatVisRender.normalizeChannels(raw, chanRng_);
                cLo = cMin_;  cHi = cMax_;
            else
                [cLo, cHi] = scalarBounds_();
            end

            if MatVisRender.stretchActiveForDims(model, xd, yd)
                % Whole-dimension colour coding handles contrast, gamma and
                % the spatial filter internally (as in the main window).
                rgb = MatVisRender.renderStretchImage(model, raw, cLo, cHi, gam_);
                if model.WithAlpha
                    aRaw = model.CachedSlice(sprintf('xsecA%d_%d', dsIdx, k), ...
                        plan.key, @() MatVisRender.rawSliceFromPlan( ...
                            model.AlphaMaps{dsIdx}, model, plan));
                    if ndims(aRaw) == 3, aRaw = mean(aRaw, 3); end
                    aN = MatVisRender.renderAlphaSlice(aRaw, ...
                        model.AlphaContrastMins(dsIdx), ...
                        model.AlphaContrastMaxs(dsIdx), model.AlphaGamma);
                    rgb = blendAlpha_(rgb, aN, model.AlphaBgWhite);
                end
            else
                disp_ = MatVisRender.filterImage(raw, model.FilterType, model.FilterPar);
                nrm   = MatVisRender.normalizeData(disp_, cLo, cHi);
                if model.WithAlpha
                    aRaw = model.CachedSlice(sprintf('xsecA%d_%d', dsIdx, k), ...
                        plan.key, @() MatVisRender.rawSliceFromPlan( ...
                            model.AlphaMaps{dsIdx}, model, plan));
                    aN = MatVisRender.renderAlphaSlice(aRaw, ...
                        model.AlphaContrastMins(dsIdx), ...
                        model.AlphaContrastMaxs(dsIdx), model.AlphaGamma);
                    rgb = MatVisRender.composeImageWithAlpha(nrm, gam_, ...
                        model.ColormapIdx, aN, model.AlphaBgWhite);
                else
                    rgb = MatVisRender.composeImage(nrm, gam_, model.ColormapIdx);
                end
            end

            set(P(k).img, 'CData', rgb);
            [H, W, ~] = size(rgb);
            if ~isequal(P(k).lastHW, [H, W])
                P(k).lastHW = [H, W];
                P(k).ax.XLim = [0.5, W + 0.5];
                P(k).ax.YLim = [0.5, H + 0.5];
            end
            applyPanelAspect(k);

            % Real-world rulers: the axes hold local pixels, the data index
            % is pixel + (lo-1).
            tickSig = [W, H, xd, yd, xLo, yLo];
            if ~isequal(tickSig, P(k).tickSig)
                MatVisRender.applyAxisScale(P(k).ax, model, xd, xLo-1, yd, yLo-1);
                P(k).tickSig = tickSig;
            end
        end

        updateCrosshair(k);
        syncOverlays(k);
    end

    function updateCrosshair(k)
        if strcmp(P(k).mode, '3d') || isempty(P(k).lineV) || ~isvalid(P(k).lineV)
            return;
        end
        [xLo, xHi] = rangeFor(k, 1);
        [yLo, yHi] = rangeFor(k, 2);
        W = xHi - xLo + 1;
        H = yHi - yLo + 1;
        px = model.CurrPos(P(k).dims(1)) - xLo + 1;
        py = model.CurrPos(P(k).dims(2)) - yLo + 1;
        if px < 0.5 || px > W + 0.5, px = NaN; end
        if py < 0.5 || py > H + 0.5, py = NaN; end
        set(P(k).lineV, 'XData', [px px],          'YData', [0.5, H + 0.5]);
        set(P(k).lineH, 'XData', [0.5, W + 0.5],   'YData', [py py]);
    end

    function applyPanelAspect(k)
        ax = P(k).ax;
        if ~model.AspectRatioFixed
            ax.DataAspectRatioMode    = 'auto';
            ax.PlotBoxAspectRatioMode = 'auto';
            return;
        end
        % Physical aspect when both dims carry comparable scale, otherwise
        % the image window's manual ratio (square pixels by default).
        sp = MatVisRender.spacingForDims(model, P(k).dims(1:2));
        if isempty(sp)
            r = model.AspectRatio;
            if numel(r) ~= 2, r = [1 1]; end
            ax.DataAspectRatio = [r(1), r(2), 1];
        else
            % One index step spans sp(1)/sp(2) real units along x/y, so equal
            % screen lengths correspond to 1/sp data units.
            ax.DataAspectRatio = [1/sp(1), 1/sp(2), 1];
        end
        ax.PlotBoxAspectRatioMode = 'auto';
    end

    % ---------------------------------------------------------------- 3-D
    function render3D(k)
        d3 = P(k).dims;
        if numel(unique(d3)) < 3 || nDims < 3, return; end

        rng3 = zeros(3, 2);
        for j = 1:3
            [l, h]    = rangeFor(k, j);
            rng3(j,:) = [l, h];
        end
        budget = MAXVOX;
        if fullRes3D, budget = Inf; end
        [lo, n, strides] = MatVisVolumeView.planSampling(rng3, budget);

        sig = sliceSignature(k, {[lo(1) n(1) strides(1)], ...
                                 [lo(2) n(2) strides(2)], ...
                                 [lo(3) n(3) strides(3)]});
        if isequal(sig, P(k).sig), return; end
        P(k).sig = sig;

        [vLo, vHi] = scalarBounds_();      % volume rendering is always scalar
        [V, voxSize] = MatVisVolumeView.extractVolume(model, ...
            model.Datasets{dsIdx}, d3, lo, n, strides, vLo, vHi, gam_);

        vv = P(k).vv;
        if isempty(vv) || ~isvalid(vv), return; end
        vv.Colormap = MatVisRender.getColormap(model.ColormapIdx, 256);
        vv.Labels   = {dimLabel(d3(1)), dimLabel(d3(2)), dimLabel(d3(3))};
        vv.setVolume(V, voxSize);
    end

    % ------------------------------------------------------- ROI overlays
    function syncOverlays(k)
        % Read-only ROI outlines and profile centre lines, drawn in panels
        % whose plane matches the plane the shape was defined in.
        xd = P(k).dims(1);
        yd = P(k).dims(2);
        [xLo, ~] = rangeFor(k, 1);
        [yLo, ~] = rangeFor(k, 2);

        visIdx = shapesInPlane(model.RoiList, xd, yd);
        n = numel(visIdx);
        for i = numel(P(k).roiLines)+1 : n
            P(k).roiLines(i) = line(P(k).ax, NaN, NaN, 'HitTest', 'off', ...
                'PickableParts', 'none');
            P(k).roiTexts(i) = text(P(k).ax, NaN, NaN, '', 'HitTest', 'off', ...
                'PickableParts', 'none', 'FontSize', 8, 'Clipping', 'on');
        end
        for i = n+1 : numel(P(k).roiLines)
            if isgraphics(P(k).roiLines(i)), delete(P(k).roiLines(i)); end
            if isgraphics(P(k).roiTexts(i)), delete(P(k).roiTexts(i)); end
        end
        P(k).roiLines = P(k).roiLines(1:n);
        P(k).roiTexts = P(k).roiTexts(1:n);

        if n > 0
            selVis = visIdx(ismember(visIdx, model.RoiSelection));
            cols   = MatVisRender.roiColors(max(numel(selVis), 1));
            for i = 1:n
                idx = visIdx(i);
                c   = model.RoiList(idx).corners;
                pos = find(selVis == idx, 1);
                if ~isempty(pos)
                    col = cols(pos, :);  w = max(model.RoiLineWidth, 0.5);
                else
                    col = [1 1 1];       w = 0.5;
                end
                set(P(k).roiLines(i), 'XData', c(1,:) - xLo + 1, ...
                    'YData', c(2,:) - yLo + 1, 'Color', col, 'LineWidth', w, ...
                    'LineStyle', model.RoiLineStyle, 'Visible', 'on');
                set(P(k).roiTexts(i), ...
                    'Position', [max(c(1,:)) - xLo + 2, mean(c(2,:)) - yLo + 1], ...
                    'String', model.RoiList(idx).name, 'Color', col, ...
                    'Visible', onOff_(model.RoiShowNames));
            end
        end

        visP = shapesInPlane(model.ProfileList, xd, yd);
        m = numel(visP);
        for i = numel(P(k).profLines)+1 : m
            P(k).profLines(i) = line(P(k).ax, NaN, NaN, 'HitTest', 'off', ...
                'PickableParts', 'none', 'LineWidth', 1.2);
        end
        for i = m+1 : numel(P(k).profLines)
            if isgraphics(P(k).profLines(i)), delete(P(k).profLines(i)); end
        end
        P(k).profLines = P(k).profLines(1:m);
        for i = 1:m
            sp = model.ProfileList(visP(i)).smoothedPoints;
            set(P(k).profLines(i), 'XData', sp(1,:) - xLo + 1, ...
                'YData', sp(2,:) - yLo + 1, 'Color', [1 1 0], 'Visible', 'on');
        end
    end

    function idx = shapesInPlane(list, xd, yd)
        idx = [];
        for i = 1:numel(list)
            xy = list(i).settings.xySel;
            if numel(xy) == 2 && xy(1) == xd && xy(2) == yd
                idx(end+1) = i; %#ok<AGROW>
            end
        end
    end

% =========================================================================
%  Panel construction
% =========================================================================
    function makeHolder(k)
        % Every mode change gets a *fresh* container.  Emptying and re-using
        % one uipanel leaves the web renderer with a stale slot: putting a
        % second viewer3d into it (the Off -> 3D sequence) comes up blank.
        % Creating the panel anew always renders, and mode changes are far
        % too rare for the cost to matter.
        if ~isempty(P(k).holder) && isvalid(P(k).holder)
            delete(P(k).holder);
        end
        h = uipanel(P(k).cell, 'BorderType', 'none');
        h.Layout.Row    = 2;
        h.Layout.Column = 1;
        P(k).holder = h;
    end

    function buildPanel(k)
        makeHolder(k);
        P(k).ax        = [];
        P(k).img       = [];
        P(k).lineV     = [];
        P(k).lineH     = [];
        P(k).selRect   = [];
        P(k).roiLines  = gobjects(1, 0);
        P(k).roiTexts  = gobjects(1, 0);
        P(k).profLines = gobjects(1, 0);
        if ~isempty(P(k).vv) && isvalid(P(k).vv)
            delete(P(k).vv);
        end
        P(k).vv        = [];
        P(k).sig       = [];
        P(k).lastHW    = [NaN NaN];
        P(k).tickSig   = [];

        switch P(k).mode
            case 'off'  % leave the holder empty
            case '3d',  build3D(k);
            otherwise,  build2D(k);
        end
        relayout();
    end

    function relayout()
        % Give the space back when a whole row or column of panels is off.
        % A switched-off panel keeps its control row so it can be switched
        % back on, hence the small residual size.
        offP = arrayfun(@(q) strcmp(P(q).mode, 'off'), 1:NPANEL);
        rowOff = [offP(1) && offP(2), offP(3) && offP(4)];   % panels 1,2 / 3,4
        colOff = [offP(1) && offP(3), offP(2) && offP(4)];   % panels 1,3 / 2,4
        COLLAPSED = 30;
        rh = {'1x', '1x'};
        cw = {'1x', '1x'};
        if rowOff(1) && ~rowOff(2), rh{1} = COLLAPSED; end
        if rowOff(2) && ~rowOff(1), rh{2} = COLLAPSED; end
        if colOff(1) && ~colOff(2), cw{1} = COLLAPSED * 8; end
        if colOff(2) && ~colOff(1), cw{2} = COLLAPSED * 8; end
        if ~isequal(pgrid.RowHeight, rh),   pgrid.RowHeight  = rh; end
        if ~isequal(pgrid.ColumnWidth, cw), pgrid.ColumnWidth = cw; end
    end

    function build2D(k)
        ax = uiaxes('Parent', P(k).holder, 'Units', 'normalized');
        fillHolder_(ax);
        disableDefaultInteractivity(ax);
        try; ax.Toolbar = []; catch; end
        ax.FontSize = 8;
        % No title: the dropdown row right above already names both
        % dimensions, and the axis labels repeat them with their units — the
        % line it would cost is better spent on the image.
        ax.XLabel.FontSize = 8;
        ax.YLabel.FontSize = 8;
        axis(ax, 'image');

        img = image(ax, zeros(1, 1, 3, 'uint8'));
        img.HitTest = 'off';  img.PickableParts = 'none';

        lineV = line(ax, [NaN NaN], [0.5 1.5], 'Color', 'w', 'LineWidth', 0.8);
        lineH = line(ax, [0.5 1.5], [NaN NaN], 'Color', 'w', 'LineWidth', 0.8);
        lineV.HitTest = 'off';  lineV.PickableParts = 'none';
        lineH.HitTest = 'off';  lineH.PickableParts = 'none';
        vis = onOff_(overlayOn);
        lineV.Visible = vis;  lineH.Visible = vis;

        selRect = rectangle(ax, 'Position', [1 1 1 1], 'EdgeColor', [1 1 0], ...
            'LineStyle', '--', 'LineWidth', 1.2, 'FaceColor', 'none', ...
            'Visible', 'off');
        selRect.HitTest = 'off';  selRect.PickableParts = 'none';

        P(k).ax = ax;  P(k).img = img;
        P(k).lineV = lineV;  P(k).lineH = lineH;  P(k).selRect = selRect;
        applyPanelAspect(k);
    end

    function build3D(k)
        % The shared volume view picks the renderer: the Image Processing
        % Toolbox one (a true rotatable MIP) when it is available, the
        % projection-on-a-face fallback otherwise.
        vv = MatVisVolumeView(P(k).holder);
        vv.PointerFcn = @ptFig;
        P(k).vv = vv;
    end

% =========================================================================
%  Dimension / mode controls
% =========================================================================
    function [dd, dm] = defaultAssignment()
        xd = model.XDim;
        yd = model.YDim;
        others = setdiff(1:nDims, [xd yd], 'stable');
        if isempty(others)
            o = 0;
        else
            o = others(1);
        end
        if o == 0
            % 2-D dataset: only one plane exists, and no 3-D view.
            dd = repmat({[xd yd yd]}, 1, NPANEL);
            dm = repmat({'2d'}, 1, NPANEL);
            return;
        end
        dd = {[xd yd o], [xd o yd], [o yd xd], [xd yd o]};
        dm = {'2d', '2d', '2d', '3d'};
    end

    function z = fullZoomFor(dims)
        z = ones(3, 2);
        for j = 1:3
            z(j, :) = [1, model.Size(dims(j))];
        end
    end

    function items = dimItems()
        items = cell(1, nDims);
        for d = 1:nDims
            items{d} = dimLabel(d);
        end
    end

    function s = dimLabel(d)
        if ~isempty(model.DimNames) && numel(model.DimNames) >= d
            s = model.DimNames{d};
        else
            s = sprintf('Dim%d', d);
        end
    end

    function syncPanelControls(k)
        P(k).dropMode.Value = P(k).mode;
        live = ~strcmp(P(k).mode, 'off');
        for j = 1:3
            P(k).dropDim(j).Value  = P(k).dims(j);
            P(k).dropDim(j).Enable = onOff_(live && (j < 3 || strcmp(P(k).mode, '3d')));
        end
    end

    function onModeChanged(k, mode)
        if strcmp(mode, '3d') && nDims < 3
            uialert(fig, 'A 3-D view needs at least three dimensions.', ...
                'Cross sections');
            P(k).dropMode.Value = P(k).mode;
            return;
        end
        userSetDims(k) = true;
        P(k).mode = mode;
        if strcmp(mode, '3d')
            % Make sure the three dimensions are distinct before building.
            P(k).dims = distinctDims(P(k).dims);
            P(k).zoom = fullZoomFor(P(k).dims);
        end
        syncPanelControls(k);
        buildPanel(k);
        renderPanel(k);
    end

    function onDimChanged(k, slot, newDim)
        userSetDims(k) = true;
        d = P(k).dims;
        nSlots = 2 + double(strcmp(P(k).mode, '3d'));
        clash = find(d(1:nSlots) == newDim & (1:nSlots) ~= slot, 1);
        if ~isempty(clash)
            d(clash) = d(slot);     % swap, so the slots stay distinct
        end
        d(slot) = newDim;
        P(k).dims = d;
        P(k).zoom = fullZoomFor(d);
        syncPanelControls(k);
        P(k).sig     = [];
        P(k).lastHW  = [NaN NaN];
        P(k).tickSig = [];
        renderPanel(k);
    end

    function d = distinctDims(d)
        used = [];
        for j = 1:3
            if any(used == d(j))
                free = setdiff(1:nDims, [used, d], 'stable');
                if isempty(free), free = setdiff(1:nDims, used, 'stable'); end
                if ~isempty(free), d(j) = free(1); end
            end
            used(end+1) = d(j); %#ok<AGROW>
        end
    end

% =========================================================================
%  Zoom handling
% =========================================================================
    function [lo, hi] = rangeFor(k, j)
        d = P(k).dims(j);
        if sharedZoom
            lo = model.ZoomRange(d, 1);
            hi = model.ZoomRange(d, 2);
        else
            lo = P(k).zoom(j, 1);
            hi = P(k).zoom(j, 2);
        end
        lo = max(1, min(round(lo), model.Size(d)));
        hi = max(lo, min(round(hi), model.Size(d)));
    end

    function setRange(k, j, lo, hi)
        d  = P(k).dims(j);
        lo = max(1, min(round(lo), model.Size(d)));
        hi = max(lo, min(round(hi), model.Size(d)));
        P(k).zoom(j, :) = [lo, hi];
    end

    function applyZoom(k, newLo, newHi, keepSize)
        % newLo/newHi: 1×2 (2-D panels) or 1×3 index ranges for the panel's
        % displayed dimensions.  keepSize says this is a pan, so the shared
        % zoom must not be refitted to the zoom window on the way through.
        if nargin < 4, keepSize = false; end
        nSlots = numel(newLo);
        if sharedZoom && ~isempty(zoomCb) && nSlots >= 2
            % Route through the main window so sliders and the image/zoom
            % windows follow the same zoom.
            zoomCb(P(k).dims(1), [newLo(1) newHi(1)], ...
                   P(k).dims(2), [newLo(2) newHi(2)], keepSize);
            if nSlots >= 3
                zoomCb(P(k).dims(3), [newLo(3) newHi(3)], ...
                       P(k).dims(3), [newLo(3) newHi(3)], true);
            end
            return;
        end
        for j = 1:nSlots
            setRange(k, j, newLo(j), newHi(j));
        end
        if sharedZoom
            % No callback available — write the shared range directly.
            for j = 1:nSlots
                model.ZoomRange(P(k).dims(j), :) = P(k).zoom(j, :);
            end
        end
        P(k).lastHW  = [NaN NaN];
        P(k).tickSig = [];
        renderPanel(k);
    end

    function resetPanelZoom(k)
        nSlots = 2 + double(strcmp(P(k).mode, '3d'));
        lo = ones(1, nSlots);
        hi = zeros(1, nSlots);
        for j = 1:nSlots
            hi(j) = model.Size(P(k).dims(j));
        end
        % Zooming/panning a 3-D panel pins its camera; hand it back to the
        % viewer so the reset really does return to the default view.
        if ~isempty(P(k).vv) && isvalid(P(k).vv)
            P(k).vv.resetCamera();
        end
        applyZoom(k, lo, hi);
    end

    function resetAllZoom()
        for k = 1:NPANEL
            resetPanelZoom(k);
        end
    end

    function onSharedZoomToggle(tf)
        sharedZoom = logical(tf);
        if sharedZoom
            % Adopt the shared ranges; leaving the mode keeps them, so the
            % display never jumps when the checkbox is switched off again.
            for k = 1:NPANEL
                for j = 1:3
                    P(k).zoom(j, :) = model.ZoomRange(P(k).dims(j), :);
                end
            end
        end
        forceRefresh();
    end

    function onFullResToggle(tf)
        fullRes3D = logical(tf);
        for k = 1:NPANEL
            if strcmp(P(k).mode, '3d'), P(k).sig = []; end
        end
        updateAll();
    end

% =========================================================================
%  Mouse interaction
% =========================================================================
    function pt = ptFig()
        % Pointer position in figure pixels.  fig.CurrentPoint stops updating
        % while the mouse is over a viewer3d — an HTML component that keeps
        % the pointer events to itself — so the position is derived from the
        % root pointer instead.  The offset between the two is measured from
        % a position the figure itself reported (calibratePointer) rather
        % than assumed, and until that has happened CurrentPoint is used as
        % before: a wrong mapping here would break every panel.
        pt = fig.CurrentPoint;
        if isempty(ptCalib), return; end
        try
            pt = get(groot, 'PointerLocation') - fig.Position(1:2) + 1 + ptCalib;
        catch
            pt = fig.CurrentPoint;
        end
    end

    function calibratePointer()
        % Called from places where fig.CurrentPoint is known to be live.
        try
            ptCalib = fig.CurrentPoint - ...
                      (get(groot, 'PointerLocation') - fig.Position(1:2) + 1);
        catch
        end
    end

    function k = panelAt()
        k = 0;
        pt = ptFig();
        for i = 1:NPANEL
            if isempty(P(i).holder) || ~isvalid(P(i).holder), continue; end
            p = getpixelposition(P(i).holder, true);
            if pt(1) >= p(1) && pt(1) <= p(1)+p(3) && ...
               pt(2) >= p(2) && pt(2) <= p(2)+p(4)
                k = i;
                return;
            end
        end
    end

    function [x, y, inside] = localPoint(k)
        ax = P(k).ax;
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);
        inside = x >= ax.XLim(1) && x <= ax.XLim(2) && ...
                 y >= ax.YLim(1) && y <= ax.YLim(2);
    end

    function onMouseDown(src)
        k = panelAt();
        if k == 0 || strcmp(P(k).mode, 'off'), return; end

        if strcmp(P(k).mode, '3d')
            % Only the toolbox-free fallback can be driven from here; a
            % viewer3d keeps every mouse event to itself (see
            % MatVisVolumeView), so over one of those this never even fires.
            if isempty(P(k).vv) || ~isvalid(P(k).vv) || P(k).vv.isViewer3D()
                return;
            end
            switch src.SelectionType
                case 'extend'                            % middle-drag: pan
                    dragPanel = k;
                    dragMode  = 'pan3';
                    dragStart = ptFig();
                    fig.Pointer = 'hand';
                case 'normal'
                    [az, el]  = P(k).vv.cameraAngles();
                    orbitView = [az, el];
                    dragPanel = k;
                    dragMode  = 'orbit';
                    dragStart = ptFig();
            end
            return;
        end

        [x, y, inside] = localPoint(k);
        if ~inside, return; end
        calibratePointer();     % a click on a 2-D panel: CurrentPoint is live
        st = src.SelectionType;

        if strcmp(st, 'open')
            dragMode = '';  dragPanel = 0;
            openExportMenu(k);
            return;
        end

        if strcmp(st, 'extend')             % middle-drag: pan the view
            [xLo, xHi] = rangeFor(k, 1);
            [yLo, yHi] = rangeFor(k, 2);
            dragPanel = k;
            dragMode  = 'pan';
            dragStart = ptFig();            % pointer, figure pixels
            panRef    = [xLo, yLo; xHi - xLo + 1, yHi - yLo + 1];
            fig.Pointer = 'hand';
            return;
        end

        if strcmp(st, 'alt')                % right-click: reset this panel
            resetPanelZoom(k);
            return;
        end

        mode = hitTest(k, x, y);
        dragPanel = k;
        dragMode  = mode;
        dragStart = [x y];
        if strcmp(mode, 'sel')
            set(P(k).selRect, 'Position', [x, y, 0.01, 0.01], 'Visible', 'on');
        end
        updateCursor(mode);
    end

    function onMouseMove()
        if dragPanel == 0
            k = panelAt();
            if k == 0 || strcmp(P(k).mode, '3d') || strcmp(P(k).mode, 'off')
                fig.Pointer = 'arrow';
                lblInfo.Text = '';
                return;
            end
            [x, y, inside] = localPoint(k);
            if inside
                calibratePointer();     % here CurrentPoint is trustworthy
                updateCursor(hitTest(k, x, y));
                showReadout(k, x, y);
            else
                fig.Pointer  = 'arrow';
                lblInfo.Text = '';
            end
            return;
        end

        k = dragPanel;
        if strcmp(dragMode, 'orbit')
            pt = ptFig();
            d  = pt - dragStart;
            P(k).vv.setCameraAngles(orbitView(1) - d(1)*0.5, ...
                                    orbitView(2) + d(2)*0.5);
            return;
        end
        if strcmp(dragMode, 'pan3')
            pt = ptFig();
            P(k).vv.pan(pt - dragStart);
            dragStart = pt;             % incremental, so nothing accumulates
            return;
        end

        if strcmp(dragMode, 'pan')
            panTo(k);
            return;
        end

        [xRaw, yRaw] = localPoint(k);
        x = clamp_(xRaw, P(k).ax.XLim(1), P(k).ax.XLim(2));
        y = clamp_(yRaw, P(k).ax.YLim(1), P(k).ax.YLim(2));
        showReadout(k, x, y);

        switch dragMode
            case 'posV',  setPosition(k, x, []);
            case 'posH',  setPosition(k, [], y);
            case 'pos2D', setPosition(k, x, y);
            case 'sel'
                x1 = dragStart(1);  y1 = dragStart(2);
                set(P(k).selRect, 'Position', ...
                    [min(x1,x), min(y1,y), max(abs(x-x1), 0.01), max(abs(y-y1), 0.01)]);
        end
    end

    function onMouseUp()
        if dragPanel == 0, return; end
        k = dragPanel;
        if strcmp(dragMode, 'pan3')
            dragPanel = 0;  dragMode = '';  dragStart = [];  panRef = [];
            fig.Pointer = 'arrow';
            return;
        end
        if strcmp(dragMode, 'sel')
            [x, y] = localPoint(k);
            x = clamp_(x, P(k).ax.XLim(1), P(k).ax.XLim(2));
            y = clamp_(y, P(k).ax.YLim(1), P(k).ax.YLim(2));
            P(k).selRect.Visible = 'off';
            [xLo, ~] = rangeFor(k, 1);
            [yLo, ~] = rangeFor(k, 2);
            x1 = round(min(dragStart(1), x)) + xLo - 1;
            x2 = round(max(dragStart(1), x)) + xLo - 1;
            y1 = round(min(dragStart(2), y)) + yLo - 1;
            y2 = round(max(dragStart(2), y)) + yLo - 1;
            if x2 > x1 && y2 > y1
                N = [model.Size(P(k).dims(1)), model.Size(P(k).dims(2))];
                [lo, hi] = fitToPanel(k, [x1 y1], [x2 y2], N);
                applyZoom(k, lo, hi);
            end
        end
        dragPanel = 0;
        dragMode  = '';
        dragStart = [];
        panRef    = [];
        fig.Pointer = 'arrow';
    end

    function f = wheelFactor(evt)
        % > 1 = zoom out.  The wheel can report several lines per detent, so
        % the step is capped: one flick should not jump by a factor of two.
        n = evt.VerticalScrollCount;
        if ~isfinite(n), n = 0; end
        f = 1.2 ^ clamp_(n, -2, 2);
    end

    function onScrollWheel(evt)
        k = panelAt();
        if k == 0 || strcmp(P(k).mode, 'off'), return; end
        if strcmp(P(k).mode, '3d')
            % A viewer3d never lets the wheel through to us; only the
            % toolbox-free fallback is zoomed from here.
            if ~isempty(P(k).vv) && isvalid(P(k).vv) && ~P(k).vv.isViewer3D()
                P(k).vv.zoomAtCursor(wheelFactor(evt));
            end
            return;
        end
        [x, y, inside] = localPoint(k);
        if ~inside, return; end
        wheelZoom2D(k, wheelFactor(evt), x, y);
    end

    function wheelZoom2D(k, factor, xLocal, yLocal)
        N  = [model.Size(P(k).dims(1)), model.Size(P(k).dims(2))];
        [xLo, xHi] = rangeFor(k, 1);
        [yLo, yHi] = rangeFor(k, 2);
        cur = [xLocal, yLocal] + [xLo, yLo] - 1;          % cursor, data coords
        [xr, yr] = MatVisRender.zoomStepAtCursor([xLo xHi], [yLo yHi], ...
            N(1), N(2), factor, cur(1), cur(2));
        [lo, hi] = fitToPanel(k, [xr(1) yr(1)], [xr(2) yr(2)], N);
        if isequal(lo, [xLo yLo]) && isequal(hi, [xHi yHi]), return; end
        applyZoom(k, lo, hi);
    end

    function [lo, hi] = fitToPanel(k, lo, hi, N)
        % Spend the empty space a letterboxed panel leaves beside the image
        % on more data, so a zoom fills the panel instead of showing a strip.
        [xr, yr] = MatVisRender.fitZoomToAxes(P(k).ax, ...
            [lo(1) hi(1)], [lo(2) hi(2)], N(1), N(2));
        lo = [xr(1), yr(1)];
        hi = [xr(2), yr(2)];
    end

    function panTo(k)
        % Middle-drag pan, measured in screen pixels from where the drag
        % started: the range always follows from the total pointer movement,
        % never from the previous step, so nothing drifts and nothing depends
        % on ax.CurrentPoint (which stops updating as soon as the pointer
        % leaves the axes, and made the pan give up mid-drag).
        if isempty(panRef), return; end
        [pxX, pxY] = MatVisRender.pixelsPerDataUnit(P(k).ax);
        if pxX <= 0 || pxY <= 0, return; end
        d = ptFig() - dragStart;
        N = [model.Size(P(k).dims(1)), model.Size(P(k).dims(2))];
        % Dragging right shows what is further left; the y axis of an image
        % points down the screen, so its sign is the other way round.
        lo = panRef(1, :) + round([-d(1)/pxX, d(2)/pxY]);
        w  = panRef(2, :);
        lo = max(1, min(lo, N - w + 1));
        [xLo, ~] = rangeFor(k, 1);
        [yLo, ~] = rangeFor(k, 2);
        if isequal(lo, [xLo, yLo]), return; end
        applyZoom(k, lo, lo + w - 1, true);
    end

    function mode = hitTest(k, x, y)
        mode = 'sel';
        axPos = getpixelposition(P(k).ax);
        xt = 6 * diff(P(k).ax.XLim) / max(axPos(3), 1);
        yt = 6 * diff(P(k).ax.YLim) / max(axPos(4), 1);
        [xLo, ~] = rangeFor(k, 1);
        [yLo, ~] = rangeFor(k, 2);
        px = model.CurrPos(P(k).dims(1)) - xLo + 1;
        py = model.CurrPos(P(k).dims(2)) - yLo + 1;
        nearV = abs(x - px) <= xt;
        nearH = abs(y - py) <= yt;
        if nearV && nearH
            mode = 'pos2D';
        elseif nearV
            mode = 'posV';
        elseif nearH
            mode = 'posH';
        end
    end

    function updateCursor(mode)
        switch mode
            case 'posV',  fig.Pointer = 'left';
            case 'posH',  fig.Pointer = 'top';
            case 'pos2D', fig.Pointer = 'fleur';
            otherwise,    fig.Pointer = 'arrow';
        end
    end

    function setPosition(k, xLocal, yLocal)
        % Move the current position along this panel's dimensions.  Empty
        % arguments leave that dimension untouched.
        xd = P(k).dims(1);
        yd = P(k).dims(2);
        [xLo, ~] = rangeFor(k, 1);
        [yLo, ~] = rangeFor(k, 2);
        if isempty(xLocal)
            xPos = model.CurrPos(xd);
        else
            xPos = clamp_(round(xLocal) + xLo - 1, 1, model.Size(xd));
        end
        if isempty(yLocal)
            yPos = model.CurrPos(yd);
        else
            yPos = clamp_(round(yLocal) + yLo - 1, 1, model.Size(yd));
        end
        if ~isempty(posCb)
            posCb(xd, xPos, yd, yPos);      % main window re-renders everything
        else
            model.CurrPos(xd) = xPos;
            model.CurrPos(yd) = yPos;
            updateAll();
        end
    end

    function showReadout(k, xLocal, yLocal)
        xd = P(k).dims(1);
        yd = P(k).dims(2);
        [xLo, ~] = rangeFor(k, 1);
        [yLo, ~] = rangeFor(k, 2);
        xi = clamp_(round(xLocal) + xLo - 1, 1, model.Size(xd));
        yi = clamp_(round(yLocal) + yLo - 1, 1, model.Size(yd));
        idx      = num2cell(model.CurrPos);
        idx{xd}  = xi;
        idx{yd}  = yi;
        val = model.Datasets{dsIdx}(idx{:});
        txt = sprintf('%s %d, %s %d  =  %g', dimLabel(xd), xi, dimLabel(yd), yi, val);
        if model.hasRealScale(xd) || model.hasRealScale(yd)
            txt = sprintf('%s   (%.4g %s, %.4g %s)', txt, ...
                model.indexToReal(xd, xi), model.dimUnit(xd), ...
                model.indexToReal(yd, yi), model.dimUnit(yd));
        end
        lblInfo.Text = txt;
    end

    function openExportMenu(k)
        xd = P(k).dims(1);
        yd = P(k).dims(2);
        [xLo, xHi] = rangeFor(k, 1);
        [yLo, yHi] = rangeFor(k, 2);
        rawFcn = @() MatVisRender.getRawSliceForDims(model, ...
            model.Datasets{dsIdx}, xd, yd, xLo:xHi, yLo:yHi);
        tag = sprintf('matVisXSec%s_d%dd%d', dsTag, xd, yd);
        MatVisExportMenu(fig, P(k).ax, ...
            {'_raw', rawFcn; '_display', @() P(k).img.CData}, tag, [tag '.png']);
    end

% =========================================================================
%  Misc
% =========================================================================
    function [lo, hi] = scalarBounds_()
        % Data-unit contrast bounds for panels that show scalar data while
        % the main window is in RGB mode (where cMin_/cMax_ are a normalized
        % window).  The reference is the middle page — green for a triad.
        if isempty(chanRng_)
            lo = cMin_;  hi = cMax_;
            return;
        end
        ref  = max(1, ceil(size(chanRng_, 1) / 2));
        base = chanRng_(ref, 1);
        span = chanRng_(ref, 2) - base;
        lo   = base + cMin_ * span;
        hi   = base + cMax_ * span;
    end

    function sig = sliceSignature(k, ranges)
        % Everything that can change what a panel shows.  Rendering is
        % skipped when this is unchanged, so playback along a dimension the
        % panel doesn't display costs nothing.
        d = P(k).dims;
        otherDims = setdiff(1:nDims, d(1:(2 + double(strcmp(P(k).mode, '3d')))));
        if model.WithAlpha
            alphaSig = [model.AlphaContrastMins(dsIdx), model.AlphaContrastMaxs(dsIdx), ...
                        model.AlphaGamma, model.AlphaBgWhite];
        else
            alphaSig = [];
        end
        sig = {P(k).mode, d, ranges, model.CurrPos(otherDims), ...
               [cMin_, cMax_, gam_, model.ColormapIdx], chanRng_, ...
               model.ProjFun, [model.ProjDim, model.ProjZoomLock], ...
               [model.RGBDim, model.RGBStretchZoomLock], model.RGBStretchMode, ...
               model.RGBStretchRange, model.FilterType, model.FilterPar, ...
               [model.FlipX, model.FlipY], alphaSig, ...
               model.AspectRatioFixed, model.AspectRatio, fullRes3D};
    end

    function setOverlayVisible(tf)
        overlayOn = logical(tf);
        vis = onOff_(overlayOn);
        for k = 1:NPANEL
            if ~isempty(P(k).lineV) && isvalid(P(k).lineV)
                P(k).lineV.Visible = vis;
                P(k).lineH.Visible = vis;
            end
        end
    end

    function onCloseRequest()
        fig.Visible = 'off';
        if ~isempty(hideCb)
            try; hideCb(); catch; end
        end
    end
end % MatVisXSecWin

% ---- Module helpers -------------------------------------------------------
function f = getCb_(cbs, name)
    if isfield(cbs, name) && isa(cbs.(name), 'function_handle')
        f = cbs.(name);
    else
        f = [];
    end
end


function img = blendAlpha_(img, a, bgWhite)
    a = max(0, min(1, double(a)));
    bg = 0;
    if bgWhite, bg = 255; end
    img = uint8(double(img) .* a + bg * (1 - a));
end

function v = clamp_(x, lo, hi)
    v = max(lo, min(hi, x));
end


function fillHolder_(ax)
    % Let the axes have the whole panel: MATLAB then keeps just enough room
    % for the ticks and labels instead of the fixed margin a normalized
    % Position would reserve.
    try
        ax.PositionConstraint = 'outerposition';
        ax.OuterPosition      = [0 0 1 1];
    catch
        ax.Position = [0.13 0.13 0.84 0.82];
    end
end

function s = onOff_(tf)
    if tf, s = 'on'; else, s = 'off'; end
end
