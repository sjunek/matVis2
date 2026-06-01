function ds = MatVisDimSelector(parent, model, renderFcn)
% MatVisDimSelector  Create X/Y dimension selection controls.
%
%   ds = MatVisDimSelector(parent, model, renderFcn)
%
%   Creates a uigridlayout inside PARENT containing:
%     - Label + dropdown + flip toggle for the X dimension
%     - Label + dropdown + flip toggle for the Y dimension
%
%   Inputs
%     parent     - Parent container (uifigure, uipanel, or uigridlayout cell)
%     model      - Object or struct with properties:
%                    .XDim      (scalar integer, 1-based)
%                    .YDim      (scalar integer, 1-based)
%                    .DimNames  (1xN cell array of strings)
%                    .Size      (1xN integer array)
%                  Optionally: .FlipX, .FlipY (logical)
%     renderFcn  - Function handle @() called after any change to trigger render
%
%   Output struct ds
%     ds.dropX    - uidropdown selecting the X dimension
%     ds.dropY    - uidropdown selecting the Y dimension
%     ds.btnFlipX - uitogglebutton for flipping the X direction
%     ds.btnFlipY - uitogglebutton for flipping the Y direction
%     ds.Update   - function handle: ds.Update() refreshes dropdowns from model

% --- Validate inputs -------------------------------------------------------
validateattributes(renderFcn, {'function_handle'}, {}, mfilename, 'renderFcn', 3);

% --- Build outer grid (2 rows x 3 cols: label | dropdown | flip btn) -------
grid = uigridlayout(parent, [2 3]);
grid.ColumnWidth   = {'fit', '1x', 'fit'};
grid.RowHeight     = {'fit', 'fit'};
grid.ColumnSpacing = 4;
grid.RowSpacing    = 4;
grid.Padding       = [4 4 4 4];

% --- Row 1: X dimension ----------------------------------------------------
lblX = uilabel(grid, 'Text', 'X:', 'HorizontalAlignment', 'right');
lblX.Layout.Row    = 1;
lblX.Layout.Column = 1;

dropX = uidropdown(grid);
dropX.Layout.Row    = 1;
dropX.Layout.Column = 2;
dropX.Tooltip       = 'Select dimension for X axis of displayed image';

btnFlipX = uitogglebutton(grid, 'Text', char(8596), ...
    'Tooltip', 'Flip X direction');
btnFlipX.Layout.Row    = 1;
btnFlipX.Layout.Column = 3;

% --- Row 2: Y dimension ----------------------------------------------------
lblY = uilabel(grid, 'Text', 'Y:', 'HorizontalAlignment', 'right');
lblY.Layout.Row    = 2;
lblY.Layout.Column = 1;

dropY = uidropdown(grid);
dropY.Layout.Row    = 2;
dropY.Layout.Column = 2;
dropY.Tooltip       = 'Select dimension for Y axis of displayed image';

btnFlipY = uitogglebutton(grid, 'Text', char(8597), ...
    'Tooltip', 'Flip Y direction');
btnFlipY.Layout.Row    = 2;
btnFlipY.Layout.Column = 3;

% --- Populate dropdowns from model -----------------------------------------
populateDropdowns(model, dropX, dropY);

% --- Sync flip button states from model (if properties exist) --------------
syncFlipButtons(model, btnFlipX, btnFlipY);

% --- Callbacks -------------------------------------------------------------
dropX.ValueChangedFcn    = @(src, ~) onDropXChanged(src, model, dropY, renderFcn);
dropY.ValueChangedFcn    = @(src, ~) onDropYChanged(src, model, dropX, renderFcn);
btnFlipX.ValueChangedFcn = @(src, ~) onFlipChanged(src, 'X', model, renderFcn);
btnFlipY.ValueChangedFcn = @(src, ~) onFlipChanged(src, 'Y', model, renderFcn);

% --- Assemble output struct ------------------------------------------------
ds.dropX    = dropX;
ds.dropY    = dropY;
ds.btnFlipX = btnFlipX;
ds.btnFlipY = btnFlipY;
ds.Update   = @() updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY);

end % MatVisDimSelector

% ===========================================================================
%  Local helpers
% ===========================================================================

function populateDropdowns(model, dropX, dropY)
% Fill both dropdowns with DimNames and set selected values.
names = model.DimNames;          % 1xN cell array of strings
idxData = num2cell(1:numel(names));

dropX.Items     = names;
dropX.ItemsData = idxData;
dropX.Value     = model.XDim;

dropY.Items     = names;
dropY.ItemsData = idxData;
dropY.Value     = model.YDim;
end

% ---------------------------------------------------------------------------

function syncFlipButtons(model, btnFlipX, btnFlipY)
% If model exposes FlipX/FlipY, read them; otherwise leave buttons at default.
if isprop(model, 'FlipX') || (isstruct(model) && isfield(model, 'FlipX'))
    btnFlipX.Value = logical(model.FlipX);
end
if isprop(model, 'FlipY') || (isstruct(model) && isfield(model, 'FlipY'))
    btnFlipY.Value = logical(model.FlipY);
end
end

% ---------------------------------------------------------------------------

function onDropXChanged(dropX, model, dropY, renderFcn)
% User changed the X dimension dropdown.
newX  = dropX.Value;   % scalar integer (ItemsData value)
currY = model.YDim;

if newX == currY
    % Collision: swap X and Y
    oldX = model.XDim;
    model.XDim = newX;
    model.YDim = oldX;
    dropY.Value = oldX;
else
    model.XDim = newX;
end

renderFcn();
end

% ---------------------------------------------------------------------------

function onDropYChanged(dropY, model, dropX, renderFcn)
% User changed the Y dimension dropdown.
newY  = dropY.Value;   % scalar integer
currX = model.XDim;

if newY == currX
    % Collision: swap X and Y
    oldY = model.YDim;
    model.YDim = newY;
    model.XDim = oldY;
    dropX.Value = oldY;
else
    model.YDim = newY;
end

renderFcn();
end

% ---------------------------------------------------------------------------

function onFlipChanged(btn, axis, model, renderFcn)
% Store flip state in model (if writable) and call render.
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

function updateFromModel(model, dropX, dropY, btnFlipX, btnFlipY)
% Refresh all controls to reflect the current model state (e.g. after
% external changes to model.XDim / model.YDim).
populateDropdowns(model, dropX, dropY);
syncFlipButtons(model, btnFlipX, btnFlipY);
end
