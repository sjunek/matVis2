function test_playspeed()
% Smoke test for playback framerate display + play-speed control.
% Verifies the main window builds with the new play-speed row, that the
% framerate readout appears in the title during playback, that positive
% speeds skip frames, and that the title resets to the base name on stop.

baseDir = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(baseDir, 'core'));
addpath(fullfile(baseDir, 'ui'));
addpath(fullfile(baseDir, 'io'));

% Synthetic 3D stack: 32 x 32 x 40 frames
data = zeros(32, 32, 40);
for k = 1:40
    data(:, :, k) = k;
end

mw = matVis(data, 'datasetNames', {'SmokeSet'});
cleanup = onCleanup(@() closeAll(mw));

assert(isfield(mw, 'fig') && isvalid(mw.fig), 'main figure not created');
assert(contains(mw.fig.Name, 'SmokeSet'), ...
    'dataset name missing from base title: "%s"', mw.fig.Name);
baseTitle = mw.fig.Name;
fprintf('Base title OK: "%s"\n', baseTitle);

% Locate the play-speed edit field in the figure
edt = findPlaySpeedField(mw.fig);
assert(~isempty(edt), 'Play speed edit field not found in main window');
fprintf('Play speed field found (value=%g)\n', edt.Value);

% --- 1) Positive speed: frame skipping, "Skip every X frame" in title ----
edt.Value = 1;                       % -> advance every 2 frames
rs3 = mw.rangeSliders{3};            % play along dim 3
rs3.IsPlaying = true;
rs3.SetPlayMode('full');             % sets PlayMode + fires PlayModeChanged

drawnow; pause(0.8); drawnow;         % let the timer tick several times
nameDuringSkip = mw.fig.Name;
fprintf('Title during skip play: "%s"\n', nameDuringSkip);
assert(contains(nameDuringSkip, 'fps:'), 'fps readout missing during playback');
assert(contains(nameDuringSkip, 'Skip every 2 frame'), ...
    'frame-skip indicator missing: "%s"', nameDuringSkip);

% Stop and confirm title resets
rs3.IsPlaying = false;
rs3.SetPlayMode('none');
drawnow; pause(0.2); drawnow;
assert(strcmp(mw.fig.Name, baseTitle), ...
    'title not reset after stop: "%s"', mw.fig.Name);
fprintf('Title reset after stop OK\n');

% --- 2) Negative speed: pause indicator in title ------------------------
edt.Value = -5;                      % -> 0.25 s pause between frames
rs3.IsPlaying = true;
rs3.SetPlayMode('full');
drawnow; pause(1.2); drawnow;
nameDuringPause = mw.fig.Name;
fprintf('Title during paused play: "%s"\n', nameDuringPause);
assert(contains(nameDuringPause, 'fps:'), 'fps readout missing (pause mode)');
assert(contains(nameDuringPause, 'pause'), ...
    'pause indicator missing: "%s"', nameDuringPause);

rs3.IsPlaying = false;
rs3.SetPlayMode('none');
drawnow; pause(0.2); drawnow;
assert(strcmp(mw.fig.Name, baseTitle), 'title not reset after paused stop');

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
