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
%       .onHide()          — the window was closed
%       .onViewChanged(s)  — a linked view setting changed here, so the owner
%                            should hand S to the other datasets' windows
%       .sharedView()      — the view the linked windows currently agree on,
%                            [] while there is none
%
%   w3.fig                        uifigure handle (created hidden)
%   w3.dsIdx                      dataset this window shows
%   w3.Show()                     show and render
%   w3.Update(cmin, cmax, gamma, chanRange)
%                                 called by the main window's render loop
%                                 with this dataset's contrast bounds; a
%                                 no-op while "Follow main window" is off
%   w3.Refresh()                  force a re-render (bypasses the skip cache)
%   w3.ViewState()                this window's linked view settings
%   w3.ApplyView(s)               adopt another window's; ignored while unlinked
%
%   With more than one dataset open the windows start linked: the dimensions,
%   the extent, the rendering and the camera of one are mirrored by the others,
%   so the same view is compared across datasets.  Contrast is not — bounds
%   only mean something per dataset — and neither is "Follow main window",
%   which is a per-window freeze switch.  Clearing "Link view to other
%   datasets" decouples a window; ticking it again rejoins the others.
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

% How long after adopting a view a camera report from the backend is taken
% for an echo of that adopt rather than a move of the user's own.  A viewer3d
% confirms a camera write through a web component, so its report lands well
% after the write — and can still carry the reading from before it.
ECHOWAIT = 0.25;     % seconds

% How often the camera is read back.  A viewer3d is an HTML component that
% keeps its gestures to itself: it offers a CameraMovedFcn, but an interactive
% rotation can pass without one, and the new camera then only reaches the
% other windows when something else happens to broadcast — which is what a
% linked view trailing one step behind actually looks like.
CAMPOLL = 0.1;       % seconds

hideCb = [];
if isfield(cbs, 'onHide') && isa(cbs.onHide, 'function_handle')
    hideCb = cbs.onHide;
end
viewChangedCb = [];
if isfield(cbs, 'onViewChanged') && isa(cbs.onViewChanged, 'function_handle')
    viewChangedCb = cbs.onViewChanged;
end
sharedViewCb = [];
if isfield(cbs, 'sharedView') && isa(cbs.sharedView, 'function_handle')
    sharedViewCb = cbs.sharedView;
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
aspect  = [1 1 1];                   % per-slot stretch on top of the pixel size
baseVox = [];                        % voxel size of the volume shown, unstretched
linked  = model.NumDatasets > 1;    % mirror the view in the other datasets
applying = false;                    % guard: adopting another window's view
pending  = [];                       % view that arrived while one was applied
adopted  = [];                       % last view adopted, to spot our own echo
adoptTic = [];                       % when that was, see ECHOWAIT
camPoll  = [];                       % timer watching the camera, see CAMPOLL
lastCam  = [];                       % camera as of the last time we looked
ready    = false;                    % construction done, so we may broadcast
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
% Tall enough for the side column, which grows by the link row (see below)
% when there is another dataset to share the view with.
fig = uifigure('Name', name, 'NumberTitle', 'off', 'Resize', 'on', ...
    'AutoResizeChildren', 'off', 'Visible', 'off', ...
    'Position', [140 140 980 710 + 25*(model.NumDatasets > 1)]);
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
% View takes one row more when there is another dataset to link the view to.
side.RowHeight     = {128, 153, 178, 190 + 25*(model.NumDatasets > 1), '1x'};
side.Padding       = [0 0 0 0];
side.RowSpacing    = 4;
side.Scrollable    = 'on';

lblStatus = uilabel(root, 'Text', '', 'FontSize', 10, 'Tag', 'matVis3DStatus', ...
    'HorizontalAlignment', 'left');
lblStatus.Layout.Row = 2;

%% ---- Volume ------------------------------------------------------------
pVol = uipanel(side, 'Title', 'Volume');
matVisShadePanelTitle(pVol);
gv = uigridlayout(pVol, [4 4]);
gv.RowHeight   = {22, 22, 22, 22};
gv.ColumnWidth = {24, '1x', 10, 58};
gv.Padding     = [6 4 6 4];
gv.RowSpacing  = 3;
gv.ColumnSpacing = 3;

