function test_rgb_and_startpos
% Headless tests for brightest-pixel start position and RGB channel mode.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));

nFail = 0;

%% 1) Brightest pixel start position
data = zeros(10, 12, 5);
data(7, 3, 4) = 99;          % brightest voxel
m = MatVisModel(data);
nFail = nFail + check(isequal(m.CurrPos, [7 3 4]), ...
    sprintf('CurrPos starts at brightest pixel (got [%s])', num2str(m.CurrPos)));

% 2-D data
d2 = magic(8);
m2 = MatVisModel(d2);
[r, c] = find(d2 == max(d2(:)), 1);
nFail = nFail + check(isequal(m2.CurrPos, [r c]), 'CurrPos 2-D brightest pixel');

%% 2) RGB defaults
nFail = nFail + check(m.RGBDim == 0, 'RGBDim defaults to 0 (off)');

%% 3) RGB triad mapping (prev->R, curr->G, next->B), no wraparound
data5 = zeros(4, 5, 5);
for k = 1:5, data5(:, :, k) = k; end
mr = MatVisModel(data5);
mr.RGBDim = 3;
mr.CurrPos = [1 1 3];        % curr=3 -> prev=2, next=4
raw = MatVisRender.getRawFullSlice(mr);
nFail = nFail + check(isequal(size(raw), [4 5 3]), ...
    sprintf('RGB full slice is HxWx3 (got %s)', mat2str(size(raw))));
nFail = nFail + check(all(raw(:, :, 1) == 2, 'all') && ...
                      all(raw(:, :, 2) == 3, 'all') && ...
                      all(raw(:, :, 3) == 4, 'all'), ...
    'Triad maps prev->R, curr->G, next->B');

raw_zoom = MatVisRender.getRawSlice(mr);
nFail = nFail + check(isequal(size(raw_zoom), [4 5 3]), 'RGB zoom slice is HxWx3');

%% 4) Wraparound at lower edge (curr=1 -> prev=last)
mr.CurrPos = [1 1 1];        % curr=1 -> prev=5 (wrap), next=2
rawL = MatVisRender.getRawFullSlice(mr);
nFail = nFail + check(all(rawL(:, :, 1) == 5, 'all') && ...
                      all(rawL(:, :, 2) == 1, 'all') && ...
                      all(rawL(:, :, 3) == 2, 'all'), ...
    'Lower-edge wrap: R=last, G=first, B=second');

%% 5) Wraparound at upper edge (curr=last -> next=first)
mr.CurrPos = [1 1 5];        % curr=5 -> prev=4, next=1 (wrap)
rawU = MatVisRender.getRawFullSlice(mr);
nFail = nFail + check(all(rawU(:, :, 1) == 4, 'all') && ...
                      all(rawU(:, :, 2) == 5, 'all') && ...
                      all(rawU(:, :, 3) == 1, 'all'), ...
    'Upper-edge wrap: R=prev, G=last, B=first');

%% 6) Dim size 2 -> prev and next both wrap to the other slice
data2c = cat(3, ones(4,5), 2*ones(4,5));
mc = MatVisModel(data2c);
mc.RGBDim = 3;
mc.CurrPos = [1 1 1];        % curr=1 -> prev=2 (wrap), next=2 (wrap)
raw2 = MatVisRender.getRawFullSlice(mc);
nFail = nFail + check(isequal(size(raw2), [4 5 3]) && ...
    all(raw2(:,:,1) == 2, 'all') && all(raw2(:,:,2) == 1, 'all') && ...
    all(raw2(:,:,3) == 2, 'all'), 'Size-2 dim: R=B=other slice, G=current');

%% 7) RGB combined with projection on a different dim
data4 = zeros(4, 5, 3, 7);
for k = 1:3, data4(:, :, k, :) = k; end
data4(2, 2, 3, 5) = 50;      % spike in slice 3 -> blue channel (next), max over dim 4
mp = MatVisModel(data4);
mp.RGBDim = 3;
mp.ProjFun = 'max'; mp.ProjDim = 4;
mp.CurrPos = [1 1 2 1];      % curr=2 -> prev=1 (R), curr=2 (G), next=3 (B)
rawp = MatVisRender.getRawFullSlice(mp);
nFail = nFail + check(isequal(size(rawp), [4 5 3]), 'RGB + projection slice is HxWx3');
nFail = nFail + check(all(rawp(:, :, 1) == 1, 'all') && ...
                      all(rawp(:, :, 2) == 2, 'all') && ...
                      rawp(2, 2, 3) == 50 && rawp(1, 1, 3) == 3, ...
    'RGB + max projection values (spike in B channel)');

%% 8) Projection on same dim as RGB -> projection wins, 2-D result
mp.ProjDim = 3;
raws = MatVisRender.getRawFullSlice(mp);
nFail = nFail + check(ismatrix(raws), 'Same-dim conflict: projection wins, 2-D slice');

%% 9) composeImage: RGB bypasses colormap, 2-D uses colormap
imgRGB = MatVisRender.composeImage(rand(4, 5, 3), 1.0, 1);
nFail = nFail + check(isa(imgRGB, 'uint8') && isequal(size(imgRGB), [4 5 3]), ...
    'composeImage RGB -> uint8 HxWx3');
img2D = MatVisRender.composeImage(rand(4, 5), 1.0, 1);
nFail = nFail + check(isa(img2D, 'uint8') && isequal(size(img2D), [4 5 3]), ...
    'composeImage 2-D -> colormapped uint8 HxWx3');

%% 10) Flips apply to RGB slices (marker in green = current slice)
dataF = zeros(4, 5, 3);
dataF(1, 1, 2) = 7;          % slice 2
mf = MatVisModel(dataF);
mf.RGBDim = 3;  mf.FlipX = true;
mf.CurrPos = [1 1 2];        % curr=2 -> green channel is slice 2
rawf = MatVisRender.getRawFullSlice(mf);
nFail = nFail + check(rawf(1, 5, 2) == 7, 'FlipX applies to RGB slice');

%% 11) RGB + tile projection (each channel tiled)
mt = MatVisModel(data4);
mt.RGBDim = 3;
mt.ProjFun = 'tile';  mt.ProjDim = 4;
mt.CurrPos = [1 1 2 1];
rawt = MatVisRender.getRawFullSlice(mt);
nFail = nFail + check(ndims(rawt) == 3 && size(rawt, 3) == 3 && ...
    size(rawt, 1) > 4 && size(rawt, 2) > 5, 'RGB + tile produces tiled HxWx3');

%% Summary
if nFail == 0
    fprintf('ALL TESTS PASSED\n');
else
    error('%d test(s) FAILED', nFail);
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
