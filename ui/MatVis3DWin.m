function w3 = MatVis3DWin(model, cbs, dsIdx)
% MatVis3DWin  Interactive 3-D volume view of one dataset.
%
%   w3 = MatVis3DWin(model, cbs, dsIdx)
%
%   One rotatable volume rendering of three user-selectable dimensions, with
%   the controls that decide what goes into it (which dims, which part of
%   them, at what sampling), how it is rendered (style, colormap, alpha,
%   isovalue, contrast) and how it is viewed (projection, preset directions,
%   camera angles and zoom).
%
%   cbs (all optional):
%       .onHide()    — the window was closed
%
%   w3.fig                        uifigure handle (created hidden)
%   w3.dsIdx                      dataset this window shows
%   w3.Show()                     show and render
%   w3.Update(cmin, cmax, gamma, chanRange)
%                                 called by the main window's render loop
%                                 with this dataset's contrast bounds; a
%                                 no-op while "Follow main window" is off
%   w3.Refresh()                  force a re-render (bypasses the skip cache)
%
%   The volume itself is a MatVisVolumeView, so this window gets the Image
%   Processing Toolbox renderer where it exists and the toolbox-free
%   projection-on-a-face fallback where it does not.  Mouse gestures over the
%   toolbox renderer are its own (left-drag rotates, ctrl + left-drag pans,
%   wheel and middle-drag zoom); over the fallback they are handled here and
%   follow the 2-D windows (left-drag rotates, middle-drag pans, wheel zooms).
%
%   See also MatVisVolumeView, MatVisXSecWin.

if nargin < 2 || isempty(cbs),   cbs = struct();               end
if nargin < 3 || isempty(dsIdx), dsIdx = model.ActiveDataset;  end
if isempty(dsIdx), dsIdx = 1; end

nDims = numel(model.Size);

% Voxel budget for interactive rendering — the same one the cross-section
% window uses.  A full-size volume is sent to the renderer only on request.
MAXVOX = 4e6;

hideCb = [];
if isfield(cbs, 'onHide') && isa(cbs.onHide, 'function_handle')
    hideCb = cbs.onHide;
end

CMAPS  = getColormapItems3D();
STYLES = MatVisVolumeView.styleItems();
STYLELBL = {'Max intensity', 'Min intensity', 'Volume rendering', ...
            'Isosurface', 'Gradient opacity', 'Slice planes'};

%% ---- state -------------------------------------------------------------
dims3   = defaultDims();
ranges  = fullRanges(dims3);
follow  = true;                      % track the main window's navigation
useMainZoom = false;                 % take the extent from the shared zoom
fullRes = false;
cMin_ = model.AllDataMins(dsIdx);    % overwritten by every Update() call
cMax_ = model.AllDataMaxs(dsIdx);
gam_  = model.Gamma;
ownContrast = false;
ocMin = cMin_;  ocMax = cMax_;  oGam = 1;
dataSig = [];
lastMs  = NaN;
lastVox = [0 0 0];
lastStr = [1 1 1];
ptCalib = [];
dragMode  = '';
dragStart = [];
orbitView = [];

%% ---- figure ------------------------------------------------------------
name = '3D view';
if model.NumDatasets > 1
    name = ['3D view: ' model.DatasetNames{dsIdx}];
end
fig = uifigure('Name', name, 'NumberTitle', 'off', 'Resize', 'on', ...
    'AutoResizeChildren', 'off', 'Visible', 'off', ...
    'Position', [140 140 980 710]);
fig.CloseRequestFcn = @(~,~) onCloseRequest();

root = uigridlayout(fig, [2 1]);
root.RowHeight  = {'1x', 20};
root.Padding    = [4 4 4 4];
root.RowSpacing = 3;

main = uigridlayout(root, [1 2]);
main.Layout.Row     = 1;
main.ColumnWidth    = {'1x', 312};
main.Padding        = [0 0 0 0];
main.ColumnSpacing  = 4;

holder = uipanel(main, 'BorderType', 'none');
holder.Layout.Column = 1;

