function ds = MatVisDimSelector(parent, model, renderFcn)
% MatVisDimSelector  Create X/Y dimension + projection + RGB controls.
%
%   ds = MatVisDimSelector(parent, model, renderFcn)
%
%   Two-row layout:
%     X: [dropX] [flipX]  Y: [dropY] [flipY]  Proj: [dropProjFun] [dropProjDim] [lock]
%                                             RGB:  [dropRGBDim          ]
%
%   Projection dimension dropdown shows only dimensions that are neither
%   XDim nor YDim.  The function dropdown includes 'none' (default = off).
%   The RGB dropdown lists 'none' (default = off) plus the available
%   dimensions; it excludes an active projection dimension and vice versa,
%   so both modes can be combined but never act on the same dimension.

validateattributes(renderFcn, {'function_handle'}, {}, mfilename, 'renderFcn', 3);

% Two rows, 10 columns: lbl | drop | btn | lbl | drop | btn | lbl | fun | dim | lock
grid = uigridlayout(parent, [2 10]);
grid.ColumnWidth   = {'fit','1x','fit', 'fit','1x','fit', 'fit','1x','1x', 'fit'};
grid.RowHeight     = {'fit', 'fit'};
grid.ColumnSpacing = 4;
grid.RowSpacing    = 4;
grid.Padding       = [4 4 4 4];

% --- X dimension -----------------------------------------------------------
lblX = uilabel(grid, 'Text', 'X:', 'HorizontalAlignment', 'right');
lblX.Layout.Row    = 1;
lblX.Layout.Column = 1;

dropX = uidropdown(grid);
dropX.Layout.Row    = 1;
dropX.Layout.Column = 2;
dropX.Tooltip = 'Select dimension for X axis';

btnFlipX = uibutton(grid, 'state', 'Text', char(8596), 'Tooltip', 'Flip X');
btnFlipX.Layout.Row    = 1;
btnFlipX.Layout.Column = 3;

% --- Y dimension -----------------------------------------------------------
lblY = uilabel(grid, 'Text', 'Y:', 'HorizontalAlignment', 'right');
lblY.Layout.Row    = 1;
lblY.Layout.Column = 4;

dropY = uidropdown(grid);
dropY.Layout.Row    = 1;
dropY.Layout.Column = 5;
dropY.Tooltip = 'Select dimension for Y axis';

btnFlipY = uibutton(grid, 'state', 'Text', char(8597), 'Tooltip', 'Flip Y');
btnFlipY.Layout.Row    = 1;
btnFlipY.Layout.Column = 6;

% --- Projection controls ---------------------------------------------------
lblProj = uilabel(grid, 'Text', 'Proj:', 'HorizontalAlignment', 'right');
lblProj.Layout.Row    = 1;
lblProj.Layout.Column = 7;

dropProjFun = uidropdown(grid);
dropProjFun.Layout.Row    = 1;
dropProjFun.Layout.Column = 8;
dropProjFun.Items     = {'none', 'max', 'min', 'mean', 'std', 'var', 'tile'};
dropProjFun.ItemsData = {'none', 'max', 'min', 'mean', 'std', 'var', 'tile'};
dropProjFun.Value     = model.ProjFun;
dropProjFun.Tooltip   = 'Projection function (''none'' = single slice)';

dropProjDim = uidropdown(grid);
dropProjDim.Layout.Row    = 1;
dropProjDim.Layout.Column = 9;
dropProjDim.Tooltip = 'Dimension to project along';

btnProjLock = uibutton(grid, 'state', ...
    'Text', '', 'Icon', dimSelOpenLockIcon_(14), 'Value', false, ...
    'Tooltip', sprintf(['Lock projection to zoom range of selected dimension.\n' ...
        'When active, only data within the zoom interval is projected.']));
btnProjLock.Layout.Row    = 1;
btnProjLock.Layout.Column = 10;

% --- RGB controls (row 2, below the projection controls) -------------------
lblRGB = uilabel(grid, 'Text', 'RGB:', 'HorizontalAlignment', 'right');
lblRGB.Layout.Row    = 2;
lblRGB.Layout.Column = 7;

dropRGBDim = uidropdown(grid);
dropRGBDim.Layout.Row    = 2;
dropRGBDim.Layout.Column = [8 9];
dropRGBDim.Tooltip = sprintf(['Map a dimension to R/G/B color channels (''none'' = off).\n' ...
    'Dimensions with up to 3 entries map slice -> channel; larger\n' ...
    'dimensions are split into three equal groups (mean of each group).\n' ...
    'Can be combined with a projection along a different dimension.']);

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
dropProjFun.ValueChangedFcn  = @(src, ~) onProjFunChanged(src, model, dropProjDim, btnProjLock, dropRGBDim, renderFcn);
dropProjDim.ValueChangedFcn  = @(src, ~) onProjDimChanged(src, model, dropRGBDim, renderFcn);
btnProjLock.ValueChangedFcn  = @(src, ~) onProjLockChanged(src, model, renderFcn);
dropRGBDim.ValueChangedFcn   = @(src, ~) onRGBDimChanged(src, model, dropProjDim, renderFcn);

% --- Output ----------------------------------------------------------------
ds.dropX        = dropX;
ds.dropY        = dropY;
ds.btnFlipX     = btnFlipX;
ds.btnFlipY     = btnFlipY;
ds.dropProjFun  = dropProjFun;
ds.dropProjDim  = dropProjDim;
ds.btnProjLock  = btnProjLock;
ds.dropRGBDim   = dropRGBDim;
ds.Update       = @() updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY, dropProjDim, dropRGBDim);

% Sync lock button enable state with initial ProjFun
btnProjLock.Enable = onoff_(~strcmp(model.ProjFun, 'none'));

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
dropProjDim.Enable = onoff_(~strcmp(model.ProjFun, 'none'));
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

function onProjFunChanged(dropProjFun, model, dropProjDim, btnProjLock, dropRGBDim, renderFcn)
model.ProjFun = dropProjFun.Value;
% Activating/deactivating the projection changes which dims the RGB
% dropdown may offer.
populateRGBDimDropdown(model, dropRGBDim);
active = ~strcmp(model.ProjFun, 'none');
dropProjDim.Enable = onoff_(active && model.ProjDim > 0);
btnProjLock.Enable = onoff_(active);
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

function updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY, dropProjDim, dropRGBDim)
populateDropdowns(model, dropX, dropY);
syncFlipButtons(model, btnFlipX, btnFlipY);
populateProjDimDropdown(model, dropProjDim);
populateRGBDimDropdown(model, dropRGBDim);
end

% ---------------------------------------------------------------------------

function s = onoff_(tf)
if tf, s = 'on'; else, s = 'off'; end
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
