function test_roi_manager
% test_roi_manager  Headless tests for ROI state, geometry, and traces.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));

data  = rand(50, 60, 30);          % dims: y(1) x x(2) x t(3)
model = MatVisModel(data);          % default XDim=2, YDim=1

%% AddRoi: rectangle in pixel coords (x along dim 2, y along dim 1)
corners = [9.5 9.5 20.5 20.5 9.5; 14.5 25.5 25.5 14.5 14.5];
idx = model.AddRoi(corners);
assert(idx == 1 && numel(model.RoiList) == 1, 'AddRoi failed');
roi = model.RoiList(1);
assert(isequal(size(roi.mask), [60, 50]), 'mask must be Size(XDim) x Size(YDim)');
assert(nnz(roi.mask) == 11 * 11, 'rect 10..20 x 15..25 must cover 11x11 px');
assert(isequal(model.RoiSelection, 1), 'new ROI must be selected');

%% Trace along dim 3 matches manual masked mean
p = MatVisRender.renderRoiProfileFromData(model, model.Data, 3, roi, false);
assert(numel(p) == 30, 'trace length mismatch');
manual = zeros(30, 1);
for t = 1:30
    sl = data(:, :, t);             % [y x]
    manual(t) = mean(sl(roi.mask'));
end
assert(max(abs(manual - p)) < 1e-12, 'ROI trace differs from manual masked mean');

% Display dims are refused
assert(isempty(MatVisRender.renderRoiProfileFromData(model, model.Data, 2, roi, false)));

% Zoom-restricted trace
model.ZoomRange(3, :) = [5, 14];
pz = MatVisRender.renderRoiProfileFromData(model, model.Data, 3, roi, true);
assert(numel(pz) == 10 && max(abs(pz - manual(5:14))) < 1e-12, 'zoom trace wrong');

%% Pixel values in current slice
v = MatVisRender.getRoiValuesFromData(model, model.Data, roi);
assert(numel(v) == nnz(roi.mask), 'getRoiValues count mismatch');
sl = data(:, :, model.CurrPos(3));
assert(abs(mean(v) - mean(sl(roi.mask'))) < 1e-12, 'getRoiValues values wrong');

%% Shift via corner edit + RecomputeRoiGeometry
model.RoiList(1).corners         = model.RoiList(1).corners + [5; 0];
model.RoiList(1).cornersPixelDim = model.RoiList(1).corners;
model.RecomputeRoiGeometry(1);
assert(nnz(model.RoiList(1).mask) == 11 * 11, 'shifted mask size changed');
assert(min(model.RoiList(1).index.x) == 15, 'shift not applied to mask');

%% Copy / rename / delete
model.CopyRois(1);
assert(numel(model.RoiList) == 2, 'copy failed');
assert(model.RoiList(2).number ~= model.RoiList(1).number, 'copy must get new number');
model.RenameRoi(2, 'soma');
assert(strcmp(model.RoiList(2).name, 'soma'), 'rename failed');
model.DeleteRois(2);
assert(numel(model.RoiList) == 1, 'delete failed');

%% Visible-ROI filtering follows the display plane
assert(isequal(model.VisibleRoiIndices(), 1));
model.XDim = 3;                     % ROI plane no longer displayed
assert(isempty(model.VisibleRoiIndices()), 'ROI must hide when plane changes');
model.XDim = 2;
assert(isequal(model.VisibleRoiIndices(), 1));

%% Export / import round-trip (original matVis format)
tmp = [tempname, '.mat'];
matVisRoiExport = model.RoiList; %#ok<NASGU>
save(tmp, 'matVisRoiExport');
S = load(tmp);
n = model.ImportRois(S.matVisRoiExport, true);
assert(n == 1 && numel(model.RoiList) == 2, 'import-append failed');
assert(isequal(model.RoiList(2).mask, model.RoiList(1).mask), 'round-trip mask differs');
n = model.ImportRois(S.matVisRoiExport, false);
assert(n == 1 && numel(model.RoiList) == 1, 'import-replace failed');
delete(tmp);

%% Import with flipped xySel transposes coordinates
flipped = model.RoiList(1);
flipped.cornersPixelDim = flipped.cornersPixelDim([2 1], :);
flipped.corners         = flipped.cornersPixelDim;
flipped.settings.xySel  = [model.YDim, model.XDim];
n = model.ImportRois(flipped, true);
assert(n == 1, 'flipped import failed');
assert(isequal(model.RoiList(2).mask, model.RoiList(1).mask), 'flip handling wrong');

%% RoiChanged event fires
fired = 0;
lh = addlistener(model, 'RoiChanged', @(~,~) assignin('caller', 'unused', 0)); %#ok<NASGU>
delete(lh);
lh2 = addlistener(model, 'RoiChanged', @(~,~) increment());
model.SetRoiSelection([1 2]);
assert(fired == 1, 'RoiChanged not fired on selection');
assert(isequal(model.RoiSelection, [1 2]));
delete(lh2);

fprintf('ALL ROI MANAGER TESTS PASS\n');

    function increment()
        fired = fired + 1;
    end
end