side = uigridlayout(main, [5 1]);
side.Layout.Column = 2;
% Room for the rows themselves (22 each), plus the spacing and padding of the
% panel's own grid and the panel title bar: 22*n + 3*(n-1) + 8 + 23.
side.RowHeight     = {128, 153, 178, 190, '1x'};
side.Padding       = [0 0 0 0];
side.RowSpacing    = 4;
side.Scrollable    = 'on';

lblStatus = uilabel(root, 'Text', '', 'FontSize', 10, 'Tag', 'matVis3DStatus', ...
    'HorizontalAlignment', 'left');
lblStatus.Layout.Row = 2;

%% ---- Volume ------------------------------------------------------------
pVol = uipanel(side, 'Title', 'Volume');
gv = uigridlayout(pVol, [4 2]);
gv.RowHeight   = {22, 22, 22, 22};
gv.ColumnWidth = {24, '1x'};
gv.Padding     = [6 4 6 4];
gv.RowSpacing  = 3;

ddDim = gobjects(1, 3);
tags  = {'X', 'Y', 'Z'};
for s_ = 1:3
    uilabel(gv, 'Text', tags{s_}, 'HorizontalAlignment', 'right');
    ddDim(s_) = uidropdown(gv, 'Items', dimItems(), 'ItemsData', 1:nDims, ...
        'Value', dims3(s_), 'ValueChangedFcn', ...
        @(src, ~) onDimChanged(s_, src.Value));
end

gvf = uigridlayout(gv, [1 2]);
gvf.Layout.Row    = 4;
gvf.Layout.Column = [1 2];
gvf.ColumnWidth   = {'1x', 66};
gvf.Padding       = [0 0 0 0];
gvf.ColumnSpacing = 4;
uicheckbox(gvf, 'Text', 'Follow main window', 'Value', follow, ...
    'Tooltip', ['On: the volume is rebuilt whenever the main window ' ...
                'navigates.' newline 'Off: it is frozen until Refresh.'], ...
    'ValueChangedFcn', @(src, ~) onFollowToggle(src.Value));
uibutton(gvf, 'Text', 'Refresh', 'ButtonPushedFcn', @(~,~) forceRefresh());

%% ---- Extent ------------------------------------------------------------
pExt = uipanel(side, 'Title', 'Extent / sampling');
ge = uigridlayout(pExt, [5 3]);
ge.RowHeight   = {22, 22, 22, 22, 22};
ge.ColumnWidth = {24, '1x', '1x'};
ge.Padding     = [6 4 6 4];
ge.RowSpacing  = 3;

spLo = gobjects(1, 3);
spHi = gobjects(1, 3);
for s_ = 1:3
    uilabel(ge, 'Text', tags{s_}, 'HorizontalAlignment', 'right');
    spLo(s_) = uispinner(ge, 'Limits', [1 model.Size(dims3(s_))], ...
        'Value', ranges(s_, 1), 'RoundFractionalValues', 'on', 'Step', 1, ...
        'ValueChangedFcn', @(~, ~) onExtentChanged(s_));
    spHi(s_) = uispinner(ge, 'Limits', [1 model.Size(dims3(s_))], ...
        'Value', ranges(s_, 2), 'RoundFractionalValues', 'on', 'Step', 1, ...
        'ValueChangedFcn', @(~, ~) onExtentChanged(s_));
end

chkMainZoom = uicheckbox(ge, 'Text', 'Use main-window zoom', ...
    'Value', useMainZoom, 'Tooltip', ...
    'Take the extent from the shared zoom ranges instead of these spinners.', ...
    'ValueChangedFcn', @(src, ~) onMainZoomToggle(src.Value));
chkMainZoom.Layout.Row    = 4;
chkMainZoom.Layout.Column = [1 3];

chkFullRes = uicheckbox(ge, 'Text', 'Full resolution', 'Value', fullRes, ...
    'Tooltip', sprintf(['Render from the full-resolution volume.\nOff ' ...
        '(default): strided down to ~%.0fM voxels so the view keeps up ' ...
        'with navigation.'], MAXVOX/1e6), ...
    'ValueChangedFcn', @(src, ~) onFullResToggle(src.Value));
chkFullRes.Layout.Row    = 5;
chkFullRes.Layout.Column = [1 2];
btnFull = uibutton(ge, 'Text', 'Full extent', ...
    'ButtonPushedFcn', @(~,~) resetExtent());
