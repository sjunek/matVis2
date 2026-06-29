function test_aspect_winscale
% Headless UI smoke test for the aspect-ratio and window-scaling buttons.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(rootDir, fullfile(rootDir, 'core'), fullfile(rootDir, 'ui'), fullfile(rootDir, 'io'));
cd(rootDir);

nFail = 0;
% Dimensions large enough that the zoom window never hits the 50 px floor.
data = rand(60, 80, 3, 10);
data(5, 8, 2, 6) = 10;   % brightest pixel

mw = matVis(data);
cleanupObj = onCleanup(@() close(mw.fig, 'force'));
dsel  = mw.dimSelector;
model = mw.model;

% --- Buttons exist -------------------------------------------------------
nFail = nFail + check(isfield(dsel, 'btnAspect') && isfield(dsel, 'btnWinScale'), ...
    'Aspect-ratio and window-scale buttons present in dim selector');

% --- Defaults: fixed 1:1, 100% ------------------------------------------
nFail = nFail + check(dsel.btnAspect.Value == true && strcmp(dsel.btnAspect.Text, '1:1'), ...
    'Aspect button defaults to fixed 1:1');
nFail = nFail + check(strcmp(dsel.btnWinScale.Text, '100%'), ...
    'Window-scale button defaults to 100%');
nFail = nFail + check(isequal(mw.imageWin.ax.DataAspectRatio, [1 1 1]) && ...
    isequal(mw.zoomWin.ax.DataAspectRatio, [1 1 1]), ...
    'Image/zoom axes start with square pixels');

% --- Toggle to fill ------------------------------------------------------
dsel.btnAspect.Value = false;
feval(dsel.btnAspect.ValueChangedFcn, dsel.btnAspect, []);
nFail = nFail + check(strcmp(dsel.btnAspect.Text, 'fill') && ~model.AspectRatioFixed, ...
    'Aspect button shows ''fill'' and model updated when toggled off');
nFail = nFail + check(strcmp(mw.imageWin.ax.DataAspectRatioMode, 'auto') && ...
    strcmp(mw.zoomWin.ax.DataAspectRatioMode, 'auto'), ...
    'Axes stretch to fill in ''fill'' mode');

% --- Toggle back to fixed ------------------------------------------------
dsel.btnAspect.Value = true;
feval(dsel.btnAspect.ValueChangedFcn, dsel.btnAspect, []);
nFail = nFail + check(isequal(mw.imageWin.ax.DataAspectRatio, [1 1 1]) && ...
    strcmp(mw.imageWin.ax.DataAspectRatioMode, 'manual') && model.AspectRatioFixed, ...
    'Toggling back restores fixed square pixels');

% --- Custom aspect ratio (drive SetAspectRatio directly; dialog is modal) -
mw.imageWin.SetAspectRatio(true, [2 1]);
mw.zoomWin.SetAspectRatio(true, [2 1]);
nFail = nFail + check(isequal(mw.imageWin.ax.DataAspectRatio, [2 1 1]) && ...
    isequal(mw.zoomWin.ax.DataAspectRatio, [2 1 1]), ...
    'Custom aspect ratio [2 1] applied to both axes');

% --- Window scaling: 200% resizes the zoom window --------------------------
% Zoom region spans the full data: XDim=2 (80 wide), YDim=1 (60 tall).
zwPx = diff(model.ZoomRange(model.XDim, :)) + 1;
zhPx = diff(model.ZoomRange(model.YDim, :)) + 1;
model.WinScalePct = 200;
feval(dsel.btnWinScale.ButtonPushedFcn, dsel.btnWinScale, []);
% Read back the applied scale (may be clamped to the screen on small displays).
sc   = model.WinScalePct / 100;
expW = max(50, round(zwPx * sc));
expH = max(50, round(zhPx * sc));
zf   = mw.zoomWin.fig.Position;
nFail = nFail + check(isequal(zf(3:4), [expW, expH]), ...
    sprintf('Window scale sizes zoom window to [%d %d] (got [%d %d])', ...
        expW, expH, zf(3), zf(4)));
nFail = nFail + check(strcmp(dsel.btnWinScale.Text, sprintf('%d%%', round(model.WinScalePct))), ...
    'Window-scale button caption reflects applied scale');

if nFail == 0
    fprintf('ALL ASPECT/WINSCALE TESTS PASSED\n');
else
    error('%d aspect/winscale test(s) FAILED', nFail);
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
