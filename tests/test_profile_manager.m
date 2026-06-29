function test_profile_manager
% test_profile_manager  Headless tests for profile (line-trace) state,
% geometry, perpendicular sampling, projection and data export.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));

% Data whose value equals the X (dim-2) coordinate, scaled per time step:
%   data(y, x, t) = x * t   -> exact, easy to predict after interp.
[~, X] = ndgrid(1:50, 1:60);
data = zeros(50, 60, 4);
for t = 1:4, data(:, :, t) = X * t; end
model = MatVisModel(data);            % default XDim=2, YDim=1

%% AddProfile: a horizontal line y=10 from x=5 to x=25 (2×N [x;y])
idx = model.AddProfile([5 25; 10 10]);
assert(idx == 1 && numel(model.ProfileList) == 1, 'AddProfile failed');
prof = model.ProfileList(1);
assert(size(prof.smoothedPoints, 1) == 2, 'smoothedPoints must be 2×M');
assert(abs(prof.length - 20) < 1e-9, 'length of a 20 px horizontal line must be 20');
assert(isequal(model.ProfileSelection, 1), 'new profile must be selected');

%% Width-1 sampling of value==x reproduces the X coordinate along the path
model.CurrPos(3) = 1;                  % sample the t=1 slice (value == x)
model.SetProfileWidth(1);
img = MatVisRender.sampleProfileImage(model, model.Data, model.ProfileList(1));
assert(size(img, 1) == 1, 'width-1 band must have a single row');
p = MatVisRender.profileProject(img, 'Mean');
assert(abs(p(1) - 5) < 1e-9 && abs(p(end) - 25) < 1e-9, ...
    'profile of value==x must run from 5 to 25');
assert(all(abs(diff(p) - mean(diff(p))) < 1e-9), 'profile must increase linearly');

%% Wider band still averages to the centre value for a value==x field
model.SetProfileWidth(5);
img5 = MatVisRender.sampleProfileImage(model, model.Data, model.ProfileList(1));
assert(size(img5, 1) == 5, 'width-5 band must have 5 rows');
p5 = MatVisRender.profileProject(img5, 'Mean');
assert(abs(p5(1) - 5) < 1e-9 && abs(p5(end) - 25) < 1e-9, ...
    'horizontal band mean equals the row value (value field is x-only)');

%% Projection variants are all the right length
for meth = {'Mean', 'Sum', 'Max', 'Min'}
    pj = MatVisRender.profileProject(img5, meth{1});
    assert(numel(pj) == size(img5, 2), ['projection length wrong: ' meth{1}]);
end

%% Trace along dim 3: value==x*t, so the mean profile scales with t
tr = MatVisRender.profileTraceAlongDim(model, model.Data, 3, model.ProfileList(1));
assert(size(tr, 2) == 4, 'trace must have one column per step along dim 3');
% Column t should equal column 1 times t (value field is x*t)
for t = 2:4
    assert(max(abs(tr(:, t) - tr(:, 1) * t)) < 1e-6, 'trace scaling with t wrong');
end

%% Display dimension refused for the band but length axis is dim-2 here
% (export along a display dim is blocked in the UI; sampling along dim 1/2
%  is meaningless, so just confirm dim 3 above is the supported path.)

%% Copy / shift / recompute
model.CopyProfiles(1);
assert(numel(model.ProfileList) == 2, 'CopyProfiles failed');
p0 = model.ProfileList(1).points;
model.ProfileList(1).points         = p0 + [3; -2];
model.ProfileList(1).smoothedPoints = model.ProfileList(1).smoothedPoints + [3; -2];
model.RecomputeProfile(1);
assert(isequal(model.ProfileList(1).points, p0 + [3; -2]), 'shift/recompute failed');

%% VisibleProfileIndices honours the XY plane
vis = model.VisibleProfileIndices();
assert(isequal(vis, [1 2]), 'both profiles visible in current plane');
model.XDim = 3;                        % switch display plane
assert(isempty(model.VisibleProfileIndices()), 'profiles hidden off-plane');
model.XDim = 2;

%% Export / import round-trip (matVis profile format)
exported = model.ProfileList;
n = model.ImportProfiles(exported, false);
assert(n == 2 && numel(model.ProfileList) == 2, 'import round-trip count wrong');

%% Delete
model.DeleteProfiles(1:numel(model.ProfileList));
assert(isempty(model.ProfileList) && isempty(model.ProfileSelection), 'delete-all failed');

%% Degenerate single-point path is rejected
assert(isempty(model.AddProfile([10; 10])), 'single-point profile must be rejected');

fprintf('ALL PROFILE MANAGER TESTS PASSED\n');
end