btnFull.Layout.Row    = 5;
btnFull.Layout.Column = 3;

%% ---- Rendering ---------------------------------------------------------
pRen = uipanel(side, 'Title', 'Rendering');
gr = uigridlayout(pRen, [6 2]);
gr.RowHeight   = {22, 22, 22, 22, 22, 22};
gr.ColumnWidth = {68, '1x'};
gr.Padding     = [6 4 6 4];
gr.RowSpacing  = 3;

uilabel(gr, 'Text', 'Style:');
ddStyle = uidropdown(gr, 'Items', STYLELBL, 'ItemsData', STYLES, ...
    'Value', STYLES{1}, 'ValueChangedFcn', @(~,~) onLookChanged());

uilabel(gr, 'Text', 'Colormap:');
ddCmap = uidropdown(gr, 'Items', [{'Follow main window'}, CMAPS], ...
    'ItemsData', [{0}, num2cell(1:numel(CMAPS))], 'Value', 0, ...
    'ValueChangedFcn', @(~,~) onLookChanged());

uilabel(gr, 'Text', 'Alpha:');
ddAlpha = uidropdown(gr, 'Items', {'Flat', 'Linear ramp', 'Window'}, ...
    'ItemsData', {'flat', 'linear', 'window'}, 'Value', 'flat', ...
    'Tooltip', ['Flat is what a projection wants: the default ramp ' ...
                'attenuates dim voxels,' newline 'so faint structure ' ...
                'disappears instead of projecting at its true value.'], ...
    'ValueChangedFcn', @(~,~) onLookChanged());

uilabel(gr, 'Text', 'Window:');
gw = uigridlayout(gr, [1 2]);
gw.ColumnWidth   = {'1x', '1x'};
gw.Padding       = [0 0 0 0];
gw.ColumnSpacing = 4;
spAlphaLo = uispinner(gw, 'Limits', [0 1], 'Value', 0, 'Step', 0.05, ...
    'ValueChangedFcn', @(~,~) onLookChanged());
spAlphaHi = uispinner(gw, 'Limits', [0 1], 'Value', 1, 'Step', 0.05, ...
    'ValueChangedFcn', @(~,~) onLookChanged());

uilabel(gr, 'Text', 'Isovalue:');
spIso = uispinner(gr, 'Limits', [0 1], 'Value', 0.15, 'Step', 0.01, ...
    'Tooltip', 'Isosurface level / gradient-opacity threshold, 0..1.', ...
    'ValueChangedFcn', @(~,~) onLookChanged());

g6 = uigridlayout(gr, [1 4]);
g6.Layout.Row    = 6;
g6.Layout.Column = [1 2];
g6.ColumnWidth   = {'fit', '1x', '1x', '1x'};
g6.Padding       = [0 0 0 0];
g6.ColumnSpacing = 3;
uicheckbox(g6, 'Text', 'Own contrast', ...
    'Value', ownContrast, 'Tooltip', ...
    ['Off: the contrast bounds and gamma of the main window.' newline ...
     'On: the ones set here — a projection often needs a different window.'], ...
    'ValueChangedFcn', @(src, ~) onOwnContrastToggle(src.Value));
spCMin = uispinner(g6, 'Value', cMin_, 'Enable', 'off', ...
    'ValueDisplayFormat', '%.10g', ...
    'Tooltip', 'Contrast minimum', 'ValueChangedFcn', @(~,~) onContrastEdit());
spCMax = uispinner(g6, 'Value', cMax_, 'Enable', 'off', ...
    'ValueDisplayFormat', '%.10g', ...
    'Tooltip', 'Contrast maximum', 'ValueChangedFcn', @(~,~) onContrastEdit());
spGam  = uispinner(g6, 'Limits', [0.1 5], 'Value', 1, 'Step', 0.1, ...
    'Enable', 'off', 'Tooltip', 'Gamma', ...
    'ValueChangedFcn', @(~,~) onContrastEdit());