ddDim    = gobjects(1, 3);
spAspect = gobjects(1, 3);
tags  = {'X', 'Y', 'Z'};
for s_ = 1:3
    uilabel(gv, 'Text', tags{s_}, 'HorizontalAlignment', 'right');
    ddDim(s_) = uidropdown(gv, 'Items', dimItems(), 'ItemsData', 1:nDims, ...
        'Value', dims3(s_), 'ValueChangedFcn', ...
        @(src, ~) onDimChanged(s_, src.Value));
    uilabel(gv, 'Text', char(215), 'HorizontalAlignment', 'center');
    spAspect(s_) = uispinner(gv, 'Limits', [0.01 100], 'Value', aspect(s_), ...
        'Step', 0.5, 'ValueDisplayFormat', '%.3g', ...
        'Tooltip', sprintf(['Stretch the %s axis by this factor.\n' ...
            '1 = true proportions from the pixel sizes.'], tags{s_}), ...
        'ValueChangedFcn', @(src, ~) onAspectChanged(s_, src.Value));
end

gvf = uigridlayout(gv, [1 2]);
gvf.Layout.Row    = 4;
gvf.Layout.Column = [1 4];
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
matVisShadePanelTitle(pExt);
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
matVisShadePanelTitle(pRen);
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
matVisShadePanelTitle(pView);
nViewRows = 6 + (model.NumDatasets > 1);
gvw = uigridlayout(pView, [nViewRows 2]);
gvw.RowHeight   = repmat({22}, 1, nViewRows);
gvw.ColumnWidth = {68, '1x'};
gvw.Padding     = [6 4 6 4];
gvw.RowSpacing  = 3;

