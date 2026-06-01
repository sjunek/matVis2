classdef parseArgsTest < matlab.unittest.TestCase
    % Unit tests for io/parseArgs.m

    methods (TestClassSetup)
        function addPath(tc) %#ok<MANU>
            addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'io'));
        end
    end

    methods (Test)

        function testBasicCall(tc)
            d = rand(4, 5, 3);
            args = parseArgs(d);
            tc.verifyEqual(args.data, d);
            tc.verifyEqual(args.dimNames, {'Dim1','Dim2','Dim3'});
            tc.verifyEqual(args.dimUnits, {'','',''});
            tc.verifyEqual(numel(args.dimScale), 3);
            tc.verifyEqual(args.dimScale{1}, 1:4);
            tc.verifyEqual(args.dimScale{2}, 1:5);
            tc.verifyEqual(args.dimScale{3}, 1:3);
            tc.verifyEmpty(args.matNames);
            tc.verifyEmpty(args.alphaMap);
            tc.verifyEqual(args.colorBarLabel, '');
            tc.verifyEqual(isstruct(args.startPar), true);
            tc.verifyEqual(args.debug, false);
        end

        function testAllOptionalArgs(tc)
            d = rand(3, 4);
            alpha = rand(3, 4);
            args = parseArgs(d, ...
                'dimNames',      {'X','Y'}, ...
                'dimUnits',      {'px','px'}, ...
                'dimScale',      {0:2, 0:3}, ...
                'matNames',      {'myData'}, ...
                'alphaMap',      alpha, ...
                'colorBarLabel', 'Intensity', ...
                'startPar',      {'gamma', 0.8, 'cmap', 5}, ...
                'debug',         true);
            tc.verifyEqual(args.dimNames, {'X','Y'});
            tc.verifyEqual(args.dimUnits, {'px','px'});
            tc.verifyEqual(args.dimScale{1}, 0:2);
            tc.verifyEqual(args.dimScale{2}, 0:3);
            tc.verifyEqual(args.matNames, {'myData'});
            tc.verifyEqual(args.alphaMap, alpha);
            tc.verifyEqual(args.colorBarLabel, 'Intensity');
            tc.verifyEqual(args.startPar.gamma, 0.8);
            tc.verifyEqual(args.startPar.cmap, 5);
            tc.verifyTrue(args.debug);
        end

        function testInvalidDataNonNumeric(tc)
            tc.verifyError(@() parseArgs({'not numeric'}), 'MATLAB:InputParser:ArgumentFailedValidation');
        end

        function testInvalidDataEmpty(tc)
            tc.verifyError(@() parseArgs([]), 'MATLAB:InputParser:ArgumentFailedValidation');
        end

        function testStartParParsing(tc)
            d = magic(4);
            args = parseArgs(d, 'startPar', {'xySel', 1, 'gamma', 1.2});
            tc.verifyEqual(args.startPar.xySel, 1);
            tc.verifyEqual(args.startPar.gamma, 1.2);
        end

        function testStartParEmpty(tc)
            d = ones(2,2);
            args = parseArgs(d, 'startPar', {});
            tc.verifyTrue(isstruct(args.startPar));
            tc.verifyEqual(fieldnames(args.startPar), cell(0,1));
        end

        function testDimNameDefaulting(tc)
            d = ones(2, 3, 4, 5);
            args = parseArgs(d);
            tc.verifyEqual(args.dimNames, {'Dim1','Dim2','Dim3','Dim4'});
        end

        function testDimNamePartialProvided(tc)
            % Fewer dimNames than ndims — pad with defaults
            d = ones(2, 3, 4);
            args = parseArgs(d, 'dimNames', {'X'});
            tc.verifyEqual(args.dimNames, {'X','Dim2','Dim3'});
        end

        function testDimScaleDefaulting(tc)
            d = ones(2, 5);
            args = parseArgs(d);
            tc.verifyEqual(args.dimScale{1}, 1:2);
            tc.verifyEqual(args.dimScale{2}, 1:5);
        end

        function testDimUnitsDefaulting(tc)
            d = rand(3, 3);
            args = parseArgs(d);
            tc.verifyEqual(args.dimUnits, {'',''});
        end

        function testColorBarLabelString(tc)
            d = rand(2,2);
            args = parseArgs(d, 'colorBarLabel', 'Signal [a.u.]');
            tc.verifyEqual(args.colorBarLabel, 'Signal [a.u.]');
        end

        function testDebugDefault(tc)
            args = parseArgs(ones(3));
            tc.verifyFalse(args.debug);
        end

    end
end