%% ---- View --------------------------------------------------------------
pView = uipanel(side, 'Title', 'View');
gvw = uigridlayout(pView, [6 2]);
gvw.RowHeight   = {22, 22, 22, 22, 22, 22};
gvw.ColumnWidth = {68, '1x'};
gvw.Padding     = [6 4 6 4];
gvw.RowSpacing  = 3;

uilabel(gvw, 'Text', 'Projection:');
uidropdown(gvw, 'Items', {'Orthographic', 'Perspective'}, ...
    'ItemsData', {'orthographic', 'perspective'}, 'Value', 'orthographic', ...
    'ValueChangedFcn', @(src, ~) onProjChanged(src.Value));

uilabel(gvw, 'Text', 'Direction:');
gp = uigridlayout(gvw, [1 4]);
gp.ColumnWidth   = {'1x', '1x', '1x', '1x'};
gp.Padding       = [0 0 0 0];
gp.ColumnSpacing = 3;
uibutton(gp, 'Text', 'XY', 'ButtonPushedFcn', @(~,~) setAngles(0, 90));
uibutton(gp, 'Text', 'XZ', 'ButtonPushedFcn', @(~,~) setAngles(0, 0));
uibutton(gp, 'Text', 'YZ', 'ButtonPushedFcn', @(~,~) setAngles(90, 0));
uibutton(gp, 'Text', '3D', 'ButtonPushedFcn', @(~,~) setAngles(-37.5, 30));

uilabel(gvw, 'Text', 'Az / El:');
ga = uigridlayout(gvw, [1 2]);
ga.ColumnWidth   = {'1x', '1x'};
ga.Padding       = [0 0 0 0];
ga.ColumnSpacing = 4;
spAz = uispinner(ga, 'Limits', [-180 180], 'Value', -37.5, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) setAngles(spAz.Value, spEl.Value));
spEl = uispinner(ga, 'Limits', [-89 89], 'Value', 30, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) setAngles(spAz.Value, spEl.Value));

uilabel(gvw, 'Text', 'Zoom:');
spZoom = uispinner(gvw, 'Limits', [0.05 50], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(src, ~) onZoomEdit(src.Value));

g5 = uigridlayout(gvw, [1 2]);
g5.Layout.Row    = 5;
g5.Layout.Column = [1 2];
g5.ColumnWidth   = {'fit', '1x'};
g5.Padding       = [0 0 0 0];
g5.ColumnSpacing = 3;
uicheckbox(g5, 'Text', 'Bounding box', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) onBoxToggle(src.Value));
uicheckbox(g5, 'Text', 'Orientation axes', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) onOrientToggle(src.Value));

ddBg = uidropdown(gvw, 'Items', {'Black', 'White'}, ...
    'ItemsData', {'black', 'white'}, 'Value', 'black', ...
    'ValueChangedFcn', @(src, ~) onBgChanged(src.Value));
ddBg.Layout.Row    = 6;
ddBg.Layout.Column = 1;
btnResetView = uibutton(gvw, 'Text', 'Reset view', ...
    'ButtonPushedFcn', @(~,~) resetView());
btnResetView.Layout.Row    = 6;
btnResetView.Layout.Column = 2;

%% ---- volume view -------------------------------------------------------
vv = MatVisVolumeView(holder);
vv.PointerFcn     = @ptFig;
vv.CameraMovedFcn = @syncCameraControls;
vv.setBoxVisible(true);
vv.setOrientationAxes(true);

fig.WindowButtonDownFcn   = @(src, ~) onMouseDown(src);
fig.WindowButtonMotionFcn = @(~, ~)   onMouseMove();
fig.WindowButtonUpFcn     = @(~, ~)   onMouseUp();
fig.WindowScrollWheelFcn  = @(~, evt) onScrollWheel(evt);

syncControls();

%% ---- public interface --------------------------------------------------
w3.fig     = fig;
w3.dsIdx   = dsIdx;
w3.Show    = @showWin;
w3.Update  = @updateAll;
w3.Refresh = @forceRefresh;
w3.View    = @currentView;    % camera + dims + style, for the video generator
w3.Dims    = @() dims3;
w3.Style   = @() ddStyle.Value;

