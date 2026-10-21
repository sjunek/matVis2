function test_3d_link
% test_3d_link  Headless tests for the linked 3-D views across datasets.
%   Two datasets, two 3-D windows: a view setting changed in one has to reach
%   the other while they are linked, has to stop reaching it once one of them
%   is decoupled, and has to be picked up again when it relinks or when a
%   window is opened later.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));

rng(0);
a = rand(24, 20, 12, 3);
b = rand(24, 20, 12, 3);
model = MatVisModel({a, b}, {'A', 'B'});

mw = MatVisMainWindow(model);
cleanup = onCleanup(@() tearDown(mw));

w1 = mw.get3DWin(1);
w2 = mw.get3DWin(2);
assert(isfield(w1, 'ApplyView') && isfield(w1, 'ViewState'), ...
    '3-D windows must expose ApplyView/ViewState');

%% A style change in window 1 reaches window 2
setDropdown(styleDrop(w1.fig), 'Isosurface');
assert(strcmp(w2.Style(), 'Isosurface'), ...
    'linked window did not follow the style change');

%% So does a dimension change
setDropdown(dimDrop(w1.fig, 3), 4);          % Z slot -> dim 4
assert(isequal(w2.Dims(), w1.Dims()), ...
    'linked window did not follow the dimension change');

%% And a checkbox in the extent panel
setCheckbox(namedCheckbox(w1.fig, 'Full resolution'), true);
assert(w2.ViewState().fullRes, 'linked window did not follow "Full resolution"');

%% The Az / El spinners drive the camera (their callbacks must see both)
spins = findall(w1.fig, '-isa', 'matlab.ui.control.Spinner');
azSp  = spins(arrayfun(@(h) isequal(h.Limits, [-180 180]), spins));
elSp  = spins(arrayfun(@(h) isequal(h.Limits, [-89 89]),   spins));
assert(isscalar(azSp) && isscalar(elSp), 'expected one Az and one El spinner');
azSp.Value = 12;
elSp.Value = -34;
feval(azSp.ValueChangedFcn, azSp, []);   % errored on an unreachable spEl
feval(elSp.ValueChangedFcn, elSp, []);

%% A window that has just adopted a view can still push one of its own
% (the guard that stops it echoing what it was told must not go further)
setDropdown(styleDrop(w2.fig), 'GradientOpacity');
assert(strcmp(w1.Style(), 'GradientOpacity'), ...
    'a window that adopted a view could no longer push one');
setDropdown(styleDrop(w2.fig), 'Isosurface');
assert(strcmp(w1.Style(), 'Isosurface'), 'second push from window 2 was lost');

%% Decoupling window 2 freezes it
setCheckbox(namedCheckbox(w2.fig, 'Link view to other datasets'), false);
setDropdown(styleDrop(w1.fig), 'VolumeRendering');
assert(strcmp(w1.Style(), 'VolumeRendering'), 'window 1 did not change');
assert(strcmp(w2.Style(), 'Isosurface'), ...
    'decoupled window followed the style change anyway');

%% ... and it also stops pushing its own changes
setDropdown(styleDrop(w2.fig), 'SlicePlanes');
assert(strcmp(w1.Style(), 'VolumeRendering'), ...
    'decoupled window pushed its style to the linked one');

%% Relinking rejoins the others
setCheckbox(namedCheckbox(w2.fig, 'Link view to other datasets'), true);
assert(strcmp(w2.Style(), 'VolumeRendering'), ...
    'relinked window did not adopt the shared view');

%% A window opened later joins the view the others already share
setDropdown(styleDrop(w1.fig), 'MinimumIntensityProjection');
delete(w2.fig);
w2 = mw.get3DWin(2);
assert(strcmp(w2.Style(), 'MinimumIntensityProjection'), ...
    'a 3-D window opened later did not join the shared view');
assert(isequal(w2.Dims(), w1.Dims()), ...
    'a 3-D window opened later did not join the shared dimensions');

%% Shown windows follow too — that path re-renders instead of only restyling
w1.Show();
w2.Show();
setDropdown(styleDrop(w1.fig), 'MaximumIntensityProjection');
assert(strcmp(w2.Style(), 'MaximumIntensityProjection'), ...
    'a visible linked window did not follow the style change');
setCheckbox(namedCheckbox(w1.fig, 'Full resolution'), false);
assert(~w2.ViewState().fullRes, ...
    'a visible linked window did not follow the sampling change');

%% ... and so does an axis stretch
spins  = findall(w1.fig, '-isa', 'matlab.ui.control.Spinner');
aspSp  = spins(arrayfun(@(h) isequal(h.Limits, [0.01 100]), spins));
assert(numel(aspSp) == 3, 'expected three aspect spinners, found %d', numel(aspSp));
zSp    = aspSp(contains({aspSp.Tooltip}, 'Z axis'));
zSp.Value = 2.5;
feval(zSp.ValueChangedFcn, zSp, []);
assert(isequal(w1.ViewState().aspect, [1 1 2.5]), 'the Z stretch did not stick');
assert(isequal(w2.ViewState().aspect, [1 1 2.5]), ...
    'a visible linked window did not follow the axis stretch');

% The video generator copies the stretch along with the camera
vw  = mw.getVideoWin();
btn = vw.controls.grabStart;
feval(btn.ButtonPushedFcn, btn, []);
assert(isequal([vw.controls.aspect3.Value], [1 1 2.5]), ...
    'the video generator did not copy the axis stretch');
delete(vw.fig);

%% Contrast stays per dataset
s = w1.ViewState();
assert(~isfield(s, 'cmin') && ~isfield(s, 'gamma'), ...
    'contrast must not be part of the shared view');

