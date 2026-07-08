function test_rgb_ui_smoke
% Headless UI smoke test: launch matVis, drive the RGB/projection controls.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(rootDir, fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));
cd(rootDir);   % avoid shadowing by the legacy matVis.m in this folder

nFail = 0;
data = rand(20, 25, 3, 10);
data(5, 8, 2, 6) = 10;   % brightest pixel

mw = matVis2(data);
cleanupObj = onCleanup(@() close(mw.fig, 'force'));
model = []; %#ok<NASGU>
dsel  = mw.dimSelector;

% --- Brightest pixel start position reflected in sliders ---
posVals = cellfun(@(rs) rs.Value, mw.rangeSliders);
nFail = nFail + check(isequal(posVals, [5 8 2 6]), ...
    sprintf('Sliders start at brightest pixel (got [%s])', num2str(posVals)));

% --- RGB control exists in the dim selector, with 'none' selected ---
nFail = nFail + check(~isfield(dsel, 'cbRGB') && isfield(dsel, 'dropRGBDim'), ...
    'RGB dropdown present, checkbox removed');
nFail = nFail + check(strcmp(dsel.dropRGBDim.Items{1}, 'none') && ...
    isequal(dsel.dropRGBDim.Value, 0), 'RGB dropdown lists ''none'' first and defaults to it');

% --- Initially: both dropdowns offer dims 3 and 4 ---
projDims = cell2mat(dsel.dropProjDim.ItemsData);
rgbDims  = cell2mat(dsel.dropRGBDim.ItemsData);
nFail = nFail + check(isequal(projDims, [3 4]) && isequal(rgbDims, [0 3 4]), ...
    'Both dropdowns offer non-XY dims when both modes inactive');

% --- Enable RGB on dim 3 via the dropdown ---
dsel.dropRGBDim.Value = 3;
feval(dsel.dropRGBDim.ValueChangedFcn, dsel.dropRGBDim, []);
img = findobj(mw.imageWin.fig, 'Type', 'image');
cd1 = img(1).CData;
nFail = nFail + check(isa(cd1, 'uint8') && isequal(size(cd1), [20 25 3]), ...
    'Image window shows RGB-composed image');

% --- Projection dropdown now excludes the RGB dim ---
projDims = cell2mat(dsel.dropProjDim.ItemsData);
nFail = nFail + check(isequal(projDims, 4), ...
    sprintf('Proj dropdown excludes active RGB dim (got [%s])', num2str(projDims)));

% --- Activate max projection along dim 4 (compatible with RGB) ---
dsel.dropProjFun.Value = 'max';
feval(dsel.dropProjFun.ValueChangedFcn, dsel.dropProjFun, []);
rgbDims = cell2mat(dsel.dropRGBDim.ItemsData);
nFail = nFail + check(isequal(rgbDims, [0 3]), ...
    sprintf('RGB dropdown excludes active proj dim (got [%s])', num2str(rgbDims)));
img = findobj(mw.imageWin.fig, 'Type', 'image');
cd2 = img(1).CData;
nFail = nFail + check(isa(cd2, 'uint8') && isequal(size(cd2), [20 25 3]), ...
    'RGB + projection renders without error');

% --- Disable RGB via 'none': proj dropdown gets dim 3 back ---
dsel.dropRGBDim.Value = 0;
feval(dsel.dropRGBDim.ValueChangedFcn, dsel.dropRGBDim, []);
projDims = cell2mat(dsel.dropProjDim.ItemsData);
nFail = nFail + check(isequal(projDims, [3 4]), ...
    'Proj dropdown restored after RGB disabled');

% --- Deactivate projection too; render still fine ---
dsel.dropProjFun.Value = 'none';
feval(dsel.dropProjFun.ValueChangedFcn, dsel.dropProjFun, []);
mw.Render();
nFail = nFail + check(true, 'Render after deactivating both modes');

% --- Change X dim and verify dropdowns repopulate consistently ---
dsel.dropX.Value = 3;
feval(dsel.dropX.ValueChangedFcn, dsel.dropX, []);
projDims = cell2mat(dsel.dropProjDim.ItemsData);
rgbDims  = cell2mat(dsel.dropRGBDim.ItemsData);
nFail = nFail + check(isequal(projDims, [2 4]) && isequal(rgbDims, [0 2 4]), ...
    'Dropdowns repopulate after X dim change');

if nFail == 0
    fprintf('ALL UI TESTS PASSED\n');
else
    error('%d UI test(s) FAILED', nFail);
end
end

function bad = check(cond, name)
if cond
    fprintf('PASS: %s\n', name);
    bad = 0;
else
    fprintf(2, 'FAIL: %s\n', name);
    bad = 1;
end
end