% =========================================================================
%  Rendering
% =========================================================================
    function updateAll(cmin, cmax, gamma, ~)
        % Called by the main window's render loop.  The per-channel RGB
        % ranges are ignored: a volume rendering is always scalar.
        if nargin >= 1 && ~isempty(cmin), cMin_ = cmin; end
        if nargin >= 2 && ~isempty(cmax), cMax_ = cmax; end
        if nargin >= 3 && ~isempty(gamma), gam_ = gamma; end
        if ~ownContrast
            spCMin.Value = cMin_;
            spCMax.Value = cMax_;
            spGam.Value  = max(0.1, min(5, gam_));
        end
        if ~follow || ~strcmp(fig.Visible, 'on'), return; end
        render();
    end

    function forceRefresh()
        dataSig = [];
        render();
    end

    function v = currentView()
        % What this window is showing, in the terms the video generator's
        % 3-D panel takes: the camera, which three dimensions the volume
        % spans, and the rendering style.  az / el / zoom come back NaN when
        % the backend cannot report them (a headless viewer3d never
        % initialises its camera), so a caller can still take the rest.
        [az, el] = vv.cameraAngles();
        v = struct('az', az, 'el', el, 'zoom', vv.cameraZoom(), ...
                   'dims', dims3, 'style', ddStyle.Value);
    end

    function showWin()
        fig.Visible = 'on';
        forceRefresh();
        figure(fig);
    end

    function render()
        if nDims < 3 || numel(unique(dims3)) < 3, return; end
        rng3 = effectiveRanges();
        budget = MAXVOX;
        if fullRes, budget = Inf; end
        [lo, n, strides] = MatVisVolumeView.planSampling(rng3, budget);

        sig = {dims3, lo, n, strides, model.CurrPos(otherDims()), ...
               contrastBounds(), model.FilterType, model.FilterPar};
        if isequal(sig, dataSig), return; end
        dataSig = sig;

        t0 = tic;
        cb = contrastBounds();
        [V, voxSize] = MatVisVolumeView.extractVolume(model, ...
            model.Datasets{dsIdx}, dims3, lo, n, strides, cb(1), cb(2), cb(3));
        vv.Colormap = currentColormap();
        vv.Alphamap = currentAlphamap();
        vv.Style    = ddStyle.Value;
        vv.IsoValue = spIso.Value;
        vv.GradientOpacityValue = spIso.Value;
        vv.Labels   = {dimLabel(dims3(1)), dimLabel(dims3(2)), dimLabel(dims3(3))};
        vv.setVolume(V, voxSize);
        lastMs  = toc(t0) * 1000;
        lastVox = double(size(V, 1:3));
        lastStr = strides;
        showStatus();
    end

    function applyLook()
        vv.Colormap = currentColormap();
        vv.Alphamap = currentAlphamap();
        vv.Style    = ddStyle.Value;
        vv.IsoValue = spIso.Value;
        vv.GradientOpacityValue = spIso.Value;
        vv.applyLook();
    end

    function c = currentColormap()
        idx = ddCmap.Value;
        if isequal(idx, 0), idx = model.ColormapIdx; end
        c = MatVisRender.getColormap(idx, 256);
    end

    function a = currentAlphamap()
        a = MatVisVolumeView.alphamapPreset(ddAlpha.Value, ...
                [spAlphaLo.Value, spAlphaHi.Value]);
    end

    function cb = contrastBounds()
        % [lo hi gamma] the volume is normalized with.
        if ownContrast
            cb = [ocMin, ocMax, oGam];
        else
            cb = [cMin_, cMax_, gam_];
        end
        if cb(2) <= cb(1), cb(2) = cb(1) + eps(cb(1)) + 1; end
    end

    function d = otherDims()
        d = setdiff(1:nDims, dims3);
    end

    function showStatus()
        strTxt = '';
        if any(lastStr > 1)
            strTxt = sprintf(' (stride %d/%d/%d)', lastStr);
        end
        backend = 'MIP fallback';
        if vv.isViewer3D(), backend = 'viewer3d'; end
        [az, el] = vv.cameraAngles();
        lblStatus.Text = sprintf('%d x %d x %d%s = %.2f M voxels  ·  %s  ·  %.0f ms  ·  az %.0f  el %.0f', ...
            lastVox(1), lastVox(2), lastVox(3), strTxt, prod(lastVox)/1e6, ...
            backend, lastMs, az, el);
    end

