function test_alpha_features
% Smoke test: alpha-weighted plot traces + 2D data-vs-alpha histogram.
% Launches the full UI with an alpha map, verifies the plot window draws
% the weighted trace and the dotted mean-alpha trace on a right y-axis,
% then opens the 2D histogram window and checks its contents.

baseDir = fileparts(mfilename('fullpath'));
addpath(fullfile(baseDir, 'core'), fullfile(baseDir, 'ui'), fullfile(baseDir, 'io'));

rng(42);
data  = rand(20, 15, 10);
alpha = rand(20, 15, 10);

model = MatVisModel({data}, {'alphaTest'});
model.SetAlphaMaps({alpha});
model.PlotDims(3) = true;

mw = MatVisMainWindow(model);
cleanupObj = onCleanup(@() close(mw.fig, 'force'));

%% 1) Plot window: weighted data trace present
pw = mw.plotWins{1};
ln = pw.lineHandles{3};
assert(numel(ln.YData) == 10, 'data trace should span dim-3 extent');
assert(all(isfinite(ln.YData)), 'data trace should be finite');

% Single pixel (avgMode 0): weighted mean reduces to the data value itself
cp = model.CurrPos;
expected = squeeze(data(cp(1), cp(2), :))';
assert(max(abs(ln.YData - expected)) < 1e-10, ...
    'avgMode 0 weighted trace must equal raw pixel values');

%% 2) Plot window: dotted alpha trace on right y-axis
ax = pw.axes{3};
assert(numel(ax.YAxis) == 2, 'plot axes should have a right (alpha) ruler');
allLines = findall(ax, 'Type', 'line');
dotted = allLines(strcmp(get(allLines, 'LineStyle'), ':'));
assert(isscalar(dotted), 'exactly one dotted alpha trace expected');
expectedA = squeeze(alpha(cp(1), cp(2), :))';
assert(max(abs(dotted.YData - expectedA)) < 1e-10, ...
    'alpha trace must equal raw alpha pixel values for avgMode 0');

%% 3) 2D data-vs-alpha histogram
btn = findall(mw.fig, 'Type', 'uistatebutton', 'Text', '2D');
assert(isscalar(btn), '2D hist toggle button expected in alpha row');
btn.Value = true;
btn.ValueChangedFcn(btn, []);

h2f = findall(groot, 'Type', 'figure', 'Name', '2D Histogram: data vs alpha');
assert(isscalar(h2f) && strcmp(h2f.Visible, 'on'), '2D hist window should be visible');
img = findall(h2f, 'Type', 'image');
assert(isscalar(img), '2D hist image expected');
assert(isequal(size(img.CData), [201, 201]), '2D hist should be 201x201 bins');
nSlicePix = size(data, 1) * size(data, 2);   % hist covers the current slice
assert(abs(sum(10.^img.CData(:) - 1) - nSlicePix) < 1, ...
    '2D hist counts should cover all pixels of the current slice');

guides = findall(h2f, 'Type', 'constantline');
assert(numel(guides) == 4, 'four contrast guide lines expected');

% Top edge aligned with the zoom window, placed to its right (unless
% clamped to the screen edge)
zp = mw.zoomWins{1}.fig.Position;
hp = h2f.Position;
assert(abs((hp(2) + hp(4)) - (zp(2) + zp(4))) < 1, ...
    '2D hist top edge should align with the zoom window');
assert(hp(3) == 560, '2D hist figure should be 560 px wide');

% Toggle off hides the window
btn.Value = false;
btn.ValueChangedFcn(btn, []);
assert(strcmp(h2f.Visible, 'off'), '2D hist window should hide on toggle off');

fprintf('\ntest_alpha_features: ALL PASSED\n');
end
