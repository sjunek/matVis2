% Test script: Verify matVis 2.0 UI improvements are working
function test_matvis_launch()

fprintf('\n=== matVis 2.0 UI Test ===\n\n');

try
    % Test 1: Create sample data
    fprintf('Test 1: Creating sample data... ');
    data = rand(32, 32, 10);
    fprintf('✓\n');

    % Test 2: Setup paths
    fprintf('Test 2: Setting up paths... ');
    addpath(pwd);
    addpath([pwd '\core']);
    addpath([pwd '\ui']);
    addpath([pwd '\io']);
    fprintf('✓\n');

    % Test 3: Verify MatVisModel contrast mode
    fprintf('Test 3: Testing MatVisModel contrast modes... ');
    model = MatVisModel(data);
    assert(strcmp(model.ContrastMode, 'Global'), 'Default mode should be Global');
    [cmin, cmax] = model.GetContrastBounds();
    assert(isnumeric(cmin) && isnumeric(cmax), 'GetContrastBounds should return numbers');
    fprintf('✓\n');

    % Test 4: Test rendering a slice
    fprintf('Test 4: Testing MatVisRender... ');
    slice2D = MatVisRender.renderSlice(model);
    assert(~isempty(slice2D), 'renderSlice should return a 2D matrix');
    fprintf('✓\n');

    % Test 5: Verify matVisConfig exists
    fprintf('Test 5: Testing matVisConfig utility... ');
    configPath = matVisConfig('GetConfigPath');
    assert(~isempty(configPath), 'Config path should not be empty');
    fprintf('✓\n');

    % Test 6: Verify file structure is complete
    fprintf('Test 6: Verifying file structure... ');
    assert(isfile([pwd '\ui\RangeSlider.m']), 'RangeSlider.m should exist');
    assert(isfile([pwd '\io\matVisConfig.m']), 'matVisConfig.m should exist');
    assert(isfile([pwd '\core\MatVisModel.m']), 'MatVisModel.m should exist');
    fprintf('✓\n');

    % Cleanup
    fprintf('\nTest 7: Cleanup... ');
    close all;
    fprintf('✓\n\n');

    fprintf('=== All tests passed! ===\n\n');

catch ME
    fprintf('\n❌ Test failed:\n');
    fprintf('  Error: %s\n', ME.message);
    fprintf('  Location: %s (line %d)\n', ME.stack(1).name, ME.stack(1).line);
    close all;
    rethrow(ME);
end

end