% =========================================================================
%  Controls
% =========================================================================
    function d = defaultDims()
        xd = model.XDim;
        yd = model.YDim;
        others = setdiff(1:nDims, [xd yd], 'stable');
        if isempty(others)
            d = [xd yd yd];
        else
            d = [xd yd others(1)];
        end
    end

    function r = fullRanges(d)
        r = [ones(3, 1), reshape(model.Size(d), [], 1)];
    end

    function r = effectiveRanges()
        if useMainZoom
            r = model.ZoomRange(dims3(:), :);
        else
            r = ranges;
        end
        for s = 1:3
            N = model.Size(dims3(s));
            r(s, 1) = max(1, min(round(r(s, 1)), N));
            r(s, 2) = max(r(s, 1), min(round(r(s, 2)), N));
        end
    end

    function items = dimItems()
        items = arrayfun(@(d) dimLabel(d), 1:nDims, 'UniformOutput', false);
    end

    function s = dimLabel(d)
        if ~isempty(model.DimNames) && numel(model.DimNames) >= d
            s = model.DimNames{d};
        else
            s = sprintf('Dim%d', d);
        end
    end

    function syncControls()
        for s = 1:3
            N = model.Size(dims3(s));
            ddDim(s).Value  = dims3(s);
            spLo(s).Limits  = [1 N];
            spHi(s).Limits  = [1 N];
            spLo(s).Value   = max(1, min(ranges(s, 1), N));
            spHi(s).Value   = max(spLo(s).Value, min(ranges(s, 2), N));
            spLo(s).Enable  = onOff3_(~useMainZoom);
            spHi(s).Enable  = onOff3_(~useMainZoom);
        end
        en = onOff3_(ownContrast);
        spCMin.Enable = en;  spCMax.Enable = en;  spGam.Enable = en;
        syncCameraControls();
    end

    function syncCameraControls()
        [az, el] = vv.cameraAngles();
        if isfinite(az), spAz.Value = max(-180, min(180, az)); end
        if isfinite(el), spEl.Value = max(-89, min(89, el)); end
        z = vv.cameraZoom();
        if isfinite(z) && z >= spZoom.Limits(1) && z <= spZoom.Limits(2)
            spZoom.Value = z;
        end
        showStatus();
    end

    function onDimChanged(slot, newDim)
        if isempty(slot), return; end
        clash = find(dims3 == newDim & (1:3) ~= slot, 1);
        if ~isempty(clash)
            dims3(clash) = dims3(slot);      % swap, so the slots stay distinct
        end
        dims3(slot) = newDim;
        ranges = fullRanges(dims3);
        syncControls();
        forceRefresh();
    end

    function onExtentChanged(slot)
        if isempty(slot), return; end
        lo = spLo(slot).Value;
        hi = spHi(slot).Value;
        if hi < lo
            hi = lo;
            spHi(slot).Value = hi;
        end
        ranges(slot, :) = [lo, hi];
        render();
    end

    function resetExtent()
        ranges = fullRanges(dims3);
        syncControls();
        render();
    end

    function onMainZoomToggle(tf)
        useMainZoom = logical(tf);
        syncControls();
        render();
    end

    function onFullResToggle(tf)
        fullRes = logical(tf);
        render();
    end

    function onFollowToggle(tf)
        follow = logical(tf);
        if follow, render(); end
    end

    function onLookChanged()
        applyLook();
        % A style or alpha change does not need a new volume, but a colormap
        % change does reach the fallback renderer's cached faces — applyLook
        % redraws those, so nothing else is needed here.
    end

    function onOwnContrastToggle(tf)
        ownContrast = logical(tf);
        if ownContrast
            ocMin = spCMin.Value;
            ocMax = spCMax.Value;
            oGam  = spGam.Value;
        else
            spCMin.Value = cMin_;
            spCMax.Value = cMax_;
            spGam.Value  = max(0.1, min(5, gam_));
        end
        syncControls();
        render();
    end

    function onContrastEdit()
        ocMin = spCMin.Value;
        ocMax = spCMax.Value;
        oGam  = spGam.Value;
        render();
    end

    function onProjChanged(mode)
        vv.setProjection(mode);
    end

    function onZoomEdit(z)
        vv.setCameraZoom(z);
    end

    function onBoxToggle(tf)
        vv.setBoxVisible(tf);
    end

    function onOrientToggle(tf)
        vv.setOrientationAxes(tf);
    end

    function onBgChanged(c)
        vv.setBackground(c);
    end

    function setAngles(az, el)
        vv.setCameraAngles(az, el);
        syncCameraControls();
    end

    function resetView()
        vv.resetCamera();
        syncCameraControls();
    end

