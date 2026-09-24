function ds = MatVisDimSelector(parent, model, renderFcn)
% MatVisDimSelector  Create X/Y dimension + projection + RGB controls.
%
%   ds = MatVisDimSelector(parent, model, renderFcn)
%
%   Four logical columns x three rows.  Each control sits in its own small
%   [label | control (| button)] sub-grid.  Fixed label-column widths make
%   controls line up across rows and keep the filter-parameter box from
%   moving when its label (Sigma/Size/Radius/Par) changes:
%
%     X:    [dropX  ] [flipX]   Y:   [dropY  ] [flipY]   RGB: [dropRGBDim ........]
%     Asp:  [btnAsp ]           Win: [btnWin ]           Proj:[dropProjFun] Dim:[dropProjDim][lk]
%                                                        Filt:[dropFilter ] Par:[editFilterPar  ]
%
%   So: dropX aligns with btnAspect, dropY with btnWinScale (same widths);
%   the RGB / projection / filter function dropdowns share a left edge and
%   the projection-fun and filter-fun dropdowns share a width; the projection
%   dimension dropdown and the filter-parameter box share a left edge; and
%   the RGB dropdown, projection lock and filter-parameter box share a right
%   edge.
%
%   Projection dimension dropdown shows only dimensions that are neither
%   XDim nor YDim.  The function dropdown includes 'none' (default = off).
%   The RGB dropdown lists 'none' (default = off) plus the available
%   dimensions; it excludes an active projection dimension and vice versa,
%   so both modes can be combined but never act on the same dimension.

validateattributes(renderFcn, {'function_handle'}, {}, mfilename, 'renderFcn', 3);

% Four equal columns; every cell is a [label | control (| mini-button)]
% sub-grid with a fixed label width, so the dropdowns / buttons line up into
% four vertical columns:
%
%   Col 1        Col 2          Col 3          Col 4
%   X:[dropX][f] Y:[dropY][f]   Asp:[btn]      Win:[btn]
%   Proj:[fun]   Dim:[dim][lk]  Filt:[fun]     Par:[edit]
%   RGB:[drop]   [Mean Stretch] [Max Stretch]  [lock]
%
% The RGB row is last so the main window can dock the blue/red-point stretch
% bar directly beneath it, aligned with the RGB dropdown..lock span.
%
FONT     = 10;   % dropdown / edit text  (1 pt smaller)
FONT_LBL =  9;   % labels (fit the narrow label column)
FONT_BTN =  8;   % button captions
LBL      = 26;   % label column width (cols 1-3)
LBL4     = 34;   % label column width (col 4 — fits the dynamic 'Radius')
BTN_MINI = 20;   % flip / projection-lock mini buttons
BTN_LOCK = 24;   % RGB stretch lock
ROW_H    = 23;   % fixed control-row height — every control fills it, so the
                 % dropdowns and buttons (incl. Mean/Max Stretch) match exactly

grid = uigridlayout(parent, [3 4]);
grid.ColumnWidth   = {'1x', '1x', '1x', '1x'};
grid.RowHeight     = {ROW_H, ROW_H, ROW_H};
grid.ColumnSpacing = 2;          % tighter gaps between the four columns
grid.RowSpacing    = 3;
grid.Padding       = [2 2 2 7];  % extra top padding nudges all controls down 5 px
                                 % (the RGB stretch bar below is unaffected)