uilabel(gvw, 'Text', 'Projection:');
ddProj = uidropdown(gvw, 'Items', {'Orthographic', 'Perspective'}, ...
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
% Through a nested function, not an anonymous one: an anonymous callback
% captures its variables where it is written, and spEl does not exist yet.
spAz = uispinner(ga, 'Limits', [-180 180], 'Value', -37.5, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onAngleEdit());
spEl = uispinner(ga, 'Limits', [-89 89], 'Value', 30, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onAngleEdit());

uilabel(gvw, 'Text', 'Zoom:');
spZoom = uispinner(gvw, 'Limits', [0.05 50], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(src, ~) onZoomEdit(src.Value));

g5 = uigridlayout(gvw, [1 2]);
g5.Layout.Row    = 5;
g5.Layout.Column = [1 2];
g5.ColumnWidth   = {'fit', '1x'};
g5.Padding       = [0 0 0 0];
g5.ColumnSpacing = 3;
chkBox = uicheckbox(g5, 'Text', 'Bounding box', 'Value', true, ...
    'ValueChangedFcn', @(src, ~) onBoxToggle(src.Value));
chkOrient = uicheckbox(g5, 'Text', 'Orientation axes', 'Value', true, ...
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

if model.NumDatasets > 1
    chkLink = uicheckbox(gvw, 'Text', 'Link view to other datasets', ...
        'Value', linked, 'Tooltip', ...
        ['On: dimensions, extent, rendering and camera are shared with the' ...
         newline 'other datasets'' 3-D windows.  Off: this one keeps its own.'], ...
        'ValueChangedFcn', @(src, ~) onLinkToggle(src.Value));
    chkLink.Layout.Row    = 7;
    chkLink.Layout.Column = [1 2];
end

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
ready = true;                % from here on a control change is broadcast

if model.NumDatasets > 1
    camPoll = timer('Name', 'matVis3DCam', 'ExecutionMode', 'fixedSpacing', ...
        'Period', CAMPOLL, 'BusyMode', 'drop', 'TimerFcn', @(~,~) pollCamera());
    fig.DeleteFcn = @(~,~) stopCamPoll();
    start(camPoll);
end

%% ---- public interface --------------------------------------------------
w3.fig     = fig;
w3.dsIdx   = dsIdx;
w3.Show    = @showWin;
w3.Update  = @updateAll;
w3.Refresh = @forceRefresh;
w3.View    = @currentView;    % camera + dims + style, for the video generator
w3.Dims    = @() dims3;
w3.Style   = @() ddStyle.Value;
w3.ViewState = @viewState;    % the settings a linked window mirrors
w3.ApplyView = @applyView;

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
        % spans, the rendering style and the per-axis stretch.  az / el / zoom come back NaN when
        % the backend cannot report them (a headless viewer3d never
        % initialises its camera), so a caller can still take the rest.
        [az, el] = vv.cameraAngles();
        v = struct('az', az, 'el', el, 'zoom', vv.cameraZoom(), ...
                   'dims', dims3, 'style', ddStyle.Value, 'aspect', aspect);
    end

    function showWin()
        fig.Visible = 'on';
        forceRefresh();
        % A view adopted while this window was hidden never reached the
        % camera: the backend only has one once it has been given a volume.
        % Now that it has, rejoin the other datasets.
        if linked && ~isempty(sharedViewCb)
            try; applyView(sharedViewCb()); catch; end
        end
        figure(fig);
    end

    function did = render()
        % DID is false when the volume was already up to date, so a caller
        % that also changed the look knows it still has to push it itself.
        did = false;
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
        baseVox = voxSize;
        vv.setVolume(V, voxSize .* aspect);
        lastMs  = toc(t0) * 1000;
        lastVox = double(size(V, 1:3));
        lastStr = strides;
        showStatus();
        did = true;
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
            spAspect(s).Value = aspect(s);
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
        lastCam = currentCam();
        broadcast();
    end

    function c = currentCam()
        [az, el] = vv.cameraAngles();
        c = struct('pose', vv.cameraPose(), 'az', az, 'el', el, ...
                   'zoom', vv.cameraZoom());
    end

    function pollCamera()
        % Has the backend moved the camera without telling us?  See CAMPOLL.
        if ~ready || applying || ~linked || ~isvalid(fig) || ...
                ~strcmp(fig.Visible, 'on')
            return;
        end
        if ~isempty(lastCam) && sameCam3_(currentCam(), lastCam), return; end
        syncCameraControls();     % refreshes the readouts and broadcasts
    end

    function stopCamPoll()
        if ~isempty(camPoll) && isvalid(camPoll)
            try; stop(camPoll);   catch; end
            try; delete(camPoll); catch; end
        end
        camPoll = [];
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
        broadcast(true);
    end

    function onAspectChanged(slot, val)
        % Only the voxel size changes, so the volume already extracted is
        % re-scaled rather than rebuilt.
        if isempty(slot), return; end
        aspect(slot) = val;
        if ~isempty(baseVox)
            vv.setVoxelSize(baseVox .* aspect);
        end
        broadcast(true);
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
        broadcast(true);
    end

    function resetExtent()
        ranges = fullRanges(dims3);
        syncControls();
        render();
        broadcast(true);
    end

    function onMainZoomToggle(tf)
        useMainZoom = logical(tf);
        syncControls();
        render();
        broadcast(true);
    end

    function onFullResToggle(tf)
        fullRes = logical(tf);
        render();
        broadcast(true);
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
        broadcast(true);
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
        broadcast(true);
    end

    function onZoomEdit(z)
        vv.setCameraZoom(z);
        broadcast(true);
    end

    function onBoxToggle(tf)
        vv.setBoxVisible(tf);
        broadcast(true);
    end

    function onOrientToggle(tf)
        vv.setOrientationAxes(tf);
        broadcast(true);
    end

    function onBgChanged(c)
        vv.setBackground(c);
        broadcast(true);
    end

    function onAngleEdit()
        setAngles(spAz.Value, spEl.Value);
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
%  Linked views
% =========================================================================
    function s = viewState()
        % What a linked window mirrors: what goes into the volume, how it is
        % rendered, and how it is viewed.  Contrast stays out — its bounds
        % only mean something per dataset — and so does "Follow main window".
        %
        % The camera travels as the backend's own pose rather than as azimuth
        % and elevation, which cannot describe the roll a free rotation adds.
        % The datasets have the same size and the same pixel sizes, and both
        % windows span the same dims and extent, so a pose means the same
        % thing in both.  The angles come along as a fallback: a backend that
        % keeps its camera on 'auto' reports no pose to copy, and they are
        % read whatever the mode says.
        [az, el] = vv.cameraAngles();
        s = struct('dims', dims3, 'ranges', ranges, 'aspect', aspect, ...
                   'useMainZoom', useMainZoom, 'fullRes', fullRes, ...
                   'style', ddStyle.Value, 'cmap', ddCmap.Value, ...
                   'alpha', ddAlpha.Value, ...
                   'alphaWin', [spAlphaLo.Value, spAlphaHi.Value], ...
                   'iso', spIso.Value, 'proj', ddProj.Value, ...
                   'bg', ddBg.Value, 'box', chkBox.Value, ...
                   'orient', chkOrient.Value, 'pose', vv.cameraPose(), ...
                   'az', az, 'el', el, 'zoom', vv.cameraZoom());
    end

    function applyView(s)
        % Adopt another dataset's view.  A decoupled window ignores it.
        %
        % Adopting one takes a render, and a render lets queued callbacks
        % through, so a newer view can arrive in the middle of an older one.
        % It is parked in PENDING and picked up here rather than applied by a
        % nested call, which would finish by laying the older view back over
        % the newer one — the window would trail one step behind for good.
        if ~linked || isempty(s) || ~isstruct(s), return; end
        if applying
            pending = s;
            return;
        end
        applying = true;
        pending  = [];
        try
            while ~isempty(s)
                if ~sameView3_(s, viewState())
                    adoptView(s);
                end
                adopted = s;
                s       = pending;
                pending = [];
            end
        catch
        end
        applying = false;
        pending  = [];
        adoptTic = tic;
    end

    function adoptView(s)
        % The scene is only touched when it differs.  A camera-only update
        % arrives as fast as the other window is being dragged, and pushing
        % the volume to the renderer at that rate would make this one crawl.
        if ~sameScene3_(s, viewState())
            adoptScene(s);
        end
        adoptCamera(s);
        % Last, because until now the angle spinners and the status line still
        % showed the camera this window had *before* the adopt.
        syncCameraControls();
    end

    function adoptScene(s)
        d = s.dims(:).';
        if numel(d) == 3 && all(d >= 1 & d <= nDims) && numel(unique(d)) == 3
            dims3 = d;
        end
        if isequal(size(s.ranges), [3 2]), ranges = s.ranges; end
        aspectChanged = false;
        if isfield(s, 'aspect') && numel(s.aspect) == 3 && ~isequal(s.aspect, aspect)
            aspect = s.aspect(:).';
            aspectChanged = true;
        end
        useMainZoom = logical(s.useMainZoom);
        fullRes     = logical(s.fullRes);
        chkMainZoom.Value = useMainZoom;
        chkFullRes.Value  = fullRes;
        ddStyle.Value   = s.style;
        ddCmap.Value    = s.cmap;
        ddAlpha.Value   = s.alpha;
        spAlphaLo.Value = s.alphaWin(1);
        spAlphaHi.Value = s.alphaWin(2);
        spIso.Value     = s.iso;
        ddProj.Value    = s.proj;
        ddBg.Value      = s.bg;
        chkBox.Value    = s.box;
        chkOrient.Value = s.orient;
        syncControls();              % clamps the extent to this dataset
        vv.setProjection(s.proj);
        vv.setBackground(s.bg);
        vv.setBoxVisible(s.box);
        vv.setOrientationAxes(s.orient);
        if strcmp(fig.Visible, 'on')
            if ~render()
                applyLook();
                if aspectChanged && ~isempty(baseVox)
                    vv.setVoxelSize(baseVox .* aspect);
                end
            end
        else
            dataSig = [];            % the next Show() rebuilds it
        end
    end

    function adoptCamera(s)
        % After the scene: a rebuilt volume re-fits a camera still in auto
        % mode, which would undo a write made before it.  It is written only
        % when it really differs, because a viewer3d answers a write with a
        % CameraMovedFcn of its own.
        if hasPose3_(s.pose)
            if ~samePose3_(s.pose, vv.cameraPose())
                vv.setCameraPose(s.pose);
            end
        else
            % Nothing to copy verbatim, so aim by the angles instead.  A roll
            % cannot survive that — but a backend that reports no pose offers
            % no way to carry one anyway.
            [az0, el0] = vv.cameraAngles();
            if isfinite(s.az) && isfinite(s.el) && ...
                    (~isfinite(az0) || ~isfinite(el0) || ...
                     abs(mod(az0 - s.az + 180, 360) - 180) > 0.01 || ...
                     abs(el0 - s.el) > 0.01)
                vv.setCameraAngles(s.az, s.el);
            end
            z0 = vv.cameraZoom();
            if isfinite(s.zoom) && (~isfinite(z0) || abs(z0 - s.zoom) > 1e-4)
                vv.setCameraZoom(s.zoom);
            end
        end
    end

    function broadcast(force)
        % Hand this view to the owner, which mirrors it into the other
        % datasets' 3-D windows.
        %
        % FORCE marks a change the user made in this window, which always
        % goes out.  Without it the call comes from the backend reporting
        % that the camera moved, and that may be nothing but the echo of a
        % view this window has just adopted — returning one of those to the
        % window it came from is what makes a pair of linked views chase each
        % other one step apart.  So an unforced report is dropped while it
        % still describes the adopted view, and during ECHOWAIT after the
        % adopt, by when a genuine gesture would have moved on.
        if ~ready || applying || ~linked || isempty(viewChangedCb), return; end
        v = viewState();
        if nargin < 1 || ~force
            if ~isempty(adoptTic) && toc(adoptTic) < ECHOWAIT, return; end
            if sameView3_(v, adopted), return; end
        end
        adopted  = [];       % from here on this window drives its own view
        adoptTic = [];
        try; viewChangedCb(v); catch; end
    end

    function onLinkToggle(tf)
        linked = logical(tf);
        if ~linked, return; end
        s = [];
        if ~isempty(sharedViewCb)
            try; s = sharedViewCb(); catch; s = []; end
        end
        if isempty(s)
            broadcast(true);     % nothing shared yet — this window sets the view
        else
            applyView(s);    % rejoin the others
        end
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

function tf = sameView3_(a, b)
    % Do two linked-view structs describe the same view?
    tf = sameScene3_(a, b) && sameCam3_(a, b);
end

function tf = sameCam3_(a, b)
    % Same camera?  Compared with a tolerance: a viewer3d hands its camera
    % back through a web component, so what comes back differs in the last
    % few digits from what was written.  NaN (no camera) equals NaN.
    tf = false;
    if isempty(a) || isempty(b) || ~isstruct(a) || ~isstruct(b), return; end
    tf = samePose3_(a.pose, b.pose) && nearPt3_(a.az, b.az) && ...
         nearPt3_(a.el, b.el) && nearPt3_(a.zoom, b.zoom);
end

function tf = sameScene3_(a, b)
    % Everything but the camera: what goes into the volume, and how it is
    % drawn.
    tf = false;
    if isempty(a) || isempty(b) || ~isstruct(a) || ~isstruct(b), return; end
    if ~isequal(a.dims, b.dims) || ~isequal(a.ranges, b.ranges) || ...
            ~isequal(a.aspect, b.aspect) || ...
            ~isequal(logical(a.useMainZoom), logical(b.useMainZoom)) || ...
            ~isequal(logical(a.fullRes), logical(b.fullRes)) || ...
            ~strcmp(a.style, b.style) || ~isequal(a.cmap, b.cmap) || ...
            ~strcmp(a.alpha, b.alpha) || ~isequal(a.alphaWin, b.alphaWin) || ...
            ~isequal(a.iso, b.iso) || ~strcmp(a.proj, b.proj) || ...
            ~strcmp(a.bg, b.bg) || ...
            ~isequal(logical(a.box), logical(b.box)) || ...
            ~isequal(logical(a.orient), logical(b.orient))
        return;
    end
    tf = true;
end

function tf = hasPose3_(p)
    % Did the backend hand over a camera, or is it still choosing one itself?
    tf = isstruct(p) && isscalar(p) && ...
         any(isfinite([p.pos, p.target, p.up, p.va, p.zoom]));
end

function tf = samePose3_(a, b)
    % Same camera pose?  What a viewer3d hands back differs in the last digits
    % from what was written into it, so the comparison is relative; a
    % component both sides leave to their backend is NaN on both.
    tf = false;
    if ~isstruct(a) || ~isstruct(b) || ~isscalar(a) || ~isscalar(b), return; end
    tf = nearPt3_(a.pos, b.pos) && nearPt3_(a.target, b.target) && ...
         nearPt3_(a.up, b.up) && nearPt3_(a.va, b.va) && ...
         nearPt3_(a.zoom, b.zoom);
end

function tf = nearPt3_(p, q)
    % Equal but for float noise, with NaN (nothing to compare) equal to NaN.
    tol = 1e-9;
    tf = numel(p) == numel(q) && ...
         all((isnan(p) & isnan(q)) | ...
             (abs(p - q) <= tol * (1 + abs(p) + abs(q))));
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
