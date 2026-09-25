function test_playspeed()
% Smoke test for playback framerate display + play-speed control.
% Verifies the main window builds with the play-speed row, that the framerate
% readout appears in the label next to the control during playback, that
% speed > 1 skips frames, speed in (0,1) slows via pauses, and that the
% framerate label clears on stop (window title always shows the dataset name).

baseDir = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(baseDir, 'core'));
addpath(fullfile(baseDir, 'ui'));
addpath(fullfile(baseDir, 'io'));

% Synthetic 3D stack: 32 x 32 x 40 frames
data = zeros(32, 32, 40);
for k = 1:40
    data(:, :, k) = k;
end

mw = matVis2(data, 'datasetNames', {'SmokeSet'});
cleanup = onCleanup(@() closeAll(mw));

assert(isfield(mw, 'fig') && isvalid(mw.fig), 'main figure not created');
assert(contains(mw.fig.Name, 'SmokeSet'), ...
    'dataset name missing from base title: "%s"', mw.fig.Name);
baseTitle = mw.fig.Name;
fprintf('Base title OK: "%s"\n', baseTitle);

% Title always shows the dataset name (no framerate appended)
assert(contains(baseTitle, 'matVis 2.0'), 'unexpected base title: "%s"', baseTitle);

% Locate the play-speed edit field and the framerate label in the figure
edt = findPlaySpeedField(mw.fig);
assert(~isempty(edt), 'Play speed edit field not found in main window');
lblFps = findall(mw.fig, 'Type', 'uilabel', 'Tag', 'matVisFrameRate');
assert(~isempty(lblFps), 'framerate label not found in main window');
lblFps = lblFps(1);
assert(edt.Value == 1, 'default play speed should be 1 (native), got %g', edt.Value);
fprintf('Play speed field (value=%g) and framerate label found\n', edt.Value);

% --- 1) Speed > 1: frame skipping, "skip every X frames" in the tooltip --
%  The label itself only has room for the framerate; the skip / pause detail
%  goes into its tooltip.
edt.Value = 2;                       % -> advance every 2 frames
rs3 = mw.rangeSliders{3};            % play along dim 3
rs3.IsPlaying = true;
rs3.SetPlayMode('full');             % sets PlayMode + fires PlayModeChanged

drawnow; pause(0.8); drawnow;         % let the timer tick several times
fpsDuringSkip = lblFps.Text;
fprintf('Framerate label during skip play: "%s"\n', fpsDuringSkip);
assert(contains(fpsDuringSkip, 'fps'), 'fps readout missing during playback');
tipDuringSkip = char(lblFps.Tooltip);
fprintf('Framerate tooltip during skip play: "%s"\n', tipDuringSkip);
assert(contains(tipDuringSkip, 'skip every 2 frames'), ...
    'frame-skip indicator missing from tooltip: "%s"', tipDuringSkip);
% Title must NOT carry framerate info
assert(strcmp(mw.fig.Name, baseTitle), ...
    'title should not change during playback: "%s"', mw.fig.Name);

% Stop and confirm the label clears
rs3.IsPlaying = false;
rs3.SetPlayMode('none');
drawnow; pause(0.2); drawnow;
assert(isempty(char(lblFps.Text)), ...
    'framerate label not cleared after stop: "%s"', lblFps.Text);
fprintf('Framerate label cleared after stop OK\n');

% --- 2) Speed in (0,1): slowed playback, pause indicator in the label ----
edt.Value = 0.5;                     % -> half native speed, pause introduced
rs3.IsPlaying = true;
rs3.SetPlayMode('full');
drawnow; pause(1.2); drawnow;
fpsDuringSlow = lblFps.Text;
fprintf('Framerate label during slowed play: "%s"\n', fpsDuringSlow);
assert(contains(fpsDuringSlow, 'fps'), 'fps readout missing (slow mode)');
tipDuringSlow = char(lblFps.Tooltip);
fprintf('Framerate tooltip during slowed play: "%s"\n', tipDuringSlow);
assert(contains(tipDuringSlow, 'pause'), ...
    'pause indicator missing from tooltip: "%s"', tipDuringSlow);

rs3.IsPlaying = false;
rs3.SetPlayMode('none');
drawnow; pause(0.2); drawnow;
assert(isempty(char(lblFps.Text)), 'framerate label not cleared after slow stop');

fprintf('\nALL PLAYSPEED TESTS PASSED\n');
end

function edt = findPlaySpeedField(fig)
edt = [];
fields = findall(fig, 'Type', 'uinumericeditfield');
for k = 1:numel(fields)
    tt = fields(k).Tooltip;
    if ischar(tt) || isstring(tt)
        if contains(string(tt), 'Speed of playback')
            edt = fields(k);
            return;
        end
    end
end
end

function closeAll(mw)
try
    if isfield(mw, 'fig') && isvalid(mw.fig)
        delete(mw.fig);
    end
catch
end
delete(timerfindall);
end