%% The camera settings the shared view carries round-trip
% A headless viewer3d never initialises its camera, so this is checked on the
% toolbox-free backend.  volshowBroken is a one-way latch: keep it last.
MatVisVolumeView.volshowBroken(true);
f = uifigure('Visible', 'off');
cleanup2 = onCleanup(@() delete(f));
h1 = uipanel(f, 'Position', [1 1 200 200]);
h2 = uipanel(f, 'Position', [210 1 200 200]);
h3 = uipanel(f, 'Position', [420 1 200 200]);
vv = MatVisVolumeView(h1);
vv.setVolume(uint8(rand(12, 10, 8) * 255), [1 1 1]);

% A view has to report a pose for the camera it *starts* with.  The linked
% windows cannot wait for one to be written explicitly, or every drag before
% the first press of a preset-direction button has nothing to share.
p0 = vv.cameraPose();
assert(all(isfinite(p0.pos)) && all(isfinite(p0.target)) && ...
       all(isfinite(p0.up)), 'a fresh view reports no pose to share');
% Re-scaling stretches the box without new data
ax1 = findall(h1, 'Type', 'axes');
vv.setVoxelSize([1 1 3]);
assert(abs(ax1.ZLim(2) - 24) < 1e-9 && abs(ax1.XLim(2) - 12) < 1e-9, ...
    'setVoxelSize did not stretch the box');
vv.setVoxelSize([1 1 1]);

vvEmpty = MatVisVolumeView(h3);
assert(~any(isfinite(vvEmpty.cameraPose().pos)), ...
    'a view with no volume must not hand out a camera');

vv.setCameraAngles(25, 40);
[az, el] = vv.cameraAngles();
assert(abs(az - 25) < 1e-6 && abs(el - 40) < 1e-6, 'camera angles did not round-trip');

% The pose is what the shared view carries, and it has to reach a second view
p = vv.cameraPose();
assert(all(isfinite(p.pos)) && all(isfinite(p.up)), ...
    'a camera that has been set must report a pose');
vv2 = MatVisVolumeView(h2);
vv2.setVolume(uint8(rand(12, 10, 8) * 255), [1 1 1]);
vv2.setCameraPose(p);
q = vv2.cameraPose();
assert(norm(q.pos - p.pos) < 1e-6 && norm(q.target - p.target) < 1e-6 && ...
       norm(q.up - p.up) < 1e-6, 'the camera pose did not transfer');
[az2, el2] = vv2.cameraAngles();
assert(abs(az2 - az) < 1e-6 && abs(el2 - el) < 1e-6, ...
    'the transferred pose points the camera somewhere else');

% ... and it keeps transferring as the source moves on.  (A rolled camera,
% which is what the pose carries over azimuth and elevation, only exists on
% the viewer3d backend: this one rotates through view(), which cannot roll,
% and a headless viewer3d has no camera to test with.)
vv.setCameraAngles(-70, -15);
vv2.setCameraPose(vv.cameraPose());
[az3, el3] = vv2.cameraAngles();
assert(abs(az3 + 70) < 1e-6 && abs(el3 + 15) < 1e-6, ...
    'the second pose did not transfer');
assert(norm(vv2.cameraPose().pos - vv.cameraPose().pos) < 1e-6, ...
    'the transferred camera sits somewhere else');

%% The camera watchdogs go away with their windows
delete(w1.fig);
delete(w2.fig);
assert(isempty(timerfind('Name', 'matVis3DCam')), ...
    'a closed 3-D window left its camera timer running');

fprintf('test_3d_link: all tests passed\n');
end

function tearDown(mw)
    try; delete(mw.fig); catch; end
    % A 3-D window stops its own timer when it is deleted; mop up any that a
    % failing assert left behind, or the batch process never exits.
    try; stop(timerfindall('Name', 'matVis3DCam'));   catch; end
    try; delete(timerfindall('Name', 'matVis3DCam')); catch; end
end

% ---- driving the controls -------------------------------------------------
% The callbacks are nested and not exposed, so a control is driven the way a
% user would: set the value, then fire its own callback.
function setDropdown(h, value)
    h.Value = value;
    feval(h.ValueChangedFcn, h, []);
end

function setCheckbox(h, tf)
    h.Value = tf;
    feval(h.ValueChangedFcn, h, []);
end

function h = styleDrop(fig)
    h = pickDropdown(fig, @(d) iscell(d.ItemsData) && ...
        ~isempty(d.ItemsData) && isequal(d.ItemsData{1}, 'MaximumIntensityProjection'));
end

function h = dimDrop(fig, slot)
    all_ = findall(fig, '-isa', 'matlab.ui.control.DropDown');
    all_ = flipud(all_(:));                 % findall returns reverse order
    keep = arrayfun(@(d) isnumeric(d.ItemsData) && ...
                         isequal(d.ItemsData(:)', 1:numel(d.ItemsData)) && ...
                         numel(d.ItemsData) > 3, all_);
    dims = all_(keep);
    assert(numel(dims) == 3, 'expected three dimension dropdowns, found %d', ...
        numel(dims));
    h = dims(slot);
end

function h = pickDropdown(fig, pred)
    all_ = findall(fig, '-isa', 'matlab.ui.control.DropDown');
    hit  = all_(arrayfun(pred, all_));
    assert(isscalar(hit), 'expected exactly one matching dropdown');
    h = hit;
end

function h = namedCheckbox(fig, text)
    h = findall(fig, '-isa', 'matlab.ui.control.CheckBox', 'Text', text);
    assert(isscalar(h), 'expected exactly one "%s" checkbox', text);
end
