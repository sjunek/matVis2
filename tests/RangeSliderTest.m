classdef RangeSliderTest < matlab.unittest.TestCase
% RangeSliderTest  Unit tests for ui/RangeSlider.m
%
%   Run with:
%       results = runtests('tests/RangeSliderTest.m');
%
%   RangeSlider is a matlab.ui.componentcontainer.ComponentContainer: it is
%   driven by properties and reports user interaction through events, rather
%   than handing back a struct of handles as the original implementation did.
%
%   Its internal controls are deliberately not reachable -- findall inside
%   the component returns nothing, by design of ComponentContainer -- so
%   these tests exercise the public contract: property round-trips, the
%   defaults the main window relies on, and the rule that pushing state in
%   does not raise events back out.  Driving the spinner and the drag
%   handles needs the real pointer and belongs in an interaction test, not
%   here.

    properties
        Fig
        Grid
        RS
        NSteps
    end

    methods (TestMethodSetup)
        function createFixture(tc)
            tc.NSteps = 20;
            tc.Fig  = uifigure('Visible', 'off');
            tc.Grid = uigridlayout(tc.Fig, [1 1]);
            tc.RS   = RangeSlider(tc.Grid);
            tc.RS.Limits   = [1 tc.NSteps];
            tc.RS.DimLabel = 'X';
        end
    end

    methods (TestMethodTeardown)
        function destroyFixture(tc)
            if isvalid(tc.Fig), delete(tc.Fig); end
        end
    end

    % ------------------------------------------------------------------ %
    %  Construction and defaults                                          %
    % ------------------------------------------------------------------ %
    methods (Test)

        function testIsAComponentContainer(tc)
            tc.verifyClass(tc.RS, 'RangeSlider');
            tc.verifyTrue(isa(tc.RS, ...
                'matlab.ui.componentcontainer.ComponentContainer'));
        end

        function testExposesTheExpectedProperties(tc)
            required = {'Value', 'ZoomMin', 'ZoomMax', 'Limits', 'DimLabel', ...
                        'ShowPlot', 'PlotLock', 'PlayMode', 'IsPlaying', ...
                        'ScaleFactor', 'ScaleUnit', 'RGBIndicatorMode', ...
                        'RGBTriadPos', 'RGBStretchSpan', 'RGBStretchColors'};
            have = properties(tc.RS);
            for k = 1:numel(required)
                tc.verifyTrue(ismember(required{k}, have), ...
                    sprintf('Missing property: %s', required{k}));
            end
        end

        function testExposesTheExpectedCallbacks(tc)
            required = {'ValueChangedFcn', 'ZoomChangedFcn', ...
                        'PlayModeChangedFcn', 'PlotToggledFcn', ...
                        'PlotLockToggledFcn'};
            have = properties(tc.RS);
            for k = 1:numel(required)
                tc.verifyTrue(ismember(required{k}, have), ...
                    sprintf('Missing callback: %s', required{k}));
            end
        end

        function testDefaultPositionIsOne(tc)
            rs = RangeSlider(tc.Grid);
            tc.verifyEqual(rs.Value, 1, 'AbsTol', 1e-9);
        end

        function testDefaultPlotFlagsAreFalse(tc)
            rs = RangeSlider(tc.Grid);
            tc.verifyFalse(rs.ShowPlot);
            tc.verifyFalse(rs.PlotLock);
            tc.verifyFalse(rs.IsPlaying);
        end

        function testDefaultPlayModeIsNone(tc)
            rs = RangeSlider(tc.Grid);
            tc.verifyEqual(rs.PlayMode, 'none');
        end
    end

    % ------------------------------------------------------------------ %
    %  Property round-trips                                               %
    % ------------------------------------------------------------------ %
    methods (Test)

        function testValueRoundTrips(tc)
            tc.RS.Value = 7;
            tc.verifyEqual(tc.RS.Value, 7, 'AbsTol', 1e-9);
        end

        function testZoomRangeRoundTrips(tc)
            tc.RS.ZoomMin = 4;
            tc.RS.ZoomMax = 15;
            tc.verifyEqual([tc.RS.ZoomMin, tc.RS.ZoomMax], [4 15], 'AbsTol', 1e-9);
        end

        function testLabelRoundTrips(tc)
            tc.RS.DimLabel = 'Time';
            tc.verifyEqual(tc.RS.DimLabel, 'Time');
        end

        function testScaleRoundTrips(tc)
            tc.RS.ScaleFactor = 0.25;
            tc.RS.ScaleUnit   = 'um';
            tc.verifyEqual(tc.RS.ScaleFactor, 0.25, 'AbsTol', 1e-12);
            tc.verifyEqual(tc.RS.ScaleUnit, 'um');
        end

        function testPlotFlagsRoundTrip(tc)
            tc.RS.ShowPlot = true;
            tc.RS.PlotLock = true;
            tc.verifyTrue(tc.RS.ShowPlot);
            tc.verifyTrue(tc.RS.PlotLock);
            tc.RS.ShowPlot = false;
            tc.verifyFalse(tc.RS.ShowPlot);
        end

        function testRgbIndicatorRoundTrips(tc)
            tc.RS.RGBIndicatorMode = 'triad';
            tc.RS.RGBTriadPos      = [3 9];
            tc.verifyEqual(tc.RS.RGBIndicatorMode, 'triad');
            tc.verifyEqual(tc.RS.RGBTriadPos, [3 9]);

            tc.RS.RGBIndicatorMode = 'stretch';
            tc.RS.RGBStretchSpan   = [2 11];
            tc.RS.RGBStretchColors = [1 0 0; 0 1 0];
            tc.verifyEqual(tc.RS.RGBStretchSpan, [2 11]);
            tc.verifyEqual(size(tc.RS.RGBStretchColors), [2 3]);
        end
    end

    % ------------------------------------------------------------------ %
    %  Contracts the main window depends on                               %
    % ------------------------------------------------------------------ %
    methods (Test)

        function testPushingStateRaisesNoEvents(tc)
            % The main window writes model state into every slider on each
            % render.  If those writes came back as events the render would
            % re-enter itself, so programmatic assignment must stay silent;
            % only real interaction reports back.
            fired = {};
            lh = [addlistener(tc.RS, 'ValueChanged', @(~,~) note('ValueChanged')), ...
                  addlistener(tc.RS, 'ZoomChanged',  @(~,~) note('ZoomChanged')), ...
                  addlistener(tc.RS, 'PlotToggled',  @(~,~) note('PlotToggled'))];
            cleanup = onCleanup(@() delete(lh)); %#ok<NASGU>

            tc.RS.Value    = 6;
            tc.RS.ZoomMin  = 3;
            tc.RS.ZoomMax  = 12;
            tc.RS.ShowPlot = true;
            drawnow;

            tc.verifyEmpty(fired, sprintf('unexpected event(s): %s', ...
                strjoin(fired, ', ')));

            function note(n), fired{end+1} = n; end %#ok<AGROW>
        end

        function testTwoInstancesAreIndependent(tc)
            rs2 = RangeSlider(tc.Grid);
            rs2.Limits = [1 tc.NSteps];

            tc.RS.Value = 9;   tc.RS.ZoomMin = 2;  tc.RS.ZoomMax = 11;
            rs2.Value   = 4;   rs2.ZoomMin   = 6;  rs2.ZoomMax   = 18;

            tc.verifyEqual(tc.RS.Value, 9, 'AbsTol', 1e-9);
            tc.verifyEqual(rs2.Value,   4, 'AbsTol', 1e-9);
            tc.verifyEqual([tc.RS.ZoomMin tc.RS.ZoomMax], [2 11], 'AbsTol', 1e-9);
            tc.verifyEqual([rs2.ZoomMin   rs2.ZoomMax],   [6 18], 'AbsTol', 1e-9);
        end

        function testLimitsAcceptsAPairOnly(tc)
            tc.verifyError(@() setLimits(tc.RS, [1 2 3]), ...
                'MATLAB:validation:IncompatibleSize');
        end

        function testSurvivesRepeatedUpdates(tc)
            % Every render pushes new state; doing it many times must not
            % leak handles or throw.
            for k = 1:25
                tc.RS.Value   = mod(k, tc.NSteps) + 1;
                tc.RS.ZoomMin = 1;
                tc.RS.ZoomMax = tc.NSteps;
            end
            drawnow;
            tc.verifyTrue(isvalid(tc.RS));
            tc.verifyEqual(tc.RS.Value, mod(25, tc.NSteps) + 1, 'AbsTol', 1e-9);
        end
    end
end

% ------------------------------------------------------------------
function setLimits(rs, v), rs.Limits = v; end