% =========================================================================
%  Mouse (fallback renderer only — a viewer3d keeps its own events)
% =========================================================================
    function pt = ptFig()
        % Pointer position in figure pixels.  fig.CurrentPoint stops updating
        % while the mouse is over a viewer3d (an HTML component that keeps
        % the pointer events to itself), so it is derived from the root
        % pointer once the offset between the two has been measured.
        pt = fig.CurrentPoint;
        if isempty(ptCalib), return; end
        try
            pt = get(groot, 'PointerLocation') - fig.Position(1:2) + 1 + ptCalib;
        catch
            pt = fig.CurrentPoint;
        end
    end

    function tf = overView()
        tf = false;
        if isempty(holder) || ~isvalid(holder), return; end
        p  = getpixelposition(holder, true);
        pt = ptFig();
        tf = pt(1) >= p(1) && pt(1) <= p(1)+p(3) && ...
             pt(2) >= p(2) && pt(2) <= p(2)+p(4);
    end

    function onMouseDown(src)
        if vv.isViewer3D() || ~overView(), return; end
        try
            ptCalib = fig.CurrentPoint - ...
                      (get(groot, 'PointerLocation') - fig.Position(1:2) + 1);
        catch
        end
        switch src.SelectionType
            case 'extend'                    % middle-drag: pan
                dragMode  = 'pan';
                dragStart = ptFig();
                fig.Pointer = 'hand';
            case 'normal'
                [az, el]  = vv.cameraAngles();
                orbitView = [az, el];
                dragMode  = 'orbit';
                dragStart = ptFig();
        end
    end

    function onMouseMove()
        if isempty(dragMode), return; end
        pt = ptFig();
        d  = pt - dragStart;
        switch dragMode
            case 'orbit'
                vv.setCameraAngles(orbitView(1) - d(1)*0.5, ...
                                   orbitView(2) + d(2)*0.5);
            case 'pan'
                vv.pan(d);
                dragStart = pt;    % incremental, so nothing accumulates
        end
        syncCameraControls();
    end

    function onMouseUp()
        dragMode    = '';
        fig.Pointer = 'arrow';
    end

    function onScrollWheel(evt)
        if vv.isViewer3D() || ~overView(), return; end
        n = evt.VerticalScrollCount;
        if ~isfinite(n), n = 0; end
        vv.zoomAtCursor(1.2 ^ max(-2, min(2, n)));
        syncCameraControls();
    end

    function onCloseRequest()
        fig.Visible = 'off';
        if ~isempty(hideCb)
            try; hideCb(); catch; end
        end
    end
end % MatVis3DWin

% ---- Module helpers -------------------------------------------------------
function s = onOff3_(tf)
    if tf, s = 'on'; else, s = 'off'; end
end

function items = getColormapItems3D()
    % The same list the main window offers, in the same order — the index is
    % what MatVisRender.getColormap takes.
    items = {
        'gray', 'Gray(Range)', '4x Gray', 'turbo', 'parula', 'jet', 'hsv', 'hot', 'cool', ...
        'Red1', 'Green1', 'Blue1', 'Cyan1', 'Magenta1', 'Yellow1', ...
        'Red2', 'Green2', 'Blue2', 'Cyan2', 'Magenta2', 'Yellow2', ...
        'Rainbow1', 'Rainbow2', 'Rainbow3', 'Rainbow4', 'Rainbow5', 'Rainbow6', ...
        'BlueGrayYellow', 'BlueGrayRed', 'GreenGrayRed', 'MagentaGrayGreen'
    };
end
