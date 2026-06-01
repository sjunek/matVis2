classdef RangeSliderTest < matlab.unittest.TestCase
% RangeSliderTest  Unit tests for ui/RangeSlider.m
%
%   Run with:
%       cd('D:\Matlab\GitRepositories\matVis2_Claude\Claude')
%       results = runtests('tests/RangeSliderTest.m');
%       disp(results)

    properties
        Fig     % test uifigure
        RS      % RangeSlider handles struct
        NSteps  % number of steps used in tests
    end

    % ------------------------------------------------------------------ %
    %  Setup / Teardown                                                    %
    % ------------------------------------------------------------------ %
    methods (TestMethodSetup)
        function createFixture(tc)
            tc.NSteps = 20;
            tc.Fig = uifigure('Visible', 'off');
            tc.RS  = RangeSlider( ...
                tc.Fig, ...       % parent
                1, ...            % dimIdx
                tc.NSteps, ...    % nSteps
                'X', ...          % label
                @(~) [], ...      % onPositionChanged (no-op for setup)
                @(~,~) []);       % onZoomChanged     (no-op for setup)
        end
    end

    methods (TestMethodTeardown)
        function destroyFixture(tc)
            if isvalid(tc.Fig)
                close(tc.Fig);
            end
        end
    end

    % ------------------------------------------------------------------ %
    %  Construction tests                                                  %
    % ------------------------------------------------------------------ %
    methods (Test)

        function testReturnedStructHasRequiredFields(tc)
            requiredFields = {'panel','label','editPos','sliderPos', ...
                              'editZoomMin','editZoomMax','btnPlay','plotCheck', ...
                              'SetValue','GetZoomRange','SetZoomRange','GetPlotChecked'};
            for k = 1:numel(requiredFields)
                tc.assertTrue(isfield(tc.RS, requiredFields{k}), ...
                    sprintf('Missing field: %s', requiredFields{k}));
            end
        end

        function testDefaultPositionIsOne(tc)
            tc.assertEqual(tc.RS.sliderPos.Value, 1, 'AbsTol', 1e-9);
            tc.assertEqual(tc.RS.editPos.Value,   1, 'AbsTol', 1e-9);
        end

        function testDefaultZoomRangeIsFullExtent(tc)
            range = tc.RS.GetZoomRange();
            tc.assertEqual(range(1), 1,          'AbsTol', 1e-9);
            tc.assertEqual(range(2), tc.NSteps,  'AbsTol', 1e-9);
        end

        function testDefaultPlotCheckIsFalse(tc)
            tc.assertFalse(tc.RS.GetPlotChecked());
        end

        function testLabelText(tc)
            tc.assertEqual(tc.RS.label.Text, 'X');
        end

        % ---------------------------------------------------------------- %
        %  SetValue                                                          %
        % ---------------------------------------------------------------- %
        function testSetValueUpdatesSliderAndEditField(tc)
            tc.RS.SetValue(10);
            tc.assertEqual(tc.RS.sliderPos.Value, 10, 'AbsTol', 1e-9);
            tc.assertEqual(tc.RS.editPos.Value,   10, 'AbsTol', 1e-9);
        end

        function testSetValueClampsToLowerBound(tc)
            tc.RS.SetValue(0);
            tc.assertEqual(tc.RS.sliderPos.Value, 1, 'AbsTol', 1e-9);
        end

        function testSetValueClampsToUpperBound(tc)
            tc.RS.SetValue(tc.NSteps + 5);
            tc.assertEqual(tc.RS.sliderPos.Value, tc.NSteps, 'AbsTol', 1e-9);
        end

        function testSetValueRoundsFractional(tc)
            tc.RS.SetValue(7.6);
            tc.assertEqual(tc.RS.sliderPos.Value, 8, 'AbsTol', 1e-9);
        end

        % ---------------------------------------------------------------- %
        %  SetZoomRange / GetZoomRange                                       %
        % ---------------------------------------------------------------- %
        function testSetZoomRangeUpdatesEditFields(tc)
            tc.RS.SetZoomRange(3, 15);
            range = tc.RS.GetZoomRange();
            tc.assertEqual(range(1), 3,  'AbsTol', 1e-9);
            tc.assertEqual(range(2), 15, 'AbsTol', 1e-9);
        end

        function testSetZoomRangeClampsLo(tc)
            tc.RS.SetZoomRange(0, 10);
            range = tc.RS.GetZoomRange();
            tc.assertEqual(range(1), 1, 'AbsTol', 1e-9);
        end

        function testSetZoomRangeClampsHi(tc)
            tc.RS.SetZoomRange(5, tc.NSteps + 10);
            range = tc.RS.GetZoomRange();
            tc.assertEqual(range(2), tc.NSteps, 'AbsTol', 1e-9);
        end

        function testSetZoomRangeSwapsIfLoGtHi(tc)
            tc.RS.SetZoomRange(15, 5);
            range = tc.RS.GetZoomRange();
            tc.assertEqual(range(1), 5,  'AbsTol', 1e-9);
            tc.assertEqual(range(2), 15, 'AbsTol', 1e-9);
        end

        % ---------------------------------------------------------------- %
        %  Callbacks fire                                                    %
        % ---------------------------------------------------------------- %
        function testOnPositionChangedFiresOnSliderMove(tc)
            fired   = false;
            firedVal = 0;
            fig2 = uifigure('Visible', 'off');
            cleanFig = onCleanup(@() close(fig2));
            rs2 = RangeSlider(fig2, 2, 30, 'Y', ...
                @(v) setFlag(v), @(~,~) []);

            rs2.sliderPos.Value = 12;
            % Manually trigger callback (simulates user interaction)
            rs2.sliderPos.ValueChangedFcn(rs2.sliderPos, ...
                struct('Value', 12, 'PreviousValue', 1, 'Source', rs2.sliderPos, 'EventName', 'ValueChanged'));

            tc.assertTrue(fired,       'onPositionChanged was not called');
            tc.assertEqual(firedVal, 12, 'AbsTol', 1e-9);

            function setFlag(v)
                fired    = true;
                firedVal = v;
            end
        end

        function testOnZoomChangedFiresOnEditChange(tc)
            loFired = 0;
            hiFired = 0;
            fig3 = uifigure('Visible', 'off');
            cleanFig = onCleanup(@() close(fig3));
            rs3 = RangeSlider(fig3, 3, 50, 'Z', ...
                @(~) [], @(lo, hi) captureZoom(lo, hi));

            rs3.editZoomMin.Value = 5;
            rs3.editZoomMax.Value = 40;
            rs3.editZoomMin.ValueChangedFcn(rs3.editZoomMin, ...
                struct('Value', 5, 'PreviousValue', 1, 'Source', rs3.editZoomMin, 'EventName', 'ValueChanged'));

            tc.assertEqual(loFired, 5,  'AbsTol', 1e-9);
            tc.assertEqual(hiFired, 40, 'AbsTol', 1e-9);

            function captureZoom(lo, hi)
                loFired = lo;
                hiFired = hi;
            end
        end

        function testOnPositionChangedFiresOnEditPosChange(tc)
            firedVal = 0;
            fig4 = uifigure('Visible', 'off');
            cleanFig = onCleanup(@() close(fig4));
            rs4 = RangeSlider(fig4, 1, 20, 'W', @(v) capture(v), @(~,~) []);

            rs4.editPos.Value = 7;
            rs4.editPos.ValueChangedFcn(rs4.editPos, ...
                struct('Value', 7, 'PreviousValue', 1, 'Source', rs4.editPos, 'EventName', 'ValueChanged'));

            tc.assertEqual(firedVal, 7, 'AbsTol', 1e-9);

            function capture(v)
                firedVal = v;
            end
        end

        % ---------------------------------------------------------------- %
        %  PlotCheck                                                         %
        % ---------------------------------------------------------------- %
        function testPlotCheckCanBeToggled(tc)
            tc.RS.plotCheck.Value = true;
            tc.assertTrue(tc.RS.GetPlotChecked());
            tc.RS.plotCheck.Value = false;
            tc.assertFalse(tc.RS.GetPlotChecked());
        end

        % ---------------------------------------------------------------- %
        %  Multiple instances are independent                                %
        % ---------------------------------------------------------------- %
        function testTwoInstancesAreIndependent(tc)
            fig5 = uifigure('Visible', 'off');
            cleanFig = onCleanup(@() close(fig5));
            rs5 = RangeSlider(fig5, 2, 10, 'T', @(~) [], @(~,~) []);

            tc.RS.SetValue(5);
            rs5.SetValue(3);

            tc.assertEqual(tc.RS.sliderPos.Value, 5, 'AbsTol', 1e-9);
            tc.assertEqual(rs5.sliderPos.Value,   3, 'AbsTol', 1e-9);
        end

    end % methods (Test)

end
