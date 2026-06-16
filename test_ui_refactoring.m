% Test script to verify UI refactoring works
fprintf('Testing matVis 2.0 UI refactoring...\n');

% Add paths
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, 'core'));
addpath(fullfile(thisDir, 'ui'));
addpath(fullfile(thisDir, 'io'));

try
    % Test 1: Create a MatVisModel
    fprintf('Test 1: Creating MatVisModel...');
    data = rand(64, 64, 20);
    model = MatVisModel(data);
    fprintf(' OK\n');

    % Test 2: Check contrast mode property
    fprintf('Test 2: Testing contrast mode property...');
    assert(strcmp(model.ContrastMode, 'Global'), 'Default mode should be Global');
    model.ContrastMode = 'Image';
    assert(strcmp(model.ContrastMode, 'Image'), 'Should be able to set to Image');
    fprintf(' OK\n');

    % Test 3: Test GetContrastBounds
    fprintf('Test 3: Testing GetContrastBounds...');
    model.SetImageData(data(:,:,10));
    [cmin, cmax] = model.GetContrastBounds();
    assert(isnumeric(cmin) && isnumeric(cmax), 'Should return numeric bounds');
    fprintf(' OK\n');

    % Test 4: Test RangeSlider properties
    fprintf('Test 4: Testing RangeSlider...');
    fig = uifigure('Visible', 'off');
    grid = uigridlayout(fig, [1 1]);
    rs = RangeSlider(grid);
    rs.Limits = [1, 100];
    rs.Value = 50;
    rs.PlayMode = 'full';
    assert(strcmp(rs.PlayMode, 'full'), 'PlayMode should be settable');
    close(fig);
    fprintf(' OK\n');

    % Test 5: Test matVisConfig
    fprintf('Test 5: Testing matVisConfig utilities...');
    configPath = matVisConfig('GetConfigPath');
    assert(ischar(configPath) || isstring(configPath), 'Should return a path');
    config = matVisConfig('LoadConfig', configPath);
    assert(isstruct(config), 'Should return a struct (even if empty)');
    fprintf(' OK\n');

    fprintf('\nAll tests passed!\n');

catch ME
    fprintf('\nTest failed: %s\n', ME.message);
    fprintf('Stack trace:\n');
    for k = 1:length(ME.stack)
        fprintf('  %s (line %d)\n', ME.stack(k).name, ME.stack(k).line);
    end
end
