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

%% 3) RGB slice extraction (dim size 3 -> direct slice->channel mapping)
data3 = zeros(4, 5, 3);
data3(:, :, 1) = 1;  data3(:, :, 2) = 2;  data3(:, :, 3) = 3;
mr = MatVisModel(data3);
mr.RGBDim = 3;
raw = MatVisRender.getRawFullSlice(mr);
nFail = nFail + check(isequal(size(raw), [4 5 3]), ...
    sprintf('RGB full slice is HxWx3 (got %s)', mat2str(size(raw))));
nFail = nFail + check(all(raw(:, :, 1) == 1, 'all') && ...
                      all(raw(:, :, 2) == 2, 'all') && ...
                      all(raw(:, :, 3) == 3, 'all'), 'RGB channels map slice->channel');

raw_zoom = MatVisRender.getRawSlice(mr);
nFail = nFail + check(isequal(size(raw_zoom), [4 5 3]), 'RGB zoom slice is HxWx3');

%% 4) RGB with dim size > 3 (grouped thirds, mean per group)
data6 = zeros(4, 5, 6);
for k = 1:6, data6(:, :, k) = k; end
mg = MatVisModel(data6);
mg.RGBDim = 3;
rawg = MatVisRender.getRawFullSlice(mg);
nFail = nFail + check(isequal(size(rawg), [4 5 3]), 'Grouped RGB slice is HxWx3');
nFail = nFail + check(abs(rawg(1,1,1) - 1.5) < 1e-12 && ...
                      abs(rawg(1,1,2) - 3.5) < 1e-12 && ...
                      abs(rawg(1,1,3) - 5.5) < 1e-12, 'Grouped RGB means of thirds');

%% 5) RGB dim size 2 -> R, G filled, B zero
data2c = cat(3, ones(4,5), 2*ones(4,5));
mc = MatVisModel(data2c);
mc.RGBDim = 3;
raw2 = MatVisRender.getRawFullSlice(mc);
nFail = nFail + check(isequal(size(raw2), [4 5 3]) && ...
    all(raw2(:,:,1) == 1, 'all') && all(raw2(:,:,2) == 2, 'all') && ...
    all(raw2(:,:,3) == 0, 'all'), 'RGB with 2 slices: R,G filled, B zero');

%% 6) RGB combined with projection on a different dim
data4 = zeros(4, 5, 3, 7);
for k = 1:3, data4(:, :, k, :) = k; end
data4(2, 2, 1, 5) = 50;      % spike visible in max projection of dim 4, channel R
mp = MatVisModel(data4);
mp.RGBDim = 3;
mp.ProjFun = 'max'; mp.ProjDim = 4;
rawp = MatVisRender.getRawFullSlice(mp);
nFail = nFail + check(isequal(size(rawp), [4 5 3]), 'RGB + projection slice is HxWx3');
nFail = nFail + check(rawp(2, 2, 1) == 50 && rawp(1, 1, 1) == 1 && ...
                      all(rawp(:, :, 2) == 2, 'all'), 'RGB + max projection values');

%% 7) Projection on same dim as RGB -> projection wins, 2-D result
mp.ProjDim = 3;
raws = MatVisRender.getRawFullSlice(mp);
nFail = nFail + check(ismatrix(raws), 'Same-dim conflict: projection wins, 2-D slice');

%% 8) composeImage: RGB bypasses colormap, 2-D uses colormap
imgRGB = MatVisRender.composeImage(rand(4, 5, 3), 1.0, 1);
nFail = nFail + check(isa(imgRGB, 'uint8') && isequal(size(imgRGB), [4 5 3]), ...
    'composeImage RGB -> uint8 HxWx3');
img2D = MatVisRender.composeImage(rand(4, 5), 1.0, 1);
nFail = nFail + check(isa(img2D, 'uint8') && isequal(size(img2D), [4 5 3]), ...
    'composeImage 2-D -> colormapped uint8 HxWx3');

%% 9) Flips apply to RGB slices
dataF = zeros(4, 5, 3);
dataF(1, 1, 2) = 7;
mf = MatVisModel(dataF);
mf.RGBDim = 3;  mf.FlipX = true;
rawf = MatVisRender.getRawFullSlice(mf);
nFail = nFail + check(rawf(1, 5, 2) == 7, 'FlipX applies to RGB slice');

%% 10) RGB + tile projection (each channel tiled)
mt = MatVisModel(data4);
mt.RGBDim = 3;
mt.ProjFun = 'tile';  mt.ProjDim = 4;
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