% --- Row 1: X / Y dimensions (+ flips), aspect ratio, window scaling --------
cX = subcell_(grid, 1, 1, {LBL, '1x', BTN_MINI});
uilabel(cX, 'Text', 'X:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropX = uidropdown(cX, 'Tooltip', 'Select dimension for X axis', 'FontSize', FONT);
btnFlipX = uibutton(cX, 'state', 'Text', char(8596), 'Tooltip', 'Flip X', 'FontSize', FONT);

cY = subcell_(grid, 1, 2, {LBL, '1x', BTN_MINI});
uilabel(cY, 'Text', 'Y:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropY = uidropdown(cY, 'Tooltip', 'Select dimension for Y axis', 'FontSize', FONT);
btnFlipY = uibutton(cY, 'state', 'Text', char(8597), 'Tooltip', 'Flip Y', 'FontSize', FONT);

% Aspect & window-scale behaviour is wired by the main window (it owns the
% image/zoom windows); here we only build the controls and expose handles.
cAsp = subcell_(grid, 1, 3, {LBL, '1x'});
uilabel(cAsp, 'Text', 'Asp:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
btnAspect = uibutton(cAsp, 'state', ...
    'Text', aspectLabel_(model), 'Value', logical(model.AspectRatioFixed), ...
    'FontSize', FONT_BTN, ...
    'Tooltip', sprintf(['Image/zoom axes: fixed aspect ratio or fill.\n' ...
        'Left click: toggle fill / fixed.\n' ...
        'Right click: set aspect ratio.']));

cWin = subcell_(grid, 1, 4, {LBL4, '1x'});
uilabel(cWin, 'Text', 'Win:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
btnWinScale = uibutton(cWin, 'push', ...
    'Text', sprintf('%d%%', round(model.WinScalePct)), 'FontSize', FONT_BTN, ...
    'Tooltip', sprintf(['Scale the zoom window (100%% = 1 data pixel per screen pixel).\n' ...
        'Left click: apply current scale.\n' ...
        'Right click: set scaling factor.']));

% --- Row 2: projection + image filter --------------------------------------
% Filtering requires the Image Processing Toolbox; if absent, the filter
% controls are shown but disabled so the layout stays consistent.
filterAvail = MatVisRender.filterAvailable();

cProjF = subcell_(grid, 2, 1, {LBL, '1x'});
uilabel(cProjF, 'Text', 'Proj:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropProjFun = uidropdown(cProjF, 'FontSize', FONT);
dropProjFun.Items     = {'none', 'max', 'min', 'mean', 'std', 'var', 'tile'};
dropProjFun.ItemsData = {'none', 'max', 'min', 'mean', 'std', 'var', 'tile'};
dropProjFun.Value     = model.ProjFun;
dropProjFun.Tooltip   = 'Projection function (''none'' = single slice)';

cProjD = subcell_(grid, 2, 2, {LBL, '1x', BTN_MINI});
uilabel(cProjD, 'Text', 'Dim:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropProjDim = uidropdown(cProjD, 'Tooltip', 'Dimension to project along', 'FontSize', FONT);
btnProjLock = uibutton(cProjD, 'state', ...
    'Text', '', 'Icon', dimSelOpenLockIcon_(14), 'Value', false, ...
    'Tooltip', sprintf(['Lock projection to zoom range of selected dimension.\n' ...
        'When active, only data within the zoom interval is projected.\n' ...
        'Can be set before switching the projection on, so a projection over ' ...
        'a large dimension never has to be computed in full.']));

cFilt = subcell_(grid, 2, 3, {LBL, '1x'});
uilabel(cFilt, 'Text', 'Filt:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropFilter = uidropdown(cFilt, 'FontSize', FONT);
if filterAvail
    filtItems = {'none', 'gauss', 'median', 'mean', 'unsharp'};
    dropFilter.Tooltip = 'Spatial filter applied to the displayed image (x/y only).';
else
    filtItems = {'none'};
    dropFilter.Enable  = 'off';
    dropFilter.Tooltip = 'Image filtering requires the Image Processing Toolbox.';
end
dropFilter.Items     = filtItems;
dropFilter.ItemsData = filtItems;
if ismember(model.FilterType, filtItems)
    dropFilter.Value = model.FilterType;
else
    dropFilter.Value = 'none';
    model.FilterType = 'none';
end

cFiltPar = subcell_(grid, 2, 4, {LBL4, '1x'});
lblFilterPar = uilabel(cFiltPar, 'Text', filterParLabel_(model.FilterType), ...
    'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
editFilterPar = uieditfield(cFiltPar, 'text', 'Value', num2str(model.FilterPar), 'FontSize', FONT);
editFilterPar.Tooltip = sprintf(['Filter parameter (0 = off). Enter a scalar for\n' ...
    'isotropic x/y filtering, or [x y] for anisotropic sizes.\n' ...
    'gauss: sigma   median/mean: size   unsharp: radius [amount].']);
editFilterPar.Enable = onoff_(filterAvail && ~strcmp(model.FilterType, 'none'));

% --- Row 3: RGB dimension + stretch modes + stretch zoom-lock --------------
% Last row so the main window can dock the blue/red-point stretch bar right
% below it. Empty label spacers align the stretch buttons with the dropdowns.
cRGB = subcell_(grid, 3, 1, {LBL, '1x'});
uilabel(cRGB, 'Text', 'RGB:', 'HorizontalAlignment', 'right', 'FontSize', FONT_LBL);
dropRGBDim = uidropdown(cRGB, 'FontSize', FONT, 'Tooltip', sprintf(['Show three consecutive positions of a dimension as R/G/B (''none'' = off).\n' ...
    'Current position -> green, previous -> red, next -> blue, wrapping\n' ...
    'around at the ends. Move the dimension''s slider to scan the triad.\n' ...
    'Use Mean Stretch / Max Stretch to colour-code the whole dimension instead.']));

% Mean Stretch / Max Stretch are mutually-exclusive state buttons (wired by
% the main window); both off = ordinary three-slice RGB triad.
cMean = subcell_(grid, 3, 2, {LBL, '1x'});
uilabel(cMean, 'Text', '', 'FontSize', FONT_LBL);   % spacer (aligns button)
btnRGBMean = uibutton(cMean, 'state', 'Text', 'Mean Stretch', 'FontSize', 8, ...
    'Enable', 'off', ...
    'Tooltip', sprintf(['Mean Stretch: colour-code the whole RGB dimension.\n' ...
        'Each x/y pixel = intensity-weighted average colour over the\n' ...
        'dimension (position -> hue via the rainbow below).']));

cMax = subcell_(grid, 3, 3, {LBL, '1x'});
uilabel(cMax, 'Text', '', 'FontSize', FONT_LBL);    % spacer (aligns button)
btnRGBMax = uibutton(cMax, 'state', 'Text', 'Max Stretch', 'FontSize', 8, ...
    'Enable', 'off', ...
    'Tooltip', sprintf(['Max Stretch: colour-code the whole RGB dimension.\n' ...
        'Each x/y pixel takes the brightness of its strongest slice and\n' ...
        'the hue of that slice''s position (rainbow below).']));

cRGBLock = subcell_(grid, 3, 4, {'1x', BTN_LOCK});
uilabel(cRGBLock, 'Text', '', 'FontSize', FONT_LBL);   % spacer (right-aligns lock)
btnRGBLock = uibutton(cRGBLock, 'state', 'Text', '', 'Icon', dimSelOpenLockIcon_(14), ...
    'Value', logical(model.RGBStretchZoomLock), 'Enable', 'off', ...
    'Tooltip', sprintf(['Lock RGB stretch to the zoom interval of the RGB dimension.\n' ...
        'When active, only indices within the zoom range are colour-coded.']));

% --- Populate from model ---------------------------------------------------
populateDropdowns(model, dropX, dropY);
syncFlipButtons(model, btnFlipX, btnFlipY);
populateProjDimDropdown(model, dropProjDim);
populateRGBDimDropdown(model, dropRGBDim);

% --- Callbacks -------------------------------------------------------------
dropX.ValueChangedFcn       = @(src, ~) onDropXChanged(src, model, dropY, dropProjDim, dropRGBDim, renderFcn);
dropY.ValueChangedFcn       = @(src, ~) onDropYChanged(src, model, dropX, dropProjDim, dropRGBDim, renderFcn);
btnFlipX.ValueChangedFcn    = @(src, ~) onFlipChanged(src, 'X', model, renderFcn);
btnFlipY.ValueChangedFcn    = @(src, ~) onFlipChanged(src, 'Y', model, renderFcn);
dropProjFun.ValueChangedFcn  = @(src, ~) onProjFunChanged(src, model, dropProjDim, dropRGBDim, renderFcn);
dropProjDim.ValueChangedFcn  = @(src, ~) onProjDimChanged(src, model, dropRGBDim, renderFcn);
btnProjLock.ValueChangedFcn  = @(src, ~) onProjLockChanged(src, model, renderFcn);
dropRGBDim.ValueChangedFcn   = @(src, ~) onRGBDimChanged(src, model, dropProjDim, renderFcn);
btnRGBMean.ValueChangedFcn   = @(src, ~) onRGBStretchModeToggle(src, model, 'mean', btnRGBMax, renderFcn);
btnRGBMax.ValueChangedFcn    = @(src, ~) onRGBStretchModeToggle(src, model, 'max',  btnRGBMean, renderFcn);
btnRGBLock.ValueChangedFcn   = @(src, ~) onRGBStretchLockToggle(src, model, renderFcn);
dropFilter.ValueChangedFcn   = @(src, ~) onFilterChanged(src, model, lblFilterPar, editFilterPar, renderFcn);
editFilterPar.ValueChangedFcn = @(src, ~) onFilterParChanged(src, model, renderFcn);

% --- Output ----------------------------------------------------------------
ds.dropX        = dropX;
ds.dropY        = dropY;
ds.btnFlipX     = btnFlipX;
ds.btnFlipY     = btnFlipY;
ds.dropProjFun  = dropProjFun;
ds.dropProjDim  = dropProjDim;
ds.btnProjLock  = btnProjLock;
ds.dropRGBDim   = dropRGBDim;
ds.btnRGBMean   = btnRGBMean;
ds.btnRGBMax    = btnRGBMax;
ds.btnRGBLock   = btnRGBLock;
ds.btnAspect    = btnAspect;
ds.btnWinScale  = btnWinScale;
ds.dropFilter   = dropFilter;
ds.editFilterPar = editFilterPar;
ds.Update       = @() updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY, dropProjDim, dropRGBDim, btnAspect, btnWinScale);

% The projection zoom lock stays enabled even with ProjFun == 'none', so it can
% be armed before the projection is switched on (avoids projecting a large
% dimension in full first).

end % MatVisDimSelector

% ===========================================================================
%  Local helpers
% ===========================================================================

function populateDropdowns(model, dropX, dropY)
names   = model.DimNames;
idxData = num2cell(1:numel(names));
dropX.Items = names;  dropX.ItemsData = idxData;  dropX.Value = model.XDim;
dropY.Items = names;  dropY.ItemsData = idxData;  dropY.Value = model.YDim;
end

% ---------------------------------------------------------------------------

function populateProjDimDropdown(model, dropProjDim)
% Only show dims that are neither XDim nor YDim, nor an active RGB dim.
N     = numel(model.DimNames);
avail = setdiff(1:N, [model.XDim, model.YDim]);
if model.RGBDim > 0
    avail = setdiff(avail, model.RGBDim);
end

if isempty(avail)
    dropProjDim.Items     = {'—'};
    dropProjDim.ItemsData = {0};
    dropProjDim.Value     = 0;
    dropProjDim.Enable    = 'off';
    model.ProjDim         = 0;
    return;
end

dropProjDim.Items     = model.DimNames(avail);
dropProjDim.ItemsData = num2cell(avail);

% Keep current ProjDim if still valid; else use first available.
if ismember(model.ProjDim, avail)
    dropProjDim.Value = model.ProjDim;
else
    dropProjDim.Value = avail(1);
    model.ProjDim     = avail(1);
end
% Stays enabled whether or not a projection is running, so the dimension can
% be chosen before the projection is engaged rather than after.
dropProjDim.Enable = 'on';
end

% ---------------------------------------------------------------------------

function populateRGBDimDropdown(model, dropRGBDim)
% List 'none' (= off) plus dims that are neither XDim nor YDim, nor an
% active projection dim.
N     = numel(model.DimNames);
avail = setdiff(1:N, [model.XDim, model.YDim]);
if ~strcmp(model.ProjFun, 'none')
    avail = setdiff(avail, model.ProjDim);
end

dropRGBDim.Items     = [{'none'}, model.DimNames(avail)];
dropRGBDim.ItemsData = [{0}, num2cell(avail)];
dropRGBDim.Enable    = onoff_(~isempty(avail));

% Keep current RGBDim if still valid; else fall back to 'none' (off).
if ismember(model.RGBDim, avail)
    dropRGBDim.Value = model.RGBDim;
else
    dropRGBDim.Value = 0;
    model.RGBDim     = 0;
end
end

% ---------------------------------------------------------------------------

function syncFlipButtons(model, btnFlipX, btnFlipY)
if isprop(model, 'FlipX') || (isstruct(model) && isfield(model, 'FlipX'))
    btnFlipX.Value = logical(model.FlipX);
end
if isprop(model, 'FlipY') || (isstruct(model) && isfield(model, 'FlipY'))
    btnFlipY.Value = logical(model.FlipY);
end
end

% ---------------------------------------------------------------------------

function onDropXChanged(dropX, model, dropY, dropProjDim, dropRGBDim, renderFcn)
newX  = dropX.Value;
currY = model.YDim;
if newX == currY
    oldX = model.XDim;
    model.YDim = oldX;   % move Y away first to avoid conflict
    model.XDim = newX;
    dropY.Value = oldX;
else
    model.XDim = newX;
end
populateProjDimDropdown(model, dropProjDim);
populateRGBDimDropdown(model, dropRGBDim);
renderFcn();
end

% ---------------------------------------------------------------------------

function onDropYChanged(dropY, model, dropX, dropProjDim, dropRGBDim, renderFcn)
newY  = dropY.Value;
currX = model.XDim;
if newY == currX
    oldY = model.YDim;
    model.XDim = oldY;   % move X away first to avoid conflict
    model.YDim = newY;
    dropX.Value = oldY;
else
    model.YDim = newY;
end
populateProjDimDropdown(model, dropProjDim);
populateRGBDimDropdown(model, dropRGBDim);
renderFcn();
end

% ---------------------------------------------------------------------------

function onProjFunChanged(dropProjFun, model, dropProjDim, dropRGBDim, renderFcn)
model.ProjFun = dropProjFun.Value;
% Activating/deactivating the projection changes which dims the RGB
% dropdown may offer.
populateRGBDimDropdown(model, dropRGBDim);
dropProjDim.Enable = onoff_(model.ProjDim > 0);
renderFcn();
end

% ---------------------------------------------------------------------------

function onProjDimChanged(dropProjDim, model, dropRGBDim, renderFcn)
v = dropProjDim.Value;
if isnumeric(v) && v > 0
    model.ProjDim = v;
end
populateRGBDimDropdown(model, dropRGBDim);
renderFcn();
end

% ---------------------------------------------------------------------------

function onRGBDimChanged(dropRGBDim, model, dropProjDim, renderFcn)
% 'none' (0) switches RGB mode off; a dim index switches it on.
model.RGBDim = dropRGBDim.Value;
populateProjDimDropdown(model, dropProjDim);
renderFcn();
end

% ---------------------------------------------------------------------------

function onRGBStretchModeToggle(btn, model, mode, btnOther, renderFcn)
% MeanStretch / MaxStretch state buttons (mutually exclusive). The main
% window reconciles enable/value/visibility after the render via syncStretchUI.
if btn.Value
    model.RGBStretchMode = mode;
    btnOther.Value = false;
elseif strcmp(model.RGBStretchMode, mode)
    model.RGBStretchMode = 'none';
end
renderFcn();
end

% ---------------------------------------------------------------------------

function onRGBStretchLockToggle(btn, model, renderFcn)
model.RGBStretchZoomLock = logical(btn.Value);
if btn.Value
    btn.Icon = dimSelLockIcon_(14);
else
    btn.Icon = dimSelOpenLockIcon_(14);
end
renderFcn();
end

% ---------------------------------------------------------------------------

function onFilterChanged(dropFilter, model, lblFilterPar, editFilterPar, renderFcn)
model.FilterType = dropFilter.Value;
lblFilterPar.Text = filterParLabel_(model.FilterType);
editFilterPar.Enable = onoff_(~strcmp(model.FilterType, 'none'));
renderFcn();
end

% ---------------------------------------------------------------------------

function onFilterParChanged(editFilterPar, model, renderFcn)
% Allow scalars and vectors (e.g. "[2 3]"); str2num mirrors the original
% matVis eval-based parsing.  Reject anything non-finite or negative.
v = str2num(editFilterPar.Value);  %#ok<ST2NM>
if isempty(v) || ~all(isfinite(v(:))) || any(v(:) < 0)
    editFilterPar.Value = num2str(model.FilterPar);   % revert to last good
    return;
end
model.FilterPar = v(:)';
renderFcn();
end

% ---------------------------------------------------------------------------

function s = filterParLabel_(filterType)
switch filterType
    case 'gauss',            s = 'Sigma';
    case 'unsharp',          s = 'Radius';
    case {'median', 'mean'}, s = 'Size';
    otherwise,               s = 'Par';
end
end

% ---------------------------------------------------------------------------

function onProjLockChanged(btn, model, renderFcn)
model.ProjZoomLock = logical(btn.Value);
if btn.Value
    btn.Icon = dimSelLockIcon_(14);
else
    btn.Icon = dimSelOpenLockIcon_(14);
end
renderFcn();
end

% ---------------------------------------------------------------------------

function onFlipChanged(btn, axis, model, renderFcn)
if strcmp(axis, 'X')
    if isprop(model, 'FlipX') || (isstruct(model) && isfield(model, 'FlipX'))
        model.FlipX = logical(btn.Value);
    end
else
    if isprop(model, 'FlipY') || (isstruct(model) && isfield(model, 'FlipY'))
        model.FlipY = logical(btn.Value);
    end
end
renderFcn();
end

% ---------------------------------------------------------------------------

function updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY, dropProjDim, dropRGBDim, btnAspect, btnWinScale)
populateDropdowns(model, dropX, dropY);
syncFlipButtons(model, btnFlipX, btnFlipY);
populateProjDimDropdown(model, dropProjDim);
populateRGBDimDropdown(model, dropRGBDim);
if nargin >= 8 && isgraphics(btnAspect)
    btnAspect.Value = logical(model.AspectRatioFixed);
    btnAspect.Text  = aspectLabel_(model);
end
if nargin >= 9 && isgraphics(btnWinScale)
    btnWinScale.Text = sprintf('%d%%', round(model.WinScalePct));
end
end

% ---------------------------------------------------------------------------

function txt = aspectLabel_(model)
% Button caption: 'a:b' when a fixed ratio is active, 'fill' otherwise.
if model.AspectRatioFixed
    r = model.AspectRatio;
    txt = sprintf('%g:%g', r(1), r(2));
else
    txt = 'fill';
end
end

% ---------------------------------------------------------------------------

function s = onoff_(tf)
if tf, s = 'on'; else, s = 'off'; end
end

% ---------------------------------------------------------------------------

function g = subcell_(parent, r, c, widths)
% One grid cell holding [label | control (| mini-button)] in a row, so the
% control keeps most of the cell width while labels line up across rows.
g = uigridlayout(parent, [1, numel(widths)]);
g.Layout.Row    = r;
g.Layout.Column = c;
g.ColumnWidth   = widths;
g.RowHeight     = {'1x'};   % controls fill the fixed-height row -> equal heights
g.Padding       = [0 0 0 0];
g.ColumnSpacing = 1;        % tight gap between label and control
end

% ---------------------------------------------------------------------------

function img = dimSelLockIcon_(sz)
% Closed padlock icon: body + closed U-shackle.
bg = 0.94;  fg = 0.18;
img = bg * ones(sz, sz, 3);
bL = round(sz * 0.18);  bR = sz + 1 - round(sz * 0.18);
bT = round(sz * 0.52);  bB = min(sz, round(sz * 0.93));
img(bT:bB, bL:bR, :) = fg;
sL = round(sz * 0.32);  sR = sz + 1 - round(sz * 0.32);
sT = max(1, round(sz * 0.10));  sw = max(2, round(sz * 0.13));
img(sT:bT,      sL:sL+sw-1, :) = fg;
img(sT:bT,      sR-sw+1:sR, :) = fg;
img(sT:sT+sw-1, sL:sR,      :) = fg;
end

% ---------------------------------------------------------------------------

function img = dimSelOpenLockIcon_(sz)
% Open padlock icon: body + shackle with right side raised.
bg = 0.94;  fg = 0.18;
img = bg * ones(sz, sz, 3);
bL = round(sz * 0.18);  bR = sz + 1 - round(sz * 0.18);
bT = round(sz * 0.52);  bB = min(sz, round(sz * 0.93));
img(bT:bB, bL:bR, :) = fg;
sL = round(sz * 0.32);  sR = sz + 1 - round(sz * 0.32);
sT = max(1, round(sz * 0.10));  sw = max(2, round(sz * 0.13));
img(sT:bT,      sL:sL+sw-1, :) = fg;   % left wall (connects to body)
img(sT:sT+sw-1, sL:sR,      :) = fg;   % top bar
openEnd = max(sT+sw, round(sz * 0.32));
img(sT:openEnd, sR-sw+1:sR,  :) = fg;  % right wall (short — open)
end
